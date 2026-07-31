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
