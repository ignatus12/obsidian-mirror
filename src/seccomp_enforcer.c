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
