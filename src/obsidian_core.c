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
