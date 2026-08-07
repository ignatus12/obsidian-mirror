// SPDX-License-Identifier: GPL-2.0
/*
 * Obsidian Mirror v3.5 - kernel-level enforcement via BPF-LSM.
 *
 * Enforced only while the protected app (and its descendant processes) run,
 * and only to that app / only by root:
 *
 *   1. Hardware restriction  - when enforce_hw is set, the app and its
 *      children are denied access to hardware device nodes / sysfs classes
 *      (GPU, input, camera, sound). Previously done with userspace tmpfs
 *      mounts; now kernel-enforced so it cannot be bypassed.
 *
 *   2. Protect the app from root - when protect_from_root is set, the root
 *      user (uid 0) is denied ptrace, kill and file access to the app's
 *      files and processes for the app's lifetime.
 *
 *   3. Safety mechanism lives in the loader: if the BPF link is ever
 *      detached (manipulation attempt) or the policy tampered, the loader
 *      SIGKILLs the app, so an attacked policy never silently leaves the
 *      app exposed.
 *
 * The set of "protected" tgids (app + descendants) is maintained by the
 * loader in the protected_tgids hash map; is_app() just does a map lookup.
 */
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

char LICENSE[] SEC("license") = "GPL";

#define PATH_MAX_LEN 256

struct obsidian_policy {
	__u8  enforce_hw;        /* 1 = deny app hardware devices */
	__u8  protect_from_root; /* 1 = deny root access to the app */
	__u8  _pad[2];
	char  home[PATH_MAX_LEN];/* app home prefix to protect from root */
};

struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, struct obsidian_policy);
} policy_map SEC(".maps");

/* tgid -> 1 for every protected process (app + descendants). */
struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 4096);
	__type(key, __u32);
	__type(value, __u8);
} protected_tgids SEC(".maps");

static __always_inline struct obsidian_policy *get_policy(void)
{
	__u32 zero = 0;
	return bpf_map_lookup_elem(&policy_map, &zero);
}

static __always_inline int is_protected(void)
{
	__u32 tgid = bpf_get_current_pid_tgid() >> 32;
	__u8 *v = bpf_map_lookup_elem(&protected_tgids, &tgid);
	return v ? 1 : 0;
}

static __always_inline int is_root(void)
{
	__u32 uid = bpf_get_current_uid_gid() & 0xffffffff;
	return uid == 0 ? 1 : 0;
}

static __always_inline int path_has_prefix(const char *path, const char *prefix)
{
	int i = 0;
	char c1, c2;
#pragma unroll
	for (i = 0; i < 32; i++) {
		c1 = prefix[i];
		if (c1 == '\0')
			return 1;
		if (bpf_probe_read_str(&c2, 1, &path[i]) != 1 || c2 != c1)
			return 0;
	}
	return 1;
}

static __always_inline int path_in_hw_list(const char *path)
{
	if (path_has_prefix(path, "/dev/dri")) return 1;
	if (path_has_prefix(path, "/dev/input")) return 1;
	if (path_has_prefix(path, "/dev/hidraw")) return 1;
	if (path_has_prefix(path, "/dev/video")) return 1;
	if (path_has_prefix(path, "/dev/snd")) return 1;
	if (path_has_prefix(path, "/dev/media")) return 1;
	if (path_has_prefix(path, "/sys/class/drm")) return 1;
	if (path_has_prefix(path, "/sys/class/input")) return 1;
	if (path_has_prefix(path, "/sys/class/hidraw")) return 1;
	if (path_has_prefix(path, "/sys/class/video4linux")) return 1;
	if (path_has_prefix(path, "/sys/class/sound")) return 1;
	if (path_has_prefix(path, "/sys/class/backlight")) return 1;
	return 0;
}

/* Requirement 1: deny the app + descendants access to hardware devices. */
SEC("lsm/file_open")
int BPF_PROG(obsidian_lsm_file_open, struct file *file, int ret)
{
	struct obsidian_policy *p;
	char path[PATH_MAX_LEN];
	long len;

	if (ret != 0)
		return ret;
	p = get_policy();
	if (!p || !p->enforce_hw)
		return 0;
	if (!is_protected())
		return 0;
	len = bpf_d_path(&file->f_path, path, sizeof(path));
	if (len < 0)
		return 0;
	if (path_in_hw_list(path))
		return -EPERM;
	return 0;
}

/* Requirement 2a/b: root may not ptrace or kill the app or its children. */
SEC("lsm/ptrace_access_check")
int BPF_PROG(obsidian_lsm_ptrace, struct task_struct *child, unsigned int mode)
{
	struct obsidian_policy *p;
	__u32 child_tgid;
	__u8 *v;

	p = get_policy();
	if (!p || !p->protect_from_root)
		return 0;
	if (!is_root())
		return 0;
	child_tgid = BPF_CORE_READ(child, tgid);
	v = bpf_map_lookup_elem(&protected_tgids, &child_tgid);
	if (v)
		return -EPERM;
	return 0;
}

SEC("lsm/task_kill")
int BPF_PROG(obsidian_lsm_task_kill, struct task_struct *target,
	     struct kernel_siginfo *info, int sig, const struct cred *cred)
{
	struct obsidian_policy *p;
	__u32 target_tgid;
	__u8 *v;

	p = get_policy();
	if (!p || !p->protect_from_root)
		return 0;
	if (!is_root())
		return 0;
	target_tgid = BPF_CORE_READ(target, tgid);
	v = bpf_map_lookup_elem(&protected_tgids, &target_tgid);
	if (v)
		return -EPERM;
	return 0;
}

/* Requirement 2c: root may not open the app's own files. */
SEC("lsm/file_open")
int BPF_PROG(obsidian_lsm_root_file_open, struct file *file, int ret)
{
	struct obsidian_policy *p;
	char path[PATH_MAX_LEN];
	long len;

	if (ret != 0)
		return ret;
	p = get_policy();
	if (!p || !p->protect_from_root)
		return 0;
	if (!is_root())
		return 0;
	len = bpf_d_path(&file->f_path, path, sizeof(path));
	if (len < 0)
		return 0;
	if (p->home[0] != '\0' && path_has_prefix(path, p->home))
		return -EPERM;
	return 0;
}
OBSIDIAN_EOF
