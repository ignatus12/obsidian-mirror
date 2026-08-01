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

    fd = open(path, O_PATH | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        /* O_NOFOLLOW on a symlink: resolve it and grant the target */
        fd = open(path, O_PATH | O_CLOEXEC);
        if (fd < 0) { rules_skipped++; return 0; }
    }

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
    int i, sep = -1;

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

    add_list(getenv("OBSIDIAN_ALLOW_PATHS_RO"),  OB_RO);
    add_list(getenv("OBSIDIAN_ALLOW_PATHS_RX"),  OB_RX);
    add_list(getenv("OBSIDIAN_ALLOW_PATHS_RW"),  OB_RW);
    add_list(getenv("OBSIDIAN_ALLOW_PATHS_RWX"), OB_RWX);
    add_list(getenv("OBSIDIAN_ALLOW_DEV"),       OB_DEV);
    add_list(getenv("OBSIDIAN_ALLOW_EXEC"),      OB_RX);
    add_net_grant(getenv("OBSIDIAN_ALLOW_NET"));

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
    fprintf(stderr, "obsidian-harden: exec %s: %s\n",
            argv[sep + 1], strerror(errno));
    if (errno == EACCES)
        fprintf(stderr,
            "obsidian-harden: the boundary denied execution of the target "
            "itself.\n"
            "                 Grant it with OBSIDIAN_ALLOW_EXEC=%s\n",
            binpath);
    return 127;
}
