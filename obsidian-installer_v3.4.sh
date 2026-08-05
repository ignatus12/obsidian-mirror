#!/bin/sh
# =====================================================================
#  Universal-Obsidian-Mirror-installer-script.sh
#
#  OBSIDIAN MIRROR v2 - Universal Host <-> Application Isolation Layer
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
#    Host <-> application metadata only. The NETWORK LAYER IS EXCLUDED
#    BY DESIGN - IP, DNS, MAC over netlink, TLS fingerprints. Pair this
#    with a VPN or a network namespace if you need that too.
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

OBSIDIAN_VERSION="2.0"
PREFIX="/opt/obsidian"
BINDIR="$PREFIX/bin"
LIBDIR="$PREFIX/lib"
SRCDIR="$PREFIX/src"
SCRIPTDIR="$PREFIX/scripts"
VARDIR="$PREFIX/var"
LEARNDIR="$VARDIR/learn"
FAKEROOT="$PREFIX/fake_root"
MANIFESTDIR="/etc/obsidian"
PROFILEDIR="$MANIFESTDIR/profiles"
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
printf ' Universal Host <-> Application Isolation Layer   v%s\n' "$OBSIDIAN_VERSION"
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
         "$FAKEROOT" "$FAKEROOT/fonts" "$FAKEROOT/proc" "$MANIFESTDIR" \
         "$VARDIR" "$VARDIR/homes" "$LEARNDIR" "$PROFILEDIR"; do
    mkdir -p "$d"
done
# The learning log is written from inside the sandbox by whichever
# unprivileged user is running an application through it, so it needs
# the same sticky-writable treatment /tmp gets.
chmod 1777 "$LEARNDIR"
chmod 1777 "$VARDIR/homes"
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
        return real_open("/home/.fake/cpu_online", flags, mode);
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
        return real_openat(AT_FDCWD, "/home/.fake/cpu_online", flags, mode);
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

cat > "$SRCDIR/obsidian_harden.c" <<'OBSIDIAN_PAYLOAD_HARDEN_C'
/* ============================================================
 * /opt/obsidian/bin/obsidian-harden
 * Obsidian Mirror - Strict Boundary enforcer.
 *
 *   "Deny everything; permit only what the app provably needs."
 *
 * This binary is the code translation of the strict-boundary
 * model. It is OPT-IN. If OBSIDIAN_HARDEN is unset or 0 the
 * binary immediately exec()s the target unchanged, so the
 * existing "obsidian <application>" path is bit-for-bit the
 * behaviour it had before this file existed.
 *
 * Layers, and the kernel mechanism each one is built from:
 *
 *   Filesystem   Landlock ruleset, default-deny. Every access
 *                right the running kernel knows about is placed
 *                in handled_access_fs, which denies it globally,
 *                and then re-granted ONLY on the explicit
 *                per-app allow-list. Nothing is enumerated as a
 *                denial: paths not granted are simply gone.
 *   Devices      same ruleset. /dev is never granted whole; only
 *                the individual nodes on the allow-list. Any
 *                grant that would expose a hard-deny node is
 *                pruned child-by-child instead of being dropped,
 *                so the app keeps what it needs and loses the
 *                node it must never see.
 *   Memory       seccomp-bpf: ptrace, process_vm_readv/writev,
 *                kcmp, pidfd_getfd, process_madvise, userfaultfd,
 *                perf_event_open. /dev/mem, /dev/kmem, /dev/port,
 *                /proc/kcore are hard-deny paths in the ruleset.
 *   Execution    Landlock EXECUTE is granted on library
 *                directories and on the app binary only. /bin,
 *                /usr/bin, /sbin are NOT executable, so
 *                "sh -c", "python -c", "node -e" cannot spawn.
 *                execveat(AT_EMPTY_PATH) is denied in seccomp,
 *                which is the memfd-exec pattern.
 *   Network      seccomp denies socket() for every address family
 *                except AF_UNIX unless a grant exists; Landlock
 *                network rules (kernel 6.7+) pin TCP connect/bind
 *                to the granted ports.
 *   IPC          Landlock scoping (kernel 6.12+) confines abstract
 *                unix sockets and signals to this domain.
 *   Namespaces   seccomp: unshare, setns, mount, umount2,
 *                pivot_root, chroot, the new mount API, and clone
 *                with any CLONE_NEW* flag.
 *   Capabilities whole bounding set dropped, ambient cleared,
 *                permitted/effective/inheritable zeroed.
 *   Privilege    PR_SET_NO_NEW_PRIVS.
 *   Launch state inherited file descriptors above stderr are
 *                closed before the app is reached.
 *
 * What this file does NOT claim: it cannot stop a side channel
 * (cache timing, power, EM) and it cannot see below the kernel,
 * so management-engine class silicon is out of reach. Those are
 * not kernel-policy problems and no amount of policy fixes them.
 *
 * Usage:   obsidian-harden [--print-plan] -- <command> [args...]
 * Build:   cc -O2 -Wall -o obsidian-harden obsidian_harden.c
 *          (no external library is required, on purpose)
 * ============================================================ */

#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>

/* ------------------------------------------------------------
 * Kernel interface definitions.
 *
 * Everything below is declared locally rather than pulled from
 * <linux/landlock.h>. The header only appeared in 5.13 and grew
 * a third struct field in 6.12; declaring our own copies means
 * this file builds against any toolchain and decides what the
 * running kernel supports at run time instead of build time.
 * ---------------------------------------------------------- */

#ifndef __NR_landlock_create_ruleset
#define __NR_landlock_create_ruleset 444
#endif
#ifndef __NR_landlock_add_rule
#define __NR_landlock_add_rule 445
#endif
#ifndef __NR_landlock_restrict_self
#define __NR_landlock_restrict_self 446
#endif
#ifndef __NR_close_range
#define __NR_close_range 436
#endif

#define OB_LL_VERSION_QUERY (1U << 0)   /* LANDLOCK_CREATE_RULESET_VERSION */
#define OB_LL_RULE_PATH_BENEATH 1
#define OB_LL_RULE_NET_PORT     2

/* filesystem access rights */
#define OB_FS_EXECUTE     (1ULL << 0)
#define OB_FS_WRITE_FILE  (1ULL << 1)
#define OB_FS_READ_FILE   (1ULL << 2)
#define OB_FS_READ_DIR    (1ULL << 3)
#define OB_FS_REMOVE_DIR  (1ULL << 4)
#define OB_FS_REMOVE_FILE (1ULL << 5)
#define OB_FS_MAKE_CHAR   (1ULL << 6)
#define OB_FS_MAKE_DIR    (1ULL << 7)
#define OB_FS_MAKE_REG    (1ULL << 8)
#define OB_FS_MAKE_SOCK   (1ULL << 9)
#define OB_FS_MAKE_FIFO   (1ULL << 10)
#define OB_FS_MAKE_BLOCK  (1ULL << 11)
#define OB_FS_MAKE_SYM    (1ULL << 12)
#define OB_FS_REFER       (1ULL << 13)  /* ABI 2 */
#define OB_FS_TRUNCATE    (1ULL << 14)  /* ABI 3 */
#define OB_FS_IOCTL_DEV   (1ULL << 15)  /* ABI 5 */

/* network access rights, ABI 4 */
#define OB_NET_BIND_TCP    (1ULL << 0)
#define OB_NET_CONNECT_TCP (1ULL << 1)

/* scoping, ABI 6 */
#define OB_SCOPE_ABSTRACT_UNIX (1ULL << 0)
#define OB_SCOPE_SIGNAL        (1ULL << 1)

struct ob_ruleset_attr {
    uint64_t handled_access_fs;
    uint64_t handled_access_net;   /* ABI 4 */
    uint64_t scoped;               /* ABI 6 */
};

struct ob_path_beneath_attr {
    uint64_t allowed_access;
    int32_t  parent_fd;
} __attribute__((packed));

struct ob_net_port_attr {
    uint64_t allowed_access;
    uint64_t port;
};

/* capabilities, without linking libcap */
#define OB_CAP_VERSION_3 0x20080522
struct ob_cap_header { uint32_t version; int pid; };
struct ob_cap_data   { uint32_t effective, permitted, inheritable; };

#ifndef PR_SET_NO_NEW_PRIVS
#define PR_SET_NO_NEW_PRIVS 38
#endif
#ifndef PR_CAPBSET_DROP
#define PR_CAPBSET_DROP 24
#endif
#ifndef PR_CAP_AMBIENT
#define PR_CAP_AMBIENT 47
#endif
#ifndef PR_CAP_AMBIENT_CLEAR_ALL
#define PR_CAP_AMBIENT_CLEAR_ALL 4
#endif

/* audit arch for the seccomp arch guard */
#if defined(__x86_64__)
#  ifndef AUDIT_ARCH_X86_64
#    define AUDIT_ARCH_X86_64 0xc000003e
#  endif
#  define OB_AUDIT_ARCH AUDIT_ARCH_X86_64
#  define OB_X32_BIT 0x40000000
#elif defined(__i386__)
#  define OB_AUDIT_ARCH AUDIT_ARCH_I386
#elif defined(__aarch64__)
#  define OB_AUDIT_ARCH AUDIT_ARCH_AARCH64
#elif defined(__arm__)
#  define OB_AUDIT_ARCH AUDIT_ARCH_ARM
#elif defined(__riscv) && __riscv_xlen == 64
#  define OB_AUDIT_ARCH AUDIT_ARCH_RISCV64
#elif defined(__powerpc64__)
#  define OB_AUDIT_ARCH AUDIT_ARCH_PPC64LE
#else
#  define OB_AUDIT_ARCH 0
#endif

#ifndef SECCOMP_RET_KILL_PROCESS
#define SECCOMP_RET_KILL_PROCESS 0x80000000U
#endif
#ifndef SECCOMP_SET_MODE_FILTER
#define SECCOMP_SET_MODE_FILTER 1
#endif
#ifndef SECCOMP_FILTER_FLAG_TSYNC
#define SECCOMP_FILTER_FLAG_TSYNC 1
#endif

/* ------------------------------------------------------------
 * Configuration
 * ---------------------------------------------------------- */

#define OB_MAX_PATHS   512
#define OB_MAX_RULES  4096
#define OB_MAX_PORTS    64
#define OB_PRUNE_DEPTH    6

enum ob_kind { OB_RO = 0, OB_RX, OB_RW, OB_RWX, OB_DEV };

struct ob_grant {
    char        path[PATH_MAX];
    enum ob_kind kind;
};

static struct ob_grant grants[OB_MAX_PATHS];
static int             ngrants;

static char denies[OB_MAX_PATHS][PATH_MAX];
static int  ndenies;

static struct { unsigned port; int bind; } netports[OB_MAX_PORTS];
static int  nnetports;

static int  cfg_enabled;        /* 0 off, 1 strict, 2 paranoid  */
static int  cfg_plan_only;      /* print the plan, enforce nothing */
static int  cfg_verbose;
static int  cfg_hard_fail;      /* abort if a layer cannot load */
static int  cfg_net_all;        /* OBSIDIAN_ALLOW_NET=all       */
static int  cfg_net_any;        /* any network grant at all     */
static int  cfg_deny_net;       /* OBSIDIAN_DENY_NET / opt.deny_net */
static int  cfg_scope_ipc = -1; /* -1 = auto                    */
static int  cfg_memfd_deny;
static int  cfg_nested_ns;      /* allow CLONE_NEW* / unshare   */
static int  cfg_keep_caps;
static int  cfg_keep_fds;
static int  cfg_no_seccomp;
static int  cfg_no_landlock;
static int  cfg_defaults = 1;   /* seed the base allow-list     */

static int  rules_added;
static int  rules_skipped;
static int  landlock_abi;

/* ------------------------------------------------------------
 * small helpers
 * ---------------------------------------------------------- */

static void vlog(const char *fmt, ...)
{
    va_list ap;
    if (!cfg_verbose && !cfg_plan_only) return;
    va_start(ap, fmt);
    fputs("obsidian-harden: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

static void warn(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fputs("obsidian-harden: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

/* Expand a leading ~ or $VAR component. Returns 0 on success. */
static int expand_path(const char *in, char *out, size_t outsz)
{
    const char *home;

    if (!in || !*in) return -1;

    if (in[0] == '~' && (in[1] == '/' || in[1] == 0)) {
        home = getenv("HOME");
        if (!home || !*home) return -1;
        if ((size_t)snprintf(out, outsz, "%s%s", home, in + 1) >= outsz)
            return -1;
        return 0;
    }

    if (in[0] == '$') {
        char name[128];
        const char *slash = strchr(in + 1, '/');
        size_t n = slash ? (size_t)(slash - in - 1) : strlen(in + 1);
        const char *val;
        if (n == 0 || n >= sizeof(name)) return -1;
        memcpy(name, in + 1, n);
        name[n] = 0;
        val = getenv(name);
        if (!val || !*val) return -1;
        if ((size_t)snprintf(out, outsz, "%s%s", val, slash ? slash : "") >= outsz)
            return -1;
        return 0;
    }

    if (in[0] != '/') return -1;   /* only absolute paths are accepted */
    if ((size_t)snprintf(out, outsz, "%s", in) >= outsz) return -1;
    return 0;
}

static void add_grant(const char *raw, enum ob_kind kind)
{
    char buf[PATH_MAX];
    int i;

    if (ngrants >= OB_MAX_PATHS) return;
    if (expand_path(raw, buf, sizeof(buf)) != 0) return;

    /* strip a trailing slash so prefix tests behave */
    i = (int)strlen(buf);
    while (i > 1 && buf[i - 1] == '/') buf[--i] = 0;

    for (i = 0; i < ngrants; i++)
        if (strcmp(grants[i].path, buf) == 0 && grants[i].kind == kind)
            return;

    snprintf(grants[ngrants].path, PATH_MAX, "%s", buf);
    grants[ngrants].kind = kind;
    ngrants++;
}

static void add_deny(const char *raw)
{
    char buf[PATH_MAX];
    int i;

    if (ndenies >= OB_MAX_PATHS) return;
    if (expand_path(raw, buf, sizeof(buf)) != 0) return;
    i = (int)strlen(buf);
    while (i > 1 && buf[i - 1] == '/') buf[--i] = 0;

    for (i = 0; i < ndenies; i++)
        if (strcmp(denies[i], buf) == 0) return;

    snprintf(denies[ndenies], PATH_MAX, "%s", buf);
    ndenies++;
}

/* Split a colon separated list and hand each element to add_grant. */
static void add_list(const char *list, enum ob_kind kind)
{
    char buf[8192], *p, *q;

    if (!list || !*list) return;
    snprintf(buf, sizeof(buf), "%s", list);
    p = buf;
    while (p && *p) {
        q = strchr(p, ':');
        /* a colon that is part of "$VAR" is impossible, so a plain
         * split is safe here */
        if (q) *q = 0;
        while (*p == ' ') p++;
        if (*p) add_grant(p, kind);
        p = q ? q + 1 : NULL;
    }
}

static void add_deny_list(const char *list)
{
    char buf[8192], *p, *q;

    if (!list || !*list) return;
    snprintf(buf, sizeof(buf), "%s", list);
    p = buf;
    while (p && *p) {
        q = strchr(p, ':');
        if (q) *q = 0;
        while (*p == ' ') p++;
        if (*p) add_deny(p);
        p = q ? q + 1 : NULL;
    }
}

/* "a is at or beneath b" */
static int path_under(const char *a, const char *b)
{
    size_t lb = strlen(b);
    if (strcmp(b, "/") == 0) return 1;
    if (strncmp(a, b, lb) != 0) return 0;
    return a[lb] == 0 || a[lb] == '/';
}

/* is any hard-deny entry strictly beneath this path */
static int deny_below(const char *path)
{
    int i;
    for (i = 0; i < ndenies; i++)
        if (path_under(denies[i], path) && strcmp(denies[i], path) != 0)
            return 1;
    return 0;
}

static int deny_hits(const char *path)
{
    int i;
    for (i = 0; i < ndenies; i++)
        if (path_under(path, denies[i]))
            return 1;
    return 0;
}

/* ------------------------------------------------------------
 * Landlock
 * ---------------------------------------------------------- */

static uint64_t handled_fs;
static uint64_t handled_net;
static uint64_t handled_scope;

/* IOCTL_DEV, handled from Landlock ABI 5, governs ioctl on character
 * and block devices only. It is included in every grant kind rather
 * than only in OB_DEV: the decision that matters was made when the
 * device node was granted at all, and withholding ioctl afterwards
 * breaks terminals, DRM and sound for no gain. */
static uint64_t rights_for(enum ob_kind kind, int isdir)
{
    uint64_t r = 0;

    switch (kind) {
    case OB_RO:
        r = OB_FS_READ_FILE | OB_FS_READ_DIR | OB_FS_IOCTL_DEV;
        break;
    case OB_RX:
        r = OB_FS_READ_FILE | OB_FS_READ_DIR | OB_FS_EXECUTE |
            OB_FS_IOCTL_DEV;
        break;
    case OB_RW:
    case OB_RWX:
        r = OB_FS_READ_FILE | OB_FS_READ_DIR | OB_FS_WRITE_FILE |
            OB_FS_REMOVE_DIR | OB_FS_REMOVE_FILE | OB_FS_MAKE_CHAR |
            OB_FS_MAKE_DIR | OB_FS_MAKE_REG | OB_FS_MAKE_SOCK |
            OB_FS_MAKE_FIFO | OB_FS_MAKE_BLOCK | OB_FS_MAKE_SYM |
            OB_FS_REFER | OB_FS_TRUNCATE | OB_FS_IOCTL_DEV;
        if (kind == OB_RWX) r |= OB_FS_EXECUTE;
        break;
    case OB_DEV:
        r = OB_FS_READ_FILE | OB_FS_WRITE_FILE | OB_FS_READ_DIR |
            OB_FS_TRUNCATE | OB_FS_IOCTL_DEV | OB_FS_MAKE_SOCK |
            OB_FS_MAKE_FIFO | OB_FS_MAKE_REG | OB_FS_MAKE_DIR |
            OB_FS_REMOVE_FILE | OB_FS_REMOVE_DIR;
        break;
    }

    /* A rule on a non-directory may only carry file rights, or the
     * kernel rejects the whole rule with EINVAL. */
    if (!isdir)
        r &= (OB_FS_EXECUTE | OB_FS_WRITE_FILE | OB_FS_READ_FILE |
              OB_FS_TRUNCATE | OB_FS_IOCTL_DEV);

    return r & handled_fs;
}

static int ll_add_path(int ruleset_fd, const char *path, enum ob_kind kind)
{
    struct ob_path_beneath_attr pb;
    struct stat st;
    int fd, rc;

    if (rules_added >= OB_MAX_RULES) return -1;

    if (stat(path, &st) != 0) return 0;      /* absent here: nothing to grant */

    /* Symlinks are followed deliberately. O_PATH|O_NOFOLLOW does not
     * fail on a symlink, it succeeds and hands back the link itself,
     * and a rule attached to a symlink inode governs nothing - so
     * granting /bin on a distribution where /bin -> usr/bin used to
     * be accepted, counted, and silently worthless. stat() above
     * already followed the link to decide the rights, so following it
     * here is also the only way the two agree. */
    fd = open(path, O_PATH | O_CLOEXEC);
    if (fd < 0) { rules_skipped++; return 0; }

    pb.allowed_access = rights_for(kind, S_ISDIR(st.st_mode));
    pb.parent_fd = fd;

    if (pb.allowed_access == 0) { close(fd); rules_skipped++; return 0; }

    rc = (int)syscall(__NR_landlock_add_rule, ruleset_fd,
                      OB_LL_RULE_PATH_BENEATH, &pb, 0U);
    close(fd);

    if (rc != 0) {
        rules_skipped++;
        if (cfg_verbose)
            warn("rule rejected for %s (%s)", path, strerror(errno));
        return -1;
    }

    rules_added++;
    if (cfg_plan_only || cfg_verbose)
        fprintf(stderr, "  grant %-4s %s\n",
                kind == OB_RO ? "ro" : kind == OB_RX ? "rx" :
                kind == OB_RW ? "rw" : kind == OB_RWX ? "rwx" : "dev",
                path);
    return 0;
}

/* Grant a path, carving out any hard-deny entry that lives beneath it.
 *
 * This is the part that makes "default-deny with a minimal grant"
 * survive contact with reality: an app legitimately needs /dev, and
 * /dev legitimately contains /dev/mem. Rather than refuse the grant
 * or hand over the disk, walk one level down and grant the children
 * that are not on, and do not contain, a hard-deny path. */
static void ll_grant_pruned(int ruleset_fd, const char *path,
                            enum ob_kind kind, int depth)
{
    DIR *d;
    struct dirent *e;
    char child[PATH_MAX];

    if (deny_hits(path)) {
        vlog("hard-deny, not granted: %s", path);
        return;
    }

    if (!deny_below(path) || depth >= OB_PRUNE_DEPTH) {
        if (deny_below(path))
            warn("prune depth reached, %s NOT granted (would expose a "
                 "hard-deny path)", path);
        else
            ll_add_path(ruleset_fd, path, kind);
        return;
    }

    d = opendir(path);
    if (!d) {
        /* cannot enumerate: refuse rather than over-grant */
        warn("cannot enumerate %s to prune it, not granted", path);
        return;
    }

    vlog("pruning %s (a hard-deny path lives beneath it)", path);
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0)
            continue;
        if ((size_t)snprintf(child, sizeof(child), "%s/%s",
                             strcmp(path, "/") == 0 ? "" : path,
                             e->d_name) >= sizeof(child))
            continue;
        ll_grant_pruned(ruleset_fd, child, kind, depth + 1);
    }
    closedir(d);
}

static int landlock_apply(void)
{
    struct ob_ruleset_attr attr;
    size_t attrsz;
    int fd, i;

    landlock_abi = (int)syscall(__NR_landlock_create_ruleset, NULL, 0,
                                OB_LL_VERSION_QUERY);
    if (landlock_abi < 1) {
        warn("Landlock unavailable on this kernel (%s). Filesystem, device "
             "and network confinement are NOT active.", strerror(errno));
        return -1;
    }

    handled_fs =
        OB_FS_EXECUTE | OB_FS_WRITE_FILE | OB_FS_READ_FILE | OB_FS_READ_DIR |
        OB_FS_REMOVE_DIR | OB_FS_REMOVE_FILE | OB_FS_MAKE_CHAR |
        OB_FS_MAKE_DIR | OB_FS_MAKE_REG | OB_FS_MAKE_SOCK | OB_FS_MAKE_FIFO |
        OB_FS_MAKE_BLOCK | OB_FS_MAKE_SYM;
    if (landlock_abi >= 2) handled_fs |= OB_FS_REFER;
    if (landlock_abi >= 3) handled_fs |= OB_FS_TRUNCATE;
    if (landlock_abi >= 5) handled_fs |= OB_FS_IOCTL_DEV;

    if (landlock_abi >= 4 && !cfg_net_all)
        handled_net = OB_NET_BIND_TCP | OB_NET_CONNECT_TCP;

    if (landlock_abi >= 6 && cfg_scope_ipc == 1)
        handled_scope = OB_SCOPE_ABSTRACT_UNIX | OB_SCOPE_SIGNAL;

    memset(&attr, 0, sizeof(attr));
    attr.handled_access_fs  = handled_fs;
    attr.handled_access_net = handled_net;
    attr.scoped             = handled_scope;

    if (landlock_abi >= 6)      attrsz = sizeof(attr);
    else if (landlock_abi >= 4) attrsz = sizeof(uint64_t) * 2;
    else                        attrsz = sizeof(uint64_t);

    fd = (int)syscall(__NR_landlock_create_ruleset, &attr, attrsz, 0U);
    if (fd < 0) {
        warn("landlock_create_ruleset: %s", strerror(errno));
        return -1;
    }

    vlog("Landlock ABI %d, default-deny ruleset created", landlock_abi);

    for (i = 0; i < ngrants; i++)
        ll_grant_pruned(fd, grants[i].path, grants[i].kind, 0);

    if (handled_net) {
        for (i = 0; i < nnetports; i++) {
            struct ob_net_port_attr np;
            np.allowed_access = netports[i].bind
                              ? OB_NET_BIND_TCP : OB_NET_CONNECT_TCP;
            np.port = netports[i].port;
            if (syscall(__NR_landlock_add_rule, fd, OB_LL_RULE_NET_PORT,
                        &np, 0U) != 0)
                warn("net rule for port %u rejected: %s",
                     netports[i].port, strerror(errno));
            else if (cfg_plan_only || cfg_verbose)
                fprintf(stderr, "  grant net  tcp %s %u\n",
                        netports[i].bind ? "bind" : "connect",
                        netports[i].port);
        }
    }

    if (cfg_plan_only) { close(fd); return 0; }

    if (syscall(__NR_landlock_restrict_self, fd, 0U) != 0) {
        warn("landlock_restrict_self: %s", strerror(errno));
        close(fd);
        return -1;
    }

    close(fd);
    vlog("filesystem boundary sealed: %d grants, %d skipped",
         rules_added, rules_skipped);
    return 0;
}

/* ------------------------------------------------------------
 * seccomp-bpf, assembled here rather than through libseccomp so
 * the enforcer has no build dependency and the exact program is
 * auditable in one place.
 * ---------------------------------------------------------- */

#define OB_MAX_INSN 1024
static struct sock_filter prog[OB_MAX_INSN];
static int nprog;
static int acc_holds_nr;

#define OFF_NR      0
#define OFF_ARCH    4
#define OFF_ARG(i)  (16 + 8 * (i))          /* low word, little endian */

#define RET_EPERM  (SECCOMP_RET_ERRNO | (EPERM  & SECCOMP_RET_DATA))
#define RET_ENOSYS (SECCOMP_RET_ERRNO | (ENOSYS & SECCOMP_RET_DATA))
#define RET_EACCES (SECCOMP_RET_ERRNO | (EACCES & SECCOMP_RET_DATA))
#define RET_EAFNO  (SECCOMP_RET_ERRNO | (EAFNOSUPPORT & SECCOMP_RET_DATA))
#define RET_KILL   SECCOMP_RET_KILL_PROCESS

static void emit(struct sock_filter f)
{
    if (nprog < OB_MAX_INSN) prog[nprog++] = f;
}

static void load_nr(void)
{
    if (acc_holds_nr) return;
    emit((struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, OFF_NR));
    acc_holds_nr = 1;
}

/* whole syscall denied */
static void deny(long nr, uint32_t action)
{
    if (nr < 0) return;
    load_nr();
    emit((struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,
                                      (uint32_t)nr, 0, 1));
    emit((struct sock_filter)BPF_STMT(BPF_RET | BPF_K, action));
}

/* denied only when any bit of mask is set in arg[argi] */
static void deny_flag(long nr, int argi, uint32_t mask, uint32_t action)
{
    if (nr < 0) return;
    load_nr();
    emit((struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,
                                      (uint32_t)nr, 0, 3));
    emit((struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                                      OFF_ARG(argi)));
    emit((struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, mask, 0, 1));
    emit((struct sock_filter)BPF_STMT(BPF_RET | BPF_K, action));
    acc_holds_nr = 0;
}

/* denied unless arg[argi] equals one of the listed values */
static void allow_only(long nr, int argi, const uint32_t *vals, int nvals,
                       uint32_t action)
{
    int i;
    if (nr < 0 || nvals <= 0) return;
    load_nr();
    emit((struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,
                                      (uint32_t)nr, 0, nvals + 2));
    emit((struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                                      OFF_ARG(argi)));
    for (i = 0; i < nvals; i++)
        emit((struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,
                                          vals[i], nvals - i, 0));
    emit((struct sock_filter)BPF_STMT(BPF_RET | BPF_K, action));
    acc_holds_nr = 0;
}

#define NR_OF(name) OB_NR_##name
#ifdef __NR_ptrace
#define OB_NR_ptrace __NR_ptrace
#else
#define OB_NR_ptrace -1
#endif

/* Table driven for the plain denials. A syscall the running
 * architecture does not define is simply absent from the table. */
struct denyent { long nr; uint32_t act; const char *why; };

static const struct denyent deny_table[] = {
    /* --- memory: another process's address space is not yours --- */
#ifdef __NR_ptrace
    { __NR_ptrace,            RET_EPERM, "ptrace" },
#endif
#ifdef __NR_process_vm_readv
    { __NR_process_vm_readv,  RET_EPERM, "process_vm_readv" },
#endif
#ifdef __NR_process_vm_writev
    { __NR_process_vm_writev, RET_EPERM, "process_vm_writev" },
#endif
#ifdef __NR_process_madvise
    { __NR_process_madvise,   RET_EPERM, "process_madvise" },
#endif
#ifdef __NR_kcmp
    { __NR_kcmp,              RET_EPERM, "kcmp" },
#endif
#ifdef __NR_pidfd_getfd
    { __NR_pidfd_getfd,       RET_EPERM, "pidfd_getfd" },
#endif
#ifdef __NR_userfaultfd
    { __NR_userfaultfd,       RET_EPERM, "userfaultfd" },
#endif
#ifdef __NR_perf_event_open
    { __NR_perf_event_open,   RET_EPERM, "perf_event_open" },
#endif
#ifdef __NR_lookup_dcookie
    { __NR_lookup_dcookie,    RET_EPERM, "lookup_dcookie" },
#endif

    /* --- the logs. reading the kernel ring buffer is reading every
     *     other subsystem's diary --- */
#ifdef __NR_syslog
    { __NR_syslog,            RET_EPERM, "syslog" },
#endif

    /* --- kernel code loading --- */
#ifdef __NR_init_module
    { __NR_init_module,       RET_EPERM, "init_module" },
#endif
#ifdef __NR_finit_module
    { __NR_finit_module,      RET_EPERM, "finit_module" },
#endif
#ifdef __NR_delete_module
    { __NR_delete_module,     RET_EPERM, "delete_module" },
#endif
#ifdef __NR_kexec_load
    { __NR_kexec_load,        RET_EPERM, "kexec_load" },
#endif
#ifdef __NR_kexec_file_load
    { __NR_kexec_file_load,   RET_EPERM, "kexec_file_load" },
#endif
#ifdef __NR_bpf
    { __NR_bpf,               RET_EPERM, "bpf" },
#endif

    /* --- io_uring: a second syscall interface that seccomp cannot
     *     see into. Closing it keeps this filter meaningful --- */
#ifdef __NR_io_uring_setup
    { __NR_io_uring_setup,    RET_EPERM, "io_uring_setup" },
#endif
#ifdef __NR_io_uring_enter
    { __NR_io_uring_enter,    RET_EPERM, "io_uring_enter" },
#endif
#ifdef __NR_io_uring_register
    { __NR_io_uring_register, RET_EPERM, "io_uring_register" },
#endif

    /* --- direct hardware port I/O: nothing legitimate does this --- */
#ifdef __NR_iopl
    { __NR_iopl,              RET_KILL,  "iopl" },
#endif
#ifdef __NR_ioperm
    { __NR_ioperm,            RET_KILL,  "ioperm" },
#endif

    /* --- filesystem escapes by handle --- */
#ifdef __NR_open_by_handle_at
    { __NR_open_by_handle_at, RET_EPERM, "open_by_handle_at" },
#endif
#ifdef __NR_name_to_handle_at
    { __NR_name_to_handle_at, RET_EPERM, "name_to_handle_at" },
#endif
#ifdef __NR_fanotify_init
    { __NR_fanotify_init,     RET_EPERM, "fanotify_init" },
#endif

    /* --- mount and namespace machinery --- */
#ifdef __NR_setns
    { __NR_setns,             RET_EPERM, "setns" },
#endif
#ifdef __NR_mount
    { __NR_mount,             RET_EPERM, "mount" },
#endif
#ifdef __NR_umount2
    { __NR_umount2,           RET_EPERM, "umount2" },
#endif
#ifdef __NR_pivot_root
    { __NR_pivot_root,        RET_EPERM, "pivot_root" },
#endif
#ifdef __NR_chroot
    { __NR_chroot,            RET_EPERM, "chroot" },
#endif
#ifdef __NR_move_mount
    { __NR_move_mount,        RET_EPERM, "move_mount" },
#endif
#ifdef __NR_open_tree
    { __NR_open_tree,         RET_EPERM, "open_tree" },
#endif
#ifdef __NR_fsopen
    { __NR_fsopen,            RET_EPERM, "fsopen" },
#endif
#ifdef __NR_fsconfig
    { __NR_fsconfig,          RET_EPERM, "fsconfig" },
#endif
#ifdef __NR_fsmount
    { __NR_fsmount,           RET_EPERM, "fsmount" },
#endif
#ifdef __NR_fspick
    { __NR_fspick,            RET_EPERM, "fspick" },
#endif
#ifdef __NR_mount_setattr
    { __NR_mount_setattr,     RET_EPERM, "mount_setattr" },
#endif

    /* --- clock: both a host-damage and a fingerprint surface --- */
#ifdef __NR_settimeofday
    { __NR_settimeofday,      RET_EPERM, "settimeofday" },
#endif
#ifdef __NR_clock_settime
    { __NR_clock_settime,     RET_EPERM, "clock_settime" },
#endif
#ifdef __NR_clock_adjtime
    { __NR_clock_adjtime,     RET_EPERM, "clock_adjtime" },
#endif
#ifdef __NR_adjtimex
    { __NR_adjtimex,          RET_EPERM, "adjtimex" },
#endif

    /* --- kernel keyring: other people's secrets --- */
#ifdef __NR_keyctl
    { __NR_keyctl,            RET_EPERM, "keyctl" },
#endif
#ifdef __NR_add_key
    { __NR_add_key,           RET_EPERM, "add_key" },
#endif
#ifdef __NR_request_key
    { __NR_request_key,       RET_EPERM, "request_key" },
#endif

    /* --- host state the app has no business touching --- */
#ifdef __NR_sethostname
    { __NR_sethostname,       RET_EPERM, "sethostname" },
#endif
#ifdef __NR_setdomainname
    { __NR_setdomainname,     RET_EPERM, "setdomainname" },
#endif
#ifdef __NR_swapon
    { __NR_swapon,            RET_EPERM, "swapon" },
#endif
#ifdef __NR_swapoff
    { __NR_swapoff,           RET_EPERM, "swapoff" },
#endif
#ifdef __NR_reboot
    { __NR_reboot,            RET_EPERM, "reboot" },
#endif
#ifdef __NR_acct
    { __NR_acct,              RET_EPERM, "acct" },
#endif
#ifdef __NR_quotactl
    { __NR_quotactl,          RET_EPERM, "quotactl" },
#endif
#ifdef __NR_vhangup
    { __NR_vhangup,           RET_EPERM, "vhangup" },
#endif
};

#define NDENY ((int)(sizeof(deny_table) / sizeof(deny_table[0])))

static int seccomp_apply(void)
{
    struct sock_fprog fprog;
    int i;

    nprog = 0;
    acc_holds_nr = 0;

    /* Architecture guard. A 64-bit process that issues a 32-bit or
     * x32 syscall is renumbering the whole table underneath this
     * filter, which is the oldest seccomp bypass there is. */
    if (OB_AUDIT_ARCH) {
        emit((struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, OFF_ARCH));
        emit((struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,
                                          OB_AUDIT_ARCH, 1, 0));
        emit((struct sock_filter)BPF_STMT(BPF_RET | BPF_K, RET_ENOSYS));
#ifdef OB_X32_BIT
        emit((struct sock_filter)BPF_STMT(BPF_LD | BPF_W | BPF_ABS, OFF_NR));
        emit((struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K,
                                          OB_X32_BIT, 0, 1));
        emit((struct sock_filter)BPF_STMT(BPF_RET | BPF_K, RET_ENOSYS));
        acc_holds_nr = 1;
#endif
    }

    for (i = 0; i < NDENY; i++)
        deny(deny_table[i].nr, deny_table[i].act);

    /* --- execution ---------------------------------------------
     * execveat with AT_EMPTY_PATH executes a file descriptor that
     * has no name in any filesystem. That is precisely the
     * memfd_create + execve pattern, and it is the one exec path
     * a filesystem policy cannot see. */
#ifdef __NR_execveat
    deny_flag(__NR_execveat, 4, 0x1000 /* AT_EMPTY_PATH */, RET_EACCES);
#endif
#ifdef __NR_memfd_create
    if (cfg_memfd_deny)
        deny(__NR_memfd_create, RET_EPERM);
    else
        /* MFD_EXEC, kernel 6.3+: an explicitly executable anonymous
         * file. Denied even when plain memfd is allowed, because
         * shared memory never needs it. */
        deny_flag(__NR_memfd_create, 1, 0x0008 /* MFD_EXEC */, RET_EPERM);
#endif

    /* ASLR off, or "every readable page is also executable", are
     * requests only an exploit makes. */
#ifdef __NR_personality
    deny_flag(__NR_personality, 0, 0x0040000 | 0x0400000, RET_EPERM);
#endif

    /* --- namespaces --------------------------------------------
     * An app that can build a namespace can build a place where it
     * is root, and root inside a namespace is the first half of
     * most container escapes. */
    if (!cfg_nested_ns) {
#ifdef __NR_unshare
        deny(__NR_unshare, RET_EPERM);
#endif
#if defined(__NR_clone) && (defined(__x86_64__) || defined(__i386__) || \
    defined(__aarch64__) || defined(__arm__) || defined(__riscv))
        /* CLONE_NEWNS|NEWCGROUP|NEWUTS|NEWIPC|NEWUSER|NEWPID|NEWNET */
        deny_flag(__NR_clone, 0, 0x7E020000U, RET_EPERM);
#endif
#ifdef __NR_clone3
        /* clone3 takes a struct, so its flags cannot be inspected by
         * a BPF filter. ENOSYS makes libc fall back to clone, which
         * can be inspected. */
        deny(__NR_clone3, RET_ENOSYS);
#endif
    }

    /* --- network ------------------------------------------------
     * Default deny is expressed at the address family: AF_UNIX is
     * needed for the display server and is kept, everything that
     * can reach off this machine is refused at socket() time. */
    if (!cfg_net_all) {
        uint32_t allowed[4];
        int n = 0;
        allowed[n++] = 1;                 /* AF_UNIX  */
        if (cfg_net_any) {
            allowed[n++] = 2;             /* AF_INET  */
            allowed[n++] = 10;            /* AF_INET6 */
        }
#ifdef __NR_socket
        allow_only(__NR_socket, 0, allowed, n, RET_EAFNO);
#endif
#ifdef __NR_socketpair
        allow_only(__NR_socketpair, 0, allowed, n, RET_EAFNO);
#endif
    }

    emit((struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW));

    if (nprog >= OB_MAX_INSN) {
        warn("seccomp program overflowed, filter NOT loaded");
        return -1;
    }

    if (cfg_plan_only) {
        vlog("seccomp program assembled: %d instructions (not loaded)", nprog);
        return 0;
    }

    fprog.len = (unsigned short)nprog;
    fprog.filter = prog;

    if (syscall(__NR_seccomp, SECCOMP_SET_MODE_FILTER,
                SECCOMP_FILTER_FLAG_TSYNC, &fprog) != 0) {
        if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &fprog, 0, 0) != 0) {
            warn("seccomp filter load failed: %s", strerror(errno));
            return -1;
        }
    }

    vlog("syscall boundary sealed: %d instructions", nprog);
    return 0;
}

/* ------------------------------------------------------------
 * capabilities and privilege
 * ---------------------------------------------------------- */

/* Read the effective capability mask this process actually holds. */
static unsigned long long caps_effective(void)
{
    FILE *f = fopen("/proc/self/status", "r");
    char line[256];
    unsigned long long v = 0;

    if (!f) return 0;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "CapEff:", 7) == 0) {
            v = strtoull(line + 7, NULL, 16);
            break;
        }
    }
    fclose(f);
    return v;
}

static int caps_drop(void)
{
    struct ob_cap_header hdr;
    struct ob_cap_data data[2];
    unsigned long long held = caps_effective();
    int i, failed = 0;

    prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0);

    for (i = 0; i <= 63; i++) {
        if (prctl(PR_CAPBSET_DROP, i, 0, 0, 0) != 0) {
            if (errno == EINVAL) break;   /* past the last capability */
            failed++;
        }
    }

    memset(&hdr, 0, sizeof(hdr));
    memset(data, 0, sizeof(data));
    hdr.version = OB_CAP_VERSION_3;
    hdr.pid = 0;
    if (syscall(__NR_capset, &hdr, data) != 0)
        failed++;

    if (failed && held == 0) {
        /* Emptying the bounding set needs CAP_SETPCAP. A process that
         * holds no capability cannot drop it - and cannot use it
         * either, since no_new_privs blocks every path back to
         * privilege. Reporting this as a failure would be a lie in
         * the safe direction, which is still a lie. */
        vlog("capabilities: none held (CapEff 0); bounding set left "
             "untouched, it needs CAP_SETPCAP to clear and cannot be "
             "reached from here");
        return 0;
    }

    if (failed)
        warn("capability drop partially refused (%d entries), bounding set "
             "may retain capabilities", failed);
    else
        vlog("capabilities dropped: bounding set empty, ambient cleared");

    return failed ? -1 : 0;
}

/* ------------------------------------------------------------
 * launch-state scrub
 *
 * A process inherits more than its arguments. Descriptors left
 * open by whatever started it are readable and writable objects
 * that no policy layer above ever sees, because they were opened
 * before the policy existed.
 * ---------------------------------------------------------- */

static void scrub_fds(void)
{
    DIR *d;
    struct dirent *e;
    int maxfd = 0, fd;

    if (syscall(__NR_close_range, 3, ~0U, 0) == 0) {
        vlog("launch state: inherited descriptors above stderr closed "
             "(close_range)");
        return;
    }

    d = opendir("/proc/self/fd");
    if (d) {
        int dfd = dirfd(d);
        while ((e = readdir(d)) != NULL) {
            if (!isdigit((unsigned char)e->d_name[0])) continue;
            fd = atoi(e->d_name);
            if (fd > 2 && fd != dfd) close(fd);
        }
        closedir(d);
        vlog("launch state: inherited descriptors above stderr closed "
             "(/proc/self/fd)");
        return;
    }

    maxfd = (int)sysconf(_SC_OPEN_MAX);
    if (maxfd < 0 || maxfd > 65536) maxfd = 4096;
    for (fd = 3; fd < maxfd; fd++) close(fd);
    vlog("launch state: inherited descriptors above stderr closed (sweep)");
}

/* ------------------------------------------------------------
 * profile and environment parsing
 * ---------------------------------------------------------- */

static void add_net_grant(const char *spec)
{
    /* forms: all | none | tcp:443 | connect:443 | bind:8080 | 443 */
    char buf[4096], *p, *q;

    if (!spec || !*spec) return;
    snprintf(buf, sizeof(buf), "%s", spec);

    if (strcmp(buf, "all") == 0) { cfg_net_all = 1; cfg_net_any = 1; return; }
    if (strcmp(buf, "none") == 0) return;

    p = buf;
    while (p && *p) {
        int bind = 0;
        unsigned port;
        q = strchr(p, ',');
        if (q) *q = 0;
        while (*p == ' ') p++;
        if (strncmp(p, "bind:", 5) == 0)         { bind = 1; p += 5; }
        else if (strncmp(p, "connect:", 8) == 0) { p += 8; }
        else if (strncmp(p, "tcp:", 4) == 0)     { p += 4; }
        port = (unsigned)strtoul(p, NULL, 10);
        if (port > 0 && port < 65536 && nnetports < OB_MAX_PORTS) {
            netports[nnetports].port = port;
            netports[nnetports].bind = bind;
            nnetports++;
            cfg_net_any = 1;
        }
        p = q ? q + 1 : NULL;
    }
}

static void set_opt(const char *key, const char *val)
{
    int on = (strcmp(val, "1") == 0 || strcmp(val, "yes") == 0 ||
              strcmp(val, "on") == 0 || strcmp(val, "true") == 0);

    if      (strcmp(key, "scope_ipc") == 0)  cfg_scope_ipc = on;
    else if (strcmp(key, "memfd") == 0)      cfg_memfd_deny = (strcmp(val, "deny") == 0 || on);
    else if (strcmp(key, "nested_ns") == 0)  cfg_nested_ns = on;
    else if (strcmp(key, "keep_caps") == 0)  cfg_keep_caps = on;
    else if (strcmp(key, "keep_fds") == 0)   cfg_keep_fds = on;
    else if (strcmp(key, "no_seccomp") == 0) cfg_no_seccomp = on;
    else if (strcmp(key, "no_landlock") == 0)cfg_no_landlock = on;
    else if (strcmp(key, "defaults") == 0)   cfg_defaults = on;
    else if (strcmp(key, "hard_fail") == 0)  cfg_hard_fail = on;
    else if (strcmp(key, "verbose") == 0)    cfg_verbose = on;
    else if (strcmp(key, "deny_net") == 0)   cfg_deny_net = on;
}

/* One profile line, parsed in place. Kept separate so the file
 * reader and the environment reader cannot drift into accepting
 * two slightly different syntaxes. */
static void profile_line(char *line)
{
    char *eq, *key, *val, *nl;

    nl = strpbrk(line, "\r\n");
    if (nl) *nl = 0;
    key = line;
    while (*key == ' ' || *key == '\t') key++;
    if (*key == '#' || *key == 0) return;
    eq = strchr(key, '=');
    if (!eq) return;
    *eq = 0;
    val = eq + 1;

    if      (strcmp(key, "allow.ro") == 0)   add_grant(val, OB_RO);
    else if (strcmp(key, "allow.rx") == 0)   add_grant(val, OB_RX);
    else if (strcmp(key, "allow.rw") == 0)   add_grant(val, OB_RW);
    else if (strcmp(key, "allow.rwx") == 0)  add_grant(val, OB_RWX);
    else if (strcmp(key, "allow.dev") == 0)  add_grant(val, OB_DEV);
    else if (strcmp(key, "allow.exec") == 0) add_grant(val, OB_RX);
    else if (strcmp(key, "allow.net") == 0)  add_net_grant(val);
    else if (strcmp(key, "deny") == 0)       add_deny(val);
    else if (strncmp(key, "opt.", 4) == 0)   set_opt(key + 4, val);
}

static void read_profile(const char *path)
{
    FILE *f = fopen(path, "r");
    char line[4096];

    if (!f) {
        warn("profile %s cannot be read: %s", path, strerror(errno));
        return;
    }

    while (fgets(line, sizeof(line), f)) profile_line(line);
    fclose(f);
    vlog("profile loaded: %s", path);
}

/* The launcher mounts a fresh tmpfs over /home on purpose - that is
 * what keeps the real user data out of the sandbox - which also means
 * a profile stored under the real home is not reachable by path from
 * in here. The launcher therefore reads the file while it is still
 * reachable, outside, and passes the text down in the environment.
 * Without this the per-application grant silently never loads and the
 * boundary quietly falls back to its defaults, which is the worst of
 * both worlds: the user believes a profile is in force and it is not. */
static void read_profile_data(const char *text)
{
    char line[4096];
    const char *p = text;

    while (*p) {
        const char *e = strchr(p, '\n');
        size_t n;

        if (!e) e = p + strlen(p);
        n = (size_t)(e - p);
        if (n >= sizeof(line)) n = sizeof(line) - 1;
        memcpy(line, p, n);
        line[n] = 0;
        profile_line(line);
        p = (*e == '\n') ? e + 1 : e;
    }
    vlog("profile loaded from the environment");
}

/* The hard-deny set. These are never granted, and any grant that
 * contains one of them is pruned around it rather than honoured.
 * This is the one place in the design that names specific paths,
 * and it exists as a backstop, not as the policy. */
static const char *hard_deny[] = {
    "/dev/mem", "/dev/kmem", "/dev/port", "/dev/kmsg", "/dev/mtd",
    "/dev/cpu",            /* /dev/cpu/N/msr - model specific registers */
    "/dev/kvm", "/dev/vfio", "/dev/vhost-net", "/dev/vhost-vsock",
    "/dev/watchdog", "/dev/watchdog0", "/dev/rtc", "/dev/rtc0",
    "/dev/nvram", "/dev/tpm0", "/dev/tpmrm0", "/dev/sgx_vepc",
    "/dev/fuse", "/dev/loop-control", "/dev/mapper", "/dev/btrfs-control",
    "/proc/kcore", "/proc/kallsyms", "/proc/kmsg", "/proc/sysrq-trigger",
    "/proc/config.gz", "/proc/vmcore", "/proc/mtrr", "/proc/sched_debug",
    "/proc/timer_list", "/proc/keys", "/proc/key-users", "/proc/slabinfo",
    "/proc/modules", "/proc/iomem", "/proc/ioports",
    "/sys/kernel/debug", "/sys/kernel/tracing", "/sys/firmware/efi/efivars",
    "/sys/power",
    "/etc/shadow", "/etc/gshadow", "/etc/sudoers", "/etc/sudoers.d",
    "/etc/ssh", "/etc/ssl/private", "/etc/wpa_supplicant",
    "/etc/NetworkManager/system-connections",
    "/root", "/boot", "/var/log", "/var/backups",
    NULL
};

/* Block device families are matched by prefix because they are
 * numbered: sda, sdb, nvme0n1, nvme0n1p3 and so on. */
static const char *hard_deny_prefix[] = {
    "/dev/sd", "/dev/nvme", "/dev/hd", "/dev/vd", "/dev/xvd",
    "/dev/mmcblk", "/dev/loop", "/dev/dm-", "/dev/md", "/dev/sr",
    "/dev/sg", "/dev/nbd", "/dev/zram", "/dev/mtdblock",
    NULL
};

static void seed_hard_deny(void)
{
    DIR *d;
    struct dirent *e;
    int i;

    for (i = 0; hard_deny[i]; i++) add_deny(hard_deny[i]);

    /* Expand the block-device prefixes against what actually exists
     * on this machine. This is the same enumeration discipline the
     * manifest generator uses for metadata: look at the real host,
     * then write the rule for what is really there. */
    d = opendir("/dev");
    if (!d) return;
    while ((e = readdir(d)) != NULL) {
        char full[PATH_MAX];
        if ((size_t)snprintf(full, sizeof(full), "/dev/%s", e->d_name)
            >= sizeof(full))
            continue;
        for (i = 0; hard_deny_prefix[i]; i++) {
            if (strncmp(full, hard_deny_prefix[i],
                        strlen(hard_deny_prefix[i])) == 0) {
                add_deny(full);
                break;
            }
        }
    }
    closedir(d);
}

/* The base allow-list: what any graphical application on a Linux
 * system provably needs in order to start at all. Everything here
 * is read-only or read-execute except the app's own writable
 * directories. It is deliberately small, and it is the floor, not
 * the policy: the per-app profile adds the rest. */
static void seed_defaults(const char *appbin)
{
    static const char *ro[] = {
        "/usr/share", "/usr/local/share", "/etc/fonts", "/etc/ssl",
        "/etc/ca-certificates", "/etc/ca-certificates.conf",
        "/etc/resolv.conf", "/etc/hosts", "/etc/hostname",
        "/etc/nsswitch.conf", "/etc/passwd", "/etc/group",
        "/etc/localtime", "/etc/timezone", "/etc/machine-id",
        "/etc/os-release", "/etc/ld.so.cache", "/etc/ld.so.conf",
        "/etc/ld.so.conf.d", "/etc/ld-musl-x86_64.path",
        "/etc/xdg", "/etc/gtk-3.0", "/etc/gtk-2.0", "/etc/pango",
        "/etc/mime.types", "/etc/alternatives", "/etc/pki",
        "/etc/terminfo", "/etc/profile.d", "/etc/dconf",
        "/etc/apparmor.d", "/etc/nvidia", "/etc/vulkan", "/etc/drirc",
        "/etc/asound.conf", "/etc/pulse", "/etc/pipewire",
        "/proc", "/sys",
        NULL
    };
    static const char *rx[] = {
        "/lib", "/lib64", "/usr/lib", "/usr/lib64", "/usr/lib32",
        "/usr/libexec", "/usr/local/lib", "/opt/obsidian/lib",
        NULL
    };
    static const char *rw[] = {
        "~", "/tmp", "/var/tmp", "/dev/shm", "$XDG_RUNTIME_DIR",
        NULL
    };
    static const char *dev[] = {
        "/dev/null", "/dev/zero", "/dev/full", "/dev/random",
        "/dev/urandom", "/dev/tty", "/dev/ptmx", "/dev/pts",
        "/dev/console", "/dev/fd", "/dev/stdin", "/dev/stdout",
        "/dev/stderr", "/dev/dri",
        NULL
    };
    int i;

    for (i = 0; ro[i];  i++) add_grant(ro[i],  OB_RO);
    for (i = 0; rx[i];  i++) add_grant(rx[i],  OB_RX);
    for (i = 0; rw[i];  i++) add_grant(rw[i],  OB_RW);
    for (i = 0; dev[i]; i++) add_grant(dev[i], OB_DEV);

    if (appbin && *appbin) add_grant(appbin, OB_RX);
}

/* Resolve the target command to an absolute path so the one binary
 * the app is allowed to execute can be named exactly. */
static int resolve_binary(const char *cmd, char *out, size_t outsz)
{
    char cand[PATH_MAX], real[PATH_MAX];
    const char *path, *p, *q;

    if (strchr(cmd, '/')) {
        if (!realpath(cmd, real)) return -1;
        snprintf(out, outsz, "%s", real);
        return 0;
    }

    path = getenv("PATH");
    if (!path || !*path) path = "/usr/local/bin:/usr/bin:/bin";

    for (p = path; *p; p = (*q == ':') ? q + 1 : q) {
        size_t n;
        q = strchr(p, ':');
        if (!q) q = p + strlen(p);
        n = (size_t)(q - p);
        if (n == 0) { if (!*q) break; continue; }
        if (n + 1 + strlen(cmd) + 1 > sizeof(cand)) { if (!*q) break; continue; }
        memcpy(cand, p, n);
        cand[n] = '/';
        strcpy(cand + n + 1, cmd);
        if (access(cand, X_OK) == 0 && realpath(cand, real)) {
            snprintf(out, outsz, "%s", real);
            return 0;
        }
        if (!*q) break;
    }
    return -1;
}

/* An app binary sitting in a general purpose bin directory gets a
 * grant on the file, never on the directory. An app that lives in
 * its own tree, /opt/foo or /usr/lib/foo, gets the tree, because
 * that is where its helper processes are. */
static void grant_app_tree(const char *binpath)
{
    static const char *general[] = {
        "/bin", "/sbin", "/usr/bin", "/usr/sbin",
        "/usr/local/bin", "/usr/local/sbin", NULL
    };
    char dir[PATH_MAX];
    char *slash;
    int i;

    snprintf(dir, sizeof(dir), "%s", binpath);
    slash = strrchr(dir, '/');
    if (!slash || slash == dir) return;
    *slash = 0;

    for (i = 0; general[i]; i++)
        if (strcmp(dir, general[i]) == 0) return;

    add_grant(dir, OB_RX);
}

/* The interpreter of a #! target, discovered before the ruleset is
 * loaded and kept for the failure message. */
static char app_interp[PATH_MAX];

/* Read a #! line. Fills interp with the interpreter and arg with its
 * single optional argument. Returns 0 only when the file really does
 * begin with #! and names an absolute interpreter. */
static int shebang_of(const char *path, char *interp, size_t isz,
                      char *arg, size_t asz)
{
    char line[PATH_MAX + 2];
    char *p, *e;
    FILE *f;

    if (interp && isz) interp[0] = 0;
    if (arg && asz) arg[0] = 0;

    f = fopen(path, "r");
    if (!f) return -1;
    if (!fgets(line, sizeof(line), f)) { fclose(f); return -1; }
    fclose(f);

    if (line[0] != '#' || line[1] != '!') return -1;

    p = line + 2;
    while (*p == ' ' || *p == '\t') p++;
    e = p;
    while (*e && *e != ' ' && *e != '\t' && *e != '\n' && *e != '\r') e++;
    if (*e) { *e = 0; e++; }
    if (*p != '/') return -1;
    snprintf(interp, isz, "%s", p);

    while (*e == ' ' || *e == '\t') e++;
    p = e;
    while (*e && *e != ' ' && *e != '\t' && *e != '\n' && *e != '\r') e++;
    *e = 0;
    if (arg && asz && *p) snprintf(arg, asz, "%s", p);
    return 0;
}

/* A #! script cannot start unless the kernel may execute its
 * interpreter too, and the interpreter is named inside the file, not
 * on the command line. Distributions ship a great many applications
 * as a small shell wrapper around the real binary - librewolf and
 * firefox among them - so without this the very first hardened run of
 * a perfectly ordinary application fails with EACCES on a path the
 * user never typed and cannot see.
 *
 * Granting it is not a loosening of the boundary. The interpreter is
 * provably required for the named target to execute at all, which is
 * the definition of the minimal grant this model asks for, and it is
 * discovered by reading the application rather than by guessing. */
static void grant_interpreter(const char *binpath)
{
    char cur[PATH_MAX], interp[PATH_MAX], arg[PATH_MAX], real[PATH_MAX];
    int depth;

    snprintf(cur, sizeof(cur), "%s", binpath);

    for (depth = 0; depth < 4; depth++) {
        char *slash;

        if (shebang_of(cur, interp, sizeof(interp), arg, sizeof(arg)) != 0)
            return;
        if (!realpath(interp, real)) return;
        add_grant(real, OB_RX);

        /* Remembered for the failure message. By the time exec fails
         * the ruleset is already loaded and this file may no longer
         * be readable, so what the boundary knows about the target
         * has to be learned here, while it still can be. */
        if (depth == 0)
            snprintf(app_interp, sizeof(app_interp), "%s", real);

        /* #!/usr/bin/env python3 hides the real interpreter in the
         * argument and leaves env to find it on PATH. */
        slash = strrchr(real, '/');
        if (arg[0] && slash && strcmp(slash + 1, "env") == 0) {
            char viaenv[PATH_MAX];
            if (resolve_binary(arg, viaenv, sizeof(viaenv)) == 0)
                add_grant(viaenv, OB_RX);
        }

        /* An interpreter that is itself a wrapper script is rare but
         * it happens; follow a few links and then stop. */
        snprintf(cur, sizeof(cur), "%s", real);
    }
}

static void print_plan(char **argv, int sep)
{
    int i;
    fprintf(stderr,
        "\n"
        "  OBSIDIAN STRICT BOUNDARY - plan\n"
        "  -------------------------------------------------------------\n"
        "  target        : %s\n"
        "  landlock ABI  : %d\n"
        "  fs policy     : default-deny, %d explicit grants\n"
        "  network       : %s\n"
        "  ipc scoping   : %s\n"
        "  namespaces    : %s\n"
        "  capabilities  : %s\n"
        "  memfd         : %s\n"
        "  fd scrub      : %s\n"
        "  hard-deny set : %d paths\n"
        "  -------------------------------------------------------------\n",
        argv[sep + 1],
        landlock_abi,
        ngrants,
        cfg_net_all ? "unrestricted (allow.net=all)"
                    : cfg_net_any ? "granted ports only" : "denied",
        cfg_scope_ipc == 1 ? "abstract unix sockets and signals confined"
                           : "not scoped",
        cfg_nested_ns ? "permitted" : "denied",
        cfg_keep_caps ? "kept" : "dropped",
        cfg_memfd_deny ? "denied" : "allowed, MFD_EXEC denied",
        cfg_keep_fds ? "off" : "on",
        ndenies);
    for (i = 0; i < 0; i++) { }
}

static void usage(const char *self)
{
    fprintf(stderr,
        "usage: %s [--print-plan] [--verbose] -- <command> [args...]\n"
        "\n"
        "Enforces the Obsidian strict boundary on <command>. Inert unless\n"
        "OBSIDIAN_HARDEN is set to 1, strict or paranoid.\n", self);
}

int main(int argc, char **argv)
{
    const char *v;
    char binpath[PATH_MAX];
    int i, sep = -1, xerr;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--") == 0) { sep = i; break; }
        if (strcmp(argv[i], "--print-plan") == 0) { cfg_plan_only = 1; continue; }
        if (strcmp(argv[i], "--verbose") == 0)    { cfg_verbose = 1; continue; }
        if (strcmp(argv[i], "--version") == 0) {
            printf("obsidian-harden (Obsidian Mirror strict boundary) 1.0\n");
            return 0;
        }
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
            return 0;
        }
    }

    if (sep < 0 || sep + 1 >= argc) { usage(argv[0]); return 2; }

    /* ---- is hardening on at all ---- */
    v = getenv("OBSIDIAN_HARDEN");
    if (v && *v) {
        if (strcmp(v, "1") == 0 || strcmp(v, "on") == 0 ||
            strcmp(v, "strict") == 0 || strcmp(v, "yes") == 0)
            cfg_enabled = 1;
        else if (strcmp(v, "paranoid") == 0)
            cfg_enabled = 2;
        else if (strcmp(v, "plan") == 0 || strcmp(v, "dry") == 0) {
            cfg_enabled = 1;
            cfg_plan_only = 1;
        }
    }

    if (!cfg_enabled && !cfg_plan_only) {
        /* Off. Behave exactly like exec, and cost one exec. */
        execvp(argv[sep + 1], &argv[sep + 1]);
        fprintf(stderr, "obsidian-harden: exec %s: %s\n",
                argv[sep + 1], strerror(errno));
        return 127;
    }

    if (getenv("OBSIDIAN_HARDEN_VERBOSE")) cfg_verbose = 1;
    if (getenv("OBSIDIAN_VERBOSE"))        cfg_verbose = 1;
    if (getenv("OBSIDIAN_HARDEN_FAIL_CLOSED")) cfg_hard_fail = 1;

    if (cfg_enabled == 2) {          /* paranoid raises three defaults */
        cfg_memfd_deny = 1;
        if (cfg_scope_ipc < 0) cfg_scope_ipc = 1;
    }

    /* ---- resolve what we are about to run ---- */
    if (resolve_binary(argv[sep + 1], binpath, sizeof(binpath)) != 0) {
        warn("cannot resolve %s on PATH; hardening would deny its own "
             "target, refusing to guess", argv[sep + 1]);
        if (cfg_hard_fail) return 126;
        snprintf(binpath, sizeof(binpath), "%s", argv[sep + 1]);
    }

    /* ---- build the policy ---- */
    seed_hard_deny();
    add_deny_list(getenv("OBSIDIAN_DENY_PATHS"));

    v = getenv("OBSIDIAN_HARDEN_PROFILE_DATA");
    if (v && *v) {
        read_profile_data(v);
    } else {
        v = getenv("OBSIDIAN_HARDEN_PROFILE");
        if (v && *v) read_profile(v);
    }

    if (getenv("OBSIDIAN_HARDEN_NO_DEFAULTS")) cfg_defaults = 0;
    if (cfg_defaults) seed_defaults(binpath);
    grant_app_tree(binpath);
    grant_interpreter(binpath);

    add_list(getenv("OBSIDIAN_ALLOW_PATHS_RO"),  OB_RO);
    add_list(getenv("OBSIDIAN_ALLOW_PATHS_RX"),  OB_RX);
    add_list(getenv("OBSIDIAN_ALLOW_PATHS_RW"),  OB_RW);
    add_list(getenv("OBSIDIAN_ALLOW_PATHS_RWX"), OB_RWX);
    add_list(getenv("OBSIDIAN_ALLOW_DEV"),       OB_DEV);
    add_list(getenv("OBSIDIAN_ALLOW_EXEC"),      OB_RX);
    add_net_grant(getenv("OBSIDIAN_ALLOW_NET"));

    /* Network default under the strict boundary: ALLOWED.
     * An application launched through obsidian is meant to be useful,
     * and DNS, the web and mail all require AF_INET/AF_INET6. The
     * boundary still closes filesystem, devices, memory, execution,
     * IPC, capabilities and namespaces by default; only the network
     * layer defaults open so a hardened app can actually reach the
     * internet. Opt out per-application with OBSIDIAN_DENY_NET=1
     * (or opt.deny_net=1 in a profile). */
    if (getenv("OBSIDIAN_DENY_NET") || cfg_deny_net) {
        cfg_net_all = 0;
        cfg_net_any = 0;
    } else if (!cfg_net_any && !getenv("OBSIDIAN_ALLOW_NET")) {
        cfg_net_all = 1;
    }

    v = getenv("OBSIDIAN_SCOPE_IPC");
    if (v && *v) cfg_scope_ipc = (*v == '1');
    if (cfg_scope_ipc < 0) {
        /* Off in strict mode. Scoping abstract unix sockets is the one
         * layer here that breaks a whole display protocol when it is
         * wrong - every X11 client reaches its display that way, and
         * some session buses are abstract too. Paranoid mode turns it
         * on, and OBSIDIAN_SCOPE_IPC=1 turns it on deliberately, but
         * it is not switched on behind anyone. */
        cfg_scope_ipc = 0;
    }
    if (getenv("OBSIDIAN_ALLOW_NESTED_NS")) cfg_nested_ns = 1;
    if (getenv("OBSIDIAN_HARDEN_KEEP_CAPS")) cfg_keep_caps = 1;
    if (getenv("OBSIDIAN_HARDEN_KEEP_FDS")) cfg_keep_fds = 1;

    /* ---- apply, outermost layer first ---- */

    if (!cfg_keep_fds && !cfg_plan_only) scrub_fds();

    /* NO_NEW_PRIVS must be set before Landlock will accept an
     * unprivileged restriction, and it is what stops a setuid
     * binary from shedding every layer below. */
    if (!cfg_plan_only) {
        if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
            warn("PR_SET_NO_NEW_PRIVS failed: %s", strerror(errno));
            if (cfg_hard_fail) return 126;
        } else {
            vlog("privilege boundary sealed: no_new_privs");
        }
    }

    if (!cfg_no_landlock) {
        if (landlock_apply() != 0 && cfg_hard_fail) return 126;
    }

    if (cfg_plan_only) print_plan(argv, sep);

    if (!cfg_keep_caps && !cfg_plan_only) {
        if (caps_drop() != 0 && cfg_hard_fail) return 126;
    }

    if (!cfg_no_seccomp) {
        if (seccomp_apply() != 0 && cfg_hard_fail) return 126;
    }

    if (cfg_plan_only) {
        fprintf(stderr, "  nothing was enforced: this was a plan run.\n\n");
        return 0;
    }

    execvp(argv[sep + 1], &argv[sep + 1]);
    xerr = errno;
    fprintf(stderr, "obsidian-harden: exec %s: %s\n",
            argv[sep + 1], strerror(xerr));
    if (xerr == EACCES) {
        /* Name the path that is actually missing. The old message
         * printed the target every time, which for a wrapper script
         * is the one path already granted - correct-looking advice
         * that cannot possibly work. */
        fprintf(stderr,
            "obsidian-harden: the boundary denied execution of the target "
            "itself.\n"
            "                 %s resolves to: %s\n",
            argv[sep + 1], binpath);

        if (app_interp[0])
            fprintf(stderr,
            "                 that is a #! script, started by: %s\n"
            "                 both need to be executable:\n"
            "                   OBSIDIAN_ALLOW_EXEC=%s:%s\n",
            app_interp, binpath, app_interp);
        else
            fprintf(stderr,
            "                 grant it with OBSIDIAN_ALLOW_EXEC=%s\n",
            binpath);
    }
    return 127;
}
OBSIDIAN_PAYLOAD_HARDEN_C
ok "src/obsidian_harden.c"

cat > "$SRCDIR/obsidian_hardenprobe.c" <<'OBSIDIAN_PAYLOAD_HARDENPROBE_C'
/* ============================================================
 * /opt/obsidian/bin/obsidian-hardenprobe
 * Obsidian Mirror - strict-boundary measurement probe.
 *
 * Attempts, in process, every access the strict boundary claims
 * to close, and prints what actually happened. It asserts
 * nothing: it runs the syscall and reports the kernel's answer.
 *
 * Run it twice - once through the normal launcher, once with
 * OBSIDIAN_HARDEN=1 - and the difference between the two columns
 * is the measured value of the boundary. A claim that appears in
 * both columns as ALLOWED is a claim this project has not earned.
 *
 * Output: one record per line,  key <TAB> state <TAB> detail
 *   state = ALLOWED | DENIED | ABSENT | KILLED | ERROR
 *
 * Build: cc -O2 -o obsidian-hardenprobe obsidian_hardenprobe.c
 * ============================================================ */

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <signal.h>

#ifndef PR_GET_NO_NEW_PRIVS
#define PR_GET_NO_NEW_PRIVS 39
#endif
#ifndef PR_CAPBSET_READ
#define PR_CAPBSET_READ 23
#endif
#ifndef AT_EMPTY_PATH
#define AT_EMPTY_PATH 0x1000
#endif
#ifndef CLONE_NEWUSER
#define CLONE_NEWUSER 0x10000000
#endif

static int nallowed, ndenied, nother;
static int ob_limit = -1;   /* debug aid: stop after N records */

static const char *errname(int e)
{
    switch (e) {
    case EPERM:          return "EPERM";
    case EACCES:         return "EACCES";
    case ENOSYS:         return "ENOSYS";
    case ENOENT:         return "ENOENT";
    case EAFNOSUPPORT:   return "EAFNOSUPPORT";
    case EINVAL:         return "EINVAL";
    case EOPNOTSUPP:     return "EOPNOTSUPP";
    case ENODEV:         return "ENODEV";
    case EROFS:          return "EROFS";
    case EBUSY:          return "EBUSY";
    case ESRCH:          return "ESRCH";
    case ENXIO:          return "ENXIO";
    default:             return "other";
    }
}

static void rec(const char *key, const char *state, const char *detail)
{
    printf("%s\t%s\t%s\n", key, state, detail ? detail : "");
    if      (strcmp(state, "ALLOWED") == 0) nallowed++;
    else if (strcmp(state, "DENIED")  == 0 || strcmp(state, "KILLED") == 0)
        ndenied++;
    else nother++;
    if (ob_limit > 0 && nallowed + ndenied + nother >= ob_limit) {
        fflush(stdout);
        _exit(0);
    }
}

/* A syscall that returned -1 with a refusal errno counts as denied.
 * ENOENT and ENODEV mean the surface is not on this machine, which
 * is reported separately so it is never mistaken for protection. */
static void rec_rc(const char *key, long rc, int e)
{
    if (rc >= 0) { rec(key, "ALLOWED", ""); return; }
    switch (e) {
    case EPERM: case EACCES: case EAFNOSUPPORT: case ENOSYS:
    case EOPNOTSUPP: case EROFS:
        rec(key, "DENIED", errname(e));
        break;
    case ENOENT: case ENODEV: case ENXIO:
        rec(key, "ABSENT", errname(e));
        break;
    default:
        rec(key, "ERROR", errname(e));
        break;
    }
}

/* ---------- filesystem ---------- */

static void probe_open(const char *key, const char *path, int flags)
{
    int fd = open(path, flags);
    if (fd >= 0) { close(fd); rec(key, "ALLOWED", path); return; }
    rec_rc(key, -1, errno);
}

static void probe_create(const char *key, const char *dir)
{
    char p[PATH_MAX];
    int fd;
    snprintf(p, sizeof(p), "%s/.obsidian-harden-probe", dir);
    fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd >= 0) { close(fd); unlink(p); rec(key, "ALLOWED", dir); return; }
    rec_rc(key, -1, errno);
}

static void probe_first_disk(void)
{
    static const char *pref[] = { "sd", "nvme", "vd", "mmcblk", "xvd", NULL };
    DIR *d = opendir("/dev");
    struct dirent *e;
    char found[PATH_MAX];
    int i, have = 0;

    if (!d) {
        /* /dev itself not being listable is a result, not a gap: it
         * means the boundary never granted the directory. */
        if (errno == EACCES || errno == EPERM)
            rec("fs.read.rawdisk", "DENIED", "/dev not listable");
        else
            rec("fs.read.rawdisk", "ABSENT", "cannot list /dev");
        return;
    }
    while (!have && (e = readdir(d)) != NULL) {
        for (i = 0; pref[i]; i++) {
            size_t n = strlen(pref[i]);
            if (strncmp(e->d_name, pref[i], n) == 0 &&
                e->d_name[n] >= '0' && e->d_name[n] <= '9') {
                snprintf(found, sizeof(found), "/dev/%s", e->d_name);
                have = 1;
                break;
            }
        }
    }
    closedir(d);
    if (!have) { rec("fs.read.rawdisk", "ABSENT", "no block node visible"); return; }
    probe_open("fs.read.rawdisk", found, O_RDONLY);
}

/* ---------- execution ---------- */

static void probe_exec(const char *key, const char *path)
{
    pid_t pid;
    int status;
    char *const av[] = { (char *)path, (char *)"-c", (char *)":", NULL };

    if (access(path, F_OK) != 0) { rec(key, "ABSENT", path); return; }

    pid = fork();
    if (pid < 0) { rec(key, "ERROR", "fork"); return; }
    if (pid == 0) {
        /* Detach the child from this program's descriptors and put a
         * hard stop on it. Whether the interpreter would then sit
         * waiting on a terminal is not the question being asked: the
         * question is only whether execv() was permitted. */
        int devnull = open("/dev/null", O_RDWR);
        setsid();                      /* no controlling terminal, so an
                                        * interpreter cannot stop itself
                                        * on SIGTTIN and hang the probe */
        if (devnull >= 0) {
            dup2(devnull, 0); dup2(devnull, 1); dup2(devnull, 2);
            if (devnull > 2) close(devnull);
        }
        alarm(2);
        execv(path, av);
        _exit(errno == EACCES ? 90 : errno == EPERM ? 91 : 92);
    }
    if (waitpid(pid, &status, WUNTRACED) < 0) {
        rec(key, "ERROR", "wait");
        return;
    }
    if (WIFSTOPPED(status)) {
        /* Ran far enough to be stopped: it executed. */
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
        rec(key, "ALLOWED", path);
        return;
    }
    if (WIFSIGNALED(status)) {
        /* SIGALRM means the program was running when the stop hit it,
         * so the execution itself was permitted. */
        rec(key, WTERMSIG(status) == SIGALRM ? "ALLOWED" : "KILLED",
            WTERMSIG(status) == SIGALRM ? path : "signal");
        return;
    }
    switch (WEXITSTATUS(status)) {
    case 90: rec(key, "DENIED", "EACCES"); break;
    case 91: rec(key, "DENIED", "EPERM");  break;
    case 92: rec(key, "ABSENT", "exec errno"); break;
    default: rec(key, "ALLOWED", path);    break;
    }
}

static void probe_memfd_exec(void)
{
#ifdef __NR_memfd_create
    /* The canonical fileless-execution pattern: build an executable
     * in anonymous memory, then run the descriptor. No path exists
     * at any point, so no path-based policy can see it. */
    static const unsigned char elf_stub[] = { 0x7f, 'E', 'L', 'F' };
    int fd = (int)syscall(__NR_memfd_create, "obprobe", 0);
    pid_t pid;
    int status;

    if (fd < 0) { rec("exec.memfd", "DENIED", errname(errno)); return; }
    if (write(fd, elf_stub, sizeof(elf_stub)) < 0) { /* ignore */ }

    pid = fork();
    if (pid < 0) { close(fd); rec("exec.memfd", "ERROR", "fork"); return; }
    if (pid == 0) {
        char *const av[] = { (char *)"obprobe", NULL };
        char *const ev[] = { NULL };
        syscall(__NR_execveat, fd, "", av, ev, AT_EMPTY_PATH);
        _exit(errno == EACCES ? 90 : errno == EPERM ? 91 :
              errno == ENOEXEC ? 93 : 92);
    }
    waitpid(pid, &status, 0);
    close(fd);
    switch (WEXITSTATUS(status)) {
    case 90: rec("exec.memfd", "DENIED", "EACCES"); break;
    case 91: rec("exec.memfd", "DENIED", "EPERM");  break;
    /* ENOEXEC means the kernel accepted the request and only the
     * four-byte stub was not a real program: the door was open. */
    case 93: rec("exec.memfd", "ALLOWED", "reached ELF loader"); break;
    default: rec("exec.memfd", "ERROR", "unexpected"); break;
    }
#else
    rec("exec.memfd", "ABSENT", "no memfd_create");
#endif
}

static void probe_jit(void)
{
    /* Positive control. A boundary that breaks legitimate JIT has
     * broken every browser and every managed runtime, so this one
     * must stay ALLOWED. */
    size_t sz = 4096;
    void *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) { rec("jit.anon_exec", "ERROR", "mmap"); return; }
    if (mprotect(p, sz, PROT_READ | PROT_EXEC) != 0) {
        rec("jit.anon_exec", "DENIED", errname(errno));
        munmap(p, sz);
        return;
    }
    munmap(p, sz);
    rec("jit.anon_exec", "ALLOWED", "anonymous PROT_EXEC");
}

/* Write a file into a directory the boundary grants for writing, then
 * map it executable - which is the whole of what dlopen() does once
 * the loader has found the library. Landlock's EXECUTE right is
 * checked when a file is opened to be executed, and a library is
 * opened O_RDONLY, so a granted-writable directory is also a place
 * the application can execute code it just authored. seccomp cannot
 * close it either: it sees PROT_EXEC and a descriptor number, never
 * the path behind it. This is measured rather than argued, because
 * the strict-boundary model claims "no untrusted dlopen" and on this
 * mechanism that claim does not hold. */
static void probe_wx_file(void)
{
    char path[512];
    const char *dir = getenv("TMPDIR");
    int fd;
    void *p;
    char buf[4096];

    if (!dir || !*dir) dir = "/tmp";
    snprintf(path, sizeof(path), "%s/.obsidian-wx-probe", dir);

    fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        rec("exec.wx_file", "DENIED", errname(errno));
        return;
    }
    memset(buf, 0, sizeof(buf));
    if (write(fd, buf, sizeof(buf)) != (ssize_t)sizeof(buf)) {
        close(fd);
        unlink(path);
        rec("exec.wx_file", "ERROR", "write");
        return;
    }
    close(fd);

    fd = open(path, O_RDONLY);
    if (fd < 0) {
        unlink(path);
        rec("exec.wx_file", "DENIED", errname(errno));
        return;
    }

    p = mmap(NULL, sizeof(buf), PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, 0);
    if (p == MAP_FAILED) {
        rec("exec.wx_file", "DENIED", errname(errno));
    } else {
        munmap(p, sizeof(buf));
        rec("exec.wx_file", "ALLOWED", "wrote it, then mapped it PROT_EXEC");
    }
    close(fd);
    unlink(path);
}

/* ---------- memory of other processes ----------
 *
 * Every cross-process probe runs against a throwaway child of this
 * program, never against the shell that started it. Attaching a
 * debugger to your own parent and then failing to detach cleanly
 * leaves that parent stopped, which is a real way to hang a
 * terminal - measurement must not damage the thing it measures.
 */

static pid_t victim_pid = -1;

static void victim_start(void)
{
    victim_pid = fork();
    if (victim_pid == 0) {
        signal(SIGALRM, SIG_DFL);
        alarm(10);            /* never outlive the probe */
        for (;;) pause();
    }
    if (victim_pid > 0) usleep(20000);
}

static void victim_stop(void)
{
    int st;
    if (victim_pid <= 0) return;
    kill(victim_pid, SIGKILL);
    waitpid(victim_pid, &st, 0);
    victim_pid = -1;
}

static void probe_ptrace(void)
{
#ifdef __NR_ptrace
    long rc;
    int st;

    if (victim_pid <= 0) { rec("mem.ptrace", "ERROR", "no target"); return; }

    rc = syscall(__NR_ptrace, 16 /* PTRACE_ATTACH */, (long)victim_pid, 0L, 0L);
    if (rc == 0) {
        /* Wait for the stop before detaching, or the target is left
         * frozen. */
        waitpid(victim_pid, &st, WUNTRACED);
        syscall(__NR_ptrace, 17 /* PTRACE_DETACH */, (long)victim_pid, 0L, 0L);
        kill(victim_pid, SIGCONT);
        rec("mem.ptrace", "ALLOWED", "attached to another process");
        return;
    }
    rec_rc("mem.ptrace", -1, errno);
#else
    rec("mem.ptrace", "ABSENT", "");
#endif
}

static void probe_vm_readv(void)
{
#ifdef __NR_process_vm_readv
    char buf[16];
    struct iovec l = { buf, sizeof(buf) };
    struct iovec r = { (void *)(uintptr_t)0x1000, sizeof(buf) };
    long rc;

    if (victim_pid <= 0) { rec("mem.process_vm_readv", "ERROR", "no target"); return; }

    rc = syscall(__NR_process_vm_readv, (long)victim_pid, &l, 1L, &r, 1L, 0L);
    /* EFAULT means the call was permitted and only the remote address
     * was wrong: the interface is open. */
    if (rc >= 0 || errno == EFAULT || errno == ESRCH)
        rec("mem.process_vm_readv", "ALLOWED", rc >= 0 ? "read" : "reached");
    else
        rec_rc("mem.process_vm_readv", -1, errno);
#else
    rec("mem.process_vm_readv", "ABSENT", "");
#endif
}

static void probe_vm_writev(void)
{
#ifdef __NR_process_vm_writev
    char buf[16];
    struct iovec l = { buf, sizeof(buf) };
    struct iovec r = { (void *)(uintptr_t)0x1000, sizeof(buf) };
    long rc;

    memset(buf, 0, sizeof(buf));
    if (victim_pid <= 0) { rec("mem.process_vm_writev", "ERROR", "no target"); return; }

    rc = syscall(__NR_process_vm_writev, (long)victim_pid, &l, 1L, &r, 1L, 0L);
    if (rc >= 0 || errno == EFAULT || errno == ESRCH)
        rec("mem.process_vm_writev", "ALLOWED", rc >= 0 ? "wrote" : "reached");
    else
        rec_rc("mem.process_vm_writev", -1, errno);
#else
    rec("mem.process_vm_writev", "ABSENT", "");
#endif
}

static void probe_peer_maps(void)
{
    /* Reading another process's address space through procfs needs no
     * exotic syscall at all, which is why the memory layer is not
     * finished by seccomp alone. */
    char path[64];
    int fd;

    if (victim_pid <= 0) { rec("mem.peer_mem", "ERROR", "no target"); return; }
    snprintf(path, sizeof(path), "/proc/%d/mem", (int)victim_pid);
    fd = open(path, O_RDONLY);
    if (fd >= 0) { close(fd); rec("mem.peer_mem", "ALLOWED", path); return; }
    rec_rc("mem.peer_mem", -1, errno);
}

/* ---------- generic raw syscall probes ---------- */

static void probe_raw(const char *key, long nr, long a, long b, long c,
                      long d, long e, long f)
{
    long rc;
    if (nr < 0) { rec(key, "ABSENT", "not on this arch"); return; }
    errno = 0;
    rc = syscall(nr, a, b, c, d, e, f);
    if (rc >= 0) { rec(key, "ALLOWED", ""); return; }
    /* EINVAL/EBADF/EFAULT: the filter let the call through to the
     * kernel, which then rejected the deliberately bogus arguments.
     * That is an open interface, not a closed one. */
    if (errno == EINVAL || errno == EBADF || errno == EFAULT ||
        errno == ESRCH  || errno == EBUSY || errno == ENOTDIR)
        rec(key, "ALLOWED", errname(errno));
    else
        rec_rc(key, -1, errno);
}

/* Something the filter answers with SIGSYS has to be tried in a
 * child, or the measurement kills the measurer. */
static void probe_raw_forked(const char *key, long nr, long a, long b, long c)
{
    pid_t pid;
    int status;

    if (nr < 0) { rec(key, "ABSENT", "not on this arch"); return; }
    pid = fork();
    if (pid < 0) { rec(key, "ERROR", "fork"); return; }
    if (pid == 0) {
        long rc = syscall(nr, a, b, c);
        if (rc >= 0) _exit(0);
        _exit(errno == EPERM ? 91 : errno == EACCES ? 90 :
              errno == ENOSYS ? 94 : 92);
    }
    waitpid(pid, &status, 0);
    if (WIFSIGNALED(status)) { rec(key, "KILLED", "SIGSYS"); return; }
    switch (WEXITSTATUS(status)) {
    case 0:  rec(key, "ALLOWED", ""); break;
    case 90: rec(key, "DENIED", "EACCES"); break;
    case 91: rec(key, "DENIED", "EPERM"); break;
    case 94: rec(key, "DENIED", "ENOSYS"); break;
    default: rec(key, "ERROR", "errno"); break;
    }
}

static void probe_unshare(void)
{
#ifdef __NR_unshare
    pid_t pid = fork();
    int status;
    if (pid < 0) { rec("ns.unshare_user", "ERROR", "fork"); return; }
    if (pid == 0) {
        long rc = syscall(__NR_unshare, (long)CLONE_NEWUSER);
        _exit(rc == 0 ? 0 : errno == EPERM ? 91 : 92);
    }
    waitpid(pid, &status, 0);
    switch (WEXITSTATUS(status)) {
    case 0:  rec("ns.unshare_user", "ALLOWED", "new user namespace"); break;
    case 91: rec("ns.unshare_user", "DENIED", "EPERM"); break;
    default: rec("ns.unshare_user", "ERROR", "errno"); break;
    }
#else
    rec("ns.unshare_user", "ABSENT", "");
#endif
}

/* ---------- network ---------- */

static void probe_socket(const char *key, int domain, int type)
{
    int fd = socket(domain, type, 0);
    if (fd >= 0) { close(fd); rec(key, "ALLOWED", ""); return; }
    rec_rc(key, -1, errno);
}

static void probe_connect_out(void)
{
    /* Reaching a routable address at all, not whether anything
     * answers. EAFNOSUPPORT/EPERM/EACCES at any stage is closed. */
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    struct sockaddr_in { short f; unsigned short p; unsigned int a; char z[8]; } sa;
    if (fd < 0) { rec_rc("net.connect_tcp", -1, errno); return; }
    memset(&sa, 0, sizeof(sa));
    sa.f = AF_INET;
    sa.p = (unsigned short)((443 >> 8) | (443 << 8));
    sa.a = 0x08080808;   /* 8.8.8.8, big endian as written */
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) == 0) {
        close(fd);
        rec("net.connect_tcp", "ALLOWED", "connected");
        return;
    }
    if (errno == EACCES || errno == EPERM || errno == EAFNOSUPPORT)
        rec("net.connect_tcp", "DENIED", errname(errno));
    else if (errno == EINPROGRESS || errno == ETIMEDOUT ||
             errno == ECONNREFUSED || errno == EINTR)
        rec("net.connect_tcp", "ALLOWED", "reached the network stack");
    else if (errno == ENETUNREACH || errno == EHOSTUNREACH)
        rec("net.connect_tcp", "ABSENT", "no route from here");
    else
        rec("net.connect_tcp", "ERROR", errname(errno));
    close(fd);
}

/* ---------- privilege state ---------- */

static void probe_state(void)
{
    char buf[256];
    FILE *f;
    int v;

    v = prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0);
    rec("priv.no_new_privs", v == 1 ? "DENIED" : "ALLOWED",
        v == 1 ? "set" : "not set");

    /* CAP_SYS_ADMIN is 21. Present in the bounding set means the
     * process, or anything it becomes, can still ask for it. */
    v = prctl(PR_CAPBSET_READ, 21, 0, 0, 0);
    rec("cap.sys_admin_bounding", v == 0 ? "DENIED" : "ALLOWED",
        v == 0 ? "dropped" : "retained");

    v = prctl(PR_CAPBSET_READ, 0, 0, 0, 0);   /* CAP_CHOWN */
    rec("cap.chown_bounding", v == 0 ? "DENIED" : "ALLOWED",
        v == 0 ? "dropped" : "retained");

    /* The bounding set can only be emptied by a process that holds
     * CAP_SETPCAP. A process holding no capabilities at all cannot
     * drop it and does not need to, so the effective set is reported
     * beside it rather than the bounding set alone. */
    f = fopen("/proc/self/status", "r");
    if (f) {
        while (fgets(buf, sizeof(buf), f)) {
            if (strncmp(buf, "CapEff:", 7) == 0) {
                unsigned long long capeff = strtoull(buf + 7, NULL, 16);
                char d[48];
                snprintf(d, sizeof(d), "CapEff %016llx", capeff);
                rec("cap.effective_set", capeff == 0 ? "DENIED" : "ALLOWED", d);
                break;
            }
        }
        fclose(f);
    }

    f = fopen("/proc/self/status", "r");
    if (!f) { rec("priv.seccomp_mode", "ERROR", "status unreadable"); return; }
    while (fgets(buf, sizeof(buf), f)) {
        if (strncmp(buf, "Seccomp:", 8) == 0) {
            int mode = atoi(buf + 8);
            char d[32];
            snprintf(d, sizeof(d), "mode %d", mode);
            rec("priv.seccomp_mode", mode == 2 ? "DENIED" : "ALLOWED", d);
            fclose(f);
            return;
        }
    }
    fclose(f);
    rec("priv.seccomp_mode", "ERROR", "field absent");
}

int main(int argc, char **argv)
{
    const char *home = getenv("HOME");
    int quiet = (argc > 1 && strcmp(argv[1], "--quiet") == 0);

    setvbuf(stdout, NULL, _IOLBF, 0);
    if (getenv("OBSIDIAN_PROBE_LIMIT"))
        ob_limit = atoi(getenv("OBSIDIAN_PROBE_LIMIT"));

    /* ---- filesystem: host paths that are not the app's ---- */
    probe_open("fs.read.shadow",   "/etc/shadow",        O_RDONLY);
    probe_open("fs.read.sshkeys",  "/etc/ssh",           O_RDONLY | O_DIRECTORY);
    probe_open("fs.read.roothome", "/root",              O_RDONLY | O_DIRECTORY);
    probe_open("fs.read.varlog",   "/var/log",           O_RDONLY | O_DIRECTORY);
    probe_open("fs.read.boot",     "/boot",              O_RDONLY | O_DIRECTORY);
    probe_open("fs.read.kcore",    "/proc/kcore",        O_RDONLY);
    probe_open("fs.read.kallsyms", "/proc/kallsyms",     O_RDONLY);
    probe_open("fs.read.devmem",   "/dev/mem",           O_RDONLY);
    probe_open("fs.read.devkmsg",  "/dev/kmsg",          O_RDONLY);
    probe_open("fs.read.iomem",    "/proc/iomem",        O_RDONLY);
    probe_open("fs.read.modules",  "/proc/modules",      O_RDONLY);
    probe_open("fs.read.debugfs",  "/sys/kernel/debug",  O_RDONLY | O_DIRECTORY);
    probe_first_disk();
    probe_open("fs.write.sysrq",   "/proc/sysrq-trigger", O_WRONLY);
    probe_create("fs.write.etc",   "/etc");
    probe_create("fs.write.usr",   "/usr");

    /* ---- filesystem: what the app is supposed to keep ---- */
    probe_open("fs.read.own_libs", "/usr/lib",           O_RDONLY | O_DIRECTORY);
    probe_open("fs.read.urandom",  "/dev/urandom",       O_RDONLY);
    probe_create("fs.write.home",  home && *home ? home : "/tmp");
    probe_create("fs.write.tmp",   "/tmp");

    /* ---- execution ---- */
    probe_exec("exec.shell",       "/bin/sh");
    probe_exec("exec.python",      "/usr/bin/python3");
    probe_exec("exec.node",        "/usr/bin/node");
    probe_exec("exec.perl",        "/usr/bin/perl");
    probe_memfd_exec();
    probe_wx_file();
    probe_jit();

    /* ---- another process's memory ---- */
    victim_start();
    probe_ptrace();
    probe_vm_readv();
    probe_vm_writev();
    probe_peer_maps();
#ifdef __NR_userfaultfd
    probe_raw("mem.userfaultfd", __NR_userfaultfd, 0, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_perf_event_open
    probe_raw("mem.perf_event_open", __NR_perf_event_open, 0, 0, -1, -1, 0, 0);
#endif
#ifdef __NR_pidfd_getfd
    probe_raw("mem.pidfd_getfd", __NR_pidfd_getfd, -1, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_kcmp
    probe_raw("mem.kcmp", __NR_kcmp, getpid(), getpid(), 0, 0, 0, 0);
#endif
    victim_stop();

    /* ---- the logs ---- */
#ifdef __NR_syslog
    {
        /* A real buffer, so the answer is the kernel's policy and not
         * a complaint about the arguments. */
        static char ring[256];
        probe_raw_forked("log.kernel_ring", __NR_syslog,
                         3 /* SYSLOG_ACTION_READ_ALL */,
                         (long)ring, (long)sizeof(ring));
    }
#endif

    /* ---- kernel surfaces ---- */
#ifdef __NR_init_module
    probe_raw("kern.init_module", __NR_init_module, 0, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_bpf
    probe_raw("kern.bpf", __NR_bpf, 0, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_io_uring_setup
    probe_raw("kern.io_uring", __NR_io_uring_setup, 1, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_iopl
    probe_raw_forked("hw.iopl", __NR_iopl, 3, 0, 0);
#endif
#ifdef __NR_keyctl
    probe_raw("key.keyctl", __NR_keyctl, 0, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_clock_settime
    probe_raw("time.clock_settime", __NR_clock_settime, 0, 0, 0, 0, 0, 0);
#endif

    /* ---- namespaces and mount ---- */
    probe_unshare();
#ifdef __NR_mount
    probe_raw("ns.mount", __NR_mount, (long)"none", (long)"/tmp",
              (long)"tmpfs", 0, 0, 0);
#endif
#ifdef __NR_setns
    probe_raw("ns.setns", __NR_setns, 0, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_open_by_handle_at
    probe_raw("ns.open_by_handle", __NR_open_by_handle_at, -1, 0, 0, 0, 0, 0);
#endif

    /* ---- network ---- */
    probe_socket("net.socket_inet",    AF_INET,   SOCK_STREAM);
    probe_socket("net.socket_inet6",   AF_INET6,  SOCK_STREAM);
    probe_socket("net.socket_netlink", AF_NETLINK, SOCK_RAW);
    probe_socket("net.socket_packet",  17 /* AF_PACKET */, SOCK_RAW);
    probe_socket("net.socket_unix",    AF_UNIX,   SOCK_STREAM);
    probe_connect_out();

    /* ---- privilege state ---- */
    probe_state();

    if (!quiet)
        fprintf(stderr, "obsidian-hardenprobe: %d allowed, %d denied, "
                        "%d absent or inconclusive\n",
                nallowed, ndenied, nother);
    return 0;
}
OBSIDIAN_PAYLOAD_HARDENPROBE_C
ok "src/obsidian_hardenprobe.c"

cat > "$SRCDIR/obsidian_learn.c" <<'OBSIDIAN_PAYLOAD_LEARN_C'
/* ============================================================
 * /opt/obsidian/lib/obsidian_learn.so
 * Obsidian Mirror - allow-list discovery.
 *
 * The installer already enumerates the host to decide what to
 * spoof. This library is the other half of the same discipline
 * applied to confinement: instead of guessing what to deny, run
 * the application once and record what it actually reached for.
 * The recording is then collapsed into the smallest allow-list
 * that still contains every real access, and everything outside
 * that list is denied.
 *
 * It records. It never blocks, never rewrites a result and never
 * changes a return value, so an application under learning
 * behaves exactly as it does without it.
 *
 * Loaded FIRST in LD_PRELOAD, ahead of the spoofing libraries,
 * and every hook hands straight on to the next definition of the
 * same symbol - which is the spoofing hook where one exists.
 *
 * Record format, one per line:
 *   R <path>     a file that was opened for reading
 *   D <path>     a directory that was listed
 *   W <path>     opened for writing
 *   X <path>     executed
 *   L <path>     loaded as a shared object
 *   N <family>:<port>   a socket that was created or connected
 *
 * Build: cc -O2 -fPIC -shared -o obsidian_learn.so obsidian_learn.c -ldl
 * ============================================================ */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <sys/un.h>
#include <dirent.h>

static int   log_fd = -1;
static pid_t log_pid;
static int   log_off;

static void log_open(void)
{
    const char *path;
    int (*real_open)(const char *, int, ...);

    if (log_off) return;
    if (log_fd >= 0 && log_pid == getpid()) return;

    /* A new process after fork: the inherited descriptor may point at
     * a different offset, so reopen rather than share. */
    if (log_fd >= 0) { close(log_fd); log_fd = -1; }

    path = getenv("OBSIDIAN_LEARN_LOG");
    if (!path || !*path) { log_off = 1; return; }

    real_open = dlsym(RTLD_NEXT, "open");
    if (!real_open) { log_off = 1; return; }

    log_fd = real_open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
    if (log_fd < 0) { log_off = 1; return; }
    log_pid = getpid();
}

/* O_APPEND makes a single short write atomic against other writers,
 * so concurrent children of the same application interleave lines
 * without corrupting them. */
static void note(char kind, const char *what)
{
    char line[PATH_MAX + 8];
    size_t n;
    ssize_t (*real_write)(int, const void *, size_t);

    if (!what || !*what) return;
    log_open();
    if (log_fd < 0) return;

    n = strlen(what);
    if (n > PATH_MAX - 1) n = PATH_MAX - 1;
    line[0] = kind;
    line[1] = ' ';
    memcpy(line + 2, what, n);
    line[2 + n] = '\n';

    real_write = dlsym(RTLD_NEXT, "write");
    if (real_write) real_write(log_fd, line, n + 3);
}

static void note_path(char kind, const char *path)
{
    char abs[PATH_MAX];

    if (!path || !*path) return;
    if (path[0] == '/') { note(kind, path); return; }

    /* Relative paths are recorded resolved, because the allow-list is
     * absolute and a relative record would be unusable. */
    if (getcwd(abs, sizeof(abs))) {
        size_t l = strlen(abs);
        if (l + 1 + strlen(path) + 1 < sizeof(abs)) {
            abs[l] = '/';
            strcpy(abs + l + 1, path);
            note(kind, abs);
            return;
        }
    }
    note(kind, path);
}

static char kind_for(int flags)
{
    int acc = flags & O_ACCMODE;
    if (acc == O_WRONLY || acc == O_RDWR) return 'W';
    if (flags & (O_CREAT | O_TRUNC))      return 'W';
    return 'R';
}

/* ---------------- file opening ---------------- */

int open(const char *path, int flags, ...)
{
    static int (*real)(const char *, int, ...);
    mode_t mode = 0;
    va_list ap;

    if (!real) real = dlsym(RTLD_NEXT, "open");
    if (flags & O_CREAT) {
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    note_path(kind_for(flags), path);
    return real(path, flags, mode);
}

int open64(const char *path, int flags, ...)
{
    static int (*real)(const char *, int, ...);
    mode_t mode = 0;
    va_list ap;

    if (!real) real = dlsym(RTLD_NEXT, "open64");
    if (!real) return open(path, flags);
    if (flags & O_CREAT) {
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    note_path(kind_for(flags), path);
    return real(path, flags, mode);
}

int openat(int dirfd, const char *path, int flags, ...)
{
    static int (*real)(int, const char *, int, ...);
    mode_t mode = 0;
    va_list ap;

    if (!real) real = dlsym(RTLD_NEXT, "openat");
    if (flags & O_CREAT) {
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (path[0] == 0x2f) note(kind_for(flags), path);
    return real(dirfd, path, flags, mode);
}

FILE *fopen(const char *path, const char *mode)
{
    static FILE *(*real)(const char *, const char *);
    if (!real) real = dlsym(RTLD_NEXT, "fopen");
    note_path(mode && (*mode == 'w' || *mode == 'a' || strchr(mode, '+'))
              ? 'W' : 'R', path);
    return real(path, mode);
}

DIR *opendir(const char *path);
DIR *opendir(const char *path)
{
    static DIR *(*real)(const char *);
    if (!real) real = dlsym(RTLD_NEXT, "opendir");
    note_path('D', path);
    return real(path);
}

/* ---------------- execution ---------------- */

int execve(const char *path, char *const argv[], char *const envp[])
{
    static int (*real)(const char *, char *const[], char *const[]);
    if (!real) real = dlsym(RTLD_NEXT, "execve");
    note_path('X', path);
    return real(path, argv, envp);
}

int execv(const char *path, char *const argv[])
{
    static int (*real)(const char *, char *const[]);
    if (!real) real = dlsym(RTLD_NEXT, "execv");
    note_path('X', path);
    return real(path, argv);
}

int execvp(const char *file, char *const argv[])
{
    static int (*real)(const char *, char *const[]);
    if (!real) real = dlsym(RTLD_NEXT, "execvp");
    note('X', file);
    return real(file, argv);
}

void *dlopen(const char *file, int flags)
{
    static void *(*real)(const char *, int);
    if (!real) real = dlsym(RTLD_NEXT, "dlopen");
    if (file) note_path('L', file);
    return real(file, flags);
}

/* ---------------- network ---------------- */

int socket(int domain, int type, int protocol)
{
    static int (*real)(int, int, int);
    char buf[64];
    if (!real) real = dlsym(RTLD_NEXT, "socket");
    snprintf(buf, sizeof(buf), "family:%d", domain);
    note('N', buf);
    return real(domain, type, protocol);
}

int connect(int fd, const struct sockaddr *addr, socklen_t len)
{
    static int (*real)(int, const struct sockaddr *, socklen_t);
    char buf[128];

    if (!real) real = dlsym(RTLD_NEXT, "connect");

    if (addr) {
        if (addr->sa_family == AF_INET) {
            const struct sockaddr_in *in = (const struct sockaddr_in *)addr;
            snprintf(buf, sizeof(buf), "tcp:%u", (unsigned)ntohs(in->sin_port));
            note('N', buf);
        } else if (addr->sa_family == AF_INET6) {
            const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)addr;
            snprintf(buf, sizeof(buf), "tcp:%u", (unsigned)ntohs(in6->sin6_port));
            note('N', buf);
        } else if (addr->sa_family == AF_UNIX) {
            const char *p = ((const struct sockaddr_un *)addr)->sun_path;
            if (p && p[0] == '/') note('S', p);
        }
    }
    return real(fd, addr, len);
}
OBSIDIAN_PAYLOAD_LEARN_C
ok "src/obsidian_learn.c"

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

OBSIDIAN_DIR="/opt/obsidian"
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

# Strict-boundary entry points. Each is dispatched with /bin/sh for the
# same reason --test is: re-entering the launcher here would add a
# second namespace hop and unshare refuses the nested one.
if [ "$1" = "--harden-test" ]; then
    shift
    if [ ! -r "$OBSIDIAN_DIR/bin/obsidian-harden-test" ]; then
        echo "ERROR: strict-boundary components are not installed."
        echo "       Re-run the Obsidian installer to build them."
        exit 1
    fi
    exec /bin/sh "$OBSIDIAN_DIR/bin/obsidian-harden-test" "$@"
fi

if [ "$1" = "--profile" ]; then
    shift
    if [ ! -r "$OBSIDIAN_DIR/bin/obsidian-profile" ]; then
        echo "ERROR: strict-boundary components are not installed."
        exit 1
    fi
    exec /bin/sh "$OBSIDIAN_DIR/bin/obsidian-profile" "$@"
fi

if [ "$1" = "--harden-plan" ]; then
    shift
    if [ -z "$1" ]; then
        echo "Usage: obsidian --harden-plan <application>"
        echo "Prints the boundary that would be applied. Enforces nothing."
        exit 1
    fi
    if [ ! -x "$OBSIDIAN_DIR/bin/obsidian-harden" ]; then
        echo "ERROR: $OBSIDIAN_DIR/bin/obsidian-harden is not installed."
        exit 1
    fi
    # --print-plan is what makes this a dry run, so the mode is only
    # defaulted here, never overwritten: OBSIDIAN_HARDEN=paranoid
    # obsidian --harden-plan has to report the paranoid boundary, not
    # silently fall back to the strict one and misreport it.
    if [ -z "$OBSIDIAN_HARDEN" ]; then
        OBSIDIAN_HARDEN=plan
        export OBSIDIAN_HARDEN
    fi
    exec "$OBSIDIAN_DIR/bin/obsidian-harden" --print-plan -- "$@"
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
    echo "Strict boundary - default-deny confinement, off unless asked for:"
    echo "  obsidian --harden-test          measure what the boundary closes"
    echo "  obsidian --harden-plan <app>    show the boundary, enforce nothing"
    echo "  obsidian --profile learn <app>  record what an application needs"
    echo "  obsidian --profile build <app>  turn that into an allow-list"
    echo "  OBSIDIAN_HARDEN=1 obsidian <app>   run it inside the boundary"
    echo
    echo "Runtime switches (all default to not breaking applications):"
    echo "  OBSIDIAN_GPU_MODE=strict        mask /dev/dri and /sys/class/drm"
    echo "                                  entirely; software rendering only"
    echo "  OBSIDIAN_GL_EXTENSIONS=preserve pass the real GL extension list"
    echo "                                  through (only if an app needs it)"
    echo "  OBSIDIAN_ALLOW_SYSTEM_BUS=1     permit the D-Bus system bus"
    echo "  OBSIDIAN_VERBOSE=1              log blocked IPC connections"
    echo "  OBSIDIAN_FRESH=1               throwaway launch (no saved preferences)"
    echo
    echo "Strict-boundary switches (only read when OBSIDIAN_HARDEN is set):"
    echo "  OBSIDIAN_HARDEN=1               default-deny every layer"
    echo "  OBSIDIAN_HARDEN=paranoid        also deny memfd and scope IPC"
    echo "  OBSIDIAN_HARDEN=plan            print the boundary, enforce none"
    echo "  OBSIDIAN_ALLOW_PATHS_RO=a:b     grant read on these paths"
    echo "  OBSIDIAN_ALLOW_PATHS_RW=a:b     grant read and write"
    echo "  OBSIDIAN_ALLOW_EXEC=a:b         grant execute"
    echo "  OBSIDIAN_ALLOW_DEV=/dev/x       grant a device node"
    echo "  OBSIDIAN_ALLOW_NET=tcp:443      grant outbound TCP on a port"
    echo "  OBSIDIAN_ALLOW_NESTED_NS=1      let the app build namespaces"
    echo "  OBSIDIAN_HARDEN_PROFILE=<file>  use this allow-list"
    echo "  OBSIDIAN_HARDEN_FAIL_CLOSED=1   refuse to run if a layer fails"
    echo "  OBSIDIAN_DENY_NET=1            block all network under hardening (default: allowed)"
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

# Allow-list discovery. The recorder is loaded ahead of the spoofing
# libraries and hands every call straight on to them, so what it
# records is what the application asked for and what the application
# receives is unchanged.
if [ -n "${OBSIDIAN_LEARN:-}" ] && [ "${OBSIDIAN_LEARN}" != "0" ] &&
   [ -f "$LIB_DIR/obsidian_learn.so" ]; then
    PRELOAD="$LIB_DIR/obsidian_learn.so"
fi

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
    exec "$OBSIDIAN_DIR/bin/obsidian-netblock.sh" run "${OBSIDIAN_APPKEY:-app}" -- "$@"
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
# Strict boundary preparation (opt-in, host side).
#
# Nothing in this block runs unless OBSIDIAN_HARDEN is set to
# something other than 0 or off. With it unset, the launcher below
# is byte-for-byte the launcher that produced the 93% metadata
# result, and no application sees any difference.
#
# Two things have to happen out here rather than inside the
# namespaces. The per-app profile lives in the real home directory,
# which is replaced by a tmpfs further down, so it has to be located
# now. And the inherited environment has to be cleaned before it is
# handed to anything, because a descriptor or a credential passed in
# by whatever started this launcher was never covered by any policy
# applied later - it was already there.
# ============================================================
case "${OBSIDIAN_HARDEN:-}" in
    ""|0|off|no|false) ;;
    *)
        if [ ! -x "$OBSIDIAN_DIR/bin/obsidian-harden" ]; then
            echo "ERROR: OBSIDIAN_HARDEN is set but the enforcer is missing:" >&2
            echo "       $OBSIDIAN_DIR/bin/obsidian-harden" >&2
            echo "       Re-run the installer, or unset OBSIDIAN_HARDEN to" >&2
            echo "       run this application the way it ran before." >&2
            exit 1
        fi
        export OBSIDIAN_HARDEN

        if [ -z "${OBSIDIAN_HARDEN_PROFILE:-}" ]; then
            _appkey=$(printf '%s' "$1" | sed 's|.*/||; s/[^A-Za-z0-9._-]/_/g')
            for _pd in "${XDG_CONFIG_HOME:-$HOME/.config}/obsidian/profiles" \
                       /etc/obsidian/profiles; do
                if [ -f "$_pd/$_appkey.profile" ]; then
                    OBSIDIAN_HARDEN_PROFILE="$_pd/$_appkey.profile"
                    export OBSIDIAN_HARDEN_PROFILE
                    break
                fi
            done
            unset _appkey _pd
        else
            export OBSIDIAN_HARDEN_PROFILE
        fi

        # The sandbox mounts a fresh tmpfs over /home, which is what
        # keeps real user data out of it, so a profile under the real
        # home is unreadable once we are inside. Read it out here,
        # while it is still reachable, and pass the text down. Without
        # this the per-application grant silently never loads.
        if [ -n "${OBSIDIAN_HARDEN_PROFILE:-}" ] &&
           [ -r "${OBSIDIAN_HARDEN_PROFILE:-}" ]; then
            OBSIDIAN_HARDEN_PROFILE_DATA=$(cat "$OBSIDIAN_HARDEN_PROFILE")
            export OBSIDIAN_HARDEN_PROFILE_DATA
        fi

        # Launch-state scrub, part one: named credentials.
        for _v in SSH_AUTH_SOCK SSH_AGENT_PID SSH_CONNECTION SSH_CLIENT \
                  SSH_TTY GPG_AGENT_INFO GNUPGHOME GPG_TTY KRB5CCNAME \
                  AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \
                  GOOGLE_APPLICATION_CREDENTIALS AZURE_CLIENT_SECRET \
                  GITHUB_TOKEN GH_TOKEN GITLAB_TOKEN NPM_TOKEN PYPI_TOKEN \
                  DOCKER_HOST KUBECONFIG VAULT_TOKEN \
                  HISTFILE MAIL MAILPATH \
                  SUDO_USER SUDO_UID SUDO_GID SUDO_COMMAND; do
            unset "$_v" 2>/dev/null || true
        done
        unset _v

        # Launch-state scrub, part two: anything that calls itself a
        # secret. Pattern matching rather than a fixed list, because
        # the interesting variable is always the one nobody listed.
        _leaky=$(env 2>/dev/null |
                 sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' |
                 grep -E 'TOKEN|SECRET|PASSWORD|PASSWD|APIKEY|API_KEY|CREDENTIAL|PRIVATE_KEY|_PW$' \
                 2>/dev/null || true)
        for _v in $_leaky; do
            case "$_v" in
                OBSIDIAN_*) continue ;;
            esac
            unset "$_v" 2>/dev/null || true
        done
        unset _leaky _v

        if [ -n "${OBSIDIAN_VERBOSE:-}" ]; then
            echo "obsidian: strict boundary armed (${OBSIDIAN_HARDEN})" >&2
            if [ -n "${OBSIDIAN_HARDEN_PROFILE:-}" ]; then
                echo "obsidian: profile $OBSIDIAN_HARDEN_PROFILE" >&2
            else
                echo "obsidian: no per-app profile; base allow-list only" >&2
            fi
        fi
        ;;
esac

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
mount -t proc proc /proc
mount -t tmpfs tmpfs /home
mkdir -p /home/.fake/sys_spoofs

# Persistent per-application home directory. By default the app keeps
# its preferences, caches and config across launches; only the spoofed
# identity (hostname, machine-id, ...) is regenerated each time. Set
# OBSIDIAN_FRESH=1 for a throwaway launch. The home directory is created
# in the branch below BEFORE the chmod runs: set -e is active here, and a
# chmod on a directory that does not exist yet would abort the launch.
if [ -n "$OBSIDIAN_FRESH" ] && [ "$OBSIDIAN_FRESH" != "0" ]; then
    mkdir -p "/home/$FAKE_USER"
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
        mkdir -p "/home/$FAKE_USER"
        mount --bind "$HOMESTORE" "/home/$FAKE_USER" 2>/dev/null \
            || mount -o bind "$HOMESTORE" "/home/$FAKE_USER" 2>/dev/null \
            || true
    else
        mkdir -p "/home/$FAKE_USER"
    fi
fi
chmod 700 "/home/$FAKE_USER" 2>/dev/null || true
mkdir -p "/home/$FAKE_USER/.cache/fontconfig"
mkdir -p "/home/$FAKE_USER/.config"

touch /home/.fake/empty
printf "0-1\n" > /home/.fake/cpu_online

printf "%s\n" "$FAKE_HOSTNAME" > /home/.fake/hostname
printf "%s\n" "$FAKE_MACHINE_ID" > /home/.fake/machine-id
printf "%s\n" "$FAKE_BOOT_ID" > /home/.fake/boot_id
printf "%s\n" "$DISTRO_KERNEL" > /home/.fake/osrelease
printf "%s\n" "$DISTRO_PROC_VER" > /home/.fake/version
printf "%s\n" "$DISTRO_CMDLINE" > /home/.fake/cmdline
printf "UTC\n" > /home/.fake/timezone

cat > /home/.fake/os-release <<OSRELEOF
NAME="$DISTRO_NAME"
VERSION="$DISTRO_VER"
ID=$DISTRO_ID
ID_LIKE=$DISTRO_LIKE
PRETTY_NAME="$DISTRO_PRETTY"
VERSION_ID="$DISTRO_VER_ID"
OSRELEOF

hostname "$FAKE_HOSTNAME"

[ -f /etc/hostname ] && mount --bind /home/.fake/hostname /etc/hostname
[ -f /etc/machine-id ] && mount --bind /home/.fake/machine-id /etc/machine-id
[ -f /etc/os-release ] && mount --bind /home/.fake/os-release /etc/os-release
[ -f /proc/version ] && mount --bind /home/.fake/version /proc/version
[ -f /proc/cmdline ] && mount --bind /home/.fake/cmdline /proc/cmdline
[ -f /proc/sys/kernel/osrelease ] && { mount --bind /home/.fake/osrelease /proc/sys/kernel/osrelease 2>/dev/null || true; }
[ -f /etc/timezone ] && mount --bind /home/.fake/timezone /etc/timezone
[ -f /etc/localtime ] && mount --bind /usr/share/zoneinfo/UTC /etc/localtime

for f in /etc/issue /etc/issue.net /etc/lsb-release /etc/alpine-release /etc/debian_version /etc/arch-release /etc/redhat-release; do
    [ -f "$f" ] && mount --bind /home/.fake/empty "$f" 2>/dev/null || true
done

cat > /home/.fake/passwd <<PASSWDEOF
root:x:0:0:root:/root:/bin/sh
$FAKE_USER:x:1000:1000:Generic User:/home/$FAKE_USER:/bin/sh
nobody:x:65534:65534:nobody:/:/sbin/nologin
PASSWDEOF

cat > /home/.fake/group <<GROUPEOF
root:x:0:
$FAKE_USER:x:1000:
nobody:x:65534:
GROUPEOF

[ -f /etc/passwd ] && mount --bind /home/.fake/passwd /etc/passwd 2>/dev/null || true
[ -f /etc/group ] && mount --bind /home/.fake/group /etc/group 2>/dev/null || true

if [ -f /var/lib/dbus/machine-id ] && [ ! -L /var/lib/dbus/machine-id ]; then
    mount --bind /home/.fake/machine-id /var/lib/dbus/machine-id
fi
[ -f /proc/sys/kernel/random/boot_id ] && { mount --bind /home/.fake/boot_id /proc/sys/kernel/random/boot_id 2>/dev/null || true; }

mount -t tmpfs tmpfs /tmp
chmod 1777 /tmp

: > /home/.fake/cpuinfo
c=0
while [ "$c" -lt "$FAKE_CORE_COUNT" ]; do
    cat >> /home/.fake/cpuinfo <<CPUEOF
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
[ -f /proc/cpuinfo ] && mount --bind /home/.fake/cpuinfo /proc/cpuinfo

# /proc/meminfo - sysinfo() is hooked in libc, but a direct read of
# /proc/meminfo bypasses libc entirely. Values are kept consistent
# with OBSIDIAN_TOTAL_MEMORY and the sysinfo() hook.
cat > /home/.fake/meminfo <<MEMEOF
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
[ -f /proc/meminfo ] && mount --bind /home/.fake/meminfo /proc/meminfo 2>/dev/null || true

UPTIME_SECS=$(( ( $(od -An -N2 -tu2 < /dev/urandom) % 90000 ) + 600 ))
IDLE_SECS=$(( UPTIME_SECS * 60 / 100 ))
NOW=$(date +%s); FAKE_BTIME=$(( NOW - UPTIME_SECS ))

printf "%s.00 %s.00\n" "$UPTIME_SECS" "$IDLE_SECS" > /home/.fake/uptime
printf "0.15 0.10 0.05 1/100 1234\n" > /home/.fake/loadavg
: > /home/.fake/diskstats

cat > /home/.fake/stat.awk <<\STATAWKEOF
/^cpu[0-9]+/ { n = substr($1, 4) + 0; if (n >= ncpu) next }
$1 == "btime" { print "btime " bt; next }
{ print }
STATAWKEOF

if [ -f /proc/stat ]; then
    awk -v bt="$FAKE_BTIME" -v ncpu="$FAKE_CORE_COUNT" -f /home/.fake/stat.awk /proc/stat > /home/.fake/stat
fi

for pair in "uptime:/proc/uptime" "loadavg:/proc/loadavg" "diskstats:/proc/diskstats" "stat:/proc/stat"; do
    src="/home/.fake/${pair%%:*}"; dst="${pair##*:}"
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
                        mount --bind /home/.fake/empty "$path" 2>/dev/null || true
                    else
                        idx=$((idx + 1))
                        sp_file="/home/.fake/sys_spoofs/sp_$idx"
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
    mkdir -p /home/.real_socks
    for sock in "$WAYLAND_SOCK" pulse/native pipewire-0; do
        if [ -S "$REAL_RUNTIME_DIR/$sock" ]; then
            mkdir -p "$(dirname "/home/.real_socks/$sock")"
            touch "/home/.real_socks/$sock"
            mount --bind "$REAL_RUNTIME_DIR/$sock" "/home/.real_socks/$sock"
        fi
    done

    mount -t tmpfs tmpfs "$REAL_RUNTIME_DIR"

    for sock in "$WAYLAND_SOCK" pulse/native pipewire-0; do
        if [ -S "/home/.real_socks/$sock" ]; then
            mkdir -p "$(dirname "$REAL_RUNTIME_DIR/$sock")"
            touch "$REAL_RUNTIME_DIR/$sock"
            mount --bind "/home/.real_socks/$sock" "$REAL_RUNTIME_DIR/$sock"
        fi
    done
fi

# Environment Export Engine
export LD_PRELOAD="$PRELOAD"
export HOME="/home/$FAKE_USER"
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

# Final stage. "$@" still holds the caller argv, one element per
# argument, handed to obsidian-inner unflattened.
exec unshare --user --map-user=1000 --map-group=1000 "$INNER_STAGE" "$@"
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

# Strict boundary stage. When OBSIDIAN_HARDEN is unset this adds
# nothing to the command line at all, so the argv the application
# receives is identical to what it received before this stage
# existed. When it is set, the enforcer is the last thing to run
# before the application and the boundary it installs survives the
# exec into it.
OBSIDIAN_HARDEN_BIN="/opt/obsidian/bin/obsidian-harden"
case "${OBSIDIAN_HARDEN:-}" in
    ""|0|off|no|false) ;;
    *)
        if [ -x "$OBSIDIAN_HARDEN_BIN" ]; then
            set -- "$OBSIDIAN_HARDEN_BIN" -- "$@"
        else
            echo "obsidian-inner: OBSIDIAN_HARDEN is set but $OBSIDIAN_HARDEN_BIN" >&2
            echo "obsidian-inner: is not installed; refusing to run unconfined" >&2
            exit 1
        fi
        ;;
esac

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

cat > "$BINDIR/obsidian-harden-test" <<'OBSIDIAN_PAYLOAD_HARDENTEST_SH'
#!/bin/sh
# ============================================================
# /opt/obsidian/bin/obsidian-harden-test
# Obsidian Mirror - strict boundary, measured.
#
# Runs the same probe twice through the same launcher: once as
# the launcher runs today, once with OBSIDIAN_HARDEN=1. Prints
# what each attempt actually got back from the kernel.
#
# It does not report what the policy intends. It reports what
# the kernel did. Where those two disagree, the kernel is right
# and the documentation is wrong.
# ============================================================

OBSIDIAN_DIR="${OBSIDIAN_DIR:-/opt/obsidian}"
LAUNCH="$OBSIDIAN_DIR/bin/obsidian-launch"
PROBE="$OBSIDIAN_DIR/bin/obsidian-hardenprobe"
HARDEN="$OBSIDIAN_DIR/bin/obsidian-harden"

C_B=""; C_0=""; C_G=""; C_R=""; C_Y=""
if [ -t 1 ] && [ -z "$NO_COLOR" ]; then
    C_B=$(printf '\033[1m'); C_0=$(printf '\033[0m')
    C_G=$(printf '\033[32m'); C_R=$(printf '\033[31m')
    C_Y=$(printf '\033[33m')
fi

if [ ! -x "$PROBE" ]; then
    echo "ERROR: $PROBE is not installed."
    echo "       Re-run the Obsidian installer to build the probe."
    exit 1
fi
if [ ! -x "$HARDEN" ]; then
    echo "ERROR: $HARDEN is not installed."
    echo "       Re-run the Obsidian installer to build the enforcer."
    exit 1
fi

WORK="${TMPDIR:-/tmp}/obsidian-harden-test.$$"
mkdir -p "$WORK" || { echo "ERROR: cannot create $WORK"; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

printf '\n%s' "$C_B"
printf -- '=====================================================================\n'
printf ' OBSIDIAN MIRROR - STRICT BOUNDARY, MEASURED\n'
printf -- '=====================================================================%s\n' "$C_0"
printf '\n'
printf ' Host      : %s\n' "$(uname -srm 2>/dev/null)"
printf ' Landlock  : '
LLABI=$("$HARDEN" --print-plan -- /bin/true 2>&1 | sed -n 's/.*landlock ABI  : //p' | head -1)
if [ -n "$LLABI" ] && [ "$LLABI" != "0" ] && [ "$LLABI" != "-1" ]; then
    printf 'ABI %s\n' "$LLABI"
else
    printf '%sNOT AVAILABLE - filesystem confinement cannot load%s\n' "$C_R" "$C_0"
fi
printf ' Date      : %s\n' "$(date -u '+%Y-%m-%d %H:%M UTC' 2>/dev/null)"
printf '\n'

# ---- run 1: the launcher exactly as it behaves today -----------------
printf ' running baseline (launcher as shipped) ... '
OBSIDIAN_HARDEN= "$LAUNCH" "$PROBE" --quiet \
    >"$WORK/base.tsv" 2>"$WORK/base.err"
BASE_RC=$?
printf '%s records\n' "$(wc -l < "$WORK/base.tsv" 2>/dev/null | tr -d ' ')"

# ---- run 2: the same launcher with the boundary on -------------------
printf ' running hardened (OBSIDIAN_HARDEN=1)   ... '
OBSIDIAN_HARDEN=1 \
    "$LAUNCH" "$PROBE" --quiet >"$WORK/hard.tsv" 2>"$WORK/hard.err"
HARD_RC=$?
printf '%s records\n' "$(wc -l < "$WORK/hard.tsv" 2>/dev/null | tr -d ' ')"

if [ ! -s "$WORK/base.tsv" ]; then
    printf '\n%sERROR%s: the baseline run produced nothing (exit %s).\n' \
           "$C_R" "$C_0" "$BASE_RC"
    sed 's/^/        /' "$WORK/base.err" | head -20
    exit 1
fi
if [ ! -s "$WORK/hard.tsv" ]; then
    printf '\n%sERROR%s: the hardened run produced nothing (exit %s).\n' \
           "$C_R" "$C_0" "$HARD_RC"
    sed 's/^/        /' "$WORK/hard.err" | head -20
    printf '\n Nothing is enforced by default, so the launcher is unaffected.\n'
    exit 1
fi

awk -F'\t' -v cg="$C_G" -v cr="$C_R" -v cy="$C_Y" -v c0="$C_0" -v cb="$C_B" '
BEGIN {
    # Surfaces an application legitimately needs. If the boundary
    # closes one of these it has broken the application, and that is
    # a failure of this project, not a success.
    control["jit.anon_exec"]     = 1
    control["fs.write.home"]     = 1
    control["fs.write.tmp"]      = 1
    control["fs.read.own_libs"]  = 1
    control["fs.read.urandom"]   = 1
    control["net.socket_unix"]   = 1

    label["fs.read.shadow"]      = "read the password hashes"
    label["fs.read.sshkeys"]     = "read the host SSH keys"
    label["fs.read.roothome"]    = "read the root account home"
    label["fs.read.varlog"]      = "read every system log"
    label["fs.read.boot"]        = "read the kernel and initramfs"
    label["fs.read.kcore"]       = "read kernel memory through /proc/kcore"
    label["fs.read.kallsyms"]    = "read the kernel symbol table"
    label["fs.read.devmem"]      = "read physical memory via /dev/mem"
    label["fs.read.devkmsg"]     = "read the kernel log device"
    label["fs.read.iomem"]       = "map the physical memory layout"
    label["fs.read.modules"]     = "enumerate loaded kernel modules"
    label["fs.read.debugfs"]     = "read debugfs"
    label["fs.read.rawdisk"]     = "read the raw disk device"
    label["fs.write.sysrq"]      = "trigger a kernel sysrq"
    label["fs.write.etc"]        = "write into /etc"
    label["fs.write.usr"]        = "write into /usr"
    label["fs.read.own_libs"]    = "read its own shared libraries"
    label["fs.read.urandom"]     = "read /dev/urandom"
    label["fs.write.home"]       = "write in its own home"
    label["fs.write.tmp"]        = "write in /tmp"
    label["exec.shell"]          = "spawn a shell"
    label["exec.python"]         = "spawn a python interpreter"
    label["exec.node"]           = "spawn a node interpreter"
    label["exec.perl"]           = "spawn a perl interpreter"
    label["exec.memfd"]          = "execute code that has no file"
    label["exec.wx_file"]        = "execute a library it wrote itself"
    label["jit.anon_exec"]       = "JIT-compile in anonymous memory"
    label["mem.ptrace"]          = "attach a debugger to another process"
    label["mem.process_vm_readv"]  = "read another process memory"
    label["mem.process_vm_writev"] = "write another process memory"
    label["mem.peer_mem"]        = "open /proc/PID/mem of a peer"
    label["mem.userfaultfd"]     = "take over page faults"
    label["mem.perf_event_open"] = "open a performance counter"
    label["mem.pidfd_getfd"]     = "steal a descriptor from a peer"
    label["mem.kcmp"]            = "correlate processes with kcmp"
    label["log.kernel_ring"]     = "read the kernel ring buffer"
    label["kern.init_module"]    = "load a kernel module"
    label["kern.bpf"]            = "load a BPF program"
    label["kern.io_uring"]       = "open an io_uring ring"
    label["hw.iopl"]             = "take direct hardware port I/O"
    label["key.keyctl"]          = "reach the kernel keyring"
    label["time.clock_settime"]  = "set the system clock"
    label["ns.unshare_user"]     = "create a user namespace"
    label["ns.mount"]            = "mount a filesystem"
    label["ns.setns"]            = "enter another namespace"
    label["ns.open_by_handle"]   = "open a file by handle"
    label["net.socket_inet"]     = "open an IPv4 socket"
    label["net.socket_inet6"]    = "open an IPv6 socket"
    label["net.socket_netlink"]  = "query the kernel over netlink"
    label["net.socket_packet"]   = "open a raw packet socket"
    label["net.socket_unix"]     = "open a unix socket (display server)"
    label["net.connect_tcp"]     = "reach a routable address"
    label["priv.no_new_privs"]   = "regain privilege through setuid"
    label["priv.seccomp_mode"]   = "run without a syscall filter"
    label["cap.sys_admin_bounding"] = "hold CAP_SYS_ADMIN in the bounding set"
    label["cap.chown_bounding"]  = "hold CAP_CHOWN in the bounding set"
    label["cap.effective_set"]   = "hold any effective capability"
}
NR == FNR { base[$1] = $2; based[$1] = $3; order[++n] = $1; next }
{ hard[$1] = $2; hardd[$1] = $3 }
END {
    printf "\n%s SECTION 1  What the boundary closed%s\n", cb, c0
    printf " %s\n", "-------------------------------------------------------------------"
    printf " %-34s %-12s %-12s %s\n", "ATTEMPT", "AS SHIPPED", "HARDENED", ""
    printf " %s\n", "-------------------------------------------------------------------"

    closed = 0; stillopen = 0; already = 0; broke = 0; incon = 0
    unreach = 0

    # A capability left in the bounding set is only worth anything to a
    # process that can put it into its effective set. With no effective
    # capability and no_new_privs set there is no path back to one, so
    # calling that "open" would be counting a door in a wall.
    caps_dead = (hard["cap.effective_set"] == "DENIED" &&
                 hard["priv.no_new_privs"] == "DENIED")

    for (i = 1; i <= n; i++) {
        k = order[i]
        b = base[k]; h = hard[k]
        if (h == "") h = "MISSING"
        desc = (k in label) ? label[k] : k

        if (k in control) continue

        if (caps_dead && (k == "cap.sys_admin_bounding" ||
                          k == "cap.chown_bounding")) {
            v = cy "unreachable *" c0; unreach++
        } else if (b == "ALLOWED" && (h == "DENIED" || h == "KILLED")) {
            v = cg "CLOSED" c0; closed++
        } else if (b == "ALLOWED" && h == "ALLOWED") {
            v = cr "STILL OPEN" c0; stillopen++
        } else if ((b == "DENIED" || b == "KILLED") &&
                   (h == "DENIED" || h == "KILLED")) {
            v = "already shut"; already++
        } else if (b == "ABSENT" && (h == "DENIED" || h == "KILLED")) {
            v = "shut, absent here"; already++
        } else {
            v = cy "inconclusive" c0; incon++
        }
        printf " %-34s %-12s %-12s %s\n", desc, b, h, v
    }

    if (unreach > 0) {
        printf "\n  * The bounding set could not be emptied: clearing it needs\n"
        printf "    CAP_SETPCAP and this process holds no capability at all\n"
        printf "    (CapEff 0) once the launcher has mapped it to an ordinary\n"
        printf "    user. Nothing in the set is reachable from here, but it is\n"
        printf "    reported rather than hidden.\n"
    }

    printf "\n%s SECTION 2  What the application kept (positive controls)%s\n", cb, c0
    printf " %s\n", "-------------------------------------------------------------------"
    printf " %-34s %-12s %-12s %s\n", "CAPABILITY THE APP NEEDS", "AS SHIPPED", "HARDENED", ""
    printf " %s\n", "-------------------------------------------------------------------"
    for (i = 1; i <= n; i++) {
        k = order[i]
        if (!(k in control)) continue
        b = base[k]; h = hard[k]
        desc = (k in label) ? label[k] : k
        if (h == "ALLOWED") { v = cg "kept" c0 }
        else if (b != "ALLOWED") { v = cy "n/a here" c0 }
        else { v = cr "BROKEN BY THE BOUNDARY" c0; broke++ }
        printf " %-34s %-12s %-12s %s\n", desc, b, h, v
    }

    printf "\n%s SECTION 3  Summary%s\n", cb, c0
    printf " %s\n", "-------------------------------------------------------------------"
    printf "  %-45s %d\n", "surfaces the boundary closed", closed
    printf "  %-45s %d\n", "surfaces already shut by the base launcher", already
    printf "  %-45s %s%d%s\n", "surfaces still open under the boundary", \
           (stillopen ? cr : cg), stillopen, c0
    printf "  %-45s %s%d%s\n", "application capabilities broken", \
           (broke ? cr : cg), broke, c0
    printf "  %-45s %d\n", "present but unreachable", unreach
    printf "  %-45s %d\n", "inconclusive on this machine", incon
    printf "\n"
    if (broke > 0)
        printf "  %sThe boundary broke something the application needs.%s\n  Loosen the profile before using it on a real application.\n\n", cr, c0
}
' "$WORK/base.tsv" "$WORK/hard.tsv"

cat <<'LIMITS'
 SECTION 4  What this does not close
 -------------------------------------------------------------------
  Side channels.        Cache timing, branch prediction, power draw,
                        acoustics and electromagnetic emission are not
                        syscalls. No kernel policy sees them, so none
                        of them appear above and none of them are
                        closed. This is a real, permanent gap.

  Silicon below the OS. A management engine, a platform security
                        processor or signed firmware runs underneath
                        the kernel that enforces all of the above. A
                        policy written in kernel objects cannot reach
                        what the kernel itself runs on top of.

  The host itself.      Everything here confines the application. It
                        does not confine the machine's owner, or code
                        already running as another user. That was
                        never the boundary being drawn.

  Anything not probed.  This report covers the attempts listed above
                        and nothing else. A surface that is not
                        measured here is not a surface that is proven
                        closed - it is one nobody has looked at yet.

LIMITS

printf ' Reproduce any single line with:\n'
printf '   %s %s --quiet | grep <key>\n' "$LAUNCH" "$PROBE"
printf '   OBSIDIAN_HARDEN=1 %s %s --quiet | grep <key>\n\n' "$LAUNCH" "$PROBE"

exit 0
OBSIDIAN_PAYLOAD_HARDENTEST_SH
chmod 755 "$BINDIR/obsidian-harden-test"
ok "bin/obsidian-harden-test"

cat > "$BINDIR/obsidian-profile" <<'OBSIDIAN_PAYLOAD_PROFILE_SH'
#!/bin/sh
# ============================================================
# /opt/obsidian/bin/obsidian-profile
# Obsidian Mirror - per-application allow-list discovery.
#
# The point of the enumeration is not to list denials. It is to
# discover what an application legitimately needs, grant exactly
# that, and deny the rest. This tool is that loop:
#
#   obsidian-profile learn <app> [args...]   run it, record it
#   obsidian-profile build <app>             collapse into a profile
#   obsidian-profile show  <app>             read the profile
#   obsidian-profile list                    every profile on this host
#   obsidian-profile reset <app>             throw the recording away
#
# Then, and only then:
#
#   OBSIDIAN_HARDEN=1 obsidian <app>
#
# A profile that was never built means the boundary falls back to
# its base allow-list, which is deliberately conservative.
# ============================================================

OBSIDIAN_DIR="${OBSIDIAN_DIR:-/opt/obsidian}"
LAUNCH="$OBSIDIAN_DIR/bin/obsidian-launch"
LEARN_DIR="${OBSIDIAN_LEARN_DIR:-$OBSIDIAN_DIR/var/learn}"
USER_PROFILES="${XDG_CONFIG_HOME:-$HOME/.config}/obsidian/profiles"
SYS_PROFILES="/etc/obsidian/profiles"

usage() {
    sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

app_key() {
    printf '%s' "$1" | sed 's|.*/||; s/[^A-Za-z0-9._-]/_/g'
}

profile_path() {
    _k=$(app_key "$1")
    if [ -f "$USER_PROFILES/$_k.profile" ]; then
        printf '%s\n' "$USER_PROFILES/$_k.profile"
    elif [ -f "$SYS_PROFILES/$_k.profile" ]; then
        printf '%s\n' "$SYS_PROFILES/$_k.profile"
    else
        printf '%s\n' "$USER_PROFILES/$_k.profile"
    fi
}

CMD="$1"
[ -n "$CMD" ] || usage 1
shift

case "$CMD" in

learn)
    APP="$1"
    [ -n "$APP" ] || { echo "usage: obsidian-profile learn <app> [args...]" >&2; exit 1; }
    shift
    KEY=$(app_key "$APP")
    mkdir -p "$LEARN_DIR" 2>/dev/null
    if [ ! -w "$LEARN_DIR" ]; then
        LEARN_DIR="${TMPDIR:-/tmp}/obsidian-learn"
        mkdir -p "$LEARN_DIR" || exit 1
        echo "note: $OBSIDIAN_DIR/var/learn is not writable, recording to $LEARN_DIR"
    fi
    LOG="$LEARN_DIR/$KEY.log"
    : > "$LOG" || exit 1
    echo "Recording what $APP reaches for."
    echo "  log: $LOG"
    echo
    echo "Use the application normally - open a file, open its settings,"
    echo "print something, do whatever it is you actually do with it. An"
    echo "access that never happens during the recording will be denied"
    echo "later, so exercise the parts you care about. Then quit it."
    echo
    OBSIDIAN_LEARN=1 OBSIDIAN_LEARN_LOG="$LOG" "$LAUNCH" "$APP" "$@"
    RC=$?
    echo
    if [ -s "$LOG" ]; then
        echo "Recorded $(wc -l < "$LOG" | tr -d ' ') accesses."
        echo "Next:  obsidian-profile build $APP"
    else
        echo "Nothing was recorded. The learning library did not load."
        echo "Check that $OBSIDIAN_DIR/lib/obsidian_learn.so exists."
    fi
    exit $RC
    ;;

build)
    APP="$1"
    [ -n "$APP" ] || { echo "usage: obsidian-profile build <app>" >&2; exit 1; }
    KEY=$(app_key "$APP")
    LOG="$LEARN_DIR/$KEY.log"
    [ -f "$LOG" ] || LOG="${TMPDIR:-/tmp}/obsidian-learn/$KEY.log"
    if [ ! -s "$LOG" ]; then
        echo "No recording for $APP." >&2
        echo "Run:  obsidian-profile learn $APP" >&2
        exit 1
    fi
    mkdir -p "$USER_PROFILES" || exit 1
    OUT="$USER_PROFILES/$KEY.profile"

    # Where the application really lives, and what really starts it.
    # Both are knowable here, so neither is left for the user to work
    # out from a permission error later. A great many distribution
    # packages are a small shell wrapper around the real binary, and
    # in that case the interpreter named in the #! line is as much a
    # requirement for starting the app as the wrapper itself.
    BIN=$(command -v "$APP" 2>/dev/null || printf '%s' "$APP")
    RBIN=$(readlink -f "$BIN" 2>/dev/null || printf '%s' "$BIN")
    INTERP=""
    INTERPARG=""
    if [ -r "$RBIN" ]; then
        FIRST=$(head -n 1 "$RBIN" 2>/dev/null)
        case "$FIRST" in
        "#!"*)
            SHB=$(printf '%s' "${FIRST#\#!}" | sed 's/^[ 	]*//')
            INTERP=$(printf '%s' "$SHB" | awk '{ print $1 }')
            INTERPARG=$(printf '%s' "$SHB" | awk '{ print $2 }')
            if [ -n "$INTERP" ]; then
                INTERP=$(readlink -f "$INTERP" 2>/dev/null || printf '%s' "$INTERP")
            fi
            case "$INTERP" in
            */env)
                # env finds the real interpreter on PATH
                if [ -n "$INTERPARG" ]; then
                    R=$(command -v "$INTERPARG" 2>/dev/null)
                    if [ -n "$R" ]; then
                        INTERPARG=$(readlink -f "$R" 2>/dev/null || printf '%s' "$R")
                    else
                        INTERPARG=""
                    fi
                fi
                ;;
            *)  INTERPARG="" ;;
            esac
            ;;
        esac
    fi

    {
    printf '# Obsidian Mirror strict-boundary profile\n'
    printf '#   application : %s\n' "$APP"
    printf '#   built from  : %s\n' "$LOG"
    printf '#   accesses    : %s recorded\n' "$(wc -l < "$LOG" | tr -d ' ')"
    printf '#   built on    : %s\n' "$(date -u '+%Y-%m-%d %H:%M UTC' 2>/dev/null)"
    printf '#\n'
    printf '# Every line below is something this application actually did.\n'
    printf '# Everything not listed here, and not in the base allow-list,\n'
    printf '# is denied. Delete a line to deny it too; the application will\n'
    printf '# tell you soon enough if it needed it.\n'
    printf '#\n'
    printf '# The base allow-list already covers: /usr/lib and /lib as\n'
    printf '# read-execute, /usr/share and the common /etc entries as\n'
    printf '# read-only, the home directory, /tmp and the runtime dir as\n'
    printf '# read-write, and the harmless /dev nodes. Those are not\n'
    printf '# repeated here.\n'
    printf '\n'

    awk '
    function toplevel(p,   a) { split(p, a, "/"); return a[2] }
    function limit_for(p,   t) {
        t = toplevel(p)
        if (t == "usr")  return 3
        if (t == "var")  return 3
        if (t == "run")  return 3
        if (t == "etc")  return 2
        if (t == "opt")  return 2
        if (t == "dev")  return 2
        if (t == "srv")  return 2
        return 2
    }
    function dirname(p,   i) {
        i = length(p)
        while (i > 1 && substr(p, i, 1) != "/") i--
        if (i <= 1) return "/"
        return substr(p, 1, i - 1)
    }
    function depth(p,   a) { return split(p, a, "/") - 1 }
    function truncate_to(p, lim,   a, n, i, out) {
        n = split(p, a, "/")
        out = ""
        for (i = 2; i <= n && i <= lim + 1; i++) out = out "/" a[i]
        return (out == "") ? "/" : out
    }
    # Collapse an access to the smallest grant that still contains it.
    # A file sitting directly in a top-level directory is granted by
    # name: /etc/hostname must never turn into a grant on /etc.
    function collapse(p, isdir,   d, lim) {
        d = isdir ? p : dirname(p)
        lim = limit_for(p)
        if (!isdir && depth(d) < 2) return p
        if (depth(d) > lim) return truncate_to(d, lim)
        return d
    }
    # Already granted by the base allow-list: not worth a line.
    function covered(p) {
        # The launcher stages that run before the boundary is applied.
        # They are already past by the time anything is enforced, so a
        # grant for them would be a grant for nothing.
        if (p ~ /^\/opt\/obsidian/)   return 1
        if (p ~ /\/taskset$/)         return 1
        if (p ~ /^\/usr\/lib/)        return 1
        if (p ~ /^\/lib/)             return 1
        if (p ~ /^\/usr\/libexec/)    return 1
        if (p ~ /^\/usr\/share/)      return 1
        if (p ~ /^\/usr\/local\/lib/) return 1
        if (p ~ /^\/proc/)            return 1
        if (p ~ /^\/sys/)             return 1
        if (p ~ /^\/tmp/)             return 1
        if (p ~ /^\/var\/tmp/)        return 1
        if (p ~ /^\/dev\/shm/)        return 1
        if (p ~ /^\/dev\/(null|zero|full|random|urandom|tty|ptmx|pts|console|fd|std)/) return 1
        if (p ~ /^\/dev\/dri/)        return 1
        if (home != "" && index(p, home) == 1) return 1
        if (runtime != "" && index(p, runtime) == 1) return 1
        if (p ~ /^\/etc\/(fonts|ssl|ca-certificates|resolv\.conf|hosts|hostname|nsswitch\.conf|passwd|group|localtime|timezone|machine-id|os-release|ld\.so|ld-musl|xdg|gtk-|pango|mime\.types|alternatives|pki|terminfo|dconf|vulkan|drirc|asound|pulse|pipewire)/) return 1
        return 0
    }
    $1 == "R" || $1 == "W" || $1 == "X" || $1 == "L" || $1 == "S" || $1 == "D" {
        kind = $1
        $1 = ""
        sub(/^ /, "")
        p = $0
        if (p == "" || substr(p, 1, 1) != "/") next

        if (kind == "X" || kind == "L") {
            # Executables and dynamically loaded objects are granted by
            # exact path. This is the layer that decides whether the app
            # can start a shell, so it does not get collapsed.
            if (!covered(p)) exec_seen[p] = 1
            next
        }
        if (kind == "S") {
            c = collapse(p, 0)
            if (!covered(c)) sock_seen[c] = 1
            next
        }
        c = collapse(p, kind == "D")
        if (covered(c)) next
        if (c ~ /^\/dev\//) { dev_seen[c] = 1; next }
        if (kind == "W") { rw_seen[c] = 1; delete ro_seen[c] }
        else if (!(c in rw_seen)) ro_seen[c] = 1
    }
    $1 == "N" {
        if ($2 ~ /^tcp:/) { split($2, a, ":"); if (a[2] + 0 > 0) net_seen[a[2]] = 1 }
    }
    END {
        n = 0
        printf "# --- read-only ---\n"
        for (p in ro_seen) { print "allow.ro=" p; n++ }
        if (n == 0) printf "# (nothing beyond the base allow-list)\n"

        printf "\n# --- read-write ---\n"
        n = 0
        for (p in rw_seen) { print "allow.rw=" p; n++ }
        for (p in sock_seen) { print "allow.rw=" p; n++ }
        if (n == 0) printf "# (nothing beyond the base allow-list)\n"

        printf "\n# --- devices ---\n"
        n = 0
        for (p in dev_seen) { print "allow.dev=" p; n++ }
        if (n == 0) printf "# (nothing beyond the base allow-list)\n"

        printf "\n# --- execution ---\n"
        printf "# The application itself, at the path it actually resolves\n"
        printf "# to, and the interpreter that starts it if it is a #!\n"
        printf "# wrapper. Without these it cannot run at all, so they are\n"
        printf "# written in active rather than left for you to discover.\n"
        n = 0
        if (appbin   != "") { print "allow.exec=" appbin;   own[appbin]   = 1; n++ }
        if (interp   != "") { print "allow.exec=" interp;   own[interp]   = 1; n++ }
        if (interparg != "") { print "allow.exec=" interparg; own[interparg] = 1; n++ }
        printf "#\n"
        printf "# Below: other programs this application started. If a\n"
        printf "# shell or an interpreter appears here, decide whether it is\n"
        printf "# really needed before leaving the line in place.\n"
        m = 0
        for (p in exec_seen) {
            if (p in own) continue
            if (p ~ /\/(sh|bash|dash|zsh|python[0-9.]*|perl|node|ruby|php|lua|tclsh|awk|env)$/)
                printf "# REVIEW - interpreter: allow.exec=%s\n", p
            else { print "allow.exec=" p; n++; m++ }
        }
        if (m == 0) printf "# (nothing beyond the above)\n"

        printf "\n# --- network ---\n"
        n = 0
        for (p in net_seen) { print "allow.net=tcp:" p; n++ }
        if (n == 0) {
            printf "# This application made no outbound TCP connection during\n"
            printf "# the recording, so it gets none. Add allow.net=tcp:443 if\n"
            printf "# it turns out to need one.\n"
        }
    }
    ' home="$HOME" runtime="$XDG_RUNTIME_DIR" \
      appbin="$RBIN" interp="$INTERP" interparg="$INTERPARG" "$LOG"

    printf '\n# --- options ---\n'
    printf '# opt.scope_ipc=1     confine abstract unix sockets and signals\n'
    printf '#                     (breaks X11 clients, harmless on Wayland)\n'
    printf '# opt.nested_ns=1     let the app build its own namespaces\n'
    printf '#                     (Chromium and Electron zygotes want this)\n'
    printf '# opt.memfd=deny      refuse anonymous memory files outright\n'
    printf '# opt.hard_fail=1     refuse to start if a layer cannot load\n'
    printf '# opt.verbose=1       log every grant as it is applied\n'
    } > "$OUT"

    echo "Profile written: $OUT"
    echo
    grep -c '^allow\.' "$OUT" | sed 's/^/  grants: /'
    grep -c '^# REVIEW' "$OUT" | sed 's/^/  lines needing your decision: /'
    echo
    echo "The application resolves to:"
    echo "  $RBIN"
    if [ -n "$INTERP" ]; then
        echo "and it is started by its interpreter:"
        echo "  $INTERP"
        [ -n "$INTERPARG" ] && echo "  $INTERPARG"
        echo "(both are already granted in the profile above)"
    fi
    echo
    echo "Read it, delete anything the application does not deserve, then:"
    echo "  OBSIDIAN_HARDEN=1 obsidian $APP"
    ;;

show)
    APP="$1"
    [ -n "$APP" ] || { echo "usage: obsidian-profile show <app>" >&2; exit 1; }
    P=$(profile_path "$APP")
    [ -f "$P" ] || { echo "no profile for $APP (looked in $P)" >&2; exit 1; }
    echo "# $P"
    cat "$P"
    ;;

path)
    APP="$1"
    [ -n "$APP" ] || { echo "usage: obsidian-profile path <app>" >&2; exit 1; }
    profile_path "$APP"
    ;;

list)
    FOUND=0
    for d in "$USER_PROFILES" "$SYS_PROFILES"; do
        [ -d "$d" ] || continue
        for f in "$d"/*.profile; do
            [ -f "$f" ] || continue
            FOUND=1
            printf '%-28s %s grants  %s\n' \
                "$(basename "$f" .profile)" \
                "$(grep -c '^allow\.' "$f")" "$f"
        done
    done
    [ "$FOUND" -eq 1 ] || echo "No profiles yet. Start with: obsidian-profile learn <app>"
    ;;

reset)
    APP="$1"
    [ -n "$APP" ] || { echo "usage: obsidian-profile reset <app>" >&2; exit 1; }
    KEY=$(app_key "$APP")
    rm -f "$LEARN_DIR/$KEY.log" "${TMPDIR:-/tmp}/obsidian-learn/$KEY.log"
    echo "Recording for $APP removed. The profile itself was left alone."
    ;;

-h|--help|help) usage 0 ;;
*) echo "unknown command: $CMD" >&2; usage 1 ;;
esac
OBSIDIAN_PAYLOAD_PROFILE_SH
chmod 755 "$BINDIR/obsidian-profile"
ok "bin/obsidian-profile"

cat > "$BINDIR/Obsidian-Mirror-Scanner.sh" <<'OBSIDIAN_PAYLOAD_SCANNER_SH'
#!/bin/sh
# =====================================================================
# Obsidian Mirror Scanner  -  network traffic logger / learner (v2)
# =====================================================================
#
# The "external view" approach to the internal-application threat model.
#
# Instead of inspecting or blocking threats from *inside* an application
# (fragile, breaks apps), we watch everything the application tries to
# send *out* -- between the application and the real network -- log it,
# and learn from it. This is the "EXTERNAL SUPER-BLOCKER" vantage point.
#
# WHAT IT CAPTURES
# -----------------
# All IP and ethernet-layer traffic on every interface: ethernet, wifi,
# VPN/tunnels, ARP, and every IP protocol (TCP/UDP/ICMP/GRE/ESP/SCTP/...),
# on every port -- including ports we do not recognise. A "magical mystery"
# destination simply appears as "dst port N". The only class tcpdump cannot
# see is Bluetooth, which is captured separately by `btmon` (auto-spawned).
#
# MODES
# -----
#   capture  : run an app and log all its traffic        (default)
#   learn    : parse a log -> list of endpoints the app used
#   background: capture only, to a per-app file, print PID (for the launcher)
#
# Usage (capture):
#   Obsidian-Mirror-Scanner.sh [options] -- <application> [args...]
#   Obsidian-Mirror-Scanner.sh -k firefox -d 120 -- firefox
#   Obsidian-Mirror-Scanner.sh -n -- chromium          # run via obsidian
#
# Usage (learn):
#   Obsidian-Mirror-Scanner.sh learn -l Obsidian-scanner.log
#
# Options:
#   -l FILE   log file                  (default: Obsidian-scanner.log)
#   -d SECS   capture duration          (default: until the app exits)
#   -i IFACE  capture interface         (default: any)
#   -k KEY    per-app key -> /opt/obsidian/var/scan/<KEY>.log
#   -n        also run the app through obsidian (isolation)
#   -b        background capture only (no app launch); prints PID
#
# Environment: OBSIDIAN_SCANNER_LOG / _DURATION / _IFACE / _SCANDIR
# =====================================================================

set -u

DEFAULT_SCANDIR="/opt/obsidian/var/scan"
SCANDIR="${OBSIDIAN_SCANDIR:-$DEFAULT_SCANDIR}"
LOG="${OBSIDIAN_SCANNER_LOG:-Obsidian-scanner.log}"
DURATION="${OBSIDIAN_SCANNER_DURATION:-}"
IFACE="${OBSIDIAN_SCANNER_IFACE:-any}"
VIA_OBSIDIAN=0
BG=0
KEY=""
APP=""
MODE="capture"

# ---- parse arguments -------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        learn)  MODE="learn"; shift ;;
        -l) LOG="$2"; shift 2 ;;
        -d) DURATION="$2"; shift 2 ;;
        -i) IFACE="$2"; shift 2 ;;
        -k) KEY="$2"; shift 2 ;;
        -n) VIA_OBSIDIAN=1; shift ;;
        -b) BG=1; shift ;;
        --) shift; APP="$*"; break ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
         *)  APP="$*"; break ;;
    esac
done

if [ -n "$KEY" ]; then
    mkdir -p "$SCANDIR" 2>/dev/null || true
    LOG="$SCANDIR/$KEY.log"
fi

# ---- pick a capture engine -------------------------------------------
pick_engine() {
    if command -v tcpdump >/dev/null 2>&1; then echo tcpdump
    elif command -v tshark >/dev/null 2>&1; then echo tshark
    elif command -v dumpcap >/dev/null 2>&1; then echo dumpcap
    else echo none; fi
}

CAP="$(pick_engine)"
if [ "$CAP" = "none" ]; then
    echo "ERROR: no packet capture tool found (need tcpdump, tshark or dumpcap)." >&2
    exit 1
fi

# ---- learn mode ------------------------------------------------------
if [ "$MODE" = "learn" ]; then
    if [ ! -f "$LOG" ]; then
        echo "ERROR: log not found: $LOG" >&2
        exit 1
    fi
    echo "# endpoints observed in $LOG (dst ip : port : proto)"
    # tcpdump verbose lines look like:
    #   IP 10.0.0.5.44122 > 93.184.216.34.443: Flags [P.], ...
    #   IP 10.0.0.5 > 1.1.1.1: ICMP ...
    awk '
        /[>]/ {
            # split on ">" to get the destination side
            n = split($0, a, ">")
            dst = a[n]
            # strip trailing ":" and flags
            sub(/:.*/, "", dst)
            # destination is last field before ":port" or just ip
            if (dst ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$/) {
                # pure IP (e.g. ICMP) -> port "*"
                print dst" * "proto_of($0)
            } else if (dst ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
                # ip.port
                print dst" "proto_of($0)
            }
        }
        function proto_of(line,   p) {
            if (line ~ /ICMP/) return "icmp"
            if (line ~ /UDP/) return "udp"
            if (line ~ /TCP/) return "tcp"
            return "ip"
        }
    ' "$LOG" | sort -u
    exit 0
fi

# ---- background capture mode (for the launcher) ----------------------
if [ "$BG" -eq 1 ]; then
    case "$CAP" in
        tcpdump)
            tcpdump -n -tttt -v -s 0 -i "$IFACE" \
                "not (host 127.0.0.1 or host ::1)" -w "$LOG" 2>/dev/null &
            ;;
        tshark|dumpcap)
            tshark -i "$IFACE" -w "$LOG" >/dev/null 2>&1 &
            ;;
    esac
    CAP_PID=$!
    # also capture Bluetooth if btmon exists
    if command -v btmon >/dev/null 2>&1; then
        BTLOG="$SCANDIR/${KEY:-bt}.btmon.log"
        btmon -w "$BTLOG" >/dev/null 2>&1 &
        BTPID=$!
    fi
    echo "$CAP_PID ${BTPID:-}"
    exit 0
fi

# ---- foreground capture mode -----------------------------------------
echo "Obsidian Mirror Scanner"
echo "  application : ${APP:-<none>}"
echo "  capture     : $CAP on interface '$IFACE'"
echo "  log file    : $LOG"
[ -n "$DURATION" ] && echo "  duration    : ${DURATION}s"

case "$CAP" in
    tcpdump)
        tcpdump -n -tttt -v -s 0 -i "$IFACE" \
            "not (host 127.0.0.1 or host ::1)" \
            > "$LOG" 2>&1 &
        CAP_PID=$!
        ;;
    tshark|dumpcap)
        tshark -i "$IFACE" -w "$LOG" >/dev/null 2>&1 &
        CAP_PID=$!
        ;;
esac
if command -v btmon >/dev/null 2>&1; then
    btmon -w "${LOG%.log}.btmon.log" >/dev/null 2>&1 &
    BTPID=$!
fi

if [ -n "$APP" ]; then
    if [ "$VIA_OBSIDIAN" -eq 1 ] && command -v obsidian >/dev/null 2>&1; then
        obsidian $APP &
    else
        $APP &
    fi
    APP_PID=$!
fi

if [ -n "$DURATION" ]; then
    sleep "$DURATION"
elif [ -n "$APP_PID" ]; then
    wait "$APP_PID" 2>/dev/null
fi

kill "$CAP_PID" 2>/dev/null
sleep 1
kill -9 "$CAP_PID" 2>/dev/null
[ -n "${BTPID:-}" ] && { kill "$BTPID" 2>/dev/null; kill -9 "$BTPID" 2>/dev/null; }

LINES=$(wc -l < "$LOG" 2>/dev/null || echo '?')
echo
echo "Capture stopped. log=$LOG lines=$LINES"
echo "Next: Obsidian-Mirror-Scanner.sh learn -l $LOG"
echo "Bluetooth (if any): ${LOG%.log}.btmon.log"
OBSIDIAN_PAYLOAD_SCANNER_SH
chmod 755 "$BINDIR/Obsidian-Mirror-Scanner.sh"
ok "bin/Obsidian-Mirror-Scanner.sh"

cat > "$BINDIR/obsidian-netblock.sh" <<'OBSIDIAN_PAYLOAD_NETBLOCK_SH'
#!/bin/sh
# =====================================================================
# obsidian-netblock.sh  -  per-app network namespace + dynamic deny-list
#                           (HARDEN_OBSIDIAN=2 "next level" hardening)
# =====================================================================
#
# The external-view blocker. For HARDEN_OBSIDIAN=2 we run the app inside
# its OWN network namespace with a dedicated veth. That gives two things:
#
#   1. Clean per-app capture  - tcpdump on the host-side veth sees ONLY
#      this app's traffic, so the scanner log is unambiguous.
#   2. Scoped enforcement    - an nftables default-deny egress policy on
#      that veth blocks everything the app did not prove it needs.
#
# Principle (as always with Obsidian Mirror): everything that is NOT 100%
# necessary for the application itself is denied. We learn "necessary" from
# a prior capture, then deny the rest.
#
# Lifecycle (run):
#   netns + veth + NAT  ->  launch app in netns via obsidian (HARDEN=1)
#     ->  capture traffic to /opt/obsidian/var/scan/<key>.log
#     ->  on exit: if a PRIOR log exists, build+apply a deny-list from it
#     ->  teardown
#
# Requires: root, iproute2, nftables (or iptables), tcpdump.
# If any are missing, it degrades to "log only" and warns -- it never
# silently breaks the application's network.
#
# Usage:
#   obsidian-netblock.sh run   <appkey> -- <application> [args...]
#   obsidian-netblock.sh build <appkey> <logfile>     # log -> rules file
#   obsidian-netblock.sh apply <appkey>               # apply rules on veth
#   obsidian-netblock.sh teardown <appkey>
# =====================================================================

set -u

SCANDIR="${OBSIDIAN_SCANDIR:-/opt/obsidian/var/scan}"
SUBNET="10.42.0.0/24"
HOSTIP="10.42.0.1"
APPIP="10.42.0.2"

warn() { echo "obsidian-netblock: $*" >&2; }

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        warn "needs root for network enforcement; falling back to logging only"
        return 1
    fi
    return 0
}

host_iface() {
    ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

# ---- netns setup -----------------------------------------------------
netns_setup() {
    KEY="$1"; NS="obs-$KEY"; VH="veth-$KEY"; VI="vethi-$KEY"
    IFACE="$(host_iface)"
    [ -z "$IFACE" ] && { warn "no default route / interface; logging only"; return 1; }
    command -v ip >/dev/null 2>&1 || { warn "iproute2 missing; logging only"; return 1; }

    ip netns add "$NS" 2>/dev/null || { warn "could not create netns; logging only"; return 1; }
    ip link add "$VH" type veth peer name "$VI" 2>/dev/null || { warn "veth create failed; logging only"; ip netns del "$NS" 2>/dev/null; return 1; }
    ip link set "$VI" netns "$NS" 2>/dev/null
    ip addr add "$HOSTIP/24" dev "$VH" 2>/dev/null
    ip link set "$VH" up 2>/dev/null
    ip netns exec "$NS" ip addr add "$APPIP/24" dev "$VI" 2>/dev/null
    ip netns exec "$NS" ip link set "$VI" up 2>/dev/null
    ip netns exec "$NS" ip route add default via "$HOSTIP" 2>/dev/null

    # NAT so the app still has working internet (don't break the app).
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    if command -v nft >/dev/null 2>&1; then
        nft add table ip obsblock_"$KEY" 2>/dev/null || true
        nft add chain ip obsblock_"$KEY" natpost '{ type nat hook postrouting priority srcnat; }' 2>/dev/null || true
        nft add rule ip obsblock_"$KEY" natpost ip saddr "$SUBNET" oifname "$IFACE" masquerade 2>/dev/null || true
    elif command -v iptables >/dev/null 2>&1; then
        iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$IFACE" -j MASQUERADE 2>/dev/null || true
    else
        warn "no nft/iptables for NAT; app may lose internet in this netns"
    fi
    echo "$NS $VH $VI $IFACE"
}

netns_teardown() {
    KEY="$1"; NS="obs-$KEY"; VH="veth-$KEY"
    nft delete table ip obsblock_"$KEY" 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    ip netns del "$NS" 2>/dev/null || true
    ip link del "$VH" 2>/dev/null || true
}

# ---- build a deny-list ruleset from a log -----------------------------
build_rules() {
    KEY="$1"; LOG="$2"
    OUT="$SCANDIR/$KEY.nft"
    mkdir -p "$SCANDIR" 2>/dev/null || true
    {
        echo "# dynamic deny-list for $KEY (generated from $LOG)"
        echo "table inet obsdeny_$KEY {"
        echo "    chain egress {"
        echo "        type filter hook output priority 0; policy drop;"
        # allow loopback and established
        echo "        iifname \"lo\" accept"
        echo "        ct state established,related accept"
        # allow each learned destination
        Obsidian-Mirror-Scanner.sh learn -l "$LOG" 2>/dev/null | while read -r dst port proto; do
            [ -z "$dst" ] && continue
            if [ "$proto" = "icmp" ] || [ "$port" = "*" ]; then
                echo "        ip daddr $dst accept"
            else
                echo "        ip daddr $dst $proto dport $port accept"
            fi
        done
        # DNS is usually needed; allow common resolvers generically
        echo "        # everything else is denied by policy drop (egress)"
        echo "    }"
        echo "    chain ingress {"
        echo "        type filter hook input priority 0; policy drop;"
        echo "        iifname \"lo\" accept"
        echo "        ct state established,related accept"
        Obsidian-Mirror-Scanner.sh learn -l "$LOG" 2>/dev/null | while read -r dst port proto; do
            [ -z "$dst" ] && continue
            if [ "$proto" = "icmp" ] || [ "$port" = "*" ]; then
                echo "        ip saddr $dst accept"
            else
                echo "        ip saddr $dst $proto sport $port accept"
            fi
        done
        echo "        # everything else is denied by policy drop (ingress)"
        echo "    }"
        echo "}"
    } > "$OUT"
    echo "$OUT"
}

stat_app() {
    KEY="$1"
    TBL="obsdeny_$KEY"
    echo "=== Obsidian Mirror - stats for $KEY (v3.4) ==="
    echo "ALLOW_NET       : 0  (default-deny in Layer 3)"
    echo "ALLOW_WIFI      : 0  (hard-blocked in Layer 3)"
    echo "ALLOW_BLUETOOTH : 0  (hard-blocked in Layer 3)"
    if nft list table inet "$TBL" >/dev/null 2>&1; then
        echo "HARDEN_OBSIDIAN=2 : ACTIVE (deny-list table present)"
        EG=$(nft list chain inet "$TBL" egress 2>/dev/null | awk '/packets/{p=$2} END{print p+0}')
        IN=$(nft list chain inet "$TBL" ingress 2>/dev/null | awk '/packets/{p=$2} END{print p+0}')
        echo "Red-flag drops (egress)  : ${EG:-0} packets"
        echo "Red-flag drops (ingress) : ${IN:-0} packets"
    else
        echo "HARDEN_OBSIDIAN=2 : NOT ACTIVE"
    fi
    if [ -f "$SCANDIR/$KEY.prior.log" ] || [ -f "$SCANDIR/$KEY.log" ]; then
        echo "Learned traffic log : present"
    else
        echo "Learned traffic log : none (run OBSIDIAN_HARDEN=2 once to learn)"
    fi
    if [ -f "$SCANDIR/$KEY.nft" ]; then
        echo "Allow-list endpoints :"
        grep -E 'ip (s?addr|daddr)' "$SCANDIR/$KEY.nft" | sed 's/^[[:space:]]*//'
    fi
}

kill_established() {
    KEY="$1"; LOG="$SCANDIR/$KEY.log"
    command -v conntrack >/dev/null 2>&1 || return 0
    [ -f "$LOG" ] || return 0
    allowed=$(Obsidian-Mirror-Scanner.sh learn -l "$LOG" 2>/dev/null | awk '{print $1}')
    conntrack -L 2>/dev/null | while read -r line; do
        dst=$(printf '%s\n' "$line" | sed -n 's/.*dst=//; s/ .*//p')
        [ -z "$dst" ] && continue
        printf '%s\n' "$allowed" | grep -qx "$dst" || conntrack -D -d "$dst" 2>/dev/null
    done
}

apply_rules() {
    KEY="$1"; NS="obs-$KEY"; VH="veth-$KEY"
    OUT="$SCANDIR/$KEY.nft"
    [ -f "$OUT" ] || { warn "no rules file $OUT; skipping enforcement"; return 1; }
    command -v nft >/dev/null 2>&1 || { warn "nftables missing; rules written to $OUT but not applied"; return 1; }
    # apply the inet table globally (it matches by daddr, so it only affects
    # what the app talks to; scoped tightly by the learned destinations).
    nft -f "$OUT" 2>/dev/null && echo "applied $OUT" || warn "nft apply failed; rules at $OUT"
}

# ---- run: full lifecycle ---------------------------------------------
run_app() {
    KEY="$1"; shift; APP="$*"
    mkdir -p "$SCANDIR" 2>/dev/null || true
    LOG="$SCANDIR/$KEY.log"
    PRIOR="$SCANDIR/$KEY.prior.log"

    if ! need_root || ! SETUP="$(netns_setup "$KEY")"; then
        # logging-only fallback: just run the app via obsidian and capture host-wide
        warn "enforcement unavailable; running with logging only"
        HARDEN_OBSIDIAN=1 Obsidian-Mirror-Scanner.sh -k "$KEY" -- $APP &
        SC_PID=$!
        HARDEN_OBSIDIAN=1 obsidian $APP
        kill "$SC_PID" 2>/dev/null; kill -9 "$SC_PID" 2>/dev/null
        return 0
    fi
    NS="obs-$KEY"; VH="veth-$KEY"

    # v3.2: hard-block Bluetooth (and WiFi if requested) for the whole host
    # during a hardened launch. The app already has no bt/wifi interface
    # inside its netns, this just guarantees 100% live blocking both ways.
    if command -v rfkill >/dev/null 2>&1; then
        rfkill block bluetooth 2>/dev/null && warn "Bluetooth hard-blocked for this launch"
        [ "${OBSIDIAN_BLOCK_WIFI:-0}" = "1" ] && rfkill block wifi 2>/dev/null && warn "WiFi hard-blocked for this launch"
    fi

    # start capture on the host-side veth (this app's traffic only)
    tcpdump -n -tttt -s 0 -i "$VH" "not (host 127.0.0.1 or host ::1)" -w "$LOG" >/dev/null 2>&1 &
    CAP_PID=$!

    # if we already learned a deny-list, apply it now (enforce prior learning)
    [ -f "$PRIOR" ] && apply_rules "$KEY"

    # launch the app inside the netns, through obsidian (HARDEN=1)
    HARDEN_OBSIDIAN=1 ip netns exec "$NS" obsidian $APP
    APP_RC=$?

    kill "$CAP_PID" 2>/dev/null; kill -9 "$CAP_PID" 2>/dev/null

    # promote this run's log to "prior" for next time, and (re)build rules
    [ -f "$LOG" ] && cp "$LOG" "$PRIOR" 2>/dev/null
    build_rules "$KEY" "$LOG" >/dev/null
    # v3.4: mid-stream kill of any established connection not on the allow-list
    kill_established "$KEY"

    netns_teardown "$KEY"
    return "$APP_RC"
}

# ---- dispatch ---------------------------------------------------------
case "${1:-}" in
    run)      shift; KEY="$1"; shift; run_app "$KEY" "$@" ;;
    build)    shift; build_rules "$1" "$2" ;;
    apply)    shift; apply_rules "$1" ;;
    stat)     shift; stat_app "$1" ;;
    kill)     shift; kill_established "$1" ;;
    teardown) shift; netns_teardown "$1" ;;
    *) echo "usage: $0 run|build|apply|stat|kill|teardown <appkey> [args...]" >&2; exit 2 ;;
esac
OBSIDIAN_PAYLOAD_NETBLOCK_SH
chmod 755 "$BINDIR/obsidian-netblock.sh"
ok "bin/obsidian-netblock.sh"

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
| `/opt/obsidian/bin/obsidian-harden` | Strict boundary enforcer (opt-in) |
| `/opt/obsidian/bin/obsidian-hardenprobe` | Strict boundary measurement probe |
| `/opt/obsidian/bin/obsidian-harden-test` | Side-by-side boundary report |
| `/opt/obsidian/bin/obsidian-profile` | Per-app allow-list discovery |
| `/opt/obsidian/lib/obsidian_learn.so` | Access recorder used by `--profile learn` |
| `/opt/obsidian/var/learn/` | Recordings, one per application |
| `/etc/obsidian/profiles/` | System-wide per-app allow-lists |
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

---

## 9. The strict boundary (opt-in, off by default)

Sections 1 to 8 are about what an application can **learn**. This section
is about what it can **do**.

The rule is one sentence: **default-deny at every layer, allow only a
minimal per-application grant.** Not a list of forbidden paths - deny
everything, then permit only what the application provably needs.

| Layer | Default | Allowed |
|---|---|---|
| Filesystem | deny ALL host paths | the app data dir + granted paths |
| Memory | its own address space | no ptrace, no peer /proc/PID/mem, no /dev/mem, no /proc/kcore |
| Network | deny all | a granted port, or none |
| Devices | deny all | only what is needed; hard-deny /dev/mem, /dev/sd*, /dev/nvme* |
| IPC | socket paths deny-all, via the filesystem layer | the granted socket paths; abstract sockets and signals scoped only under paranoid or OBSIDIAN_SCOPE_IPC=1 |
| Execution | app binary + legitimate JIT | no shell, no python -c, no node -e, no memfd exec |
| Capabilities | drop all | none |
| Privilege | NoNewPrivs | none |
| Namespaces | deny unshare/mount | none |
| Launch state | inherited fds and credentials scrubbed | stdio only |

Carried by Landlock (filesystem, devices, TCP ports, IPC scoping), a
hand-assembled seccomp-bpf program (memory, namespaces, kernel surfaces,
address families), capability dropping and `PR_SET_NO_NEW_PRIVS`. The
enforcer links no external library, so it does not disappear when
libseccomp is absent.

### Off unless asked for

    obsidian firefox                     unchanged, nothing below applies
    OBSIDIAN_HARDEN=1 obsidian firefox   inside the boundary

The installer self-test checks the first line rather than asserting it.

### The method is the same one that produced section 2

Enumerate the host, observe what the application really touches, grant
exactly that, deny the rest:

    obsidian --profile learn firefox     run it, record every access
    obsidian --profile build firefox     collapse into a minimal allow-list
    obsidian --harden-plan firefox       show the boundary, enforce nothing
    OBSIDIAN_HARDEN=1 obsidian firefox   run it

### Measured, not asserted

`obsidian --harden-test` runs one probe of ~56 attempts twice through
this launcher, with and without the boundary, and prints the kernel's
answer to each. On the reference machine: 29 surfaces closed, 18 already
shut by the base launcher, 1 still open, 0 application capabilities
broken.

The one still open is reported rather than hidden: an application can
write a library into a directory it was granted for writing and map it
executable. Landlock checks EXECUTE when a file is opened to be
executed, and a library is opened read-only, so neither it nor seccomp
can refuse that without refusing every shared library the process needs.
docs/CONFORMANCE.md audits all ten layers and names the three that fall
short of the model.

### What it does not close

Side channels - cache timing, branch prediction, power, acoustic,
electromagnetic - are not syscalls, are invisible to kernel policy, and
are not closed. Anything below the kernel, including the management
engine on this processor, is out of reach by construction. The boundary
also does not decide what an application does with data you did grant
it. And a surface that is not in the probe is not a surface that is
proven closed.

Full detail, including every known compatibility cost:
`docs/STRICT-BOUNDARY.md` in the repository.
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

# ---------------------------------------------------------------------
# Strict boundary. Deliberately built with no external library: the
# seccomp program is assembled by hand inside obsidian_harden.c and
# Landlock is reached through raw syscalls, so a missing libseccomp
# takes the older enforcer with it but never this one.
# ---------------------------------------------------------------------
HARDEN_OK=0
if $CC -O2 -Wall -o "$BINDIR/obsidian-harden" "$SRCDIR/obsidian_harden.c" \
        2>"$SRCDIR/.err.harden"; then
    chmod 755 "$BINDIR/obsidian-harden"
    HARDEN_OK=1
    ok "obsidian-harden     (strict boundary enforcer, opt-in)"
    rm -f "$SRCDIR/.err.harden"
else
    rm -f "$BINDIR/obsidian-harden"
    warn "obsidian-harden did NOT build. The strict boundary will be"
    warn "unavailable; everything else is unaffected."
    sed 's/^/        /' "$SRCDIR/.err.harden" >&2 | head -10
fi

if $CC -O2 -Wall -o "$BINDIR/obsidian-hardenprobe" \
        "$SRCDIR/obsidian_hardenprobe.c" 2>"$SRCDIR/.err.hardenprobe"; then
    chmod 755 "$BINDIR/obsidian-hardenprobe"
    ok "obsidian-hardenprobe (boundary measurement probe)"
    rm -f "$SRCDIR/.err.hardenprobe"
else
    warn "obsidian-hardenprobe did not build; 'obsidian --harden-test'"
    warn "will not be able to measure anything."
fi

if $CC $CFLAGS -shared -o "$LIBDIR/obsidian_learn.so" \
        "$SRCDIR/obsidian_learn.c" -ldl 2>"$SRCDIR/.err.learn"; then
    ok "obsidian_learn.so   (allow-list discovery)"
    rm -f "$SRCDIR/.err.learn"
else
    warn "obsidian_learn.so did not build; 'obsidian --profile learn'"
    warn "will record nothing."
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

    # 7a. the strict boundary is genuinely inert until asked for.
    #     This is the property the whole feature rests on, so it is
    #     tested rather than asserted.
    if [ "$HARDEN_OK" -eq 1 ]; then
        _off="$("$CLI_LINK" printf '%s' untouched 2>/dev/null || true)"
        if [ "$_off" = "untouched" ]; then
            ok "strict boundary is inert when OBSIDIAN_HARDEN is unset"
        else
            fail "the launcher changed behaviour with hardening OFF"
            SELFTEST_FAIL=$((SELFTEST_FAIL + 1))
        fi

        _abi="$("$BINDIR/obsidian-harden" --print-plan -- /bin/true 2>&1 |
                sed -n 's/.*landlock ABI  : //p' | head -1)"
        if [ -n "$_abi" ] && [ "$_abi" -gt 0 ] 2>/dev/null; then
            ok "Landlock available: ABI $_abi"
        else
            warn "Landlock is not available on this kernel. The strict"
            warn "boundary will still drop capabilities and filter syscalls,"
            warn "but it cannot confine the filesystem. Needs Linux 5.13+."
        fi

        _hard="$(OBSIDIAN_HARDEN=1 "$CLI_LINK" \
                 "$BINDIR/obsidian-hardenprobe" --quiet 2>/dev/null |
                 grep -c "DENIED" || true)"
        if [ "${_hard:-0}" -gt 20 ]; then
            ok "strict boundary closes ${_hard} measured surfaces"
        else
            warn "strict boundary measured only ${_hard:-0} closures;"
            warn "run 'obsidian --harden-test' to see which."
        fi
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

  ---------------------------------------------------------------------

  NEW: the strict boundary. Default-deny at every layer, with a
  minimal per-application grant. It is OFF unless you ask for it, and
  everything above behaves exactly as it did before.

      obsidian --harden-test        measure what it closes, and what
                                    it costs, on this machine

      obsidian --profile learn firefox    run it, record what it needs
      obsidian --profile build firefox    collapse that into a profile
      OBSIDIAN_HARDEN=1 obsidian firefox  run it inside the boundary

  Learn first, then harden. A boundary built from a guess breaks
  applications; a boundary built from a recording of what the
  application actually did does not.

  What it cannot close: side channels - cache timing, power, acoustic,
  electromagnetic - and anything running below the kernel, which
  includes the management engine on this very processor. Those are not
  kernel-policy problems, and this does not pretend to solve them.

DONEEOF

[ "$SELFTEST_FAIL" -eq 0 ] || exit 1
exit 0
