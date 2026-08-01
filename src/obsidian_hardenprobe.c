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
