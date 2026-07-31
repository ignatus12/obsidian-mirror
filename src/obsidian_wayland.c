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
