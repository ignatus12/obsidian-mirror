# Conformance audit: the strict-boundary model vs. the shipped code

The strict boundary was specified as one rule:

> **Default-deny at every layer, allow only a minimal per-app grant.**
> Not "deny these specific paths." Deny everything; permit only what the
> app provably needs.

This document takes that specification one row at a time and answers a
single question for each: **is it actually in the code, and what did it
measure?** Not "is it designed", not "is it intended" — is it there, and
what happened when it was tried.

Three rows are **not** fully honoured. They are listed with the same
prominence as the ones that are, because a conformance document that
only lists successes is marketing.

Measurements below are from `obsidian --harden-test` on the development
box: Linux 6.1, x86_64, **Landlock ABI 2**. Where an ABI newer than 2
changes the answer, it is said so explicitly — that matters, because the
target machine (Alpine, 6.18) is ABI 5 or 6 and will enforce *more* than
what was measurable here.

---

## Summary

| # | Layer | Verdict |
|---|---|---|
| 1 | Filesystem | **Met**, with a documented default allow-list |
| 2 | Memory | **Met** |
| 3 | Network | **Met** (port granularity needs ABI 4+) |
| 4 | Devices | **Met**, block-device rule unexercised here |
| 5 | IPC | **Partial** — no D-Bus name filtering |
| 6 | Execution | **Partial** — `dlopen` of self-written code is open |
| 7 | Capabilities | **Met**, bounding set unreachable-not-empty |
| 8 | Privilege | **Met** |
| 9 | Namespaces | **Met** |
| 10 | Launch-state scrub | **Met** |

---

## 1. Filesystem — deny ALL host paths

*Asked for:* deny all host paths; allow the app's own data dir and
explicitly granted XDG paths.

**In the code.** `obsidian_harden.c`, `landlock_create_ruleset()` with
the full `handled_fs` mask and no rules attached by default: every path
is denied until something grants it. Grants are added by `add_grant()` /
`rights_for()`, and every grant is pruned child-by-child around the
hard-deny set (`seed_hard_deny()`), so granting `/etc` cannot smuggle in
`/etc/shadow`.

**Measured.** `read the host SSH keys`, `read every system log`, `read
the kernel and initramfs`, `read the kernel symbol table`, `write into
/etc`, `write into /usr` — all DENIED under the boundary, all but the
writes ALLOWED without it.

**Deviation, stated plainly.** The default is not literally "only the
app's own data dir". `seed_defaults()` grants a base list — fonts, CA
certificates, `/etc/resolv.conf`, locale, `ld.so.cache` and similar —
66 grants for a trivial binary. Without it essentially nothing starts,
so it exists to satisfy the "no breaking changes" rule. It is a
deviation from the pure model and it is switchable:
`OBSIDIAN_HARDEN_NO_DEFAULTS=1` removes it and gives the literal
reading, where you grant every path yourself.

---

## 2. Memory — own address space only

*Asked for:* deny `ptrace`, `process_vm_readv`/`writev`,
`memfd_create`+`execve`, `/dev/mem`, `/proc/kcore`.

**In the code.** Hand-assembled seccomp-bpf deny list in
`obsidian_harden.c`: `ptrace`, `process_vm_readv`, `process_vm_writev`,
`kcmp`, `pidfd_getfd`, `process_madvise`, `userfaultfd`,
`perf_event_open`. `execveat(AT_EMPTY_PATH)` is denied by flag, and
`memfd_create` is denied outright in paranoid, `MFD_EXEC` denied always.
`/dev/mem`, `/dev/kmem`, `/proc/kcore` are in the hard-deny set.

**Measured.** `attach a debugger to another process`, `read another
process memory`, `write another process memory`, `open /proc/PID/mem of
a peer`, `steal a descriptor from a peer`, `open a performance counter`,
`execute code that has no file` — every one ALLOWED as shipped, DENIED
under the boundary. `/dev/mem` and `/proc/kcore` were already shut by
the base launcher and stay shut.

**Verdict: met.** Every mechanism named in the row is present and every
one of them measured.

---

## 3. Network — deny all, only a granted destination/port

**In the code.** Two mechanisms, because one is not enough. Landlock
network rules (ABI 4+) restrict `bind`/`connect` to granted ports, via
`OBSIDIAN_ALLOW_NET=tcp:443` or `allow.net=` in a profile. Underneath
that, seccomp filters `socket()` and `socketpair()` on argument 0, so
with no grant only `AF_UNIX` survives and everything that can leave the
machine is refused at creation.

**Measured.** `open an IPv4 socket`, `open an IPv6 socket`, `query the
kernel over netlink`, `reach a routable address` — ALLOWED as shipped,
DENIED under the boundary.

**ABI note.** On ABI 2 there are no Landlock network rules, so the
enforcement measured here is the address-family filter: all-or-nothing.
Per-port granularity is real but only from ABI 4, i.e. on the 6.18
target and not on this test box.

---

## 4. Devices — deny all, hard-deny the dangerous nodes

**In the code.** `/dev` is not granted wholesale; nodes are granted
individually (`OBSIDIAN_ALLOW_DEV`, `allow.dev=`). The hard-deny set
names `/dev/mem`, `/dev/kmem`, `/dev/port`, `/dev/kmsg`, `/dev/cpu`
(MSRs), `/dev/kvm`, `/dev/vfio`, `/dev/tpm*`, `/dev/watchdog*` and
others, and block devices are **enumerated from the real `/dev`** at
startup by prefix (`sd`, `nvme`, `vd`, `mmcblk`, `xvd`) rather than
guessed from a fixed list.

**Measured.** `read physical memory via /dev/mem` and `read the kernel
log device` DENIED. `read the raw disk device` reported *shut, absent
here* — this container has no block nodes at all, so the enumeration had
nothing to enumerate.

**Honest limit.** The `/dev/sd*`, `/dev/nvme*` rule is therefore
**unexercised**. On a Latitude 7480 with a real NVMe or SATA disk it has
something to bite on, and that is exactly the case that has not been
run. Worth checking first on the target machine.

---

## 5. IPC — **partial**

*Asked for:* deny all; allow only needed D-Bus names, shared memory,
sockets.

**What is there.** Sockets bound to a filesystem path inherit the
filesystem layer: no grant, no socket. The base launcher already refuses
the D-Bus **system bus** by default (`connect()` returns
`ECONNREFUSED`, re-enabled with `OBSIDIAN_ALLOW_SYSTEM_BUS=1`).
Address families are filtered at `socket()`. Landlock IPC scoping
(ABI 6) can confine abstract unix sockets and signals — off in `strict`
because it breaks every X11 client, on in `paranoid`.

**What is missing.** **D-Bus *name*-level filtering does not exist.**
"Only the needed D-Bus names" means brokering the bus and allowing
specific destinations and interfaces, which needs a proxy in the
connection path — `xdg-dbus-proxy` does this for Flatpak. There is no
such proxy here. The granularity available today is bus-level: the whole
system bus, or none of it.

**Also weaker than the row implies.** Shared memory is not per-app
minimal: `/dev/shm` sits in the base allow-list because too much breaks
without it.

**Verdict: partial.** Coarse denial yes, minimal per-name grant no.

---

## 6. Execution — **partial**

*Asked for:* only the app binary and legitimate JIT; deny `sh` /
`python -c` / `node -e` spawn, untrusted `dlopen`, memfd exec.

**Met, and measured.** `spawn a shell`, `spawn a python interpreter`,
`spawn a node interpreter`, `spawn a perl interpreter`, `execute code
that has no file` — all ALLOWED as shipped, all DENIED under the
boundary. The positive control `JIT-compile in anonymous memory` stayed
ALLOWED, so legitimate JIT survives, which was the other half of the
row.

**Not met: untrusted `dlopen`.** Measured directly, and it is open:

```
exec.wx_file   ALLOWED   wrote it, then mapped it PROT_EXEC
```

Landlock's `EXECUTE` right is evaluated when a file is opened *to be
executed*. A shared library is opened `O_RDONLY` and then mapped
`PROT_EXEC`, which is a different path through the kernel, so any
directory the app may write and read is a directory it can author code
in and load. seccomp cannot close it: at `mmap` time the filter sees
`PROT_EXEC` and a file descriptor number, never the path, and denying
every file-backed executable mapping denies every shared library the
process needs.

This needs an LSM that is path-aware at mapping time — SELinux
`execmod`, AppArmor's `m` permission — which is not one of the two
mechanisms this enforcer is built on. The mitigation that *is* available
is a smaller RW grant: no writable-and-readable directory, nowhere to
stage the library.

It is now attempt `execute a library it wrote itself` in
`obsidian_hardenprobe.c`, so it appears in every report as **still open
under the boundary** instead of being quietly absent.

---

## 7. Capabilities — drop all

**In the code.** `PR_CAP_AMBIENT_CLEAR_ALL`, then `PR_CAPBSET_DROP` over
every capability, then `capset()` to empty the effective, permitted and
inheritable sets.

**Measured.** `hold any effective capability` — DENIED (`CapEff` is 0).
`hold CAP_SYS_ADMIN in the bounding set` and `hold CAP_CHOWN in the
bounding set` — reported **unreachable**, not closed: emptying the
bounding set needs `CAP_SETPCAP`, and by the time the enforcer runs the
launcher has already mapped the process to an ordinary user holding no
capability at all. Nothing in the set can be acquired from there, since
`NoNewPrivs` is set and no file can grant them, but the honest report is
"present and unreachable", which is what it prints.

---

## 8. Privilege — `NoNewPrivs`

**In the code.** `prctl(PR_SET_NO_NEW_PRIVS, 1, ...)`, set before the
seccomp filter is installed (the kernel requires it for an unprivileged
filter, so this layer is load-bearing for layer 2 as well).

**Measured.** `regain privilege through setuid` — ALLOWED as shipped,
DENIED under the boundary.

---

## 9. Namespaces — deny `unshare` / `mount`

**In the code.** seccomp denies `unshare`, `setns`, `mount`,
`mount_setattr`, `pivot_root`, `open_tree`, `move_mount`,
`fsopen`/`fsconfig`/`fsmount`, and `clone` with any namespace flag in
argument 0. `clone3` returns `ENOSYS` on purpose, because its arguments
live in a struct that BPF cannot read — which makes glibc fall back to
`clone`, which BPF *can* inspect.

**Measured.** `create a user namespace`, `enter another namespace` —
ALLOWED as shipped, DENIED under the boundary. `mount a filesystem` was
already shut.

**Escape hatch.** `OBSIDIAN_ALLOW_NESTED_NS=1`, needed by Chromium and
Electron zygotes, gives this layer up for that application. Documented
as a cost, not hidden as a default.

---

## 10. Launch-state scrub

*Asked for:* a minimal, restricted launch-state scrub — the
lesser-known vector.

**In the code.** Two halves. In `obsidian-launch`, named credentials are
unset (`SSH_AUTH_SOCK`, `GPG_AGENT_INFO`, `KRB5CCNAME`, the AWS/Azure/
GCP triplets, `GITHUB_TOKEN`, `KUBECONFIG`, `VAULT_TOKEN`, `SUDO_*` …)
plus a pattern sweep over anything whose *name* advertises a secret,
because the interesting variable is always the one nobody listed. In
`obsidian_harden.c`, `close_range(3, ~0U)` drops every inherited
descriptor above stdio.

**Measured.** `steal a descriptor from a peer` DENIED; stdio positive
controls still pass, so the app keeps the three descriptors it needs.

---

## What this audit does not cover

Side channels — cache timing, branch prediction, power, acoustic,
electromagnetic — are not syscalls, so no probe here can see them and no
kernel policy can close them. Anything running below the kernel, such as
the management engine on the target CPU, sits underneath every mechanism
described above. Both are permanent gaps, not pending work.

And the standing rule from the metadata work applies unchanged: a
surface that is not in `obsidian_hardenprobe.c` is not a surface proven
closed. It is one nobody has looked at yet.
