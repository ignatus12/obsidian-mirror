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
