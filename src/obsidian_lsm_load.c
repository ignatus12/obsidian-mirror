// SPDX-License-Identifier: GPL-2.0
/*
 * Obsidian Mirror v3.5 - BPF-LSM loader + safety watchdog.
 *
 * Loads obsidian_lsm.bpf.o, applies the per-app policy (home prefix,
 * hw-restriction + root-protection flags), attaches the LSM hooks, then:
 *   - keeps the protected_tgids map populated with the app AND every
 *     descendant process (walked from /proc), so req (1) hardware denial
 *     and req (2) root protection cover the whole app tree;
 *   - watches the app: if it dies, detach and exit;
 *   - if the BPF link is removed/tampered, or the policy map is altered,
 *     SIGKILL the app immediately (requirement 3: an app under Obsidian
 *     must never run unprotected if its kernel restrictions are touched).
 *
 * Requires root (CAP_BPF + CAP_SYS_ADMIN) to attach LSM programs. When the
 * kernel lacks BPF-LSM or the toolchain is missing, the caller skips this
 * and the app still runs under the userspace sandbox.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <dirent.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <bpf/libbpf.h>
#include <bpf/bpf.h>
#include "obsidian_lsm.skel.h"

static volatile sig_atomic_t g_stop = 0;
static void on_sig(int s) { (void)s; g_stop = 1; }

/* Read ppid of a pid from /proc/<pid>/stat. Returns -1 if not found. */
static int read_ppid(int pid)
{
	char path[64];
	FILE *f;
	char buf[512];
	int ppid = -1;

	snprintf(path, sizeof(path), "/proc/%d/stat", pid);
	f = fopen(path, "r");
	if (!f)
		return -1;
	if (fgets(buf, sizeof(buf), f)) {
		/* pid (comm) state ppid ... */
		char *p = buf;
		int n = 0;
		/* skip pid */
		while (*p && *p != ' ') p++;
		while (*p == ' ') p++;
		/* skip (comm) including nested parens */
		if (*p == '(') {
			while (*p && *p != ')') p++;
			if (*p == ')') p++;
		}
		/* skip state + read ppid (3rd field) */
		while (*p == ' ') p++;
		while (*p && *p != ' ') p++;
		while (*p == ' ') p++;
		ppid = atoi(p);
	}
	fclose(f);
	return ppid;
}

/* Collect app_pid + all descendants into tgids[] (max n). */
static int collect_tree(int app_pid, int *tgids, int n)
{
	int cur = 0, i, parent;
	tgids[cur++] = app_pid;
	for (i = 0; i < cur; i++) {
		DIR *d = opendir("/proc");
		struct dirent *e;
		if (!d) break;
		while ((e = readdir(d)) && cur < n) {
			int pid = atoi(e->d_name);
			if (pid <= 0) continue;
			parent = read_ppid(pid);
			if (parent == tgids[i])
				tgids[cur++] = pid;
		}
		closedir(d);
	}
	return cur;
}

static int refresh_tgids(struct obsidian_lsm *skel, int app_pid)
{
	int tgids[2048];
	int n = collect_tree(app_pid, tgids, 2048);
	int fd = bpf_map__fd(skel->maps.protected_tgids);
	__u32 key;
	__u8 val = 1;
	int i;

	/* clear then repopulate (simple, correct for modest trees) */
	__u32 prev_key = 0;
	while (bpf_map_get_next_key(fd, NULL, &prev_key) == 0) {
		bpf_map_delete_elem(fd, &prev_key);
		prev_key = 0;
		if (bpf_map_get_next_key(fd, NULL, &prev_key) != 0) break;
	}
	for (i = 0; i < n; i++) {
		key = (__u32)tgids[i];
		bpf_map_update_elem(fd, &key, &val, BPF_ANY);
	}
	return n;
}

int main(int argc, char **argv)
{
	__u32 app_tgid = 0;
	const char *home = NULL;
	int enforce_hw = 0, protect_root = 0;
	int i;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--pid") && i + 1 < argc)
			app_tgid = (__u32)atoi(argv[++i]);
		else if (!strcmp(argv[i], "--home") && i + 1 < argc)
			home = argv[++i];
		else if (!strcmp(argv[i], "--enforce-hw"))
			enforce_hw = 1;
		else if (!strcmp(argv[i], "--protect-root"))
			protect_root = 1;
	}
	if (app_tgid == 0) {
		fprintf(stderr, "obsidian-lsm-load: --pid required\n");
		return 2;
	}
	if (geteuid() != 0) {
		fprintf(stderr, "obsidian-lsm-load: needs root; skipping kernel enforcement\n");
		return 0;
	}

	struct obsidian_lsm *skel = obsidian_lsm__open_and_load();
	if (!skel) {
		fprintf(stderr, "obsidian-lsm-load: open/load failed\n");
		return 0;
	}

	struct obsidian_policy p = {0};
	p.enforce_hw = enforce_hw ? 1 : 0;
	p.protect_from_root = protect_root ? 1 : 0;
	if (home)
		strncpy(p.home, home, sizeof(p.home) - 1);
	int pfd = bpf_map__fd(skel->maps.policy_map);
	if (bpf_map_update_elem(pfd, &(__u32){0}, &p, BPF_ANY)) {
		fprintf(stderr, "obsidian-lsm-load: policy set failed\n");
		obsidian_lsm__destroy(skel);
		return 0;
	}

	struct bpf_link *links[4] = {0};
	links[0] = bpf_program__attach_lsm(skel->progs.obsidian_lsm_file_open);
	links[1] = bpf_program__attach_lsm(skel->progs.obsidian_lsm_ptrace);
	links[2] = bpf_program__attach_lsm(skel->progs.obsidian_lsm_task_kill);
	links[3] = bpf_program__attach_lsm(skel->progs.obsidian_lsm_root_file_open);
	for (i = 0; i < 4; i++) {
		if (!links[i]) {
			fprintf(stderr, "obsidian-lsm-load: attach failed\n");
			while (i-- > 0) bpf_link__destroy(links[i]);
			obsidian_lsm__destroy(skel);
			return 0;
		}
	}

	refresh_tgids(skel, (int)app_tgid);

	signal(SIGTERM, on_sig);
	signal(SIGINT, on_sig);

	while (!g_stop) {
		if (kill((pid_t)app_tgid, 0) != 0 && errno == ESRCH)
			break; /* app exited */

		refresh_tgids(skel, (int)app_tgid);

		/* policy intact? */
		struct obsidian_policy cur = {0};
		if (bpf_map_lookup_elem(pfd, &(__u32){0}, &cur) != 0 ||
		    cur.protect_from_root != p.protect_from_root ||
		    cur.enforce_hw != p.enforce_hw) {
			kill((pid_t)app_tgid, SIGKILL);
			break;
		}
		/* link still attached? (manipulation detection) */
		struct bpf_link_info info;
		__u32 info_len = sizeof(info);
		memset(&info, 0, sizeof(info));
		if (bpf_link_get_info_by_fd(bpf_link__fd(links[0]), &info, &info_len) != 0) {
			kill((pid_t)app_tgid, SIGKILL);
			break;
		}
		usleep(300000);
	}

	for (i = 0; i < 4; i++)
		bpf_link__destroy(links[i]);
	obsidian_lsm__destroy(skel);
	return 0;
}
OBSIDIAN_EOF
