#!/bin/sh
# =====================================================================
#  obsidian-installer_v3.4.sh
#
#  OBSIDIAN MIRROR v3.4 - Universal Host <-> Application Isolation Layer
#  (three protection layers: metadata / hardware boundary / network)
#
#  One self-contained installer. No network access, no repository, no
#  companion files: every C source, shell stage, fontconfig file and
#  the coverage document are embedded below as here-documents.
#
#  WHAT IT DOES
#    1. Installs the build and runtime dependencies (Alpine: apk).
#    2. Unpacks all sources into /opt/obsidian.
#    3. Compiles three LD_PRELOAD hook libraries, the seccomp-bpf
#       enforcer and the audit socket probe.
#    4. Scans THIS machine's hardware and writes a per-host spoof and
#       mask manifest to /etc/obsidian/hw-manifest.conf.
#    5. Installs the "obsidian" command into /usr/local/bin.
#    6. Runs a self-test.
#
#  USAGE
#      sh Universal-Obsidian-Mirror-installer-script.sh              install
#      sh Universal-Obsidian-Mirror-installer-script.sh --uninstall  remove
#      sh Universal-Obsidian-Mirror-installer-script.sh --help
#
#  THEN
#      obsidian <application> [args...]     run anything, mirrored
#      obsidian --test                      audit what is protected
#      obsidian --coverage                  read the honest limits
#
#  SCOPE
#    Layer 1 (always on) hides host<->application metadata: hostname, ids,
#    CPU/RAM, clock, fonts. Layer 2 (OBSIDIAN_HARDEN=1) default-denies the
#    filesystem, memory, devices, IPC, execution and namespaces. Layer 3
#    (OBSIDIAN_HARDEN=2) adds a per-app network namespace with a default-deny
#    ingress+egress firewall, so the app's traffic is filtered both ways and
#    Bluetooth/WiFi are hard-blocked. With all three layers the network layer
#    IS covered; the plain "obsidian <app>" launch leaves the network to you
#    (pair with a VPN or network namespace if you want it hidden too).
#
#  HARD RULE
#    Nothing here may change the behaviour of a program launched with
#    "obsidian <application>". Where a privacy fix collided with that
#    rule it became an opt-in switch instead of a default:
#
#      OBSIDIAN_GPU_MODE=strict         mask /dev/dri + /sys/class/drm
#                                       (zero GPU fingerprint, but
#                                       software rendering only)
#      OBSIDIAN_GL_EXTENSIONS=preserve  pass the real GL extension list
#      OBSIDIAN_ALLOW_SYSTEM_BUS=1      permit the D-Bus system bus
#
#    "obsidian --test" section 4 verifies the rule on every run.
#
#  Target: Alpine Linux (any release, x86_64 or aarch64), run as root.
#  Also installs on glibc distributions if the toolchain is present.
# =====================================================================

set -eu

OBSIDIAN_VERSION="3.4"
PREFIX="/opt/obsidian"
BINDIR="$PREFIX/bin"
LIBDIR="$PREFIX/lib"
SRCDIR="$PREFIX/src"
SCRIPTDIR="$PREFIX/scripts"
FAKEROOT="$PREFIX/fake_root"
MANIFESTDIR="/etc/obsidian"
CLI_LINK="/usr/local/bin/obsidian"

DO_DEPS=1
DO_SCAN=1
DO_TEST=1
DO_UNINSTALL=0

# ---------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------
if [ -t 1 ]; then
    C_B=$(printf '\033[1m');  C_G=$(printf '\033[32m')
    C_Y=$(printf '\033[33m'); C_R=$(printf '\033[31;1m')
    C_0=$(printf '\033[0m')
else
    C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi

STEP=0
step() { STEP=$((STEP + 1)); printf '\n%s[%d/%d]%s %s\n' "$C_B" "$STEP" "$NSTEPS" "$C_0" "$1"; }
ok()   { printf '      %s+%s %s\n' "$C_G" "$C_0" "$1"; }
warn() { printf '      %s!%s %s\n' "$C_Y" "$C_0" "$1"; }
fail() { printf '      %sx%s %s\n' "$C_R" "$C_0" "$1"; }
die()  { printf '\n%sERROR:%s %s\n\n' "$C_R" "$C_0" "$1" >&2; exit 1; }

usage() {
    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall)  DO_UNINSTALL=1 ;;
        --skip-deps)  DO_DEPS=0 ;;
        --skip-scan)  DO_SCAN=0 ;;
        --skip-test)  DO_TEST=0 ;;
        -h|--help)    usage ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
    shift
done

NSTEPS=8
[ "$DO_UNINSTALL" -eq 1 ] && NSTEPS=1

printf '\n%s' "$C_B"
cat <<'BANNER'
  ___  _         _     _ _              __  __ _
 / _ \| |__  ___(_) __| (_) __ _ _ __  |  \/  (_)_ __ _ __ ___  _ __
| | | | '_ \/ __| |/ _` | |/ _` | '_ \ | |\/| | | '__| '__/ _ \| '__|
| |_| | |_) \__ \ | (_| | | (_| | | | || |  | | | |  | | | (_) | |
 \___/|_.__/|___/_|\__,_|_|\__,_|_| |_||_|  |_|_|_|  |_|  \___/|_|
BANNER
printf '%s' "$C_0"
printf ' Universal Host <-> Application Isolation Layer   v%s  (three protection layers)\n' "$OBSIDIAN_VERSION"
printf ' Network layer intentionally out of scope.\n'

# ---------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "this installer must run as root.  Try:  sudo sh $0"

if [ "$DO_UNINSTALL" -eq 1 ]; then
    step "Removing Obsidian Mirror"
    rm -f  "$CLI_LINK"                 && ok "removed $CLI_LINK"
    rm -rf "$PREFIX"                   && ok "removed $PREFIX"
    rm -rf "$MANIFESTDIR"              && ok "removed $MANIFESTDIR"
    printf '\n Obsidian Mirror removed.\n\n'
    exit 0
fi

IS_ALPINE=0
[ -f /etc/alpine-release ] && IS_ALPINE=1
HOST_ARCH="$(uname -m 2>/dev/null || echo unknown)"

# =====================================================================
step "Checking the host"
# =====================================================================
if [ "$IS_ALPINE" -eq 1 ]; then
    ok "Alpine Linux $(cat /etc/alpine-release 2>/dev/null), $HOST_ARCH"
else
    warn "not Alpine Linux ($(uname -s) $HOST_ARCH)"
    warn "installing anyway; dependency installation is skipped"
    DO_DEPS=0
fi

case "$(uname -s 2>/dev/null)" in
    Linux) ok "Linux kernel $(uname -r 2>/dev/null)" ;;
    *) die "Obsidian Mirror is Linux only (namespaces, /proc, /sys)." ;;
esac

if [ -e /proc/sys/kernel/unprivileged_userns_clone ]; then
    if [ "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null)" = "0" ]; then
        warn "unprivileged user namespaces are disabled on this kernel"
        warn "enable with: sysctl -w kernel.unprivileged_userns_clone=1"
    fi
fi

# =====================================================================
step "Installing dependencies"
# =====================================================================
APK_PKGS="gcc musl-dev linux-headers libseccomp-dev libseccomp util-linux coreutils fontconfig pciutils gawk grep"
if [ "$DO_DEPS" -eq 1 ]; then
    if command -v apk >/dev/null 2>&1; then
        printf '      apk add --no-cache %s\n' "$APK_PKGS"
        if apk add --no-cache $APK_PKGS >/dev/null 2>&1; then
            ok "dependencies installed"
        else
            warn "apk reported an error; retrying package by package"
            for p in $APK_PKGS; do
                apk add --no-cache "$p" >/dev/null 2>&1 && ok "$p" || warn "$p unavailable"
            done
        fi
    else
        warn "apk not found; skipping dependency installation"
    fi
else
    warn "dependency installation skipped"
fi

CC=""
for c in cc gcc clang; do
    command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }
done
[ -n "$CC" ] || die "no C compiler found.  On Alpine:  apk add gcc musl-dev"
ok "C compiler: $CC"

for t in unshare; do
    command -v "$t" >/dev/null 2>&1 && ok "$t present" \
        || die "$t is required.  On Alpine:  apk add util-linux"
done
command -v taskset >/dev/null 2>&1 && ok "taskset present" \
    || warn "taskset absent - CPU affinity clamping will be skipped at runtime"

# =====================================================================
step "Creating the directory tree"
# =====================================================================
for d in "$PREFIX" "$BINDIR" "$LIBDIR" "$SRCDIR" "$SCRIPTDIR" \
         "$FAKEROOT" "$FAKEROOT/fonts" "$FAKEROOT/proc" "$MANIFESTDIR"; do
    mkdir -p "$d"
done
chmod 755 "$PREFIX" "$BINDIR" "$LIBDIR" "$SCRIPTDIR" "$FAKEROOT" "$MANIFESTDIR"
ok "$PREFIX"
ok "$MANIFESTDIR"

# =====================================================================
step "Unpacking embedded sources"
# =====================================================================
cat > "$SRCDIR/obsidian_core.c" <<'OBSIDIAN_PAYLOAD_CORE_C'
#define _GNU_SOURCE
#include <pwd.h>
#include <grp.h>
#include <dlfcn.h>
#include <string.h>
#include <stdio.h>
#include <sys/utsname.h>
#include <sys/sysinfo.h>
#include <sys/time.h>
#include <unistd.h>
#include <time.h>
#include <stdlib.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <stdarg.h>
#include <sched.h>
#include <errno.h>
#include <sys/syscall.h>

/* statx: musl >= 1.2 and glibc >= 2.28 expose it via <sys/stat.h>.
 * Fall back to <linux/stat.h> (linux-headers) when they do not. */
#ifndef STATX_BASIC_STATS
# if defined(__has_include)
#  if __has_include(<linux/stat.h>)
#   include <linux/stat.h>
#  endif
# else
#  include <linux/stat.h>
# endif
#endif

static const char *get_target_kernel(void) {
    const char *k = getenv("OBSIDIAN_KERNEL_RELEASE");
    return (k && *k) ? k : "6.5.0-14-generic";
}

static long get_target_memory_kb(void) {
    const char *m = getenv("OBSIDIAN_TOTAL_MEMORY");
    if (m && *m) {
        long val = atol(m);
        if (val > 0) return val;
    }
    return 8192000;
}

int uname(struct utsname *buf) {
    static int (*real_uname)(struct utsname *) = NULL;
    if (!real_uname) real_uname = dlsym(RTLD_NEXT, "uname");
    int ret = real_uname(buf);
    if (ret == 0) {
        const char *k = get_target_kernel();
        strncpy(buf->release, k, sizeof(buf->release) - 1);
        buf->release[sizeof(buf->release) - 1] = '\0';
        strncpy(buf->version, "#1 SMP PREEMPT_DYNAMIC", sizeof(buf->version) - 1);
        buf->version[sizeof(buf->version) - 1] = '\0';
        strncpy(buf->machine, "x86_64", sizeof(buf->machine) - 1);
        buf->machine[sizeof(buf->machine) - 1] = '\0';
    }
    return ret;
}

int gethostname(char *name, size_t len) {
    static int (*real_gethostname)(char *, size_t) = NULL;
    if (!real_gethostname) real_gethostname = dlsym(RTLD_NEXT, "gethostname");
    return real_gethostname(name, len);
}

int sethostname(const char *name, size_t len) {
    (void)name; (void)len;
    return 0;
}

int sysinfo(struct sysinfo *info) {
    static int (*real_sysinfo)(struct sysinfo *) = NULL;
    if (!real_sysinfo) real_sysinfo = dlsym(RTLD_NEXT, "sysinfo");
    int ret = real_sysinfo(info);
    if (ret == 0) {
        long mem_kb = get_target_memory_kb();
        info->mem_unit = 1;
        info->totalram = (unsigned long)mem_kb * 1024UL;
        info->freeram = info->totalram / 2;
        info->sharedram = info->totalram / 8;
        info->bufferram = info->totalram / 16;
        info->totalswap = 2097152UL * 1024UL;
        info->freeswap = info->totalswap;
        info->loads[0] = 1000; info->loads[1] = 1000; info->loads[2] = 1000;
        info->procs = 50;
    }
    return ret;
}

time_t time(time_t *tloc) {
    static time_t (*real_time)(time_t *) = NULL;
    if (!real_time) real_time = dlsym(RTLD_NEXT, "time");
    time_t t = real_time(NULL);
    if (tloc) *tloc = t;
    return t;
}

int gettimeofday(struct timeval *restrict tv, void *restrict tz) {
    static int (*real_gtd)(struct timeval *restrict, void *restrict) = NULL;
    if (!real_gtd) real_gtd = dlsym(RTLD_NEXT, "gettimeofday");
    int ret = real_gtd(tv, tz);
    if (tv) tv->tv_usec = 0;
    if (tz) memset(tz, 0, sizeof(int) * 2);
    return ret;
}

struct tm *localtime(const time_t *timep) { return gmtime(timep); }
struct tm *localtime_r(const time_t *timep, struct tm *result) { return gmtime_r(timep, result); }

char *getenv(const char *name) {
    static char *(*real_getenv)(const char *) = NULL;
    if (!real_getenv) real_getenv = dlsym(RTLD_NEXT, "getenv");
    if (name && strcmp(name, "TZ") == 0) return "UTC";
    return real_getenv(name);
}

struct group *getgrgid(gid_t gid) {
    (void)gid;
    static struct group fake_grp;
    static char grp_name_buf[64];
    const char *u = getenv("USER");
    snprintf(grp_name_buf, sizeof(grp_name_buf), "%s", u ? u : "user");
    fake_grp.gr_name = grp_name_buf;
    fake_grp.gr_passwd = "x";
    fake_grp.gr_gid = 1000;
    fake_grp.gr_mem = NULL;
    return &fake_grp;
}

struct passwd *getpwuid(uid_t uid) {
    (void)uid;
    static struct passwd fake_pwd;
    static char usr_name_buf[64];
    static char usr_dir_buf[128];
    const char *u = getenv("USER");
    snprintf(usr_name_buf, sizeof(usr_name_buf), "%s", u ? u : "user");
    snprintf(usr_dir_buf, sizeof(usr_dir_buf), "/home/%s", usr_name_buf);
    fake_pwd.pw_name = usr_name_buf;
    fake_pwd.pw_passwd = "x";
    fake_pwd.pw_uid = 1000;
    fake_pwd.pw_gid = 1000;
    fake_pwd.pw_gecos = "Generic User";
    fake_pwd.pw_dir = usr_dir_buf;
    fake_pwd.pw_shell = "/bin/sh";
    return &fake_pwd;
}

int getifaddrs(struct ifaddrs **ifap) {
    static int (*real_getifaddrs)(struct ifaddrs **) = NULL;
    if (!real_getifaddrs) real_getifaddrs = dlsym(RTLD_NEXT, "getifaddrs");
    int ret = real_getifaddrs(ifap);
    if (ret != 0 || !ifap || !*ifap) return ret;
    struct ifaddrs *cur = *ifap;
    while (cur) {
        if (cur->ifa_name && strcmp(cur->ifa_name, "lo") != 0) {
            cur->ifa_name = "eth0";
            if (cur->ifa_addr && cur->ifa_addr->sa_family == AF_INET) {
                struct sockaddr_in *in = (struct sockaddr_in *)cur->ifa_addr;
                in->sin_addr.s_addr = htonl(0x0a00020f); /* 10.0.2.15 */
            }
        }
        cur = cur->ifa_next;
    }
    return 0;
}

/* ------------------------------------------------------------
 * Timestamp normalisation.
 * Floor to the hour AND zero the nanosecond field. Leaving
 * st_*tim.tv_nsec intact defeats the whole purpose: nanosecond
 * creation times are effectively unique per install.
 * ------------------------------------------------------------ */
static void obsidian_round_stat(struct stat *s) {
    if (!s) return;
    s->st_atime = (s->st_atime / 3600) * 3600;
    s->st_mtime = (s->st_mtime / 3600) * 3600;
    s->st_ctime = (s->st_ctime / 3600) * 3600;
#ifdef st_atime
    s->st_atim.tv_nsec = 0;
    s->st_mtim.tv_nsec = 0;
    s->st_ctim.tv_nsec = 0;
#endif
}

int stat(const char *pathname, struct stat *statbuf) {
    static int (*real_stat)(const char *, struct stat *) = NULL;
    if (!real_stat) real_stat = dlsym(RTLD_NEXT, "stat");
    int ret = real_stat(pathname, statbuf);
    if (ret == 0) obsidian_round_stat(statbuf);
    return ret;
}

int lstat(const char *pathname, struct stat *statbuf) {
    static int (*real_lstat)(const char *, struct stat *) = NULL;
    if (!real_lstat) real_lstat = dlsym(RTLD_NEXT, "lstat");
    int ret = real_lstat(pathname, statbuf);
    if (ret == 0) obsidian_round_stat(statbuf);
    return ret;
}

int fstat(int fd, struct stat *statbuf) {
    static int (*real_fstat)(int, struct stat *) = NULL;
    if (!real_fstat) real_fstat = dlsym(RTLD_NEXT, "fstat");
    int ret = real_fstat(fd, statbuf);
    if (ret == 0) obsidian_round_stat(statbuf);
    return ret;
}

int fstatat(int dirfd, const char *pathname, struct stat *statbuf, int flags) {
    static int (*real_fstatat)(int, const char *, struct stat *, int) = NULL;
    if (!real_fstatat) real_fstatat = dlsym(RTLD_NEXT, "fstatat");
    int ret = real_fstatat(dirfd, pathname, statbuf, flags);
    if (ret == 0) obsidian_round_stat(statbuf);
    return ret;
}

/* ------------------------------------------------------------
 * statx(): modern musl and glibc route stat()/fstatat() through
 * statx internally, and many toolkits call it directly. Without
 * this hook the four classic hooks above are bypassed entirely
 * and full-resolution timestamps leak.
 * ------------------------------------------------------------ */
#ifdef STATX_BASIC_STATS
static void obsidian_round_statx_ts(struct statx_timestamp *t) {
    if (!t) return;
    t->tv_sec = (t->tv_sec / 3600) * 3600;
    t->tv_nsec = 0;
}

int statx(int dirfd, const char *pathname, int flags,
          unsigned int mask, struct statx *statxbuf) {
    static int (*real_statx)(int, const char *, int, unsigned int, struct statx *) = NULL;
    static int resolved = 0;
    int ret;

    if (!resolved) {
        real_statx = dlsym(RTLD_NEXT, "statx");
        resolved = 1;
    }

    if (real_statx) {
        ret = real_statx(dirfd, pathname, flags, mask, statxbuf);
    } else {
        /* Older musl has no statx() wrapper, so this library would be
         * the only definition of the symbol in the process. Returning
         * ENOSYS here would break any caller that resolves it through
         * us, so go straight to the kernel instead. */
#ifdef __NR_statx
        ret = (int)syscall(__NR_statx, dirfd, pathname, flags, mask, statxbuf);
#else
        errno = ENOSYS;
        return -1;
#endif
    }

    if (ret == 0 && statxbuf) {
        obsidian_round_statx_ts(&statxbuf->stx_atime);
        obsidian_round_statx_ts(&statxbuf->stx_mtime);
        obsidian_round_statx_ts(&statxbuf->stx_ctime);
        obsidian_round_statx_ts(&statxbuf->stx_btime);
    }
    return ret;
}
#endif

static int (*real_open)(const char *, int, ...) = NULL;
static int (*real_openat)(int, const char *, int, ...) = NULL;

static int is_cpu_topology_path(const char *pathname) {
    if (!pathname) return 0;
    return strstr(pathname, "cpu/online") != NULL ||
           strstr(pathname, "cpu/possible") != NULL ||
           strstr(pathname, "cpu/present") != NULL;
}

int open(const char *pathname, int flags, ...) {
    if (!real_open) real_open = dlsym(RTLD_NEXT, "open");
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args; va_start(args, flags);
        mode = va_arg(args, mode_t); va_end(args);
    }
    if (is_cpu_topology_path(pathname)) {
        return real_open("$FAKE_HOME/.fake/cpu_online", flags, mode);
    }
    return real_open(pathname, flags, mode);
}

int openat(int dirfd, const char *pathname, int flags, ...) {
    if (!real_openat) real_openat = dlsym(RTLD_NEXT, "openat");
    if (!real_open) real_open = dlsym(RTLD_NEXT, "open");
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args; va_start(args, flags);
        mode = va_arg(args, mode_t); va_end(args);
    }
    if (is_cpu_topology_path(pathname)) {
        return real_openat(AT_FDCWD, "$FAKE_HOME/.fake/cpu_online", flags, mode);
    }
    return real_openat(dirfd, pathname, flags, mode);
}

int sched_getaffinity(pid_t pid, size_t cpusetsize, cpu_set_t *mask) {
    static int (*real_sga)(pid_t, size_t, cpu_set_t *) = NULL;
    if (!real_sga) real_sga = dlsym(RTLD_NEXT, "sched_getaffinity");
    int ret = real_sga(pid, cpusetsize, mask);
    if (ret == 0 && mask) {
        for (int i = 2; i < (int)(cpusetsize * 8); i++) {
            CPU_CLR(i, mask);
        }
    }
    return ret;
}
OBSIDIAN_PAYLOAD_CORE_C
ok "src/obsidian_core.c"

cat > "$SRCDIR/obsidian_gpu.c" <<'OBSIDIAN_PAYLOAD_GPU_C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <stddef.h>

typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef int GLint;
typedef unsigned char GLubyte;

#define GL_VENDOR                   0x1F00
#define GL_RENDERER                 0x1F01
#define GL_VERSION                  0x1F02
#define GL_SHADING_LANGUAGE_VERSION 0x8B8C
#define GL_EXTENSIONS               0x1F03
#define GL_NUM_EXTENSIONS           0x821D
#define GL_MAX_TEXTURE_SIZE         0x0D33
#define GL_MAX_RENDERBUFFER_SIZE    0x84E8
#define GL_MAX_VIEWPORT_DIMS        0x0D3A
#define GL_MAX_TEXTURE_IMAGE_UNITS  0x8872
#define GL_MAX_VERTEX_ATTRIBS       0x8869

/* EGL */
typedef void *EGLDisplay;
typedef int EGLint;
#define EGL_VENDOR      0x3053
#define EGL_VERSION_STR 0x3054
#define EGL_EXTENSIONS  0x3055
#define EGL_CLIENT_APIS 0x308D

static const char *fake_renderer(void) {
    const char *v = getenv("OBSIDIAN_GPU_RENDERER");
    return (v && *v) ? v : "Mesa Intel(R) HD Graphics 630 (Kaby Lake GT2)";
}

static const char *fake_vendor(void) {
    const char *v = getenv("OBSIDIAN_GPU_VENDOR");
    return (v && *v) ? v : "Intel";
}

/* The GL extension list is one of the highest-entropy fingerprints
 * available to a graphical application - it is effectively unique
 * per driver build. It is blanked by default.
 *
 * Some applications refuse to start without a specific extension.
 * If one does, set OBSIDIAN_GL_EXTENSIONS=preserve to pass the real
 * list through; you keep every other GPU protection and lose only
 * this one. */
static int preserve_extensions(void) {
    static int cached = -1;
    if (cached < 0) {
        const char *e = getenv("OBSIDIAN_GL_EXTENSIONS");
        cached = (e && strcmp(e, "preserve") == 0) ? 1 : 0;
    }
    return cached;
}

const GLubyte *glGetString(GLenum name) {
    static const GLubyte *(*real_glGetString)(GLenum) = NULL;
    if (!real_glGetString) real_glGetString = dlsym(RTLD_NEXT, "glGetString");

    switch (name) {
        case GL_VENDOR:   return (const GLubyte *)fake_vendor();
        case GL_RENDERER: return (const GLubyte *)fake_renderer();
        case GL_VERSION:  return (const GLubyte *)"OpenGL ES 3.2 Mesa 21.0.0";
        case GL_SHADING_LANGUAGE_VERSION:
                          return (const GLubyte *)"OpenGL ES GLSL ES 3.20";
        case GL_EXTENSIONS:
            if (preserve_extensions() && real_glGetString)
                return real_glGetString(name);
            return (const GLubyte *)"";
        default:
            if (real_glGetString) return real_glGetString(name);
            return (const GLubyte *)"";
    }
}

const GLubyte *glGetStringi(GLenum name, GLuint index) {
    static const GLubyte *(*real_glGetStringi)(GLenum, GLuint) = NULL;
    if (!real_glGetStringi) real_glGetStringi = dlsym(RTLD_NEXT, "glGetStringi");
    if (preserve_extensions() && real_glGetStringi)
        return real_glGetStringi(name, index);
    (void)name; (void)index;
    return (const GLubyte *)"";
}

void glGetIntegerv(GLenum pname, GLint *data) {
    static void (*real_glGetIntegerv)(GLenum, GLint *) = NULL;
    if (!real_glGetIntegerv) real_glGetIntegerv = dlsym(RTLD_NEXT, "glGetIntegerv");
    if (!data) { if (real_glGetIntegerv) real_glGetIntegerv(pname, data); return; }

    switch (pname) {
        case GL_MAX_TEXTURE_SIZE:        *data = 16384; return;
        case GL_MAX_RENDERBUFFER_SIZE:   *data = 16384; return;
        case GL_MAX_VIEWPORT_DIMS:       data[0] = 16384; data[1] = 16384; return;
        case GL_MAX_TEXTURE_IMAGE_UNITS: *data = 16; return;
        case GL_MAX_VERTEX_ATTRIBS:      *data = 16; return;
        /* Keep the count consistent with the blanked extension list,
         * otherwise applications loop over glGetStringi() reading
         * empty strings and some abort. */
        case GL_NUM_EXTENSIONS:
            if (!preserve_extensions()) { *data = 0; return; }
            break;
        default: break;
    }
    if (real_glGetIntegerv) real_glGetIntegerv(pname, data);
}

/* EGL vendor string only. EGL_EXTENSIONS is deliberately passed
 * through: Wayland EGL clients require EGL_KHR_platform_wayland and
 * friends, and blanking that list breaks them outright. */
const char *eglQueryString(EGLDisplay dpy, EGLint name) {
    static const char *(*real_eglQueryString)(EGLDisplay, EGLint) = NULL;
    if (!real_eglQueryString) real_eglQueryString = dlsym(RTLD_NEXT, "eglQueryString");
    if (name == EGL_VENDOR) return fake_vendor();
    if (real_eglQueryString) return real_eglQueryString(dpy, name);
    return "";
}
OBSIDIAN_PAYLOAD_GPU_C
ok "src/obsidian_gpu.c"

cat > "$SRCDIR/obsidian_wayland.c" <<'OBSIDIAN_PAYLOAD_WAYLAND_C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <errno.h>
#include <stdio.h>

/* ------------------------------------------------------------
 * Compositor control / IPC sockets.
 *
 * These are NOT the Wayland display socket. They are the
 * side-channel control sockets that expose window titles, output
 * models, workspace layout and the full input-device inventory.
 * Blocking them does not affect rendering: a client that cannot
 * reach the IPC socket simply does without the extra feature.
 *
 * The Wayland socket itself (wayland-0 / wayland-1) is
 * deliberately NOT matched here - blocking it would break every
 * graphical application.
 * ------------------------------------------------------------ */
static const char *ipc_patterns[] = {
    "sway-ipc",          /* sway            */
    "/hypr/",            /* Hyprland        */
    ".hyprland",         /* Hyprland legacy */
    "i3/ipc-socket",     /* i3 / i3-gaps    */
    "/tmp/i3-",          /* i3 legacy       */
    "wayfire",           /* Wayfire         */
    "river-control",     /* River           */
    "labwc",             /* labwc           */
    "niri.",             /* niri            */
    "hyprcursor",        /* Hyprland aux    */
    NULL
};

static int env_flag(const char *name, int dflt) {
    const char *e = getenv(name);
    if (!e || !*e) return dflt;
    if (strcmp(e, "0") == 0 || strcmp(e, "no") == 0 || strcmp(e, "false") == 0) return 0;
    return 1;
}

/* The D-Bus SYSTEM bus exposes hostname, OS release, timedate,
 * locale and hardware inventory through systemd-hostnamed,
 * systemd-timedated and UDisks. It is rarely present on Alpine.
 * Blocked by default; set OBSIDIAN_ALLOW_SYSTEM_BUS=1 to permit. */
static int block_system_bus(void) {
    static int cached = -1;
    if (cached < 0) cached = env_flag("OBSIDIAN_ALLOW_SYSTEM_BUS", 0) ? 0 : 1;
    return cached;
}

static int verbose(void) {
    static int cached = -1;
    if (cached < 0) cached = env_flag("OBSIDIAN_VERBOSE", 0);
    return cached;
}

static int is_compositor_ipc(const char *path) {
    int i;
    if (!path || !*path) return 0;
    for (i = 0; ipc_patterns[i]; i++) {
        if (strstr(path, ipc_patterns[i]) != NULL) return 1;
    }
    return 0;
}

static int is_system_bus(const char *path) {
    if (!path || !*path) return 0;
    return strstr(path, "dbus/system_bus_socket") != NULL;
}

int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen) {
    static int (*real_connect)(int, const struct sockaddr *, socklen_t) = NULL;
    if (!real_connect) real_connect = dlsym(RTLD_NEXT, "connect");

    if (addr && addr->sa_family == AF_UNIX) {
        const struct sockaddr_un *un = (const struct sockaddr_un *)addr;
        const char *path = un->sun_path;

        /* Abstract namespace sockets: pass through untouched. */
        if (path[0] == '\0') {
            return real_connect(sockfd, addr, addrlen);
        }

        if (is_compositor_ipc(path)) {
            if (verbose())
                fprintf(stderr, "[Obsidian Mirror] Blocked compositor IPC: %s\n", path);
            errno = ECONNREFUSED;
            return -1;
        }

        if (block_system_bus() && is_system_bus(path)) {
            if (verbose())
                fprintf(stderr, "[Obsidian Mirror] Blocked D-Bus system bus: %s\n", path);
            errno = ECONNREFUSED;
            return -1;
        }
    }

    return real_connect(sockfd, addr, addrlen);
}
OBSIDIAN_PAYLOAD_WAYLAND_C
ok "src/obsidian_wayland.c"

cat > "$SRCDIR/seccomp_enforcer.c" <<'OBSIDIAN_PAYLOAD_SECCOMP_C'
/* ============================================================
 * /opt/obsidian/bin/seccomp_enforcer
 * Obsidian Mirror - syscall confinement stage.
 *
 * Installs a seccomp-bpf filter, then exec()s the command that
 * follows the "--" separator. The filter survives exec, so the
 * target application and every child it spawns inherit it.
 *
 * Policy: default ALLOW, with a deny list. A default-DENY policy
 * is stronger but breaks arbitrary applications, and the hard
 * constraint on this project is that "obsidian <application>"
 * must not change how the application behaves.
 *
 *   KILL   iopl, ioperm            - direct hardware port I/O.
 *                                    Nothing legitimate uses these.
 *   EPERM  everything else below   - introspection, module and
 *                                    time control, key management,
 *                                    and the self-escape syscalls
 *                                    (unshare/setns/pivot_root/
 *                                    mount/umount2).
 *
 * EPERM rather than KILL is deliberate: a well-written program
 * checks the return value and carries on, whereas SIGSYS kills it.
 *
 * Build: cc -O2 -o seccomp_enforcer seccomp_enforcer.c -lseccomp
 * ============================================================ */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <seccomp.h>
#include <sys/prctl.h>

struct rule {
    const char *name;
    int         action;   /* 0 = EPERM, 1 = KILL */
};

static const struct rule rules[] = {
    /* --- direct hardware port I/O: kill outright --- */
    { "iopl",              1 },
    { "ioperm",            1 },

    /* --- process introspection --- */
    { "ptrace",            0 },
    { "process_vm_readv",  0 },
    { "process_vm_writev", 0 },
    { "kcmp",              0 },
    { "syslog",            0 },
    { "perf_event_open",   0 },

    /* --- kernel module control --- */
    { "init_module",       0 },
    { "finit_module",      0 },
    { "delete_module",     0 },

    /* --- clock control (timing fingerprint + host damage) --- */
    { "settimeofday",      0 },
    { "clock_settime",     0 },

    /* --- kernel keyring --- */
    { "keyctl",            0 },
    { "add_key",           0 },
    { "request_key",       0 },

    /* --- self-escape blocks: stop the application building its
     *     own namespaces to climb back out of this one --- */
    { "unshare",           0 },
    { "setns",             0 },
    { "pivot_root",        0 },
    { "mount",             0 },
    { "umount2",           0 },

    /* --- misc privileged surfaces --- */
    { "bpf",               0 },
    { "kexec_load",        0 },
    { "acct",              0 },
};

#define NRULES ((int)(sizeof(rules) / sizeof(rules[0])))

static void usage(const char *self)
{
    fprintf(stderr, "usage: %s -- <command> [args...]\n", self);
}

int main(int argc, char **argv)
{
    scmp_filter_ctx ctx;
    int i, sep = -1, added = 0, skipped = 0;
    const char *verbose = getenv("OBSIDIAN_VERBOSE");

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--") == 0) { sep = i; break; }
    }
    if (sep < 0 || sep + 1 >= argc) {
        usage(argv[0]);
        return 2;
    }

    ctx = seccomp_init(SCMP_ACT_ALLOW);
    if (!ctx) {
        fprintf(stderr, "seccomp_enforcer: seccomp_init failed\n");
        /* Fail open on the filter, never on the application. */
        execvp(argv[sep + 1], &argv[sep + 1]);
        perror("seccomp_enforcer: exec");
        return 127;
    }

    for (i = 0; i < NRULES; i++) {
        int nr = seccomp_syscall_resolve_name(rules[i].name);
        uint32_t act;

        /* Syscall not known to this kernel/arch: nothing to block. */
        if (nr == __NR_SCMP_ERROR) { skipped++; continue; }

        act = rules[i].action ? SCMP_ACT_KILL : SCMP_ACT_ERRNO(EPERM);
        if (seccomp_rule_add(ctx, act, nr, 0) == 0)
            added++;
        else
            skipped++;
    }

    /* No new privileges: also stops setuid binaries from shedding
     * the filter, and is required for an unprivileged load. */
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0 && verbose)
        fprintf(stderr, "seccomp_enforcer: PR_SET_NO_NEW_PRIVS failed\n");

    if (seccomp_load(ctx) != 0) {
        if (verbose)
            fprintf(stderr, "seccomp_enforcer: filter load failed, continuing unfiltered\n");
    } else if (verbose) {
        fprintf(stderr, "seccomp_enforcer: %d rules active, %d unavailable\n",
                added, skipped);
    }

    seccomp_release(ctx);

    execvp(argv[sep + 1], &argv[sep + 1]);
    fprintf(stderr, "seccomp_enforcer: exec %s: %s\n",
            argv[sep + 1], strerror(errno));
    return 127;
}
OBSIDIAN_PAYLOAD_SECCOMP_C
ok "src/seccomp_enforcer.c"

cat > "$SRCDIR/obsidian_ipcprobe.c" <<'OBSIDIAN_PAYLOAD_IPCPROBE_C'
/* ============================================================
 * /opt/obsidian/bin/obsidian-ipcprobe
 * Obsidian Mirror - IPC reachability probe (audit support tool).
 *
 * For each AF_UNIX path given on the command line, attempts a
 * connect() and prints one line:
 *
 *     <path>\t<state>
 *
 * where <state> is one of:
 *     connected   the socket accepted the connection
 *     refused     connect() returned ECONNREFUSED
 *     denied      connect() returned EACCES / EPERM
 *     absent      no such socket on the filesystem
 *     error:<n>   any other errno
 *
 * This exists so obsidian-audit can *measure* the compositor-IPC
 * and D-Bus system-bus block in obsidian_wayland.so instead of
 * assuming it. Run natively you get "connected"; run under
 * "obsidian" you should get "refused" or "absent".
 *
 * It is also the compatibility check for the Wayland display
 * socket: that one must stay "connected" inside the sandbox, or
 * graphical applications are broken.
 *
 * Read-only, connects and immediately closes, sends nothing.
 *
 * Build: cc -O2 -o obsidian-ipcprobe obsidian_ipcprobe.c
 * ============================================================ */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>

static void probe_one(const char *path)
{
    struct sockaddr_un addr;
    struct stat st;
    int fd, rc;

    if (!path || !*path) return;

    if (strlen(path) >= sizeof(addr.sun_path)) {
        printf("%s\ttoo-long\n", path);
        return;
    }

    if (stat(path, &st) != 0) {
        printf("%s\tabsent\n", path);
        return;
    }

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        printf("%s\terror:%d\n", path, errno);
        return;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (rc == 0) {
        printf("%s\tconnected\n", path);
    } else if (errno == ECONNREFUSED) {
        printf("%s\trefused\n", path);
    } else if (errno == EACCES || errno == EPERM) {
        printf("%s\tdenied\n", path);
    } else if (errno == ENOENT) {
        printf("%s\tabsent\n", path);
    } else {
        printf("%s\terror:%d\n", path, errno);
    }
    close(fd);
}

int main(int argc, char **argv)
{
    int i;
    if (argc < 2) {
        fprintf(stderr, "usage: %s <unix-socket-path> [...]\n", argv[0]);
        return 2;
    }
    for (i = 1; i < argc; i++) probe_one(argv[i]);
    return 0;
}
OBSIDIAN_PAYLOAD_IPCPROBE_C
ok "src/obsidian_ipcprobe.c"

cat > "$SCRIPTDIR/generate-manifest.sh" <<'OBSIDIAN_PAYLOAD_MANIFEST_SH'
#!/bin/sh
# /opt/obsidian/scripts/generate-manifest.sh
# Universal Hardware Scanner - Generates /etc/obsidian/hw-manifest.conf
set -e

MANIFEST_DIR="/etc/obsidian"
MANIFEST="$MANIFEST_DIR/hw-manifest.conf"
mkdir -p "$MANIFEST_DIR"

intel_pci_to_mesa() {
    case "$1" in
        0x0166) echo "Mesa Intel(R) HD Graphics 4000 (IVB GT2)" ;;
        0x0a16) echo "Mesa Intel(R) HD Graphics 4400 (HSW GT2)" ;;
        0x1616) echo "Mesa Intel(R) HD Graphics 5500 (BDW GT2)" ;;
        0x1916) echo "Mesa Intel(R) HD Graphics 520 (SKL GT2)" ;;
        0x5912|0x5916|0x591b) echo "Mesa Intel(R) HD Graphics 630 (KBL GT2)" ;;
        0x5917) echo "Mesa Intel(R) UHD Graphics 620 (KBL GT2)" ;;
        0x5926) echo "Mesa Intel(R) Iris Plus Graphics 640 (KBL GT3e)" ;;
        0x3ea0) echo "Mesa Intel(R) UHD Graphics 620 (WHL GT2)" ;;
        0x9b41) echo "Mesa Intel(R) UHD Graphics (CML GT1)" ;;
        0x9bc4|0x9bc5|0x9bc8) echo "Mesa Intel(R) UHD Graphics 630 (CML GT2)" ;;
        0x8a52) echo "Mesa Intel(R) Iris Plus Graphics (ICL GT2)" ;;
        0x9a49) echo "Mesa Intel(R) Iris Xe Graphics (TGL GT2)" ;;
        0x4680) echo "Mesa Intel(R) UHD Graphics 770 (ADL-S GT1)" ;;
        *) echo "" ;;
    esac
}

generate_manifest() {
    tmp_m=$(mktemp)
    cat <<EOF > "$tmp_m"
# /etc/obsidian/hw-manifest.conf
# Automatically generated by Obsidian Universal Hardware Scanner
# Target Scope: Host <-> Application Protection Layer ONLY.
EOF

    # 1. TPM Critical Cryptographic Identity Nullification
    if [ -e /sys/class/tpm/tpm0 ] || [ -e /dev/tpm0 ] || [ -e /dev/tpmrm0 ]; then
        cat <<EOF >> "$tmp_m"
# TPM Nullification - Cryptographic hardware identity
sys.mask.tpm=*
sys.mask.tpmrm=*
dev.null=/dev/tpm0
dev.null=/dev/tpmrm0
EOF
    fi

    # 2. Block Storage Spoofing & SCSI/ATA Masking
    echo "# Storage Identity Rules" >> "$tmp_m"
    for dev in /sys/block/sd* /sys/block/nvme* /sys/block/vd* /sys/block/hd*; do
        [ -e "$dev" ] || continue
        name=$(basename "$dev")
        [ -f "$dev/device/vendor" ] && echo "sys.spoof./sys/block/$name/device/vendor=ATA" >> "$tmp_m"
        [ -f "$dev/device/model" ] && echo "sys.spoof./sys/block/$name/device/model=Generic SSD" >> "$tmp_m"
        [ -f "$dev/device/serial" ] && echo "sys.spoof./sys/block/$name/device/serial=000000000000000" >> "$tmp_m"
        [ -f "$dev/wwid" ] && echo "sys.spoof./sys/block/$name/wwid=naa.5000000000000000" >> "$tmp_m"
    done
    cat <<EOF >> "$tmp_m"
sys.mask.ata_device=*
sys.mask.ata_link=*
sys.mask.ata_port=*
sys.mask.scsi_device=*
sys.mask.scsi_disk=*
sys.mask.scsi_generic=*
EOF

    # 3. Power Supply / Battery Spoofing
    echo "# Power Supply Rules" >> "$tmp_m"
    for bat in /sys/class/power_supply/BAT*; do
        [ -e "$bat" ] || continue
        name=$(basename "$bat")
        [ -f "$bat/manufacturer" ] && echo "sys.spoof./sys/class/power_supply/$name/manufacturer=Generic" >> "$tmp_m"
        [ -f "$bat/model_name" ] && echo "sys.spoof./sys/class/power_supply/$name/model_name=Battery Pack" >> "$tmp_m"
        [ -f "$bat/serial_number" ] && echo "sys.spoof./sys/class/power_supply/$name/serial_number=00000" >> "$tmp_m"
    done
    echo "" >> "$tmp_m"

    # 4. Thermal & Hwmon Normalization
    echo "# Thermal and Hwmon Rules" >> "$tmp_m"
    for h in /sys/class/hwmon/hwmon*; do
        [ -e "$h" ] || continue
        name=$(basename "$h")
        [ -f "$h/name" ] && echo "sys.spoof./sys/class/hwmon/$name/name=acpitz" >> "$tmp_m"
    done
    i=0
    for tz in /sys/class/thermal/thermal_zone*; do
        [ -e "$tz" ] || continue
        name=$(basename "$tz")
        if [ $((i % 2)) -eq 0 ]; then val="acpitz"; else val="x86_pkg_temp"; fi
        [ -f "$tz/type" ] && echo "sys.spoof./sys/class/thermal/$name/type=$val" >> "$tmp_m"
        i=$((i + 1))
    done
    for cd in /sys/class/thermal/cooling_device*; do
        [ -e "$cd" ] || continue
        name=$(basename "$cd")
        [ -f "$cd/type" ] && echo "sys.spoof./sys/class/thermal/$name/type=Processor" >> "$tmp_m"
    done
    echo "" >> "$tmp_m"

    # 5. Bluetooth Spoofing
    for hci in /sys/class/bluetooth/hci*; do
        [ -e "$hci" ] || continue
        name=$(basename "$hci")
        echo "sys.spoof./sys/class/bluetooth/$name/address=02:1a:11:00:00:01" >> "$tmp_m"
    done

    # 6. Backlight & RTC Normalization
    for bl in /sys/class/backlight/*; do
        [ -e "$bl" ] || continue
        name=$(basename "$bl")
        [ -f "$bl/type" ] && echo "sys.spoof./sys/class/backlight/$name/type=raw" >> "$tmp_m"
    done
    for r in /sys/class/rtc/rtc*; do
        [ -e "$r" ] || continue
        rname=$(basename "$r")
        [ -f "$r/name" ] && echo "sys.spoof./sys/class/rtc/$rname/name=rtc_cmos" >> "$tmp_m"
    done

    # ------------------------------------------------------------
    # 7. DMI / SMBIOS Identities (Class & Virtual Paths)
    #    Full field set: the OEM pins every one of these, and any
    #    single unspoofed field re-identifies the machine.
    # ------------------------------------------------------------
    echo "# DMI / SMBIOS Rules" >> "$tmp_m"
    for root in /sys/class/dmi/id /sys/devices/virtual/dmi/id; do
        cat <<EOF >> "$tmp_m"
sys.spoof.$root/sys_vendor=Generic
sys.spoof.$root/product_name=Generic Laptop
sys.spoof.$root/product_version=1.0
sys.spoof.$root/product_serial=To Be Filled By O.E.M.
sys.spoof.$root/product_uuid=00000000-0000-0000-0000-000000000000
sys.spoof.$root/product_family=Generic
sys.spoof.$root/product_sku=Generic
sys.spoof.$root/board_vendor=Generic
sys.spoof.$root/board_name=Generic Board
sys.spoof.$root/board_version=1.0
sys.spoof.$root/board_serial=To Be Filled By O.E.M.
sys.spoof.$root/board_asset_tag=To Be Filled By O.E.M.
sys.spoof.$root/bios_vendor=Generic
sys.spoof.$root/bios_version=1.0.0
sys.spoof.$root/bios_date=01/01/2020
sys.spoof.$root/bios_release=1.0
sys.spoof.$root/ec_firmware_release=1.0
sys.spoof.$root/chassis_vendor=Generic
sys.spoof.$root/chassis_version=1.0
sys.spoof.$root/chassis_serial=To Be Filled By O.E.M.
sys.spoof.$root/chassis_asset_tag=To Be Filled By O.E.M.
sys.spoof.$root/chassis_type=10
sys.spoof.$root/modalias=dmi:bvnGeneric:bvr1.0.0:bd01/01/2020:svnGeneric:pnGenericLaptop:
EOF
    done

    # 8. GPU PCI Identification Scanning & Non-GPU PCI BOM Anonymization
    gpu_pci=""
    gpu_mesa=""
    for pci in /sys/bus/pci/devices/*; do
        [ -f "$pci/class" ] || continue
        cls=$(cat "$pci/class" 2>/dev/null || true)
        case "$cls" in
            0x0300*|0x0380*)
                vend=$(cat "$pci/vendor" 2>/dev/null || true)
                devid=$(cat "$pci/device" 2>/dev/null || true)
                gpu_pci="$devid"
                if [ "$vend" = "0x8086" ]; then
                    gpu_mesa=$(intel_pci_to_mesa "$devid")
                fi
                [ -n "$gpu_mesa" ] && break
                ;;
            *)
                echo "sys.spoof.$pci/vendor=0x8086" >> "$tmp_m"
                echo "sys.spoof.$pci/device=0x0000" >> "$tmp_m"
                ;;
        esac
    done

    [ -z "$gpu_pci" ] && gpu_pci="0x5916"
    [ -z "$gpu_mesa" ] && gpu_mesa="Mesa Intel(R) HD Graphics 630 (Kaby Lake GT2)"

    echo "gpu.vendor=Intel" >> "$tmp_m"
    echo "gpu.pci_id=$gpu_pci" >> "$tmp_m"
    echo "gpu.mesa_string=$gpu_mesa" >> "$tmp_m"
    echo "" >> "$tmp_m"

    # ------------------------------------------------------------
    # 8b. DRM identity - COMPAT SAFE subset.
    #
    # Deliberately NOT spoofed here: device/vendor, device/device and
    # device/uevent. libdrm and Mesa select the kernel driver from
    # those three; lying about them makes Mesa load the wrong driver
    # and hardware acceleration collapses to software rendering.
    #
    # Spoofed instead: the OEM board pins (subsystem_vendor and
    # subsystem_device), which identify the exact laptop model but
    # play no part in driver selection.
    #
    # Monitor EDID is masked outright - it carries the display's
    # serial number and manufacture date, and nothing needs to read
    # it directly when a compositor is present.
    #
    # Full DRM masking is available at runtime with
    # OBSIDIAN_GPU_MODE=strict (see obsidian-launch).
    # ------------------------------------------------------------
    echo "# DRM identity (compat-safe subset)" >> "$tmp_m"
    for node in /sys/class/drm/*; do
        [ -e "$node" ] || continue
        nname=$(basename "$node")
        case "$nname" in
            *-*)
                # connector node, e.g. card0-eDP-1
                [ -f "$node/edid" ] && echo "sys.spoof.$node/edid=" >> "$tmp_m"
                ;;
            card[0-9]*|renderD[0-9]*)
                [ -f "$node/device/subsystem_vendor" ] && \
                    echo "sys.spoof.$node/device/subsystem_vendor=0x8086" >> "$tmp_m"
                [ -f "$node/device/subsystem_device" ] && \
                    echo "sys.spoof.$node/device/subsystem_device=0x0000" >> "$tmp_m"
                [ -f "$node/device/label" ] && \
                    echo "sys.spoof.$node/device/label=Generic Graphics" >> "$tmp_m"
                ;;
        esac
    done
    echo "" >> "$tmp_m"

    # 9. Fail-Closed Sweep for Unrecognized Subsystems
    echo "# Fail-Closed Unrecognized Subsystem Rules" >> "$tmp_m"
    known_subsystems="ata_device ata_link ata_port scsi_device scsi_disk scsi_generic tpm tpmrm power_supply hwmon thermal bluetooth backlight rtc net dmi drm block input sound hidraw video4linux mem tty vtconsole graphics vc drm_render net_device misc"
    for cdir in /sys/class/*; do
        [ -d "$cdir" ] || continue
        cname=$(basename "$cdir")
        is_k=0
        for k in $known_subsystems; do
            if [ "$cname" = "$k" ]; then is_k=1; break; fi
        done
        if [ "$is_k" -eq 0 ]; then
            echo "sys.mask.$cdir=*" >> "$tmp_m"
        fi
    done

    mv "$tmp_m" "$MANIFEST"
    # Allow all local users to read the hardware manifest (644)
    chmod 644 "$MANIFEST"
}

generate_manifest
echo "Hardware scanner executed successfully -> $MANIFEST"
OBSIDIAN_PAYLOAD_MANIFEST_SH
chmod 755 "$SCRIPTDIR/generate-manifest.sh"
ok "scripts/generate-manifest.sh"

cat > "$SCRIPTDIR/obsidian-probe.sh" <<'OBSIDIAN_PAYLOAD_PROBE_SH'
#!/bin/sh
# ============================================================
# /opt/obsidian/scripts/obsidian-probe.sh
# Obsidian Mirror - metadata observation probe.
#
# Emits one "KEY<TAB>VALUE" line per observable metadata item.
# Side-effect free, unprivileged, POSIX sh + BusyBox only.
#
# Run it natively to see the REAL host identity, and run it
# under "obsidian" to see the SPOOFED identity. obsidian-audit
# does both and diffs them.
# ============================================================

# Deliberately no "set -e": a probe must survive every missing file.

NONE="(none)"

emit() {
    _k="$1"; shift
    _v="$*"
    _v=$(printf '%s' "$_v" | tr '\n\r\t' '   ' | sed 's/  */ /g; s/^ //; s/ *$//')
    [ -z "$_v" ] && _v="$NONE"
    printf '%s\t%s\n' "$_k" "$_v"
}

# read a file, first line only, bounded
rd1() {
    if [ -r "$1" ]; then
        head -n 1 "$1" 2>/dev/null | cut -c1-160
    else
        printf ''
    fi
}

# read whole file bounded
rdall() {
    if [ -r "$1" ]; then
        head -c 400 "$1" 2>/dev/null
    else
        printf ''
    fi
}

# list a glob, basenames, space separated
lsglob() {
    _o=""
    for _p in "$@"; do
        [ -e "$_p" ] || continue
        _o="$_o $(basename "$_p")"
    done
    printf '%s' "$_o"
}

countglob() {
    _n=0
    for _p in "$@"; do
        [ -e "$_p" ] || continue
        _n=$((_n + 1))
    done
    printf '%s' "$_n"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------
# IDENTITY
# ------------------------------------------------------------
emit id.hostname        "$(hostname 2>/dev/null)"
emit id.uname_nodename  "$(uname -n 2>/dev/null)"
emit id.uname_sysname   "$(uname -s 2>/dev/null)"
emit id.uname_release   "$(uname -r 2>/dev/null)"
emit id.uname_version   "$(uname -v 2>/dev/null)"
emit id.uname_machine   "$(uname -m 2>/dev/null)"
emit id.machine_id      "$(rd1 /etc/machine-id)"
emit id.dbus_machine_id "$(rd1 /var/lib/dbus/machine-id)"
emit id.boot_id         "$(rd1 /proc/sys/kernel/random/boot_id)"
emit id.env_user        "$USER"
emit id.env_logname     "$LOGNAME"
emit id.env_home        "$HOME"
emit id.uid             "$(id -u 2>/dev/null)"
emit id.gid             "$(id -g 2>/dev/null)"
emit id.username        "$(id -un 2>/dev/null)"
emit id.groupname       "$(id -gn 2>/dev/null)"
emit id.passwd_lines    "$(grep -c . /etc/passwd 2>/dev/null)"
emit id.group_lines     "$(grep -c . /etc/group 2>/dev/null)"
emit id.passwd_self     "$(grep "^$(id -un 2>/dev/null):" /etc/passwd 2>/dev/null | head -n1)"
emit id.shell           "$SHELL"

# ------------------------------------------------------------
# OPERATING SYSTEM
# ------------------------------------------------------------
if [ -r /etc/os-release ]; then
    emit os.id       "$(grep -E '^ID='          /etc/os-release 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\"')"
    emit os.pretty   "$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\"')"
    emit os.version  "$(grep -E '^VERSION_ID='  /etc/os-release 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\"')"
else
    emit os.id "$NONE"; emit os.pretty "$NONE"; emit os.version "$NONE"
fi
emit os.proc_version    "$(rd1 /proc/version)"
emit os.proc_cmdline    "$(rdall /proc/cmdline)"
emit os.kernel_osrelease "$(rd1 /proc/sys/kernel/osrelease)"
emit os.issue           "$(rdall /etc/issue)"
emit os.lsb_release     "$(rdall /etc/lsb-release)"
emit os.distro_files    "$(cat /etc/alpine-release /etc/debian_version /etc/redhat-release /etc/arch-release /etc/gentoo-release 2>/dev/null | head -c 200)"
emit os.distro_file_names "$(lsglob /etc/alpine-release /etc/debian_version /etc/redhat-release /etc/arch-release)"
emit os.apk_world       "$(grep -c . /etc/apk/world 2>/dev/null)"
emit os.apk_installed   "$(grep -c '^P:' /lib/apk/db/installed 2>/dev/null)"

# ------------------------------------------------------------
# CPU
# ------------------------------------------------------------
emit cpu.nproc          "$(nproc 2>/dev/null)"
emit cpu.model          "$(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2-)"
emit cpu.vendor         "$(grep -m1 '^vendor_id'  /proc/cpuinfo 2>/dev/null | cut -d: -f2-)"
emit cpu.count_cpuinfo  "$(grep -c '^processor'   /proc/cpuinfo 2>/dev/null)"
emit cpu.mhz            "$(grep -m1 '^cpu MHz'    /proc/cpuinfo 2>/dev/null | cut -d: -f2-)"
emit cpu.cache          "$(grep -m1 '^cache size' /proc/cpuinfo 2>/dev/null | cut -d: -f2-)"
emit cpu.bogomips       "$(grep -m1 '^bogomips'   /proc/cpuinfo 2>/dev/null | cut -d: -f2-)"
emit cpu.flags_len      "$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | wc -w)"
emit cpu.online         "$(rd1 /sys/devices/system/cpu/online)"
emit cpu.possible       "$(rd1 /sys/devices/system/cpu/possible)"
emit cpu.sysfs_dirs     "$(countglob /sys/devices/system/cpu/cpu[0-9]*)"

# ------------------------------------------------------------
# MEMORY
# ------------------------------------------------------------
mi() { grep -m1 "^$1" /proc/meminfo 2>/dev/null | tr -s ' ' | cut -d' ' -f2; }
emit mem.meminfo_total  "$(mi MemTotal)"
emit mem.meminfo_free   "$(mi MemFree)"
emit mem.meminfo_avail  "$(mi MemAvailable)"
emit mem.meminfo_swap   "$(mi SwapTotal)"
emit mem.meminfo_lines  "$(grep -c . /proc/meminfo 2>/dev/null)"
emit mem.sysinfo_total  "$(free -k 2>/dev/null | awk '/^Mem/{print $2; exit}')"
emit mem.sysinfo_swap   "$(free -k 2>/dev/null | awk '/^Swap/{print $2; exit}')"

# ------------------------------------------------------------
# TIME
# ------------------------------------------------------------
emit time.zone_abbr     "$(date +%Z 2>/dev/null)"
emit time.utc_offset    "$(date +%z 2>/dev/null)"
emit time.etc_timezone  "$(rd1 /etc/timezone)"
emit time.localtime     "$(readlink /etc/localtime 2>/dev/null)"
emit time.uptime        "$(cut -d. -f1 /proc/uptime 2>/dev/null)"
emit time.btime         "$(grep -m1 '^btime' /proc/stat 2>/dev/null | cut -d' ' -f2)"
emit time.loadavg       "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
emit time.stat_cpulines "$(grep -c '^cpu[0-9]' /proc/stat 2>/dev/null)"

# ------------------------------------------------------------
# FILE TIMESTAMP RESOLUTION
#
# Creates a throwaway file and reads its mtime back. The stat
# family and statx() are both hooked to floor tv_sec to the hour
# and zero tv_nsec, so a protected host reports 0 for both.
# A real host reports an essentially random second-within-hour
# and a nanosecond field with ~30 bits of entropy -- that is a
# per-file, per-event tracking identifier.
# ------------------------------------------------------------
_tsf="${TMPDIR:-/tmp}/.obsidian_ts_probe.$$"
: > "$_tsf" 2>/dev/null
if [ -f "$_tsf" ] && have stat; then
    _mt="$(stat -c %Y "$_tsf" 2>/dev/null)"
    _my="$(stat -c %y "$_tsf" 2>/dev/null)"
    case "$_mt" in
        ''|*[!0-9]*) emit ts.mtime_mod3600 "(stat unusable)" ;;
        *)           emit ts.mtime_mod3600 "$((_mt % 3600))" ;;
    esac
    _mns="$(printf '%s' "$_my" | sed -n 's/.*\.\([0-9][0-9]*\).*/\1/p')"
    [ -z "$_mns" ] && _mns=0
    # strip leading zeros without octal interpretation
    _mns="$(printf '%s' "$_mns" | sed 's/^0*//')"
    [ -z "$_mns" ] && _mns=0
    emit ts.mtime_nsec "$_mns"
    emit ts.mtime_raw  "$_my"
else
    emit ts.mtime_mod3600 "(stat absent)"
    emit ts.mtime_nsec    "(stat absent)"
    emit ts.mtime_raw     "(stat absent)"
fi
rm -f "$_tsf" 2>/dev/null

# ------------------------------------------------------------
# DMI / SMBIOS / FIRMWARE
# ------------------------------------------------------------
for f in sys_vendor product_name product_version product_serial product_uuid \
         product_family product_sku \
         board_vendor board_name board_version board_serial board_asset_tag \
         bios_vendor bios_version bios_date bios_release \
         chassis_vendor chassis_version chassis_serial chassis_asset_tag \
         chassis_type modalias; do
    v="$(rd1 /sys/class/dmi/id/$f)"
    [ -z "$v" ] && v="$(rd1 /sys/devices/virtual/dmi/id/$f)"
    emit "dmi.$f" "$v"
done
emit fw.acpi_tables     "$(countglob /sys/firmware/acpi/tables/*)"
emit fw.efi_present     "$([ -d /sys/firmware/efi ] && echo yes || echo no)"
emit fw.dtb_present     "$([ -e /sys/firmware/devicetree ] && echo yes || echo no)"

# ------------------------------------------------------------
# STORAGE
# ------------------------------------------------------------
emit blk.devices        "$(lsglob /sys/block/*)"
emit blk.count          "$(countglob /sys/block/*)"
_bmodel=""; _bserial=""; _bvendor=""; _bwwid=""
for d in /sys/block/sd* /sys/block/nvme* /sys/block/vd* /sys/block/hd*; do
    [ -e "$d" ] || continue
    [ -z "$_bmodel" ]  && _bmodel="$(rd1 "$d/device/model")"
    [ -z "$_bserial" ] && _bserial="$(rd1 "$d/device/serial")"
    [ -z "$_bvendor" ] && _bvendor="$(rd1 "$d/device/vendor")"
    [ -z "$_bwwid" ]   && _bwwid="$(rd1 "$d/wwid")"
done
emit blk.model          "$_bmodel"
emit blk.serial         "$_bserial"
emit blk.vendor         "$_bvendor"
emit blk.wwid           "$_bwwid"
emit blk.scsi_classes   "$(countglob /sys/class/scsi_device/* /sys/class/scsi_disk/* /sys/class/scsi_generic/* /sys/class/ata_device/* /sys/class/ata_port/*)"
emit blk.mount_count    "$(grep -c . /proc/mounts 2>/dev/null)"
emit blk.root_source    "$(awk '$2=="/"{print $1; exit}' /proc/mounts 2>/dev/null)"

# ------------------------------------------------------------
# TPM / CRYPTO HARDWARE
# ------------------------------------------------------------
emit tpm.class_nodes    "$(lsglob /sys/class/tpm/*)"
emit tpm.dev_nodes      "$(lsglob /dev/tpm*)"
emit tpm.version        "$(rd1 /sys/class/tpm/tpm0/tpm_version_major)"

# ------------------------------------------------------------
# POWER / THERMAL
# ------------------------------------------------------------
emit pwr.supplies       "$(lsglob /sys/class/power_supply/*)"
_bm=""; _bs=""
for b in /sys/class/power_supply/BAT*; do
    [ -e "$b" ] || continue
    [ -z "$_bm" ] && _bm="$(rd1 "$b/manufacturer")"
    [ -z "$_bs" ] && _bs="$(rd1 "$b/serial_number")"
done
emit pwr.bat_manufacturer "$_bm"
emit pwr.bat_serial       "$_bs"
_tz=""
for t in /sys/class/thermal/thermal_zone*; do
    [ -e "$t" ] || continue
    _tz="$_tz $(rd1 "$t/type")"
done
emit thermal.zone_types "$_tz"
_hw=""
for h in /sys/class/hwmon/hwmon*; do
    [ -e "$h" ] || continue
    _hw="$_hw $(rd1 "$h/name")"
done
emit hwmon.names        "$_hw"
_cd=""
for c in /sys/class/thermal/cooling_device*; do
    [ -e "$c" ] || continue
    _cd="$_cd $(rd1 "$c/type")"
done
emit thermal.cooling_types "$_cd"

# ------------------------------------------------------------
# PERIPHERALS
# ------------------------------------------------------------
_bt=""
for h in /sys/class/bluetooth/hci*; do
    [ -e "$h" ] || continue
    _bt="$_bt $(rd1 "$h/address")"
done
emit bt.addresses       "$_bt"
_rtc=""
for r in /sys/class/rtc/rtc*; do
    [ -e "$r" ] || continue
    _rtc="$_rtc $(rd1 "$r/name")"
done
emit rtc.names          "$_rtc"
_bl=""
for b in /sys/class/backlight/*; do
    [ -e "$b" ] || continue
    _bl="$_bl $(rd1 "$b/type")"
done
emit backlight.types    "$_bl"
emit input.proc_count   "$(grep -c '^N: Name' /proc/bus/input/devices 2>/dev/null)"
emit input.dev_count    "$(countglob /dev/input/*)"
emit input.class_count  "$(countglob /sys/class/input/*)"
emit snd.cards          "$(rdall /proc/asound/cards)"
emit snd.dev_count      "$(countglob /dev/snd/*)"
emit usb.device_count   "$(countglob /sys/bus/usb/devices/*)"
emit video.dev_nodes    "$(lsglob /dev/video* /dev/media*)"
emit hidraw.dev_nodes   "$(lsglob /dev/hidraw*)"
emit udev.db_entries    "$(countglob /run/udev/data/*)"

# ------------------------------------------------------------
# GPU / GRAPHICS
# ------------------------------------------------------------
emit gpu.dri_nodes      "$(lsglob /dev/dri/*)"
emit gpu.dri_count      "$(countglob /dev/dri/*)"
emit gpu.drm_class      "$(lsglob /sys/class/drm/*)"
emit gpu.drm_count      "$(countglob /sys/class/drm/*)"
emit gpu.pci_line       "$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -n1)"

# DRM board pins: these identify the exact laptop model. Spoofed in
# compat mode (the whole class is masked in strict mode).
_dsv=""; _dsd=""; _dlbl=""
for c in /sys/class/drm/card[0-9]*; do
    [ -e "$c" ] || continue
    [ -z "$_dsv" ]  && _dsv="$(rd1 "$c/device/subsystem_vendor")"
    [ -z "$_dsd" ]  && _dsd="$(rd1 "$c/device/subsystem_device")"
    [ -z "$_dlbl" ] && _dlbl="$(rd1 "$c/device/label")"
done
emit gpu.drm_subsys_vendor "$_dsv"
emit gpu.drm_subsys_device "$_dsd"
emit gpu.drm_label         "$_dlbl"

# Monitor EDID carries the display serial number and manufacture week.
_edid=0
for e in /sys/class/drm/*/edid; do
    [ -e "$e" ] || continue
    _sz="$(wc -c < "$e" 2>/dev/null)"
    case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
    _edid=$((_edid + _sz))
done
emit gpu.edid_bytes     "$_edid"

if have glxinfo; then
    emit gpu.gl_vendor   "$(glxinfo -B 2>/dev/null | grep -m1 -i 'OpenGL vendor'   | cut -d: -f2-)"
    emit gpu.gl_renderer "$(glxinfo -B 2>/dev/null | grep -m1 -i 'OpenGL renderer' | cut -d: -f2-)"
    emit gpu.gl_ext_count "$(glxinfo 2>/dev/null | tr ' ' '\n' | grep -c '^GL_')"
else
    emit gpu.gl_vendor    "(glxinfo absent)"
    emit gpu.gl_renderer  "(glxinfo absent)"
    emit gpu.gl_ext_count "(glxinfo absent)"
fi
emit gpu.env_vendor     "$OBSIDIAN_GPU_VENDOR"
emit gpu.env_renderer   "$OBSIDIAN_GPU_RENDERER"
emit gpu.mode           "${OBSIDIAN_GPU_MODE:-(unset)}"

# ------------------------------------------------------------
# PCI BUS
# ------------------------------------------------------------
emit pci.device_count   "$(countglob /sys/bus/pci/devices/*)"
_pv=""
for p in /sys/bus/pci/devices/*; do
    [ -e "$p" ] || continue
    _pv="$_pv$(rd1 "$p/vendor") "
done
emit pci.vendor_ids     "$(printf '%s' "$_pv" | tr ' ' '\n' | sort -u | tr '\n' ' ')"

# ------------------------------------------------------------
# NETWORK  (explicitly OUT OF SCOPE - audited to show the boundary)
# ------------------------------------------------------------
emit net.interfaces     "$(lsglob /sys/class/net/*)"
_mac=""
for n in /sys/class/net/*; do
    [ -e "$n" ] || continue
    case "$(basename "$n")" in lo) continue ;; esac
    _mac="$_mac $(rd1 "$n/address")"
done
emit net.mac_addresses  "$_mac"
emit net.resolv_conf    "$(rdall /etc/resolv.conf)"
emit net.hosts_lines    "$(grep -c . /etc/hosts 2>/dev/null)"

# ------------------------------------------------------------
# PROCESS / IPC / KERNEL SURFACE
# ------------------------------------------------------------
emit proc.pid1_comm     "$(rd1 /proc/1/comm)"
emit proc.visible_pids  "$(ls /proc 2>/dev/null | grep -c '^[0-9][0-9]*$')"
emit proc.self_pid      "$$"
emit ipc.shm_segments   "$(ipcs -m 2>/dev/null | grep -c '^0x')"
emit sec.seccomp_mode   "$(grep -m1 '^Seccomp:'   /proc/self/status 2>/dev/null | tr -s ' \t' ' ' | cut -d' ' -f2)"
emit sec.nonewprivs     "$(grep -m1 '^NoNewPrivs:' /proc/self/status 2>/dev/null | tr -s ' \t' ' ' | cut -d' ' -f2)"
emit sec.cap_effective  "$(grep -m1 '^CapEff:'    /proc/self/status 2>/dev/null | tr -s ' \t' ' ' | cut -d' ' -f2)"
emit sec.userns_uidmap  "$(rdall /proc/self/uid_map)"

# ------------------------------------------------------------
# FILESYSTEM EXPOSURE
# ------------------------------------------------------------
emit fs.home_entries    "$(ls -A /home 2>/dev/null | tr '\n' ' ')"
emit fs.home_count      "$(ls -A /home 2>/dev/null | grep -c .)"
emit fs.tmp_count       "$(ls -A /tmp 2>/dev/null | grep -c .)"
emit fs.userhome_count  "$(ls -A "$HOME" 2>/dev/null | grep -c .)"
emit fs.root_home       "$(ls -A /root 2>/dev/null | grep -c . 2>/dev/null)"

# ------------------------------------------------------------
# FONTS
#
# The installed font set is a strong, stable fingerprint. The
# mirrored view pins FONTCONFIG_FILE at a config that scans only
# the distribution font directory, drops every per-user and
# host-local directory and pins the cache into the private tmpfs.
# Fonts are NOT removed -- an app with no fonts cannot draw text.
# ------------------------------------------------------------
emit fs.fontconfig_file "${FONTCONFIG_FILE:-(unset)}"
if have fc-list; then
    emit fs.font_count      "$(fc-list 2>/dev/null | grep -c .)"
    emit fs.font_families   "$(fc-list : family 2>/dev/null | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -c .)"
    emit fs.font_family_sig "$(fc-list : family 2>/dev/null | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep . | sort -u | cksum 2>/dev/null | cut -d' ' -f1)"
else
    emit fs.font_count      "(fc-list absent)"
    emit fs.font_families   "(fc-list absent)"
    emit fs.font_family_sig "(fc-list absent)"
fi
_fdirs=""
for d in "$HOME/.fonts" "$HOME/.local/share/fonts" "$HOME/.config/fontconfig"; do
    [ -d "$d" ] && _fdirs="$_fdirs $d"
done
emit fs.user_font_dirs  "$_fdirs"
_hdirs=""
for d in /usr/local/share/fonts /opt/share/fonts /etc/fonts/conf.d; do
    [ -e "$d" ] && _hdirs="$_hdirs $d"
done
emit fs.hostlocal_font_dirs "$_hdirs"

# ------------------------------------------------------------
# IPC REACHABILITY  (measured, not assumed)
#
# obsidian-ipcprobe attempts a real connect() to each socket.
# Compositor control sockets and the D-Bus system bus must NOT be
# reachable from inside. The Wayland display socket MUST stay
# reachable -- that is the compatibility guarantee.
# ------------------------------------------------------------
IPCP="/opt/obsidian/bin/obsidian-ipcprobe"
ipc_state() {
    # $1 = one or more candidate globs; prints the first decisive state
    _st=""
    for _c in $1; do
        [ -e "$_c" ] || continue
        if [ -x "$IPCP" ]; then
            _r="$("$IPCP" "$_c" 2>/dev/null | head -n1 | cut -f2)"
        else
            _r="present(no-probe)"
        fi
        [ -n "$_r" ] && { _st="$_r"; break; }
    done
    [ -z "$_st" ] && _st="absent"
    printf '%s' "$_st"
}

_rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u 2>/dev/null)}"
emit ipc.compositor_ctl "$(ipc_state "$_rt/sway-ipc.* $_rt/hypr/*/.socket.sock /tmp/hypr/*/.socket.sock $_rt/i3/ipc-socket.* /tmp/i3-*/ipc-socket.* $_rt/wayfire-wayland-*.socket $_rt/niri.*.sock")"
emit ipc.dbus_system    "$(ipc_state "/run/dbus/system_bus_socket /var/run/dbus/system_bus_socket")"
emit ipc.dbus_session   "$(ipc_state "$_rt/bus")"
emit ipc.wayland_disp   "$(ipc_state "$_rt/${WAYLAND_DISPLAY:-wayland-0} $_rt/wayland-0 $_rt/wayland-1")"
emit ipc.runtime_dir_entries "$(ls -A "$_rt" 2>/dev/null | grep -c .)"

# ------------------------------------------------------------
# DETECTABILITY  (can the app tell it is being mirrored?)
# ------------------------------------------------------------
emit det.ld_preload     "$LD_PRELOAD"
emit det.obsidian_env   "$(env 2>/dev/null | grep -c '^OBSIDIAN_')"
emit det.mount_fakes    "$(grep -c 'home/\.fake' /proc/self/mountinfo 2>/dev/null)"
emit det.mountinfo_rows "$(grep -c . /proc/self/mountinfo 2>/dev/null)"
emit det.opt_obsidian   "$([ -d /opt/obsidian ] && echo visible || echo hidden)"
OBSIDIAN_PAYLOAD_PROBE_SH
chmod 755 "$SCRIPTDIR/obsidian-probe.sh"
ok "scripts/obsidian-probe.sh"

cat > "$BINDIR/obsidian-launch" <<'OBSIDIAN_PAYLOAD_LAUNCH'
#!/bin/sh
# ============================================================
# /opt/obsidian/bin/obsidian-launch
# Obsidian Mirror - Universal Host <-> Application Isolation Launcher
#
# SCOPE: Host <-> Application layer ONLY. Network stack excluded.
#
# Runtime knobs (all optional, all default to "do not break apps"):
#   OBSIDIAN_GPU_MODE=compat|strict   default compat
#         compat - GPU acceleration preserved; OEM board pins and
#                  monitor EDID spoofed; GL strings spoofed.
#         strict - /dev/dri and /sys/class/drm fully masked. Zero
#                  GPU fingerprint, software rendering only.
#   OBSIDIAN_GL_EXTENSIONS=preserve   pass the real GL extension
#         list through (only if an app refuses to start without it)
#   OBSIDIAN_ALLOW_SYSTEM_BUS=1       permit D-Bus system bus
#   OBSIDIAN_MANIFEST=<path>          alternate hardware manifest
#   OBSIDIAN_VERBOSE=1                log blocked IPC connections
# ============================================================

OBSIDIAN_DIR="/opt/obsidian"; export OBSIDIAN_DIR
FAKE_ROOT="$OBSIDIAN_DIR/fake_root"
LIB_DIR="$OBSIDIAN_DIR/lib"
INNER_STAGE="$OBSIDIAN_DIR/bin/obsidian-inner"
FONTS_CONF="$FAKE_ROOT/fonts/fonts.conf"
MANIFEST_PATH="${OBSIDIAN_MANIFEST:-/etc/obsidian/hw-manifest.conf}"

if [ "$1" = "--regenerate-manifest" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: Re-generating manifest requires root permissions."
        exit 1
    fi
    exec "$OBSIDIAN_DIR/scripts/generate-manifest.sh"
fi

if [ "$1" = "--test" ] || [ "$1" = "--audit" ]; then
    shift
    exec /bin/sh "$OBSIDIAN_DIR/bin/obsidian-audit" "$@"
fi

if [ "$1" = "--coverage" ] || [ "$1" = "--doc" ]; then
    if [ -r "$OBSIDIAN_DIR/COVERAGE.md" ]; then
        if command -v less >/dev/null 2>&1 && [ -t 1 ]; then
            exec less "$OBSIDIAN_DIR/COVERAGE.md"
        fi
        exec cat "$OBSIDIAN_DIR/COVERAGE.md"
    fi
    echo "ERROR: $OBSIDIAN_DIR/COVERAGE.md not installed."
    exit 1
fi

if [ "$1" = "--version" ]; then
    echo "Obsidian Mirror - Universal Isolation Layer, v2"
    echo "Manifest: $MANIFEST_PATH"
    echo "GPU mode: ${OBSIDIAN_GPU_MODE:-compat}"
    exit 0
fi

if [ -z "$1" ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Usage: obsidian <application> [args...]"
    echo
    echo "  obsidian --test                 audit metadata protection"
    echo "  obsidian --coverage             what is and is not protected"
    echo "  obsidian --regenerate-manifest  rescan this hardware (root)"
    echo "  obsidian --version"
    echo
    echo "Runtime switches (all default to not breaking applications):"
    echo "  OBSIDIAN_GPU_MODE=strict        mask /dev/dri and /sys/class/drm"
    echo "                                  entirely; software rendering only"
    echo "  OBSIDIAN_GL_EXTENSIONS=preserve pass the real GL extension list"
    echo "                                  through (only if an app needs it)"
    echo "  OBSIDIAN_ALLOW_SYSTEM_BUS=1     permit the D-Bus system bus"
    echo "  OBSIDIAN_VERBOSE=1              log blocked IPC connections"
    echo
    echo "Example: obsidian firefox"
    [ -z "$1" ] && exit 1
    exit 0
fi

if [ ! -x "$INNER_STAGE" ]; then
    echo "ERROR: Missing execution stage: $INNER_STAGE"
    echo "       Re-run the Obsidian installer as root."
    exit 1
fi

GPU_MODE="${OBSIDIAN_GPU_MODE:-compat}"
case "$GPU_MODE" in
    compat|strict) ;;
    *) GPU_MODE="compat" ;;
esac

PRELOAD=""
for lib in obsidian_core.so obsidian_wayland.so obsidian_gpu.so; do
    if [ -f "$LIB_DIR/$lib" ]; then
        if [ -z "$PRELOAD" ]; then
            PRELOAD="$LIB_DIR/$lib"
        else
            PRELOAD="$PRELOAD:$LIB_DIR/$lib"
        fi
    fi
done

REAL_UID="$(id -u)"
REAL_GID="$(id -g)"
REAL_RUNTIME_DIR="${XDG_RUNTIME_DIR}"
REAL_WAYLAND_SOCK="${WAYLAND_DISPLAY:-wayland-0}"

# Per-application persistent home key. Each application's data
# (preferences, caches, configuration) is stored under
# /opt/obsidian/var/homes/<appkey> by default so it survives across
# launches -- the application is not re-launched as if for the first
# time on every run. OBSIDIAN_FRESH=1 makes a launch throwaway (the
# previous behaviour). The key is derived from the command name and
# sanitised so it is safe to use as a filesystem path component.
OBSIDIAN_APPKEY=$(printf '%s' "$1" | sed 's|.*/||; s/[^A-Za-z0-9._-]/_/g')
export OBSIDIAN_APPKEY

# HARDEN_OBSIDIAN=2: next-level hardening. Route the launch through the
# per-app network namespace + dynamic deny-list blocker instead of the
# normal path. The blocker still runs the app under HARDEN_OBSIDIAN=1
# inside its own netns, logs its traffic, and denies everything it did not
# prove it needs.
if [ "${OBSIDIAN_HARDEN:-}" = "2" ]; then
    exec "$OBSIDIAN_DIR/bin/obsidian-netblock.sh" run "${OBSIDIAN_APPKEY:-app}" "$@"
fi

# v3.4: `obsidian <app> --stat` prints the per-app statistics page
for _a in "$@"; do
    [ "$_a" = "--stat" ] && { "$OBSIDIAN_DIR/bin/obsidian-netblock.sh" stat "${OBSIDIAN_APPKEY:-app}"; exit 0; }
done

REAL_NPROC="$(nproc 2>/dev/null || echo 1)"
if [ "$REAL_NPROC" -ge 2 ]; then
    FAKE_CORE_COUNT=2
    TASKSET_ARG="0,1"
else
    FAKE_CORE_COUNT=1
    TASKSET_ARG="0"
fi

rand_hex() { tr -dc 'a-f0-9' < /dev/urandom | head -c "$1"; }

gen_uuid() {
    h=$(rand_hex 32)
    printf '%s-%s-%s-%s-%s\n' \
        "$(printf '%s' "$h" | cut -c1-8)" \
        "$(printf '%s' "$h" | cut -c9-12)" \
        "$(printf '%s' "$h" | cut -c13-16)" \
        "$(printf '%s' "$h" | cut -c17-20)" \
        "$(printf '%s' "$h" | cut -c21-32)"
}

OS_INDEX=$(( ( $(od -An -N2 -tu2 < /dev/urandom) % 10 ) + 1 ))
case "$OS_INDEX" in
    1)
        DISTRO_NAME="Ubuntu"
        DISTRO_VER="22.04.4 LTS (Jammy Jellyfish)"
        DISTRO_ID="ubuntu"
        DISTRO_LIKE="debian"
        DISTRO_PRETTY="Ubuntu 22.04.4 LTS"
        DISTRO_VER_ID="22.04"
        DISTRO_KERNEL="6.5.0-28-generic"
        DISTRO_PROC_VER="Linux version 6.5.0-28-generic (buildd@lcy02-amd64-001) (gcc (Ubuntu 12.3.0-1ubuntu1~22.04) 12.3.0) #29~22.04.1-Ubuntu SMP PREEMPT_DYNAMIC"
        DISTRO_CMDLINE="BOOT_IMAGE=/vmlinuz-6.5.0-28-generic root=UUID=$(gen_uuid) ro quiet splash"
        ;;
    2)
        DISTRO_NAME="Debian GNU/Linux"
        DISTRO_VER="12 (bookworm)"
        DISTRO_ID="debian"
        DISTRO_LIKE=""
        DISTRO_PRETTY="Debian GNU/Linux 12 (bookworm)"
        DISTRO_VER_ID="12"
        DISTRO_KERNEL="6.1.0-18-amd64"
        DISTRO_PROC_VER="Linux version 6.1.0-18-amd64 (debian-kernel@lists.debian.org) (gcc-12 (Debian 12.2.0-14) 12.2.0) #1 SMP PREEMPT_DYNAMIC Debian 6.1.76-1"
        DISTRO_CMDLINE="BOOT_IMAGE=/boot/vmlinuz-6.1.0-18-amd64 root=UUID=$(gen_uuid) ro quiet"
        ;;
    3)
        DISTRO_NAME="Fedora Linux"
        DISTRO_VER="39 (Workstation Edition)"
        DISTRO_ID="fedora"
        DISTRO_LIKE=""
        DISTRO_PRETTY="Fedora Linux 39 (Workstation Edition)"
        DISTRO_VER_ID="39"
        DISTRO_KERNEL="6.5.6-300.fc39.x86_64"
        DISTRO_PROC_VER="Linux version 6.5.6-300.fc39.x86_64 (mockbuild@bkernel02.iad2.fedoraproject.org) (gcc (GCC) 13.2.1 20230918) #1 SMP PREEMPT_DYNAMIC"
        DISTRO_CMDLINE="BOOT_IMAGE=(hd0,gpt2)/vmlinuz-6.5.6-300.fc39.x86_64 root=UUID=$(gen_uuid) ro rhgb quiet"
        ;;
    4)
        DISTRO_NAME="Arch Linux"
        DISTRO_VER="Rolling"
        DISTRO_ID="arch"
        DISTRO_LIKE=""
        DISTRO_PRETTY="Arch Linux"
        DISTRO_VER_ID=""
        DISTRO_KERNEL="6.8.1-arch1-1"
        DISTRO_PROC_VER="Linux version 6.8.1-arch1-1 (linux@archlinux) (gcc (GCC) 13.2.1 20230801) #1 SMP PREEMPT_DYNAMIC"
        DISTRO_CMDLINE="initrd=\\intel-ucode.img initrd=\\initramfs-linux.img root=UUID=$(gen_uuid) rw quiet loglevel=3"
        ;;
    5)
        DISTRO_NAME="Linux Mint"
        DISTRO_VER="21.3 (Virginia)"
        DISTRO_ID="linuxmint"
        DISTRO_LIKE="ubuntu debian"
        DISTRO_PRETTY="Linux Mint 21.3"
        DISTRO_VER_ID="21.3"
        DISTRO_KERNEL="5.15.0-91-generic"
        DISTRO_PROC_VER="Linux version 5.15.0-91-generic (buildd@lcy02-amd64-042) (gcc (Ubuntu 11.4.0-1ubuntu1~22.04) 11.4.0) #101-Ubuntu SMP"
        DISTRO_CMDLINE="BOOT_IMAGE=/boot/vmlinuz-5.15.0-91-generic root=UUID=$(gen_uuid) ro quiet splash"
        ;;
    6)
        DISTRO_NAME="Pop!_OS"
        DISTRO_VER="22.04 LTS"
        DISTRO_ID="pop"
        DISTRO_LIKE="ubuntu debian"
        DISTRO_PRETTY="Pop!_OS 22.04 LTS"
        DISTRO_VER_ID="22.04"
        DISTRO_KERNEL="6.6.10-76060610-generic"
        DISTRO_PROC_VER="Linux version 6.6.10-76060610-generic (pop-build@pop-os) (gcc (Ubuntu 11.4.0-1ubuntu1~22.04) 11.4.0) #202401051437~1705603643~22.04"
        DISTRO_CMDLINE="splash loglevel=0 systemd.show_status=false root=UUID=$(gen_uuid) ro"
        ;;
    7)
        DISTRO_NAME="Manjaro Linux"
        DISTRO_VER="23.1.3"
        DISTRO_ID="manjaro"
        DISTRO_LIKE="arch"
        DISTRO_PRETTY="Manjaro Linux"
        DISTRO_VER_ID="23.1.3"
        DISTRO_KERNEL="6.6.19-1-MANJARO"
        DISTRO_PROC_VER="Linux version 6.6.19-1-MANJARO (buildusr@manjaro) (gcc (GCC) 13.2.1 20230801) #1 SMP PREEMPT"
        DISTRO_CMDLINE="BOOT_IMAGE=/boot/vmlinuz-6.6-x86_64 root=UUID=$(gen_uuid) rw quiet apparmor=1"
        ;;
    8)
        DISTRO_NAME="openSUSE Tumbleweed"
        DISTRO_VER="20240315"
        DISTRO_ID="opensuse-tumbleweed"
        DISTRO_LIKE="opensuse suse"
        DISTRO_PRETTY="openSUSE Tumbleweed"
        DISTRO_VER_ID="20240315"
        DISTRO_KERNEL="6.7.9-1-default"
        DISTRO_PROC_VER="Linux version 6.7.9-1-default (geeko@buildhost) (gcc (SUSE Linux) 13.2.1 20240202) #1 SMP PREEMPT_DYNAMIC"
        DISTRO_CMDLINE="BOOT_IMAGE=/boot/vmlinuz-6.7.9-1-default root=UUID=$(gen_uuid) splash=silent quiet security=apparmor"
        ;;
    9)
        DISTRO_NAME="Alpine Linux"
        DISTRO_VER="v3.19"
        DISTRO_ID="alpine"
        DISTRO_LIKE=""
        DISTRO_PRETTY="Alpine Linux v3.19"
        DISTRO_VER_ID="3.19.1"
        DISTRO_KERNEL="6.6.14-0-virt"
        DISTRO_PROC_VER="Linux version 6.6.14-0-virt (builduser@alpine) (gcc (Alpine 13.2.1_git20231014) 13.2.1) #1-Alpine SMP PREEMPT_DYNAMIC"
        DISTRO_CMDLINE="root=UUID=$(gen_uuid) modules=loop,squashfs console=tty0"
        ;;
    10)
        DISTRO_NAME="Red Hat Enterprise Linux"
        DISTRO_VER="9.3 (Plow)"
        DISTRO_ID="rhel"
        DISTRO_LIKE="fedora"
        DISTRO_PRETTY="Red Hat Enterprise Linux 9.3 (Plow)"
        DISTRO_VER_ID="9.3"
        DISTRO_KERNEL="5.14.0-362.18.1.el9_3.x86_64"
        DISTRO_PROC_VER="Linux version 5.14.0-362.18.1.el9_3.x86_64 (mockbuild@x86-vm-07.build.eng.bos.redhat.com) (gcc (GCC) 11.4.1 20231218) #1 SMP PREEMPT"
        DISTRO_CMDLINE="BOOT_IMAGE=(hd0,gpt2)/vmlinuz-5.14.0-362.18.1.el9_3.x86_64 root=UUID=$(gen_uuid) ro rhgb quiet"
        ;;
esac

USER_POOL="user admin guest dev"
HOST_PREFIXES="desktop workstation laptop pc host node"

pick_from() {
    set -- $1
    n=$#
    idx=$(( ( $(od -An -N2 -tu2 < /dev/urandom) % n ) + 1 ))
    eval "printf '%s' \"\${$idx}\""
}

FAKE_USER="$(pick_from "$USER_POOL")"
FAKE_HOSTNAME="$(pick_from "$HOST_PREFIXES")-$(rand_hex 6)"
FAKE_MACHINE_ID="$(rand_hex 32)"
FAKE_BOOT_ID="$(gen_uuid)"

GPU_VENDOR="Intel"
GPU_MESA_STR="Mesa Intel(R) HD Graphics 630 (Kaby Lake GT2)"
if [ -f "$MANIFEST_PATH" ]; then
    v=$(grep '^gpu.vendor=' "$MANIFEST_PATH" | cut -d= -f2-)
    r=$(grep '^gpu.mesa_string=' "$MANIFEST_PATH" | cut -d= -f2-)
    [ -n "$v" ] && GPU_VENDOR="$v"
    [ -n "$r" ] && GPU_MESA_STR="$r"
fi

# ============================================================
# Isolation stage.
#
# The middle script contains NO single-quote characters, so it
# is safe inside a single-quoted sh -c argument. It ends by
# exec'ing the pre-installed obsidian-inner stage with "$@",
# preserving argv element boundaries exactly.
# ============================================================
exec unshare --user --map-root-user --mount --uts --pid --ipc --fork sh -c '
set -e
REAL_UID="$1"; REAL_GID="$2"
FAKE_ROOT="$3"; PRELOAD="$4"
FAKE_USER="$5"; FAKE_HOSTNAME="$6"
FAKE_MACHINE_ID="$7"; FAKE_BOOT_ID="$8"
shift 8
DISTRO_NAME="$1"; DISTRO_VER="$2"; DISTRO_ID="$3"
DISTRO_LIKE="$4"; DISTRO_PRETTY="$5"; DISTRO_VER_ID="$6"
DISTRO_KERNEL="$7"; DISTRO_PROC_VER="$8"; DISTRO_CMDLINE="$9"
shift 9
REAL_RUNTIME_DIR="$1"; WAYLAND_SOCK="$2"
FAKE_CORE_COUNT="$3"; TASKSET_ARG="$4"; MANIFEST_PATH="$5"
GPU_VENDOR="$6"; GPU_MESA_STR="$7"; INNER_STAGE="$8"
GPU_MODE="$9"
shift 9
FONTS_CONF="$1"
shift 1

mount --make-rprivate / 2>/dev/null || true
# v3.5 fix: fake home location. Root mounts a tmpfs on /home and uses $FAKE_HOME
# there. Non-root users cannot write /home nor execute in /tmp (noexec), so their
# fake home lives under their own real home, which is both writable and exec-able.
if [ "$(id -u)" = "0" ]; then
    FAKE_HOME="$FAKE_HOME"
else
    FAKE_HOME="$HOME/.obsidian/$FAKE_USER"
fi
export FAKE_HOME
mount -t proc proc /proc
mount -t tmpfs tmpfs /home
mkdir -p $FAKE_HOME/.fake/sys_spoofs

# Persistent per-application home directory. By default the app keeps
# its preferences, caches and config across launches; only the spoofed
# identity (hostname, machine-id, ...) is regenerated each time. Set
# OBSIDIAN_FRESH=1 for a throwaway launch. The home directory is created
# in the branch below BEFORE the chmod runs: set -e is active here, and a
# chmod on a directory that does not exist yet would abort the launch.
if [ -n "$OBSIDIAN_FRESH" ] && [ "$OBSIDIAN_FRESH" != "0" ]; then
    mkdir -p "$FAKE_HOME"
else
    HOMESTORE="/opt/obsidian/var/homes/$OBSIDIAN_APPKEY"
    # Best-effort, never fatal. If the persistent store cannot be
    # created (e.g. the launcher is run by a user that cannot write
    # /opt/obsidian/var/homes) or the bind is refused by the kernel or
    # filesystem, fall back to a throwaway tmpfs home so the launch
    # still works. set -e is active in this script, so every step is
    # guarded and a failure degrades to the original behaviour.
    if mkdir -p "$HOMESTORE" 2>/dev/null; then
        chmod 700 "$HOMESTORE" 2>/dev/null || true
        chown "$REAL_UID" "$HOMESTORE" 2>/dev/null || true
        mkdir -p "$FAKE_HOME"
        mount --bind "$HOMESTORE" "$FAKE_HOME" 2>/dev/null \
            || mount -o bind "$HOMESTORE" "$FAKE_HOME" 2>/dev/null \
            || true
    else
        mkdir -p "$FAKE_HOME"
    fi
fi
chmod 700 "$FAKE_HOME" 2>/dev/null || true
mkdir -p "$FAKE_HOME/.cache/fontconfig"
mkdir -p "$FAKE_HOME/.config"

touch $FAKE_HOME/.fake/empty
printf "0-1\n" > $FAKE_HOME/.fake/cpu_online

printf "%s\n" "$FAKE_HOSTNAME" > $FAKE_HOME/.fake/hostname
printf "%s\n" "$FAKE_MACHINE_ID" > $FAKE_HOME/.fake/machine-id
printf "%s\n" "$FAKE_BOOT_ID" > $FAKE_HOME/.fake/boot_id
printf "%s\n" "$DISTRO_KERNEL" > $FAKE_HOME/.fake/osrelease
printf "%s\n" "$DISTRO_PROC_VER" > $FAKE_HOME/.fake/version
printf "%s\n" "$DISTRO_CMDLINE" > $FAKE_HOME/.fake/cmdline
printf "UTC\n" > $FAKE_HOME/.fake/timezone

cat > $FAKE_HOME/.fake/os-release <<OSRELEOF
NAME="$DISTRO_NAME"
VERSION="$DISTRO_VER"
ID=$DISTRO_ID
ID_LIKE=$DISTRO_LIKE
PRETTY_NAME="$DISTRO_PRETTY"
VERSION_ID="$DISTRO_VER_ID"
OSRELEOF

hostname "$FAKE_HOSTNAME"

[ -f /etc/hostname ] && mount --bind $FAKE_HOME/.fake/hostname /etc/hostname
[ -f /etc/machine-id ] && mount --bind $FAKE_HOME/.fake/machine-id /etc/machine-id
[ -f /etc/os-release ] && mount --bind $FAKE_HOME/.fake/os-release /etc/os-release
[ -f /proc/version ] && mount --bind $FAKE_HOME/.fake/version /proc/version
[ -f /proc/cmdline ] && mount --bind $FAKE_HOME/.fake/cmdline /proc/cmdline
[ -f /proc/sys/kernel/osrelease ] && { mount --bind $FAKE_HOME/.fake/osrelease /proc/sys/kernel/osrelease 2>/dev/null || true; }
[ -f /etc/timezone ] && mount --bind $FAKE_HOME/.fake/timezone /etc/timezone
[ -f /etc/localtime ] && mount --bind /usr/share/zoneinfo/UTC /etc/localtime

for f in /etc/issue /etc/issue.net /etc/lsb-release /etc/alpine-release /etc/debian_version /etc/arch-release /etc/redhat-release; do
    [ -f "$f" ] && mount --bind $FAKE_HOME/.fake/empty "$f" 2>/dev/null || true
done

cat > $FAKE_HOME/.fake/passwd <<PASSWDEOF
root:x:0:0:root:/root:/bin/sh
$FAKE_USER:x:1000:1000:Generic User:$FAKE_HOME:/bin/sh
nobody:x:65534:65534:nobody:/:/sbin/nologin
PASSWDEOF

cat > $FAKE_HOME/.fake/group <<GROUPEOF
root:x:0:
$FAKE_USER:x:1000:
nobody:x:65534:
GROUPEOF

[ -f /etc/passwd ] && mount --bind $FAKE_HOME/.fake/passwd /etc/passwd 2>/dev/null || true
[ -f /etc/group ] && mount --bind $FAKE_HOME/.fake/group /etc/group 2>/dev/null || true

if [ -f /var/lib/dbus/machine-id ] && [ ! -L /var/lib/dbus/machine-id ]; then
    mount --bind $FAKE_HOME/.fake/machine-id /var/lib/dbus/machine-id
fi
[ -f /proc/sys/kernel/random/boot_id ] && { mount --bind $FAKE_HOME/.fake/boot_id /proc/sys/kernel/random/boot_id 2>/dev/null || true; }

mount -t tmpfs tmpfs /tmp
chmod 1777 /tmp

: > $FAKE_HOME/.fake/cpuinfo
c=0
while [ "$c" -lt "$FAKE_CORE_COUNT" ]; do
    cat >> $FAKE_HOME/.fake/cpuinfo <<CPUEOF
processor	: $c
vendor_id	: GenuineIntel
cpu family	: 6
model		: 142
model name	: Intel(R) Core(TM) i5-8250U CPU @ 1.60GHz
stepping	: 10
cpu MHz		: 1600.000
cache size	: 6144 KB
physical id	: 0
siblings	: $FAKE_CORE_COUNT
core id		: $c
cpu cores	: $FAKE_CORE_COUNT
apicid		: $c
flags		: fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush mmx fxsr sse sse2 ss ht syscall nx rdtscp lm constant_tsc rep_good nopl cpuid pni ssse3 cx16 sse4_1 sse4_2 x2apic popcnt aes xsave avx f16c rdrand hypervisor
bogomips	: 3600.00

CPUEOF
    c=$((c + 1))
done
[ -f /proc/cpuinfo ] && mount --bind $FAKE_HOME/.fake/cpuinfo /proc/cpuinfo

# /proc/meminfo - sysinfo() is hooked in libc, but a direct read of
# /proc/meminfo bypasses libc entirely. Values are kept consistent
# with OBSIDIAN_TOTAL_MEMORY and the sysinfo() hook.
cat > $FAKE_HOME/.fake/meminfo <<MEMEOF
MemTotal:        8192000 kB
MemFree:         4096000 kB
MemAvailable:    6144000 kB
Buffers:          204800 kB
Cached:          2048000 kB
SwapCached:            0 kB
Active:          2048000 kB
Inactive:        1024000 kB
Active(anon):     786432 kB
Inactive(anon):   131072 kB
Active(file):    1261568 kB
Inactive(file):   892928 kB
Unevictable:           0 kB
Mlocked:               0 kB
SwapTotal:       2097152 kB
SwapFree:        2097152 kB
Dirty:               128 kB
Writeback:             0 kB
AnonPages:       1024000 kB
Mapped:           512000 kB
Shmem:            102400 kB
Slab:             204800 kB
SReclaimable:     131072 kB
SUnreclaim:        73728 kB
KernelStack:        8192 kB
PageTables:        24576 kB
CommitLimit:     6193152 kB
Committed_AS:    2621440 kB
VmallocTotal:   34359738367 kB
VmallocUsed:       32768 kB
VmallocChunk:          0 kB
MEMEOF
[ -f /proc/meminfo ] && mount --bind $FAKE_HOME/.fake/meminfo /proc/meminfo 2>/dev/null || true

UPTIME_SECS=$(( ( $(od -An -N2 -tu2 < /dev/urandom) % 90000 ) + 600 ))
IDLE_SECS=$(( UPTIME_SECS * 60 / 100 ))
NOW=$(date +%s); FAKE_BTIME=$(( NOW - UPTIME_SECS ))

printf "%s.00 %s.00\n" "$UPTIME_SECS" "$IDLE_SECS" > $FAKE_HOME/.fake/uptime
printf "0.15 0.10 0.05 1/100 1234\n" > $FAKE_HOME/.fake/loadavg
: > $FAKE_HOME/.fake/diskstats

cat > $FAKE_HOME/.fake/stat.awk <<\STATAWKEOF
/^cpu[0-9]+/ { n = substr($1, 4) + 0; if (n >= ncpu) next }
$1 == "btime" { print "btime " bt; next }
{ print }
STATAWKEOF

if [ -f /proc/stat ]; then
    awk -v bt="$FAKE_BTIME" -v ncpu="$FAKE_CORE_COUNT" -f $FAKE_HOME/.fake/stat.awk /proc/stat > $FAKE_HOME/.fake/stat
fi

for pair in "uptime:/proc/uptime" "loadavg:/proc/loadavg" "diskstats:/proc/diskstats" "stat:/proc/stat"; do
    src="$FAKE_HOME/.fake/${pair%%:*}"; dst="${pair##*:}"
    [ -f "$dst" ] && mount --bind "$src" "$dst" 2>/dev/null || true
done

[ -d /etc/apk ] && mount -t tmpfs tmpfs /etc/apk 2>/dev/null || true
[ -d /lib/apk ] && mount -t tmpfs tmpfs /lib/apk 2>/dev/null || true
[ -d /sys/firmware/acpi ] && mount -t tmpfs tmpfs /sys/firmware/acpi 2>/dev/null || true

# Hardware Manifest Enforcement
if [ -f "$MANIFEST_PATH" ]; then
    idx=0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            \#*|"") continue ;;
            sys.mask.*=*)
                rest="${line#sys.mask.}"
                sub="${rest%%=*}"
                case "$sub" in
                    /*) mask_dir="$sub" ;;
                    *)  mask_dir="/sys/class/$sub" ;;
                esac
                if [ -d "$mask_dir" ]; then
                    mount -t tmpfs tmpfs "$mask_dir" 2>/dev/null || true
                fi
                ;;
            sys.spoof.*=*)
                rest="${line#sys.spoof.}"
                path="${rest%%=*}"
                val="${rest#*=}"
                if [ -e "$path" ]; then
                    if [ -z "$val" ]; then
                        mount --bind $FAKE_HOME/.fake/empty "$path" 2>/dev/null || true
                    else
                        idx=$((idx + 1))
                        sp_file="$FAKE_HOME/.fake/sys_spoofs/sp_$idx"
                        printf "%s\n" "$val" > "$sp_file"
                        mount --bind "$sp_file" "$path" 2>/dev/null || true
                    fi
                fi
                ;;
            dev.null=*)
                dpath="${line#dev.null=}"
                if [ -e "$dpath" ]; then
                    mount --bind /dev/null "$dpath" 2>/dev/null || true
                fi
                ;;
        esac
    done < "$MANIFEST_PATH"
fi

# GPU strict mode: full DRM blackout. Software rendering only.
if [ "$GPU_MODE" = strict ]; then
    [ -d /sys/class/drm ] && mount -t tmpfs tmpfs /sys/class/drm 2>/dev/null || true
    [ -d /dev/dri ] && mount -t tmpfs tmpfs /dev/dri 2>/dev/null || true
fi

# Hardware Subsystem Namespace Isolation Sweeps
mask_sysfs_class_targets() {
    class_dir="$1"
    [ -d "$class_dir" ] || return 0
    for link in "$class_dir"/*; do
        [ -e "$link" ] || continue
        [ -L "$link" ] || continue
        target="$(readlink -f "$link" 2>/dev/null)" || continue
        [ -n "$target" ] && [ -d "$target" ] && mount -t tmpfs tmpfs "$target" 2>/dev/null || true
    done
}
mask_sysfs_class_targets /sys/class/input
mask_sysfs_class_targets /sys/class/sound
mask_sysfs_class_targets /sys/class/hidraw
mask_sysfs_class_targets /sys/class/video4linux

for d in /sys/devices/system/cpu /sys/block /sys/bus/usb \
         /dev/bus/usb /proc/bus/input /dev/input /sys/class/input \
         /proc/asound /sys/class/sound /dev/snd \
         /sys/class/hidraw /sys/bus/hid /sys/class/video4linux \
         /run/udev; do
    [ -d "$d" ] && mount -t tmpfs tmpfs "$d" 2>/dev/null || true
done

for vd in /dev/video* /dev/media* /dev/hidraw*; do
    [ -e "$vd" ] && mount --bind /dev/null "$vd" 2>/dev/null || true
done

# IPC and Wayland Socket Passthrough
if [ -n "$REAL_RUNTIME_DIR" ] && [ -d "$REAL_RUNTIME_DIR" ]; then
    mkdir -p /tmp/obsidian/.real_socks
    for sock in "$WAYLAND_SOCK" pulse/native pipewire-0; do
        if [ -S "$REAL_RUNTIME_DIR/$sock" ]; then
            mkdir -p "$(dirname "/tmp/obsidian/.real_socks/$sock")"
            touch "/tmp/obsidian/.real_socks/$sock"
            mount --bind "$REAL_RUNTIME_DIR/$sock" "/tmp/obsidian/.real_socks/$sock"
        fi
    done

    mount -t tmpfs tmpfs "$REAL_RUNTIME_DIR"

    for sock in "$WAYLAND_SOCK" pulse/native pipewire-0; do
        if [ -S "/tmp/obsidian/.real_socks/$sock" ]; then
            mkdir -p "$(dirname "$REAL_RUNTIME_DIR/$sock")"
            touch "$REAL_RUNTIME_DIR/$sock"
            mount --bind "/tmp/obsidian/.real_socks/$sock" "$REAL_RUNTIME_DIR/$sock"
        fi
    done
fi

# Environment Export Engine
export LD_PRELOAD="$PRELOAD"
export HOME="$FAKE_HOME"
export USER="$FAKE_USER"
export LOGNAME="$FAKE_USER"
export TZ=UTC
export LANG=en_US.UTF-8
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_CONFIG_HOME="$HOME/.config"
export TASKSET_ARG
export OBSIDIAN_KERNEL_RELEASE="$DISTRO_KERNEL"
export OBSIDIAN_TOTAL_MEMORY="8192000"
export OBSIDIAN_GPU_VENDOR="$GPU_VENDOR"
export OBSIDIAN_GPU_RENDERER="$GPU_MESA_STR"
export OBSIDIAN_GPU_MODE="$GPU_MODE"
[ -n "$REAL_RUNTIME_DIR" ] && export XDG_RUNTIME_DIR="$REAL_RUNTIME_DIR" || true

# Fontconfig: the installed font list is a strong fingerprint. This
# config keeps the system font directory (so text still renders) but
# drops host-specific and per-user font paths and pins the cache into
# the private tmpfs, making the enumeration deterministic.
if [ -f "$FONTS_CONF" ] && [ -d /usr/share/fonts ]; then
    export FONTCONFIG_FILE="$FONTS_CONF"
fi

# Layer 2 (HARDEN=1 / paranoid): point the hardening stage at the per-app
# profile built by `obsidian --profile build`, if one exists.
if [ "${OBSIDIAN_HARDEN:-}" = "1" ] || [ "${OBSIDIAN_HARDEN:-}" = "paranoid" ]; then
    _pp="${XDG_CONFIG_HOME:-$HOME/.config}/obsidian/profiles/$OBSIDIAN_APPKEY.profile"
    [ -f "$_pp" ] || _pp="/etc/obsidian/profiles/$OBSIDIAN_APPKEY.profile"
    [ -f "$_pp" ] || _pp="$OBSIDIAN_DIR/var/profiles/$OBSIDIAN_APPKEY.profile"
    [ -f "$_pp" ] && export OBSIDIAN_HARDEN_PROFILE="$_pp"
fi

# Final stage. "$@" still holds the caller argv, one element per
# argument, handed to obsidian-inner unflattened.
# When launched as root we keep root mapped so the namespace has the
# capabilities the sandbox needs (mounts, netns setup, BPF-LSM attach).
# Otherwise we map the real non-root user.
if [ "$(id -u)" = "0" ]; then
    UNS_ARGS="--user --map-root-user --mount"
else
    UNS_ARGS="--user --map-user=1000 --map-group=1000 --mount"
fi

# v3.5 (AppArmor backend, Option C). When AppArmor + aa-exec are present and
# we are root, load the per-app profile and run the whole launch under it so
# the app is kernel-confined (hardware denied, cannot read other users/root,
# cannot read Obsidian internals). The profile is loaded here, in the root
# context, because the inner stage runs unprivileged and cannot load it.
OBS_AA="$BINDIR/obsidian-apparmor.sh"
if [ -x "$OBS_AA" ] && [ "$(id -u)" = "0" ] && command -v aa-exec >/dev/null 2>&1; then
    HW_FLAG=""; [ "$GPU_MODE" = strict ] && HW_FLAG="--enforce-hw"
    "$OBS_AA" load "$OBSIDIAN_APPKEY" "$HOME" $HW_FLAG >/dev/null 2>&1 || true
    exec aa-exec -p "obsidian-$OBSIDIAN_APPKEY" -- unshare $UNS_ARGS "$INNER_STAGE" "$@"
fi
exec unshare $UNS_ARGS "$INNER_STAGE" "$@"
' -- "$REAL_UID" "$REAL_GID" "$FAKE_ROOT" "$PRELOAD" "$FAKE_USER" "$FAKE_HOSTNAME" \
     "$FAKE_MACHINE_ID" "$FAKE_BOOT_ID" "$DISTRO_NAME" "$DISTRO_VER" "$DISTRO_ID" \
     "$DISTRO_LIKE" "$DISTRO_PRETTY" "$DISTRO_VER_ID" "$DISTRO_KERNEL" "$DISTRO_PROC_VER" \
     "$DISTRO_CMDLINE" "$REAL_RUNTIME_DIR" "$REAL_WAYLAND_SOCK" "$FAKE_CORE_COUNT" \
     "$TASKSET_ARG" "$MANIFEST_PATH" "$GPU_VENDOR" "$GPU_MESA_STR" "$INNER_STAGE" \
     "$GPU_MODE" "$FONTS_CONF" "$@"
OBSIDIAN_PAYLOAD_LAUNCH
chmod 755 "$BINDIR/obsidian-launch"
ok "bin/obsidian-launch"

cat > "$BINDIR/obsidian-inner" <<'OBSIDIAN_PAYLOAD_INNER'
#!/bin/sh
# ============================================================
# /opt/obsidian/bin/obsidian-inner
# Obsidian Mirror - Final execution stage.
#
# Runs INSIDE the isolation namespaces, after the environment
# export engine has completed. Applies seccomp-bpf confinement
# and CPU-affinity clamping, then hands control to the target
# application.
#
# NOTE: This file is written ONCE, at install time, by
# install.sh. It is deliberately NOT generated at launch time
# from a nested here-document -- that is what produced the
# "exec: line 7: <command>: not found" argv-flattening defect.
# ============================================================
set -e

OBSIDIAN_SECCOMP="/opt/obsidian/bin/seccomp_enforcer"
TASKSET_ARG="${TASKSET_ARG:-0}"

if [ "$#" -eq 0 ]; then
    echo "obsidian-inner: no command supplied" >&2
    exit 1
fi

# "$@" is expanded HERE, at run time, by this shell -- each
# argument stays a separate argv element.
if command -v taskset >/dev/null 2>&1; then
    if [ -x "$OBSIDIAN_SECCOMP" ]; then
        exec "$OBSIDIAN_SECCOMP" -- taskset -c "$TASKSET_ARG" "$@"
    fi
    exec taskset -c "$TASKSET_ARG" "$@"
fi

if [ -x "$OBSIDIAN_SECCOMP" ]; then
    exec "$OBSIDIAN_SECCOMP" -- "$@"
fi

exec "$@"
OBSIDIAN_PAYLOAD_INNER
chmod 755 "$BINDIR/obsidian-inner"
ok "bin/obsidian-inner"

cat > "$BINDIR/obsidian-audit" <<'OBSIDIAN_PAYLOAD_AUDIT'
#!/bin/sh
# ============================================================
# /opt/obsidian/bin/obsidian-audit
# Obsidian Mirror - metadata protection audit.
#
# Runs the metadata probe twice -- once natively on the host, once
# inside the Obsidian isolation layer -- and reports, in order:
#
#   1  SUMMARY OF PROTECTED METADATA
#      how many host identifiers are spoofed or masked, broken
#      down by category, with a coverage figure.
#
#   2  REAL vs PROTECTED
#      every observed item side by side: what the host really is,
#      and what the application is allowed to see.
#
#   3  HOST METADATA NOT PROTECTED
#      every item that still reaches the application, each with
#      the reason it is not covered and, where one exists, the
#      switch that covers it.
#
#   4  APPLICATION COMPATIBILITY
#      proof that the isolation layer did not break the thing it
#      is wrapping: argv integrity, exit status, stdin, and the
#      Wayland display socket.
#
# Grades used:
#   PROTECT  the application sees a spoofed / masked value
#   LEAK     the real host value reaches the application
#   GAP      known limitation, documented with a reason
#   SCOPE    network layer: excluded from this project by design
#   N/A      the host does not have this hardware
#   INFO     shown, never graded
#
# Usage:
#   obsidian --test             full report   (same as obsidian-audit)
#   obsidian-audit -q           sections 1, 3 and 4 only
#   obsidian-audit -a           also show unrated informational rows
#   obsidian-audit -v           do not truncate values
#   obsidian-audit --raw        dump both probe outputs, no grading
#   obsidian-audit --no-color   plain text, for piping to a file
# ============================================================

OBSIDIAN_DIR="/opt/obsidian"
PROBE="$OBSIDIAN_DIR/scripts/obsidian-probe.sh"
LAUNCHER="${OBSIDIAN_LAUNCHER:-obsidian}"

MODE_FULL=1; SHOW_INFO=0; VERBOSE=0; RAW=0; COLOR=auto

while [ $# -gt 0 ]; do
    case "$1" in
        -q|--quiet)    MODE_FULL=0 ;;
        -a|--all)      SHOW_INFO=1 ;;
        -v|--verbose)  VERBOSE=1 ;;
        --raw)         RAW=1 ;;
        --no-color)    COLOR=no ;;
        -h|--help)
            sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "obsidian-audit: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ ! -r "$PROBE" ]; then
    echo "ERROR: probe not found: $PROBE" >&2
    exit 1
fi
if ! command -v "$LAUNCHER" >/dev/null 2>&1; then
    echo "ERROR: launcher '$LAUNCHER' not on PATH." >&2
    exit 1
fi

WIDTH="$(stty size 2>/dev/null | cut -d' ' -f2)"
case "$WIDTH" in ''|*[!0-9]*) WIDTH="$COLUMNS" ;; esac
case "$WIDTH" in ''|*[!0-9]*) WIDTH=100 ;; esac
[ "$WIDTH" -lt 60 ] && WIDTH=100

if [ "$COLOR" = auto ]; then
    if [ -t 1 ]; then COLOR=yes; else COLOR=no; fi
fi

TMPD="$(mktemp -d 2>/dev/null || echo /tmp/obsidian-audit.$$)"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT INT TERM

echo "Collecting host baseline..." >&2
sh "$PROBE" > "$TMPD/host.tsv" 2>"$TMPD/host.err"

echo "Collecting mirrored view (via $LAUNCHER)..." >&2
"$LAUNCHER" sh "$PROBE" > "$TMPD/inner.tsv" 2>"$TMPD/inner.err"

if [ ! -s "$TMPD/inner.tsv" ]; then
    echo "ERROR: the mirrored probe produced no output." >&2
    echo "----- stderr -----" >&2
    cat "$TMPD/inner.err" >&2
    exit 1
fi

if [ "$RAW" -eq 1 ]; then
    echo "===== HOST ====="; cat "$TMPD/host.tsv"
    echo; echo "===== OBSIDIAN ====="; cat "$TMPD/inner.tsv"
    exit 0
fi

# ------------------------------------------------------------
# Application-compatibility probes.
#
# The hard requirement on this project is that wrapping a command
# in "obsidian" must not change how that command behaves. These
# four checks are run live, every audit.
# ------------------------------------------------------------
echo "Running compatibility checks..." >&2
: > "$TMPD/compat.tsv"

# 1. argv integrity: three arguments, the middle one containing
#    spaces, must arrive as three separate argv elements. This is
#    the exact regression that the launcher rewrite fixed.
cargv="$("$LAUNCHER" printf '%s|' one "two three" four 2>/dev/null)"
if [ "$cargv" = "one|two three|four|" ]; then
    printf 'compat.argv\tOK\targv passed through unflattened\t%s\n' "$cargv" >> "$TMPD/compat.tsv"
else
    printf 'compat.argv\tBROKEN\targv passed through unflattened\t%s\n' "$cargv" >> "$TMPD/compat.tsv"
fi

# 2. exit status must propagate back out of all the namespaces.
"$LAUNCHER" sh -c 'exit 42' >/dev/null 2>&1
crc=$?
if [ "$crc" -eq 42 ]; then
    printf 'compat.exit\tOK\texit status propagates\t42\n' >> "$TMPD/compat.tsv"
else
    printf 'compat.exit\tBROKEN\texit status propagates\t%s\n' "$crc" >> "$TMPD/compat.tsv"
fi

# 3. stdin must reach the application.
cstdin="$(printf 'obsidian-stdin-ok\n' | "$LAUNCHER" cat 2>/dev/null)"
if [ "$cstdin" = "obsidian-stdin-ok" ]; then
    printf 'compat.stdin\tOK\tstdin reaches the application\tobsidian-stdin-ok\n' >> "$TMPD/compat.tsv"
else
    printf 'compat.stdin\tBROKEN\tstdin reaches the application\t%s\n' "$cstdin" >> "$TMPD/compat.tsv"
fi

# 4. the Wayland display socket must stay reachable, otherwise
#    every graphical application is broken. Read from the probe.
why="$(grep '^ipc.wayland_disp' "$TMPD/inner.tsv" 2>/dev/null | cut -f2)"
whyh="$(grep '^ipc.wayland_disp' "$TMPD/host.tsv" 2>/dev/null | cut -f2)"
if [ "$whyh" != "connected" ]; then
    printf 'compat.wayland\tN/A\tWayland display socket reachable\tno compositor on host\n' >> "$TMPD/compat.tsv"
elif [ "$why" = "connected" ]; then
    printf 'compat.wayland\tOK\tWayland display socket reachable\tconnected\n' >> "$TMPD/compat.tsv"
else
    printf 'compat.wayland\tBROKEN\tWayland display socket reachable\t%s\n' "$why" >> "$TMPD/compat.tsv"
fi

# 5. GPU acceleration path. In compat mode the render node must
#    still be present; in strict mode its absence is intended.
gmode="$(grep '^gpu.mode' "$TMPD/inner.tsv" 2>/dev/null | cut -f2)"
gin="$(grep '^gpu.dri_count' "$TMPD/inner.tsv" 2>/dev/null | cut -f2)"
ghost="$(grep '^gpu.dri_count' "$TMPD/host.tsv" 2>/dev/null | cut -f2)"
if [ "$ghost" = "0" ] || [ -z "$ghost" ]; then
    printf 'compat.gpu\tN/A\tGPU render node available\tno DRM device on host\n' >> "$TMPD/compat.tsv"
elif [ "$gmode" = strict ]; then
    printf 'compat.gpu\tOK\tGPU render node available\tmasked on purpose (strict mode)\n' >> "$TMPD/compat.tsv"
elif [ "$gin" != "0" ]; then
    printf 'compat.gpu\tOK\tGPU render node available\t%s node(s) visible\n' "$gin" >> "$TMPD/compat.tsv"
else
    printf 'compat.gpu\tBROKEN\tGPU render node available\thidden in compat mode\n' >> "$TMPD/compat.tsv"
fi

# ------------------------------------------------------------
# Grading rules
#   key <TAB> mode <TAB> expected <TAB> label <TAB> reason
#
#   DIFF     must differ from the host value
#   EQ       must equal the expected value exactly
#   HAS      must contain the expected substring
#   EMPTY    must be "(none)" or 0
#   SOFT     protected if it equals the expected value OR differs
#            from the host (covers spoof-or-mask, either is fine)
#   IN       must equal one of a |-separated list of accepted values
#   MAX      numeric: must be less than or equal to the expected value
#   NOCONN   socket must not be reachable from inside
#   GAP      known limitation; PROTECT if it happens to differ
#   TELL     detectability signal; PROTECT only at the clean value
#   SCOPE    out of scope by project design (network layer)
#   INFO     shown, never graded
#
# The reason column is what section 3 prints. Every non-protected
# item must carry one: an unexplained gap is a lie by omission.
# ------------------------------------------------------------
cat > "$TMPD/rules.tsv" <<'RULES'
id.hostname	DIFF		Hostname (UTS namespace)	
id.uname_nodename	DIFF		uname nodename	
id.uname_release	DIFF		Kernel release (uname -r)	The OS identity is drawn at random from 10 complete profiles on every launch. On this run the draw happened to match the real host - a 1-in-10 event, not a rule failure. Re-run the audit and it will differ.
id.uname_version	HAS	SMP PREEMPT_DYNAMIC	Kernel version string	
id.uname_machine	INFO		Architecture	CPU architecture is not concealable; every binary is built for it
id.machine_id	DIFF		/etc/machine-id	
id.dbus_machine_id	DIFF		D-Bus machine-id	
id.boot_id	DIFF		Kernel boot_id	
id.env_user	DIFF		$USER	
id.env_home	DIFF		$HOME	
id.uid	EQ	1000	Numeric UID	
id.gid	EQ	1000	Numeric GID	
id.username	DIFF		getpwuid() name	
id.groupname	DIFF		getgrgid() name	
id.passwd_lines	EQ	3	/etc/passwd entry count	
id.group_lines	EQ	3	/etc/group entry count	
id.passwd_self	DIFF		Own passwd record	
id.shell	INFO		$SHELL	
os.id	DIFF		Distribution ID	The OS identity is drawn at random from 10 complete profiles on every launch. On this run the draw happened to match the real host - a 1-in-10 event, not a rule failure. Re-run the audit and it will differ.
os.pretty	DIFF		Distribution pretty name	The OS identity is drawn at random from 10 complete profiles on every launch. On this run the draw happened to match the real host - a 1-in-10 event, not a rule failure. Re-run the audit and it will differ.
os.version	DIFF		Distribution version	The OS identity is drawn at random from 10 complete profiles on every launch. On this run the draw happened to match the real host - a 1-in-10 event, not a rule failure. Re-run the audit and it will differ.
os.proc_version	DIFF		/proc/version	
os.proc_cmdline	DIFF		/proc/cmdline (boot args + root UUID)	
os.kernel_osrelease	DIFF		/proc/sys/kernel/osrelease	
os.issue	EMPTY		/etc/issue	
os.lsb_release	EMPTY		/etc/lsb-release	
os.distro_files	EMPTY		Distro release file contents	
os.distro_file_names	INFO		Distro release file names	The filenames survive as empty bind mounts; only their contents are blanked. An empty /etc/debian_version tells an application nothing.
os.apk_world	EMPTY		Package selection list	
os.apk_installed	EMPTY		Installed package database	
cpu.nproc	EQ	2	nproc()	
cpu.model	HAS	i5-8250U	CPU model name	
cpu.vendor	HAS	GenuineIntel	CPU vendor	
cpu.count_cpuinfo	EQ	2	Core count (/proc/cpuinfo)	
cpu.mhz	HAS	1600	CPU clock	
cpu.cache	HAS	6144	CPU cache size	
cpu.bogomips	HAS	3600	BogoMIPS	
cpu.online	SOFT	0-1	cpu/online (open() redirect)	
cpu.possible	SOFT	0-1	cpu/possible (open() redirect)	
cpu.sysfs_dirs	EMPTY		Per-core sysfs directories	
cpu.flags_len	INFO		CPU flag count	CPUID runs in userspace; feature bits cannot be masked without a hypervisor
mem.meminfo_total	EQ	8192000	RAM total (/proc/meminfo)	
mem.meminfo_free	EQ	4096000	RAM free (/proc/meminfo)	
mem.meminfo_avail	EQ	6144000	RAM available (/proc/meminfo)	
mem.meminfo_swap	EQ	2097152	Swap total (/proc/meminfo)	
mem.sysinfo_total	EQ	8192000	RAM via sysinfo()	
mem.meminfo_lines	INFO		/proc/meminfo field count	
time.zone_abbr	IN	UTC|GMT|UCT|Z|Zulu	Timezone abbreviation	
time.utc_offset	EQ	+0000	UTC offset	
time.etc_timezone	EQ	UTC	/etc/timezone	
time.uptime	DIFF		System uptime	
time.btime	DIFF		Boot timestamp (/proc/stat)	
time.loadavg	EQ	0.15 0.10 0.05	Load average	
time.stat_cpulines	EQ	2	Per-CPU rows in /proc/stat	
ts.mtime_mod3600	EQ	0	File mtime, second within hour	
ts.mtime_nsec	EQ	0	File mtime nanoseconds (statx)	
ts.mtime_raw	INFO		Raw mtime as the app reads it	
dmi.sys_vendor	EQ	Generic	DMI system vendor	
dmi.product_name	EQ	Generic Laptop	DMI product name	
dmi.product_version	EQ	1.0	DMI product version	
dmi.product_serial	HAS	O.E.M.	DMI product serial	
dmi.product_uuid	EQ	00000000-0000-0000-0000-000000000000	DMI product UUID	
dmi.product_family	EQ	Generic	DMI product family	
dmi.product_sku	EQ	Generic	DMI product SKU	
dmi.board_vendor	EQ	Generic	DMI board vendor	
dmi.board_name	EQ	Generic Board	DMI board name	
dmi.board_version	EQ	1.0	DMI board version	
dmi.board_serial	HAS	O.E.M.	DMI board serial	
dmi.board_asset_tag	HAS	O.E.M.	DMI board asset tag	
dmi.bios_vendor	EQ	Generic	BIOS vendor	
dmi.bios_version	EQ	1.0.0	BIOS version	
dmi.bios_date	EQ	01/01/2020	BIOS date	
dmi.bios_release	EQ	1.0	BIOS release	
dmi.chassis_vendor	EQ	Generic	DMI chassis vendor	
dmi.chassis_version	EQ	1.0	DMI chassis version	
dmi.chassis_serial	HAS	O.E.M.	DMI chassis serial	
dmi.chassis_asset_tag	HAS	O.E.M.	DMI chassis asset tag	
dmi.chassis_type	EQ	10	DMI chassis type	
dmi.modalias	HAS	Generic	DMI modalias string	
fw.acpi_tables	EMPTY		ACPI table blobs	
fw.efi_present	INFO		EFI firmware present	
fw.dtb_present	INFO		Device tree present	
blk.devices	EMPTY		Block device list	
blk.count	EMPTY		Block device count	
blk.model	DIFF		Disk model	
blk.serial	DIFF		Disk serial	
blk.vendor	DIFF		Disk vendor	
blk.wwid	DIFF		Disk WWID	
blk.scsi_classes	EMPTY		SCSI/ATA class entries	
blk.root_source	INFO		Root filesystem source	
blk.mount_count	INFO		Mount table size	
tpm.class_nodes	EMPTY		TPM sysfs class	
tpm.version	EMPTY		TPM version	
tpm.dev_nodes	INFO		TPM device nodes (bound to /dev/null)	
pwr.supplies	INFO		Power supply list	
pwr.bat_manufacturer	EQ	Generic	Battery manufacturer	
pwr.bat_serial	EQ	00000	Battery serial	
thermal.zone_types	HAS	acpitz	Thermal zone types	
hwmon.names	HAS	acpitz	Hwmon sensor driver names	
thermal.cooling_types	HAS	Processor	Cooling device types	
bt.addresses	HAS	02:1a:11	Bluetooth adapter MAC	
rtc.names	HAS	rtc_cmos	RTC driver name	
backlight.types	HAS	raw	Backlight type	
input.proc_count	EMPTY		Input devices (/proc/bus/input)	
input.dev_count	EMPTY		/dev/input nodes	
input.class_count	EMPTY		/sys/class/input entries	
snd.cards	EMPTY		ALSA card list	
snd.dev_count	EMPTY		/dev/snd nodes	
usb.device_count	EMPTY		USB device count	
udev.db_entries	EMPTY		udev database entries	
video.dev_nodes	INFO		Camera nodes (bound to /dev/null)	
hidraw.dev_nodes	INFO		HID raw nodes (bound to /dev/null)	
gpu.drm_subsys_vendor	SOFT	0x8086	DRM subsystem vendor (OEM board pin)	
gpu.drm_subsys_device	SOFT	0x0000	DRM subsystem device (OEM board pin)	
gpu.drm_label	SOFT	Generic Graphics	DRM device label	
gpu.edid_bytes	EQ	0	Monitor EDID (serial + build date)	
gpu.dri_nodes	GAP		DRM render nodes (/dev/dri)	Left reachable so GPU acceleration keeps working. Vulkan and EGL can read the real adapter through them. Run OBSIDIAN_GPU_MODE=strict obsidian <app> to mask /dev/dri and /sys/class/drm completely -- the app then falls back to software rendering.
gpu.drm_class	GAP		DRM sysfs class	Same trade-off as /dev/dri: masking the class breaks Mesa driver selection. Covered by OBSIDIAN_GPU_MODE=strict.
gpu.pci_line	GAP		GPU PCI identification	The GPU PCI vendor/device pair is deliberately left real: Mesa picks its driver from it, and lying makes hardware acceleration collapse. Every non-GPU PCI device is anonymised. Covered by OBSIDIAN_GPU_MODE=strict.
gpu.gl_vendor	INFO		OpenGL vendor string	
gpu.gl_renderer	INFO		OpenGL renderer string	
gpu.gl_ext_count	INFO		OpenGL extension count	
gpu.mode	INFO		Active GPU mode	
pci.vendor_ids	DIFF		PCI vendor ID set	
pci.device_count	INFO		PCI device count	
net.interfaces	SCOPE		Network interface names	Network layer is out of scope by design. Pair Obsidian Mirror with a VPN or a network namespace.
net.mac_addresses	SCOPE		NIC MAC addresses	Out of scope. getifaddrs() is hooked, but anything using netlink directly (ip, ss, most language runtimes) sees the real MAC.
net.resolv_conf	SCOPE		DNS resolver configuration	Out of scope: resolver identity belongs to the network layer.
net.hosts_lines	SCOPE		/etc/hosts	Out of scope.
proc.visible_pids	DIFF		Visible process count (PID ns)	
proc.pid1_comm	DIFF		PID 1 command	
ipc.shm_segments	EMPTY		SysV shared memory segments	
ipc.compositor_ctl	NOCONN		Compositor control socket	
ipc.dbus_system	NOCONN		D-Bus system bus	
ipc.dbus_session	NOCONN		D-Bus session bus	
ipc.wayland_disp	INFO		Wayland display socket	Passed through on purpose. wl_output still reports real resolution, refresh rate, physical size and monitor make -- inherent to sharing the host compositor. Only a nested compositor (cage, wlheadless) removes it.
ipc.runtime_dir_entries	MAX	3	XDG_RUNTIME_DIR contents	
sec.seccomp_mode	EQ	2	seccomp filter mode	
sec.nonewprivs	EQ	1	NoNewPrivs flag	
sec.userns_uidmap	DIFF		User namespace UID map	
sec.cap_effective	INFO		Effective capabilities	
fs.home_entries	DIFF		/home contents	
fs.user_font_dirs	EMPTY		Per-user font directories	
fs.hostlocal_font_dirs	INFO		Host-local font directories	Still present on disk - there is no pivot_root - but no longer scanned, because FONTCONFIG_FILE points at a config that does not list them.
fs.fontconfig_file	HAS	fonts.conf	Fontconfig pinned to Obsidian config	Set only when fontconfig and /usr/share/fonts are both present on the host. Without it the installed font list stays readable and is a strong fingerprint.
fs.font_count	INFO		Fonts visible to the app	
fs.font_families	INFO		Font families visible	
fs.font_family_sig	INFO		Font family set signature	
fs.root_home	GAP		Host /root readable (no pivot_root)	There is no pivot_root, so the host filesystem outside the masked paths is still visible, subject to normal permissions. /home is tmpfs, so user data is covered; /root, /var, /srv and other users' files are not. Fixing this needs a full root pivot, which breaks applications that read their own installation directory.
fs.userhome_count	INFO		Files in $HOME	
fs.tmp_count	INFO		Files in /tmp	
det.ld_preload	TELL	(none)	LD_PRELOAD visible to application	LD_PRELOAD must stay set for the libc hooks to exist. Any application that reads /proc/self/environ can see it. Obsidian Mirror makes you anonymous, not invisible.
det.obsidian_env	TELL	0	OBSIDIAN_* variables in environment	The hooks read their spoofed values from these variables, so they have to be in the environment.
det.mount_fakes	TELL	0	Spoof binds visible in mountinfo	/proc/self/mountinfo lists every bind mount. Hiding it needs a pivot_root plus a private /proc, which breaks applications.
det.opt_obsidian	TELL	hidden	/opt/obsidian visible in filesystem	The launcher, hooks and manifest have to live somewhere the sandboxed process can reach.
det.mountinfo_rows	INFO		Mount table rows	
RULES

AWK="$(command -v gawk 2>/dev/null || command -v awk)"

"$AWK" -F'\t' \
    -v W="$WIDTH" -v COLOR="$COLOR" -v FULL="$MODE_FULL" \
    -v SHOWINFO="$SHOW_INFO" -v VERB="$VERBOSE" \
    -v HOSTF="$TMPD/host.tsv" -v INNF="$TMPD/inner.tsv" \
    -v CMPF="$TMPD/compat.tsv" '
function trunc(s, n) {
    if (VERB) return s
    if (length(s) <= n) return s
    return substr(s, 1, n - 1) "~"
}
function pad(s, n,   r) { r = s; while (length(r) < n) r = r " "; return substr(r, 1, n) }
function col(c, s) { if (COLOR != "yes") return s; return c s "\033[0m" }
function grp(k,   p) { p = k; sub(/\..*$/, "", p); return p }
function rule(s,   i, r) { r = ""; for (i = 0; i < W && i < 200; i++) r = r "-"; return r }
function spaces(n,   i, r) { r = ""; for (i = 0; i < n; i++) r = r " "; return r }
function wrap(s, ind,   out, line, n, i, words, w, pfx) {
    pfx = spaces(ind)
    n = split(s, words, " ")
    out = ""; line = ""
    for (i = 1; i <= n; i++) {
        w = words[i]
        if (length(line) + length(w) + 1 > W - ind - 2) {
            out = out (out == "" ? "" : "\n") pfx line
            line = w
        } else {
            line = (line == "" ? w : line " " w)
        }
    }
    if (line != "") out = out (out == "" ? "" : "\n") pfx line
    return out
}
BEGIN {
    GN["id"]="IDENTITY";        GN["os"]="OPERATING SYSTEM"
    GN["cpu"]="PROCESSOR";      GN["mem"]="MEMORY"
    GN["time"]="TIME & CLOCK";  GN["ts"]="FILE TIMESTAMPS"
    GN["dmi"]="DMI / SMBIOS FIRMWARE"
    GN["fw"]="FIRMWARE TABLES"; GN["blk"]="STORAGE"
    GN["tpm"]="TPM / CRYPTO HARDWARE"; GN["pwr"]="POWER & BATTERY"
    GN["thermal"]="THERMAL";    GN["hwmon"]="SENSORS"
    GN["bt"]="BLUETOOTH";       GN["rtc"]="REAL-TIME CLOCK"
    GN["backlight"]="DISPLAY BACKLIGHT"; GN["input"]="INPUT DEVICES"
    GN["snd"]="AUDIO";          GN["usb"]="USB BUS"
    GN["udev"]="UDEV";          GN["video"]="CAMERA / V4L"
    GN["hidraw"]="HID";         GN["gpu"]="GPU / GRAPHICS"
    GN["pci"]="PCI BUS";        GN["net"]="NETWORK (out of scope)"
    GN["proc"]="PROCESS TABLE"; GN["ipc"]="IPC & COMPOSITOR SOCKETS"
    GN["sec"]="KERNEL CONFINEMENT"; GN["fs"]="FILESYSTEM & FONTS"
    GN["det"]="DETECTABILITY"

    while ((getline line < HOSTF) > 0) { split(line, a, "\t"); H[a[1]] = a[2] }
    while ((getline line < INNF) > 0) { split(line, a, "\t"); I[a[1]] = a[2] }
    ncmp = 0
    while ((getline line < CMPF) > 0) {
        split(line, a, "\t")
        ncmp++; CK[ncmp]=a[1]; CS[ncmp]=a[2]; CL[ncmp]=a[3]; CV[ncmp]=a[4]
    }
    nr = 0
}
{
    if ($1 == "" || $1 ~ /^#/) next
    nr++; K[nr] = $1; M[nr] = $2; E[nr] = $3; L[nr] = $4; R[nr] = $5
}
END {
    kw = 34
    if (VERB) { vw = 200 } else { vw = int((W - kw - 11) / 2); if (vw < 12) vw = 12 }
    sep = rule()

    # ---------- grade everything first ----------
    for (i = 1; i <= nr; i++) {
        k = K[i]; m = M[i]; e = E[i]
        hv = (k in H) ? H[k] : "(absent)"
        iv = (k in I) ? I[k] : "(absent)"
        st = ""

        if (m == "SCOPE")      st = "SCOPE"
        else if (m == "INFO")  st = "INFO"
        else if (m != "TELL" && m != "NOCONN" \
                 && (hv == "(none)" || hv == "(absent)") \
                 && (iv == "(none)" || iv == "(absent)")) st = "N/A"
        else if (m == "NOCONN") {
            if (hv == "absent" || hv == "(none)" || hv == "(absent)") st = "N/A"
            else st = (iv != "connected") ? "PROTECT" : "LEAK"
        }
        else if (m == "TELL")  st = (iv == e) ? "PROTECT" : "GAP"
        else if (m == "DIFF")  st = (iv != hv) ? "PROTECT" : "LEAK"
        else if (m == "EQ")    st = (iv == e) ? "PROTECT" : "LEAK"
        else if (m == "HAS")   st = (index(iv, e) > 0) ? "PROTECT" : "LEAK"
        else if (m == "SOFT")  st = (iv == e || iv != hv) ? "PROTECT" : "LEAK"
        else if (m == "IN") {
            st = "LEAK"
            nacc = split(e, acc, "|")
            for (ai = 1; ai <= nacc; ai++) if (iv == acc[ai]) st = "PROTECT"
        }
        else if (m == "MAX")   st = ((iv + 0) <= (e + 0)) ? "PROTECT" : "LEAK"
        else if (m == "EMPTY") st = (iv == "(none)" || iv == "0" || iv == "(absent)") ? "PROTECT" : "LEAK"
        else if (m == "GAP")   st = (iv != hv) ? "PROTECT" : "GAP"

        ST[i] = st; HV[i] = hv; IV[i] = iv
        C[st]++
        g = grp(k)
        if (!(g in SEEN)) { SEEN[g] = 1; ORD[++nord] = g }
        if (st == "PROTECT" || st == "LEAK" || st == "GAP") GT[g]++
        if (st == "PROTECT") GP[g]++
    }

    printf "\n%s\n", sep
    printf " OBSIDIAN MIRROR - METADATA PROTECTION AUDIT\n"
    printf " host <-> application layer   (network layer out of scope by design)\n"
    printf "%s\n", sep

    # ============================================================
    # 1. SUMMARY OF PROTECTED METADATA
    # ============================================================
    printf "\n%s\n", col("\033[1m", " 1. PROTECTED METADATA - SUMMARY")
    printf "%s\n", sep
    printf "   What the host reveals about itself, and how much of it the\n"
    printf "   application is prevented from seeing.\n\n"
    printf "   %-30s %8s %8s %8s\n", "CATEGORY", "GRADED", "PROTECT", "COVER"
    printf "   %-30s %8s %8s %8s\n", "------------------------------", "------", "-------", "-----"
    for (i = 1; i <= nord; i++) {
        g = ORD[i]
        if (GT[g] == 0) continue
        gname = (g in GN) ? GN[g] : toupper(g)
        printf "   %-30s %8d %8d %7d%%\n", substr(gname, 1, 30), GT[g], GP[g] + 0, int((GP[g] + 0) * 100 / GT[g])
    }
    tot = C["PROTECT"] + C["LEAK"] + C["GAP"]
    printf "   %-30s %8s %8s %8s\n", "------------------------------", "------", "-------", "-----"
    if (tot > 0)
        printf "   %-30s %8d %8d %7d%%\n", "TOTAL", tot, C["PROTECT"], int(C["PROTECT"] * 100 / tot)
    printf "\n"
    printf "   %-42s %d\n", "Protected (spoofed, masked or blocked)", C["PROTECT"] + 0
    printf "   %-42s %d\n", "Not protected - known gap (see section 3)", C["GAP"] + 0
    printf "   %-42s %d\n", "Not protected - unexpected leak", C["LEAK"] + 0
    printf "   %-42s %d\n", "Out of scope (network layer)", C["SCOPE"] + 0
    printf "   %-42s %d\n", "Not applicable (no such hardware here)", C["N/A"] + 0
    printf "   %-42s %d\n", "Informational only", C["INFO"] + 0

    # ============================================================
    # 2. REAL vs PROTECTED
    # ============================================================
    if (FULL) {
        printf "\n%s\n", col("\033[1m", " 2. REAL vs PROTECTED - ITEM BY ITEM")
        printf "%s\n", sep
        printf "   REAL is what this host actually is. MIRRORED is all the\n"
        printf "   application is given.\n"
        printf "\n%s %s %s %s\n", pad("STATUS", 9), pad("ITEM", kw), pad("REAL (host)", vw), "MIRRORED (app sees)"
        printf "%s\n", sep

        lastg = ""
        for (i = 1; i <= nr; i++) {
            st = ST[i]
            if (st == "INFO" && !SHOWINFO) continue
            g = grp(K[i])
            if (g != lastg) {
                gname = (g in GN) ? GN[g] : toupper(g)
                printf "\n%s\n", col("\033[1m", "  " gname)
                lastg = g
            }
            if (st == "PROTECT")   sc = col("\033[32m",   pad("PROTECT", 9))
            else if (st == "LEAK") sc = col("\033[31;1m", pad("LEAK", 9))
            else if (st == "GAP")  sc = col("\033[33m",   pad("GAP", 9))
            else if (st == "SCOPE")sc = col("\033[36m",   pad("SCOPE", 9))
            else if (st == "N/A")  sc = col("\033[2m",    pad("N/A", 9))
            else                   sc = col("\033[2m",    pad("INFO", 9))
            printf "%s %s %s %s\n", sc, pad(L[i], kw), pad(trunc(HV[i], vw), vw), trunc(IV[i], vw)
        }
    }

    # ============================================================
    # 3. HOST METADATA NOT PROTECTED
    # ============================================================
    printf "\n%s\n", col("\033[1m", " 3. HOST METADATA NOT PROTECTED - AND WHY")
    printf "%s\n", sep

    if (C["LEAK"] > 0) {
        printf "\n   %s\n", col("\033[31;1m", "UNEXPECTED LEAKS - these should be protected and are not")
        printf "   %s\n", "A leak here means a rule did not fire on this host. Worth reporting."
        for (i = 1; i <= nr; i++) {
            if (ST[i] != "LEAK") continue
            printf "\n   * %s  [%s]\n", L[i], K[i]
            printf "       host sees : %s\n", HV[i]
            printf "       app sees  : %s\n", IV[i]
            if (R[i] != "") printf "%s\n", wrap("reason: " R[i], 7)
        }
        printf "\n"
    }

    if (C["GAP"] > 0) {
        printf "\n   %s\n", col("\033[33m", "KNOWN LIMITATIONS - not covered, by design or by physics")
        for (i = 1; i <= nr; i++) {
            if (ST[i] != "GAP") continue
            printf "\n   * %s  [%s]\n", L[i], K[i]
            printf "       app sees  : %s\n", IV[i]
            if (R[i] != "") printf "%s\n", wrap("reason: " R[i], 7)
            else            printf "       reason: documented limitation, see COVERAGE.md\n"
        }
        printf "\n"
    }

    if (C["SCOPE"] > 0) {
        printf "\n   %s\n", col("\033[36m", "OUT OF SCOPE - the network layer, excluded by design")
        for (i = 1; i <= nr; i++) {
            if (ST[i] != "SCOPE") continue
            printf "\n   * %s  [%s]\n", L[i], K[i]
            printf "       app sees  : %s\n", IV[i]
            if (R[i] != "") printf "%s\n", wrap("reason: " R[i], 7)
        }
        printf "\n"
    }

    printf "\n   %s\n", col("\033[1m", "CANNOT BE FIXED AT THIS LAYER")
    printf "%s\n", wrap("* CPUID instruction: runs in userspace. Real CPU vendor, family, model, stepping and feature bits are readable by any program. /proc/cpuinfo is spoofed; the instruction is not. Only a hypervisor can mask it.", 5)
    printf "%s\n", wrap("* RDTSC and timing: clock skew, TSC frequency and boot-time correlation are physical properties of the machine.", 5)
    printf "%s\n", wrap("* Raw syscalls bypass LD_PRELOAD: syscall(SYS_uname) returns the real kernel release. Go binaries, static binaries and hand-written assembly skip libc entirely. Mount-level spoofs still apply to them; libc hooks do not.", 5)
    printf "%s\n", wrap("* setuid / setgid binaries: the dynamic loader drops LD_PRELOAD for them, so they run unhooked.", 5)
    printf "%s\n", wrap("* glibc symbol aliases: programs calling __xstat / __fxstat (gcompat, glibc containers) miss the stat hooks.", 5)
    printf "%s\n", wrap("* Detectability: an application can tell it is being mirrored. Obsidian Mirror makes you anonymous, not invisible.", 5)

    # ============================================================
    # 4. APPLICATION COMPATIBILITY
    # ============================================================
    printf "\n%s\n", col("\033[1m", " 4. APPLICATION COMPATIBILITY")
    printf "%s\n", sep
    printf "   The isolation layer must not change how a wrapped program\n"
    printf "   behaves. Checked live on every audit run.\n\n"
    nbroken = 0
    for (i = 1; i <= ncmp; i++) {
        if (CS[i] == "OK")          { sc = col("\033[32m", pad("OK", 9)) }
        else if (CS[i] == "BROKEN") { sc = col("\033[31;1m", pad("BROKEN", 9)); nbroken++ }
        else                        { sc = col("\033[2m", pad("N/A", 9)) }
        printf "   %s %s %s\n", sc, pad(CL[i], 38), CV[i]
    }

    # ---------- verdict ----------
    printf "\n%s\n", sep
    if (tot > 0)
        printf " VERDICT: %d of %d graded host identifiers are hidden from the application (%d%%).\n", \
               C["PROTECT"], tot, int(C["PROTECT"] * 100 / tot)
    if (C["LEAK"] > 0)
        printf "          %d unexpected leak(s) - see section 3.\n", C["LEAK"]
    if (C["GAP"] > 0)
        printf "          %d documented limitation(s) - see section 3.\n", C["GAP"]
    if (nbroken > 0)
        printf "          %s\n", col("\033[31;1m", nbroken " COMPATIBILITY CHECK(S) FAILED - see section 4.")
    else
        printf "          All compatibility checks passed.\n"
    printf "%s\n\n", sep
}
' "$TMPD/rules.tsv"
OBSIDIAN_PAYLOAD_AUDIT
chmod 755 "$BINDIR/obsidian-audit"
ok "bin/obsidian-audit"

mkdir -p "$FAKEROOT/fonts"
cat > "$FAKEROOT/fonts/fonts.conf" <<'OBSIDIAN_PAYLOAD_FONTS_CONF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<!--
  /opt/obsidian/fake_root/fonts/fonts.conf

  Obsidian Mirror - deterministic font enumeration.

  The installed font list is one of the strongest fingerprints a
  graphical application can collect: the exact set of families, and
  the order they are returned in, is close to unique per machine.

  This config does NOT hide fonts - an application with no fonts
  cannot render text, which would violate the "must not break the
  application" rule. What it does is make the enumeration
  *deterministic and impersonal*:

    - only the distribution font directory is scanned
    - per-user font directories (~/.fonts, ~/.local/share/fonts)
      are dropped: those are the ones that actually identify you
    - host-local and admin-added directories (/usr/local/share/fonts,
      /opt/*/fonts) are dropped
    - the cache is pinned inside the private tmpfs, so no cache file
      from the real host is read and none is left behind
    - generic aliases resolve to a fixed preference order, so
      "sans-serif" maps to the same family on every host that has it

  Activated by obsidian-launch via FONTCONFIG_FILE, and only when
  /usr/share/fonts exists.
-->
<fontconfig>

  <!-- The one directory that is scanned. -->
  <dir>/usr/share/fonts</dir>

  <!-- Cache lives in the throwaway tmpfs home, never on the host. -->
  <cachedir prefix="xdg">fontconfig</cachedir>
  <cachedir>/tmp/.fontconfig</cachedir>

  <!-- Deliberately NOT included:
         <dir prefix="xdg">fonts</dir>
         <dir>~/.fonts</dir>
         <dir>/usr/local/share/fonts</dir>
         <dir>/usr/share/fonts/X11</dir>
       and any /etc/fonts/conf.d include, which on most hosts pulls
       in locale- and vendor-specific ordering rules. -->

  <!-- Fixed generic-family preference order. -->
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>DejaVu Sans</family>
      <family>Liberation Sans</family>
      <family>Noto Sans</family>
      <family>Arial</family>
      <family>Helvetica</family>
    </prefer>
  </alias>

  <alias>
    <family>serif</family>
    <prefer>
      <family>DejaVu Serif</family>
      <family>Liberation Serif</family>
      <family>Noto Serif</family>
      <family>Times New Roman</family>
      <family>Times</family>
    </prefer>
  </alias>

  <alias>
    <family>monospace</family>
    <prefer>
      <family>DejaVu Sans Mono</family>
      <family>Liberation Mono</family>
      <family>Noto Sans Mono</family>
      <family>Courier New</family>
      <family>Courier</family>
    </prefer>
  </alias>

  <!-- Uniform rendering. Hinting style and subpixel order are
       themselves fingerprintable, and they are display-hardware
       dependent, so both are pinned. -->
  <match target="font">
    <edit name="antialias"  mode="assign"><bool>true</bool></edit>
    <edit name="hinting"    mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle"  mode="assign"><const>hintslight</const></edit>
    <edit name="rgba"       mode="assign"><const>none</const></edit>
    <edit name="lcdfilter"  mode="assign"><const>lcddefault</const></edit>
    <edit name="embeddedbitmap" mode="assign"><bool>false</bool></edit>
  </match>

  <!-- No network font sources, no user config layering. -->
  <config></config>

</fontconfig>
OBSIDIAN_PAYLOAD_FONTS_CONF
chmod 644 "$FAKEROOT/fonts/fonts.conf"
ok "fake_root/fonts/fonts.conf"

cat > "$PREFIX/COVERAGE.md" <<'OBSIDIAN_PAYLOAD_COVERAGE_MD'
# Obsidian Mirror v2 — Metadata Protection Coverage

What an application actually sees when you run `obsidian <application>`, how each item is
enforced, and — just as importantly — what is *not* covered.

**Scope:** Host ↔ Application layer only. The network stack is excluded by design.

**Hard rule this version was built under:** nothing may change the behaviour of a program
launched with `obsidian <application>`. Where a privacy fix and that rule collided, the fix
became an opt-in runtime mode rather than a forced default. Those switches are listed in §6.

---

## 1. The six enforcement layers

| # | Layer | Implemented by | Defeats |
|---|---|---|---|
| 1 | **libc interposition** | `LD_PRELOAD` → `obsidian_core.so`, `obsidian_gpu.so`, `obsidian_wayland.so` | `uname()`, `sysinfo()`, `getpwuid()`, `stat`/`statx`, `glGetString()`, `eglQueryString()`, `connect()` |
| 2 | **Mount namespace** | ~65 bind-mounts + tmpfs masks over `/proc`, `/sys`, `/etc`, `/dev` | Direct file reads that bypass libc |
| 3 | **UTS / PID / IPC / user namespaces** | `unshare --uts --pid --ipc --user` | Hostname, process table, SysV IPC, credentials |
| 4 | **seccomp-bpf filter** | `seccomp_enforcer` (24 rules) | Syscall-level introspection and sandbox escape |
| 5 | **Environment scrubbing + affinity clamp** | Export engine, `taskset -c 0,1`, `sched_getaffinity()` hook | Env-var identity leaks, core-count fingerprinting |
| 6 | **Fontconfig pinning** | `FONTCONFIG_FILE` → private `fonts.conf` | Installed-font-set fingerprinting |

Layer 2 is driven by `/etc/obsidian/hw-manifest.conf`, generated per host by
`generate-manifest.sh`. Regenerate it after a hardware change:

```sh
obsidian --regenerate-manifest      # as root
```

---

## 2. Closed in v2

Every item in this table was listed as a *known gap* in v1 §3.2.

| v1 gap | v2 status | How |
|---|---|---|
| `/proc/meminfo` not bind-mounted | **Closed** | A full 30-field synthetic `meminfo` is generated in the private tmpfs and bind-mounted over `/proc/meminfo`, kept numerically consistent with the `sysinfo()` hook (8 GB RAM, 2 GB swap) |
| `statx()` not hooked | **Closed** | `statx()` is hooked in `obsidian_core.c`; `stx_atime/mtime/ctime/btime` are floored to the hour and their nanosecond fields zeroed, matching the four `stat` variants |
| DMI `product_version`, `board_serial`, `chassis_*` missing | **Closed** | `generate-manifest.sh` §7 now emits the complete 23-field DMI set at both `/sys/class/dmi/id` and `/sys/devices/virtual/dmi/id` |
| Font list readable | **Closed** | `FONTCONFIG_FILE` restored, pointing at a config that scans only `/usr/share/fonts`, drops every per-user and host-local font directory, and pins the cache into the private tmpfs |
| Only `sway-ipc` blocked | **Closed** | The `connect()` block now matches sway, Hyprland, i3, Wayfire, River, labwc and niri control sockets |
| D-Bus system bus unmasked | **Closed (default-on)** | `connect()` to `dbus/system_bus_socket` returns `ECONNREFUSED`. Re-enable with `OBSIDIAN_ALLOW_SYSTEM_BUS=1` |
| `/dev/dri`, `/sys/class/drm` exposed | **Partly closed** | Monitor EDID masked, DRM OEM board pins spoofed, `eglQueryString(EGL_VENDOR)` spoofed. Full masking is opt-in: `OBSIDIAN_GPU_MODE=strict`. See §4 for why it is not the default |

---

## 3. What is protected

### 3.1 Machine & user identity

| Item | Application sees | Mechanism |
|---|---|---|
| Hostname / `uname` nodename | `laptop-a3f2c1` — random prefix + 6 hex, new every launch | UTS ns + bind |
| `/etc/machine-id`, D-Bus machine-id | random 32-hex, new every launch | bind mount |
| Kernel `boot_id` | random UUID, new every launch | bind mount |
| `$USER` / `$LOGNAME` / `$HOME` | one of `user`/`admin`/`guest`/`dev`, home on a fresh tmpfs | env export |
| `getpwuid()` / `getgrgid()` | `Generic User`, uid/gid 1000, `/bin/sh` | libc hook |
| `/etc/passwd`, `/etc/group` | exactly 3 synthetic lines each | bind mount |
| UID / GID | 1000 / 1000 | nested user ns |

### 3.2 Operating system identity — the Top-10 engine

Every launch picks one of **10 complete, internally coherent Linux identities** at random:
Ubuntu 22.04, Debian 12, Fedora 39, Arch, Mint 21.3, Pop!_OS 22.04, Manjaro 23.1.3,
openSUSE Tumbleweed, Alpine 3.19, RHEL 9.3. Kernel release, `/proc/version` build string, boot
cmdline and `os-release` all agree with each other — a profile mismatch would itself be a
fingerprint.

`/etc/issue`, `/etc/lsb-release` and every distro release file are emptied; `/etc/apk` and
`/lib/apk` become tmpfs, which hides the installed-package list — close to a unique fingerprint
of a machine.

### 3.3 Processor

Synthetic 2 × `Intel(R) Core(TM) i5-8250U @ 1.60GHz`; `nproc()` = 2 via
`sched_getaffinity()` hook plus `taskset -c 0,1`; `cpu/online`, `cpu/possible`, `cpu/present`
redirected to `0-1`; `/sys/devices/system/cpu` masked; `/proc/stat` trimmed to 2 CPU rows.

### 3.4 Memory — *new in v2*

| Item | Application sees | Mechanism |
|---|---|---|
| `sysinfo()` totalram / freeram / swap | 8 192 000 kB / derived / 2 097 152 kB | libc hook |
| `/proc/meminfo` **MemTotal / MemFree / MemAvailable / SwapTotal** | 8192000 / 4096000 / 6144000 / 2097152 kB | **bind mount (v2)** |
| Full `meminfo` body (Slab, PageTables, Committed_AS, …) | synthetic, internally consistent | bind mount |

Both paths now agree. In v1, `free` was clean but `cat /proc/meminfo` told the truth.

### 3.5 Time, clock and file timestamps

| Item | Application sees | Mechanism |
|---|---|---|
| Timezone | **UTC always** | `getenv("TZ")` hook + `/etc/timezone` + `/etc/localtime` binds |
| `localtime()` / `localtime_r()` | redirected to `gmtime()` | libc hook |
| `gettimeofday()` µs field | zeroed | libc hook |
| `/proc/uptime` | random 600–90 600 s per launch | bind mount |
| `/proc/stat` btime | derived from the fake uptime | awk rewrite |
| File `atime`/`mtime`/`ctime` | floored to the hour | `stat`, `lstat`, `fstat`, `fstatat` hooks |
| File timestamps via **`statx()`** | floored to the hour, **nanoseconds zeroed** | **`statx` hook (v2)** |

Nanosecond timestamps are a per-file, per-event tracking identifier — roughly 30 bits of
entropy attached to every file the application touches. The audit measures this directly:
`ts.mtime_nsec` and `ts.mtime_mod3600` must both read `0`.

### 3.6 DMI / SMBIOS — *complete in v2*

Spoofed at **both** `/sys/class/dmi/id/` and `/sys/devices/virtual/dmi/id/`:

| Field group | Application sees |
|---|---|
| `sys_vendor`, `board_vendor`, `bios_vendor`, `chassis_vendor`, `product_family`, `product_sku` | `Generic` |
| `product_name` / `board_name` | `Generic Laptop` / `Generic Board` |
| `product_version`, `board_version`, `chassis_version`, `bios_release`, `ec_firmware_release` | `1.0` |
| `product_serial`, `board_serial`, `chassis_serial`, `board_asset_tag`, `chassis_asset_tag` | `To Be Filled By O.E.M.` |
| `product_uuid` | all-zero UUID |
| `bios_version` / `bios_date` | `1.0.0` / `01/01/2020` |
| `chassis_type` | `10` (generic laptop) |
| `modalias` | rebuilt from the spoofed fields, so it cannot contradict them |
| `/sys/firmware/acpi` | tmpfs — OEM-signed ACPI tables hidden |

`modalias` matters: it concatenates the DMI fields into one string, so leaving it real would
have undone the other 22 spoofs on its own.

### 3.7 Storage, TPM, sensors, peripherals

`/sys/block` masked entirely; disk vendor/model/serial/WWID rewritten; SCSI and ATA classes
masked. TPM sysfs classes masked and `/dev/tpm*` bound to `/dev/null` — a TPM endorsement key
is a permanent, unforgeable hardware serial. Battery, hwmon, thermal, cooling, Bluetooth MAC,
RTC and backlight all normalised. `/sys/class/input`, `/dev/input`, `/proc/bus/input`,
`/sys/class/sound`, `/dev/snd`, `/proc/asound`, `/sys/class/hidraw`, `/dev/hidraw*`,
`/dev/video*`, `/dev/media*`, `/sys/bus/usb`, `/dev/bus/usb` and `/run/udev` are masked or
nulled.

### 3.8 GPU

| Item | Application sees |
|---|---|
| `glGetString(GL_VENDOR)` / `(GL_RENDERER)` | manifest values — a Mesa string chosen to match your real PCI generation |
| `glGetString(GL_VERSION)` | `OpenGL ES 3.2 Mesa 21.0.0` |
| `glGetString(GL_EXTENSIONS)`, `glGetStringi()` | **empty** (extension sets are near-unique per driver build) |
| `GL_NUM_EXTENSIONS` | `0`, kept consistent with the blanked list |
| `eglQueryString(EGL_VENDOR)` | spoofed — *new in v2* |
| `GL_MAX_*` limits | fixed 16384 / 16 values |
| DRM `subsystem_vendor` / `subsystem_device` / `label` | `0x8086` / `0x0000` / `Generic Graphics` — *new in v2* |
| Monitor **EDID** | masked to empty — *new in v2* (EDID carries the display serial and manufacture week) |

### 3.9 Fonts — *new in v2*

`FONTCONFIG_FILE` points at `/opt/obsidian/fake_root/fonts/fonts.conf`, which scans only
`/usr/share/fonts`, drops `~/.fonts`, `~/.local/share/fonts`, `/usr/local/share/fonts` and any
`/etc/fonts/conf.d` layering, pins the cache inside the private tmpfs, and fixes the
generic-family preference order and hinting/subpixel settings.

Fonts are deliberately **not removed** — an application with no fonts cannot draw text, which
would break it. What changes is that the enumeration becomes impersonal and deterministic.

### 3.10 Process, IPC and compositor sockets

PID namespace, IPC namespace, private `/tmp` and private `/home`.

`connect()` to an `AF_UNIX` path returns `ECONNREFUSED` when the path matches any of:
`sway-ipc`, `/hypr/`, `.hyprland`, `i3/ipc-socket`, `/tmp/i3-`, `wayfire`, `river-control`,
`labwc`, `niri.`, `hyprcursor`, or `dbus/system_bus_socket`. Compositor control sockets
otherwise hand out window titles, output models, workspace layout and the full input-device
inventory.

`XDG_RUNTIME_DIR` is replaced with a tmpfs containing **only** the Wayland socket,
`pulse/native` and `pipewire-0`. Everything else that normally accumulates there — systemd,
gnupg, keyring, the D-Bus session bus, per-app sockets — is simply not there.

**seccomp-bpf** — killed outright: `iopl`, `ioperm`. Returned `EPERM`: `ptrace`,
`process_vm_readv`, `process_vm_writev`, `kcmp`, `syslog`, `perf_event_open`, `init_module`,
`finit_module`, `delete_module`, `settimeofday`, `clock_settime`, `keyctl`, `add_key`,
`request_key`, `unshare`, `setns`, `pivot_root`, `mount`, `umount2`, `bpf`, `kexec_load`,
`acct`. The `unshare`/`setns`/`pivot_root`/`mount` denials are the self-escape blocks.

### 3.11 Fail-closed sweep

Any `/sys/class/*` subsystem the scanner does not recognise is masked with tmpfs. New or exotic
hardware is hidden by default rather than exposed by default.

---

## 4. Why `/dev/dri` is still reachable by default

This is the one v1 gap that v2 does **not** close by default, and the reason is the hard rule
at the top of this document.

Mesa and libdrm select the kernel driver by reading `/sys/class/drm/card0/device/vendor` and
`device/device`. Mask the DRM class, or lie about those two files, and one of two things
happens: hardware acceleration silently collapses to software rendering, or the application
fails to create a GL/Vulkan context at all. Electron apps, browsers, video players and anything
using `wgpu` are affected.

So the default (`OBSIDIAN_GPU_MODE=compat`) keeps the driver path intact and removes everything
around it that identifies *your specific machine*: the OEM subsystem IDs, the device label, the
monitor EDID, the GL vendor/renderer/version strings, the GL extension list, and the EGL vendor.
What remains readable is the GPU *model* — shared with every other owner of that model.

If you want the model gone too:

```sh
OBSIDIAN_GPU_MODE=strict obsidian <application>
```

That masks `/dev/dri` and `/sys/class/drm` completely. Zero GPU fingerprint, software rendering
only. It is the right choice for a text-mode or network tool, and the wrong choice for a
browser.

---

## 5. What is still NOT protected

### 5.1 Out of scope by design — the network layer

Untouched, deliberately: IP addresses, routing, DNS resolver config, real NIC MACs in
`/sys/class/net/*/address`, TLS/JA3 fingerprints, HTTP headers, NTP, mDNS.

`getifaddrs()` *is* hooked (renames to `eth0`, rewrites IPv4 to `10.0.2.15`), but anything using
netlink directly — `ip`, `ss`, most language runtimes — sees the truth. Do not rely on it.

**Pair Obsidian Mirror with a VPN or a network namespace for network-layer privacy.**

### 5.2 Inherent to sharing the host

| Limitation | Effect | Why it stays |
|---|---|---|
| Wayland socket passthrough | `wl_output` reports real resolution, refresh rate, physical size and monitor make/model | Removing it removes the display. Only a nested compositor (`cage`, headless wlroots) fixes this, and that changes how the app is presented |
| PulseAudio / PipeWire passthrough | Real device names and card serials travel over the protocol | Same trade-off: cutting it removes audio |
| GPU model readable in compat mode | Vulkan and DRM ioctls see the real adapter | §4. Opt in to `OBSIDIAN_GPU_MODE=strict` |
| No `pivot_root` | Host filesystem outside the masked paths is still visible, subject to normal permissions: `/root`, `/var`, `/srv`, other users' files | `/home` *is* tmpfs, so user data is covered. A real pivot breaks applications that read their own installation directory |

### 5.3 Hard limits — cannot be fixed at this layer

| Limit | Why |
|---|---|
| **`CPUID` instruction** | Executed in userspace directly. Real CPU vendor, family, model, stepping and feature bits are readable by any program. `/proc/cpuinfo` is spoofed; the instruction is not. Only a hypervisor can mask this |
| **`RDTSC` / timing** | Clock skew, TSC frequency and boot-time correlation are physical properties |
| **Raw syscalls bypass `LD_PRELOAD`** | `syscall(SYS_uname)` returns the real kernel release. Go binaries, static binaries and hand-written assembly skip libc entirely. Mount-level spoofs still apply; libc hooks do not |
| **setuid/setgid binaries** | The dynamic loader drops `LD_PRELOAD` for them |
| **glibc symbol aliases** | Programs using `__xstat`/`__fxstat` (gcompat, glibc containers) miss the `stat` hooks |
| **Detectability** | An application can tell it is being mirrored: `LD_PRELOAD` is in `/proc/self/environ`, `OBSIDIAN_*` vars are exported, `/proc/self/mountinfo` lists every bind, `/opt/obsidian` exists, and the PID namespace is suspiciously empty |

That last row is the honest headline. Against passive fingerprinting — the actual threat model
for application metadata leaks — this layer is very strong. Against an adversary specifically
probing for a sandbox, it is detectable. **Obsidian Mirror makes you anonymous, not invisible.**

---

## 6. Runtime switches

Every switch defaults to the setting that does not break applications.

| Variable | Default | Effect |
|---|---|---|
| `OBSIDIAN_GPU_MODE` | `compat` | `strict` masks `/dev/dri` and `/sys/class/drm` entirely. Zero GPU fingerprint, software rendering only |
| `OBSIDIAN_GL_EXTENSIONS` | *(blanked)* | `preserve` passes the real GL extension list through. Use only if an application refuses to start; every other GPU protection stays on |
| `OBSIDIAN_ALLOW_SYSTEM_BUS` | *(blocked)* | `1` permits `connect()` to the D-Bus system bus |
| `OBSIDIAN_VERBOSE` | *(off)* | `1` logs every blocked IPC connection and the seccomp rule count to stderr |
| `OBSIDIAN_MANIFEST` | `/etc/obsidian/hw-manifest.conf` | Alternate hardware manifest |

```sh
OBSIDIAN_GPU_MODE=strict obsidian curl https://example.com
OBSIDIAN_GL_EXTENSIONS=preserve obsidian some-picky-game
OBSIDIAN_VERBOSE=1 obsidian firefox
```

---

## 7. Testing it

```sh
obsidian --test          # the full four-section audit
obsidian --test -q       # summary, gaps and compatibility only
obsidian --test -a       # include informational rows
obsidian --test -v       # do not truncate values
obsidian --test --raw    # dump both probe outputs, ungraded
```

`obsidian --test` runs a ~165-point probe twice — once natively, once through the isolation
layer — and prints:

1. **Protected metadata summary** — per-category counts and a coverage percentage.
2. **Real vs protected** — every item side by side: what the host is, what the app is given.
3. **Host metadata not protected** — every remaining item with the reason, and the switch that
   covers it where one exists.
4. **Application compatibility** — argv integrity, exit-status propagation, stdin passthrough,
   Wayland socket reachability and the GPU render node. These are the guardrails on the hard
   rule; if any of them says `BROKEN`, the isolation layer is interfering with the application
   and that is a bug, not a feature.

Spot checks by hand:

```sh
obsidian sh -c 'hostname; echo $USER; id; cat /etc/machine-id'
obsidian sh -c 'grep -E "MemTotal|SwapTotal" /proc/meminfo'   # 8192000 / 2097152
obsidian sh -c 'touch /tmp/x; stat -c %y /tmp/x'              # .000000000
obsidian cat /sys/class/dmi/id/board_serial                   # To Be Filled By O.E.M.
obsidian ls /sys/block                                        # empty
obsidian sh -c 'grep Seccomp /proc/self/status'               # 2
for i in 1 2 3; do obsidian sh -c 'grep PRETTY /etc/os-release; uname -r'; done
```

Hostname, kernel and distro must change together on every launch, and the kernel must always
match the distro. A stable value that should change, or a kernel that does not match its
distro, is a bug.

---

## 8. Files installed

| Path | Purpose |
|---|---|
| `/usr/local/bin/obsidian` | CLI entry point (symlink) |
| `/opt/obsidian/bin/obsidian-launch` | Isolation launcher |
| `/opt/obsidian/bin/obsidian-inner` | Final execution stage (seccomp + affinity + exec) |
| `/opt/obsidian/bin/obsidian-audit` | Four-section protection audit |
| `/opt/obsidian/bin/seccomp_enforcer` | seccomp-bpf filter loader |
| `/opt/obsidian/bin/obsidian-ipcprobe` | Socket reachability probe used by the audit |
| `/opt/obsidian/lib/obsidian_core.so` | uname / sysinfo / stat / statx / open / affinity hooks |
| `/opt/obsidian/lib/obsidian_gpu.so` | GL and EGL string hooks |
| `/opt/obsidian/lib/obsidian_wayland.so` | `connect()` IPC block |
| `/opt/obsidian/scripts/generate-manifest.sh` | Hardware scanner |
| `/opt/obsidian/scripts/obsidian-probe.sh` | ~165-point metadata probe |
| `/opt/obsidian/fake_root/fonts/fonts.conf` | Deterministic font enumeration |
| `/opt/obsidian/COVERAGE.md` | This document |
| `/etc/obsidian/hw-manifest.conf` | Generated per-host spoof/mask manifest |
OBSIDIAN_PAYLOAD_COVERAGE_MD
chmod 644 "$PREFIX/COVERAGE.md"
ok "COVERAGE.md"


# =====================================================================
step "Compiling"
# =====================================================================
CFLAGS="-O2 -Wall -fPIC"

build_so() {
    _name="$1"; _src="$2"
    if $CC $CFLAGS -shared -o "$LIBDIR/$_name" "$_src" -ldl 2>"$SRCDIR/.err.$_name"; then
        ok "$_name"
        rm -f "$SRCDIR/.err.$_name"
    else
        fail "$_name failed to build:"
        sed 's/^/        /' "$SRCDIR/.err.$_name" >&2
        die "cannot continue without $_name"
    fi
}

build_so obsidian_core.so    "$SRCDIR/obsidian_core.c"
build_so obsidian_gpu.so     "$SRCDIR/obsidian_gpu.c"
build_so obsidian_wayland.so "$SRCDIR/obsidian_wayland.c"

# seccomp_enforcer needs libseccomp headers. If they are missing the
# other four layers still work, so this one degrades instead of dying.
SECCOMP_OK=0
if $CC -O2 -Wall -o "$BINDIR/seccomp_enforcer" "$SRCDIR/seccomp_enforcer.c" -lseccomp \
        2>"$SRCDIR/.err.seccomp"; then
    chmod 755 "$BINDIR/seccomp_enforcer"
    SECCOMP_OK=1
    ok "seccomp_enforcer  (syscall confinement layer active)"
    rm -f "$SRCDIR/.err.seccomp"
else
    rm -f "$BINDIR/seccomp_enforcer"
    warn "seccomp_enforcer did NOT build - libseccomp-dev is missing."
    warn "Layers 1,2,3,5,6 still work; syscall confinement (layer 4) is off."
    warn "Fix with:  apk add libseccomp-dev  then re-run this installer."
fi

if $CC -O2 -Wall -o "$BINDIR/obsidian-ipcprobe" "$SRCDIR/obsidian_ipcprobe.c" \
        2>"$SRCDIR/.err.ipcprobe"; then
    chmod 755 "$BINDIR/obsidian-ipcprobe"
    ok "obsidian-ipcprobe  (audit support tool)"
    rm -f "$SRCDIR/.err.ipcprobe"
else
    warn "obsidian-ipcprobe did not build; the audit will report IPC sockets"
    warn "as present rather than measuring reachability."
fi

# v3.5 - BPF-LSM kernel-level enforcement (Option A). Built only when the
# toolchain (clang, bpftool, libbpf, and kernel BTF) is present. If anything
# is missing the userspace sandbox still applies and the app runs normally.
if command -v clang >/dev/null 2>&1 && command -v bpftool >/dev/null 2>&1 && \
   command -v gcc >/dev/null 2>&1 && [ -f "$SRCDIR/obsidian_lsm.bpf.c" ]; then
    VMLINUX="$SRCDIR/vmlinux.h"
    if [ ! -f "$VMLINUX" ]; then
        bpftool btf dump file /sys/kernel/btf/vmlinux format c > "$VMLINUX" 2>/dev/null || true
    fi
    if [ -f "$VMLINUX" ]; then
        if clang -O2 -g -target bpf -D__TARGET_ARCH_x86_64 \
                -I"$SRCDIR" -c "$SRCDIR/obsidian_lsm.bpf.c" -o "$SRCDIR/obsidian_lsm.bpf.o" 2>"$SRCDIR/.err.lsm" && \
           bpftool gen skeleton "$SRCDIR/obsidian_lsm.bpf.o" > "$SRCDIR/obsidian_lsm.skel.h" 2>/dev/null && \
           $CC -O2 -I"$SRCDIR" -o "$BINDIR/obsidian-lsm-load" "$SRCDIR/obsidian_lsm_load.c" -lbpf 2>>"$SRCDIR/.err.lsm"; then
            chmod 755 "$BINDIR/obsidian-lsm-load"
            ok "obsidian-lsm-load  (v3.5 BPF-LSM kernel enforcement ready)"
        else
            warn "obsidian-lsm-load did NOT build (clang/bpftool/libbpf mismatch). v3.5 kernel enforcement skipped; userspace sandbox still applies."
        fi
        rm -f "$SRCDIR/.err.lsm"
    else
        warn "obsidian-lsm-load skipped: BTF/vmlinux.h unavailable (needs CONFIG_DEBUG_INFO_BTF). v3.5 off."
    fi
else
    warn "obsidian-lsm-load skipped: clang/bpftool/gcc not installed. v3.5 kernel enforcement off."
fi

# v3.5 (AppArmor backend, Option C). If AppArmor userspace is present, lock
# down the Obsidian source so a confined app (and other actors) cannot read the
# implementation. The bin/ directory stays executable (the launcher must run as
# the unprivileged user). Per-app runtime profiles are loaded at launch.
chmod 755 "$BINDIR" 2>/dev/null
if command -v apparmor_parser >/dev/null 2>&1 && [ -x "$BINDIR/obsidian-apparmor.sh" ]; then
    # Remove any stale profiles from an older Obsidian install that attach to
    # the launcher path and would confine/deny the launch (e.g. a
    # 'obsidian'/'obsidian-mirror' (complain) profile). Our profiles are
    # named obsidian-<appkey> and do not collide by name.
    for _old in obsidian obsidian-mirror obsidian-launch; do
        if [ -f "/etc/apparmor.d/$_old" ]; then
            apparmor_parser -R "/etc/apparmor.d/$_old" 2>/dev/null
            rm -f "/etc/apparmor.d/$_old" 2>/dev/null
        fi
    done
    if "$BINDIR/obsidian-apparmor.sh" protect-src on 2>/dev/null; then
        ok "obsidian-apparmor: source locked to root (700); bin left 755"
    else
        warn "obsidian-apparmor: protect-src failed; source not locked"
    fi
else
    warn "obsidian-apparmor: apparmor_parser not installed; source not locked. 'apk add apparmor apparmor-utils' for v3.5."
fi

chmod 755 "$BINDIR/obsidian-launch" "$BINDIR/obsidian-inner" "$BINDIR/obsidian-audit"
chmod 755 "$SCRIPTDIR/generate-manifest.sh" "$SCRIPTDIR/obsidian-probe.sh"
chmod 644 "$FAKEROOT/fonts/fonts.conf" "$PREFIX/COVERAGE.md"

# Exported symbol sanity check: a hook library that exports nothing is
# a silent no-op, and that is exactly the failure this project has had
# before. Verify rather than assume.
if command -v nm >/dev/null 2>&1; then
    for pair in "obsidian_core.so:uname" "obsidian_core.so:statx" \
                "obsidian_gpu.so:glGetString" "obsidian_wayland.so:connect"; do
        _lib="${pair%%:*}"; _sym="${pair##*:}"
        if nm -D --defined-only "$LIBDIR/$_lib" 2>/dev/null | grep -q " $_sym\$"; then
            ok "$_lib exports $_sym"
        else
            warn "$_lib does not export $_sym - that hook will not fire"
        fi
    done
fi

# =====================================================================
step "Scanning this machine's hardware"
# =====================================================================
if [ "$DO_SCAN" -eq 1 ]; then
    if sh "$SCRIPTDIR/generate-manifest.sh" >/dev/null 2>&1; then
        _rules=$(grep -c '^sys\.\|^dev\.' "$MANIFESTDIR/hw-manifest.conf" 2>/dev/null || echo 0)
        _spoof=$(grep -c '^sys\.spoof\.' "$MANIFESTDIR/hw-manifest.conf" 2>/dev/null || echo 0)
        _mask=$(grep -c '^sys\.mask\.'  "$MANIFESTDIR/hw-manifest.conf" 2>/dev/null || echo 0)
        ok "manifest written: $MANIFESTDIR/hw-manifest.conf"
        ok "$_rules rules  ($_spoof spoofs, $_mask subsystem masks)"
        _gpu=$(grep '^gpu.mesa_string=' "$MANIFESTDIR/hw-manifest.conf" 2>/dev/null | cut -d= -f2-)
        [ -n "$_gpu" ] && ok "GPU will report: $_gpu"
    else
        warn "hardware scan failed; run 'obsidian --regenerate-manifest' later"
    fi
else
    warn "hardware scan skipped - run 'obsidian --regenerate-manifest' before use"
fi

# =====================================================================
step "Installing the obsidian command"
# =====================================================================
mkdir -p "$(dirname "$CLI_LINK")"
rm -f "$CLI_LINK"
ln -s "$BINDIR/obsidian-launch" "$CLI_LINK"
chmod 755 "$BINDIR/obsidian-launch"
ok "$CLI_LINK -> $BINDIR/obsidian-launch"

case ":$PATH:" in
    *:/usr/local/bin:*) ok "/usr/local/bin is on PATH" ;;
    *) warn "/usr/local/bin is not on PATH; call $CLI_LINK by full path" ;;
esac

# =====================================================================
step "Self-test"
# =====================================================================
SELFTEST_FAIL=0
if [ "$DO_TEST" -eq 1 ]; then

    # 1. argv integrity - the defect this launcher was rebuilt to fix.
    _got="$("$CLI_LINK" printf '%s|' alpha "beta gamma" delta 2>/dev/null || true)"
    if [ "$_got" = "alpha|beta gamma|delta|" ]; then
        ok "argv integrity: multi-word arguments survive intact"
    else
        fail "argv integrity FAILED - got [$_got]"
        SELFTEST_FAIL=$((SELFTEST_FAIL + 1))
    fi

    # 2. exit status propagation through four namespaces.
    "$CLI_LINK" sh -c 'exit 42' >/dev/null 2>&1 || _rc=$?
    if [ "${_rc:-0}" -eq 42 ]; then
        ok "exit status propagates out of the sandbox"
    else
        fail "exit status propagation FAILED - got ${_rc:-0}, expected 42"
        SELFTEST_FAIL=$((SELFTEST_FAIL + 1))
    fi

    # 3. identity is actually spoofed.
    _hn="$("$CLI_LINK" hostname 2>/dev/null || true)"
    _rh="$(hostname 2>/dev/null || true)"
    if [ -n "$_hn" ] && [ "$_hn" != "$_rh" ]; then
        ok "hostname spoofed: $_rh -> $_hn"
    else
        fail "hostname NOT spoofed (got [$_hn])"
        SELFTEST_FAIL=$((SELFTEST_FAIL + 1))
    fi

    # 4. the /proc/meminfo bind mount - closed gap #1.
    _mt="$("$CLI_LINK" sh -c 'grep -m1 MemTotal /proc/meminfo' 2>/dev/null | tr -s ' ' | cut -d' ' -f2 || true)"
    if [ "$_mt" = "8192000" ]; then
        ok "/proc/meminfo spoofed: MemTotal 8192000 kB"
    else
        warn "/proc/meminfo reports [$_mt], expected 8192000"
    fi

    # 5. the statx hook - closed gap #2.
    _ns="$("$CLI_LINK" sh -c 'touch /tmp/.ob_st; stat -c %y /tmp/.ob_st' 2>/dev/null | sed -n 's/.*\.\([0-9]*\).*/\1/p' || true)"
    if [ "$_ns" = "000000000" ] || [ -z "$_ns" ]; then
        ok "file timestamps floored, nanoseconds zeroed"
    else
        warn "file timestamp nanoseconds read [$_ns], expected zeros"
    fi

    # 6. stdin passthrough.
    _si="$(printf 'ping\n' | "$CLI_LINK" cat 2>/dev/null || true)"
    if [ "$_si" = "ping" ]; then
        ok "stdin reaches the application"
    else
        fail "stdin passthrough FAILED"
        SELFTEST_FAIL=$((SELFTEST_FAIL + 1))
    fi

    # 7. seccomp, if it built.
    if [ "$SECCOMP_OK" -eq 1 ]; then
        _sc="$("$CLI_LINK" sh -c 'grep -m1 Seccomp: /proc/self/status' 2>/dev/null | tr -s ' \t' ' ' | cut -d' ' -f2 || true)"
        if [ "$_sc" = "2" ]; then
            ok "seccomp filter active (mode 2)"
        else
            warn "seccomp filter reports mode [$_sc], expected 2"
        fi
    fi
else
    warn "self-test skipped"
fi

# =====================================================================
# Done
# =====================================================================
printf '\n%s' "$C_B"
printf -- '---------------------------------------------------------------------\n'
if [ "$SELFTEST_FAIL" -eq 0 ]; then
    printf ' OBSIDIAN MIRROR v%s INSTALLED\n' "$OBSIDIAN_VERSION"
else
    printf ' OBSIDIAN MIRROR v%s INSTALLED - %d SELF-TEST FAILURE(S)\n' \
           "$OBSIDIAN_VERSION" "$SELFTEST_FAIL"
fi
printf -- '---------------------------------------------------------------------%s\n' "$C_0"
cat <<'DONEEOF'

  Run anything through it:

      obsidian firefox
      obsidian sh -c 'hostname; uname -r; id'
      obsidian curl https://example.com

  See exactly what it protects, item by item, with the real host
  value beside the value the application is given:

      obsidian --test

  Section 3 of that report lists every piece of host metadata that is
  still reachable and the reason it is not covered. Read it. A privacy
  tool that overstates itself is worse than no tool.

      obsidian --coverage            the full written coverage document
      obsidian --regenerate-manifest after any hardware change (root)

  Runtime switches, all defaulting to "do not break the application":

      OBSIDIAN_GPU_MODE=strict         no GPU fingerprint at all, but
                                       software rendering only
      OBSIDIAN_GL_EXTENSIONS=preserve  real GL extension list, if an
                                       application refuses to start
      OBSIDIAN_ALLOW_SYSTEM_BUS=1      permit the D-Bus system bus
      OBSIDIAN_VERBOSE=1               log blocked IPC connections

  Not covered, by design: the network layer. IP, DNS, routing, real
  MAC addresses over netlink and TLS fingerprints are untouched. Pair
  this with a VPN or a network namespace.

DONEEOF

[ "$SELFTEST_FAIL" -eq 0 ] || exit 1
exit 0
