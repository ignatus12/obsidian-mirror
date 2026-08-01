# The Strict Boundary

**Default-deny at every layer, allow only a minimal per-application grant.**

Not "deny these specific paths." Deny everything; permit only what the
application provably needs.

This document describes what that sentence became once it was written in
code, which kernel mechanism carries each layer, what the result measures
at on a real machine, and — at the end, in its own section — what it does
not and cannot do.

It is **off by default.** Nothing in this document happens unless
`OBSIDIAN_HARDEN` is set. With it unset, `obsidian <application>` is the
same launcher that produced the metadata result (91% of 74 checks on
this box, and it varies by host), byte for byte, and
the installer's self-test checks that claim rather than asserting it.

---

## 1. The model

| Layer | Default | Allowed (minimal, per-app) |
|---|---|---|
| **Filesystem** | deny ALL host paths | the app's own data dir + explicitly granted paths |
| **Memory** | own address space only | no `ptrace`, `process_vm_readv/writev`, `/proc/PID/mem`, `memfd`+`execve`, `/dev/mem`, `/proc/kcore` |
| **Network** | deny all | granted destination port, or none |
| **Devices** (`/dev`) | deny all | only what is needed (`dri`, `input`); hard-deny `/dev/mem`, `/dev/kmem`, `/dev/sd*`, `/dev/nvme*` |
| **IPC** | socket paths deny-all, inherited from the filesystem layer | the granted socket paths; abstract unix sockets and signals are scoped to the app only under `paranoid` (see §9) |
| **Execution** | the app binary + legitimate JIT | no `sh`/`python -c`/`node -e` spawn, no memfd exec. **`dlopen` of a library the app wrote itself is NOT closed** - measured, see §9 |
| **Capabilities** | drop all | none |
| **Privilege** | `NoNewPrivs` | none |
| **Namespaces** | deny `unshare`/`mount` | none |
| **Launch state** | inherited descriptors and credentials scrubbed | stdio only |

An application gets **its own memory, its own allowed files, and nothing
else.**

---

## 2. What carries each layer

The boundary is not one mechanism. Each layer is the kernel primitive
that is actually authoritative for that layer, because a policy enforced
at the wrong layer is a policy with a hole in it.

| Layer | Mechanism | Where |
|---|---|---|
| Filesystem, devices | **Landlock** ruleset, default-deny | `obsidian_harden.c` |
| Network (TCP ports) | **Landlock** network rules, ABI 4+ | `obsidian_harden.c` |
| Network (address families) | **seccomp-bpf** on `socket`/`socketpair` argument 0 | `obsidian_harden.c` |
| IPC scoping (paranoid only) | **Landlock** `scoped`, ABI 6+ | `obsidian_harden.c` |
| Memory, namespaces, kernel surfaces | **seccomp-bpf** deny list, hand-assembled | `obsidian_harden.c` |
| Execution | **Landlock** `EXECUTE` right + seccomp on `execveat(AT_EMPTY_PATH)` | `obsidian_harden.c` |
| Capabilities | `PR_CAPBSET_DROP`, `PR_CAP_AMBIENT_CLEAR_ALL`, `capset` | `obsidian_harden.c` |
| Privilege | `PR_SET_NO_NEW_PRIVS` | `obsidian_harden.c` |
| Launch state, descriptors | `close_range(3, ~0)` | `obsidian_harden.c` |
| Launch state, environment | `unset` of named and pattern-matched credentials | `obsidian-launch` |
| Host identity, metadata | the existing six layers | unchanged |

The enforcer links **no external library**. The seccomp program is
assembled instruction by instruction in C and Landlock is reached through
raw syscalls. That is not stylistic: `seccomp_enforcer` needs
`libseccomp-dev` and silently degrades when it is missing, and a boundary
that disappears when a package is absent is not a boundary.

---

## 3. Why the enumeration exists

The installer already walks this machine's hardware to decide what to
spoof. The same discipline produces the allow-list, and it runs in this
order:

```
enumerate the host  ->  observe what the app really touches
                    ->  grant exactly that
                    ->  deny everything else
```

That is what the three profile commands are:

```sh
obsidian --profile learn firefox     # run it, record every access
obsidian --profile build firefox     # collapse the recording into a profile
OBSIDIAN_HARDEN=1 obsidian firefox   # run it inside the boundary
```

`learn` loads `obsidian_learn.so` ahead of the spoofing libraries. It
hooks `open`, `openat`, `fopen`, `opendir`, `execve`, `dlopen`, `socket`
and `connect`, records what was asked for, and hands every call straight
on to the next definition of the same symbol. It never blocks anything
and never alters a return value, so an application under learning behaves
exactly as it does without it.

`build` collapses the recording to the smallest set of grants that still
contains every observed access — one grant per subsystem, not one per
file — drops everything the base allow-list already covers, and flags
every interpreter the application started as a line you have to decide
about by hand rather than granting silently.

This is the same reason the metadata layer reached its result without breaking
applications: measure the real thing, then write the rule.

**Learn first, then harden.** A boundary built from a guess breaks
applications. A boundary built from a recording of what the application
actually did does not.

---

## 4. Measured, on real hardware

`obsidian --harden-test` runs the same probe twice through the same
launcher — once as it ships, once with `OBSIDIAN_HARDEN=1` — and prints
the kernel's answer to each of 51 attempts, side by side. It reports
what the kernel did, not what the policy intended. Where those disagree,
the kernel is right and this document is wrong.

Result on the development machine, Linux 6.1, Landlock ABI 2, no
`libseccomp` present (so the older `seccomp_enforcer` was not even in the
chain — every closure below came from the new enforcer alone):

```
  surfaces the boundary closed                  29
  surfaces already shut by the base launcher    18
  surfaces still open under the boundary         1
  application capabilities broken                0
  present but unreachable                        2
  inconclusive on this machine                   1
```

The one still open is `execute a library it wrote itself`: the app
writes a file into a directory it was granted for writing, then maps it
`PROT_EXEC`. Neither Landlock nor seccomp can refuse that without
refusing every shared library in the process. It is described in full in
section 7 and audited in `docs/CONFORMANCE.md`.

Closed, measured, one line each: read the host SSH keys · read every
system log · read the kernel and initramfs · read the kernel symbol table
· read the kernel log device · map the physical memory layout · spawn a
shell · spawn python · spawn node · spawn perl · execute code that has no
file · attach a debugger to another process · read another process's
memory · write another process's memory · open `/proc/PID/mem` of a peer
· open a performance counter · steal a descriptor from a peer · read the
kernel ring buffer · open an io_uring ring · reach the kernel keyring ·
set the system clock · create a user namespace · enter another namespace
· open an IPv4 socket · open an IPv6 socket · query the kernel over
netlink · reach a routable address · regain privilege through setuid ·
run without a syscall filter.

Still working afterwards, and checked every run as positive controls,
because a boundary that breaks the application has not secured anything:
read its own shared libraries · read `/dev/urandom` · write in its own
home · write in `/tmp` · **JIT-compile in anonymous memory** · open a
unix socket for the display server.

"Present but unreachable" is the capability bounding set. Clearing it
needs `CAP_SETPCAP`, and once the launcher has mapped the process to an
ordinary user it holds no capability at all (`CapEff 0`). Nothing in the
set can be reached from there — but it is reported rather than hidden,
because a report that quietly drops its own awkward line is marketing.

---

## 5. Using it

### Off (the default)

```sh
obsidian firefox
```

Nothing in this document applies. Identical to before.

### Look before you leap

```sh
obsidian --harden-plan firefox
```

Prints the exact boundary that would be applied — every grant, the
Landlock ABI, the network decision, the hard-deny count — and enforces
nothing.

### On

```sh
OBSIDIAN_HARDEN=1 obsidian firefox        # strict
OBSIDIAN_HARDEN=paranoid obsidian firefox # also deny memfd, scope IPC
```

### Granting, without a profile

```sh
OBSIDIAN_HARDEN=1 \
OBSIDIAN_ALLOW_PATHS_RW="$HOME/Documents" \
OBSIDIAN_ALLOW_NET=tcp:443 \
  obsidian someapp
```

| Variable | Effect |
|---|---|
| `OBSIDIAN_ALLOW_PATHS_RO` | colon-separated paths, read |
| `OBSIDIAN_ALLOW_PATHS_RW` | colon-separated paths, read and write |
| `OBSIDIAN_ALLOW_PATHS_RX` | colon-separated paths, read and execute |
| `OBSIDIAN_ALLOW_EXEC` | grant execute on a binary |
| `OBSIDIAN_ALLOW_DEV` | grant a device node |
| `OBSIDIAN_ALLOW_NET` | `tcp:443`, `bind:8080`, `all`, or unset for none |
| `OBSIDIAN_ALLOW_NESTED_NS` | let the app build its own namespaces |
| `OBSIDIAN_DENY_PATHS` | add to the hard-deny set |
| `OBSIDIAN_HARDEN_PROFILE` | use a specific profile file |
| `OBSIDIAN_HARDEN_PROFILE_DATA` | profile text itself, set by the launcher so the profile survives the home tmpfs; wins over the path |
| `OBSIDIAN_HARDEN_FAIL_CLOSED` | refuse to start if any layer fails to load |
| `OBSIDIAN_SCOPE_IPC` | `1` to scope abstract sockets and signals; default `0` in `strict`, `1` in `paranoid` |
| `OBSIDIAN_HARDEN_KEEP_FDS` | keep inherited descriptors |
| `OBSIDIAN_HARDEN_NO_DEFAULTS` | drop the base allow-list; grant everything by hand |

### Profile file format

`~/.config/obsidian/profiles/<app>.profile`, or `/etc/obsidian/profiles/`
for a system-wide one. The user path wins.

```
allow.ro=/usr/share/myapp
allow.rw=~/Documents
allow.rx=/opt/myapp
allow.dev=/dev/dri
allow.exec=/opt/myapp/helper
allow.net=tcp:443
deny=/etc/private
opt.scope_ipc=1
opt.nested_ns=1
opt.memfd=deny
opt.hard_fail=1
opt.verbose=1
```

`~` and `$VAR` are expanded.

### How the profile reaches the enforcer

The launcher mounts a fresh tmpfs over `/home` - that is what keeps real
user data out of the sandbox - so by the time the enforcer runs, a
profile stored under the real home is no longer reachable by path. The
launcher therefore reads the file *before* entering the sandbox and
passes its text down in `OBSIDIAN_HARDEN_PROFILE_DATA`, which the
enforcer parses in preference to `OBSIDIAN_HARDEN_PROFILE`.

This is worth stating because the failure it replaces was silent: the
enforcer would warn that the profile could not be read, fall back to its
own defaults, and run the application inside a boundary the user
believed had been tailored to it. `verify-installer.sh` now asserts both
halves of the hand-off so it cannot regress quietly.

---

## 6. When an application breaks

It will, the first time, for something. The boundary is default-deny and
your recording did not cover every code path. This is the expected
workflow, not a defect.

| Symptom | Cause | Fix |
|---|---|---|
| Exits immediately, `EACCES` on its own binary | the target was not resolvable on `PATH` | `OBSIDIAN_ALLOW_EXEC=/full/path` |
| Blank window, no display | X11 client, abstract socket scoped away | `OBSIDIAN_SCOPE_IPC=0` |
| Chromium/Electron dies at startup | its zygote wants its own namespaces | `OBSIDIAN_ALLOW_NESTED_NS=1`, or `--no-sandbox` |
| No network, no error | default-deny network | `OBSIDIAN_ALLOW_NET=tcp:443` |
| Cannot open your files | only the app's own dirs are granted | `OBSIDIAN_ALLOW_PATHS_RW=$HOME/Documents` |
| A helper tool fails to launch | `/usr/bin` has no execute right | `OBSIDIAN_ALLOW_EXEC=/usr/bin/thattool` |
| No sound | `/dev/snd` is not in the base list | `OBSIDIAN_ALLOW_DEV=/dev/snd` |

`OBSIDIAN_HARDEN_VERBOSE=1` prints every grant as it is applied, which is
usually enough to see which one is missing.

---

## 7. What this does **not** close

This section is the reason the rest of the document is worth reading.

**Side channels.** Cache timing, branch prediction, speculative
execution, power draw, acoustics, electromagnetic emission. None of these
are syscalls. No kernel policy sees them, so none of them appear in the
measurement above and none of them are closed. Two processes on one
core share microarchitecture, and the boundary here is drawn in kernel
objects, which is a layer above where that sharing happens. This is a
real, permanent gap and it is not solvable at this layer by anyone.

**Silicon below the operating system.** A management engine, a platform
security processor, signed firmware, microcode. All of it runs
underneath the kernel that enforces everything above. A policy written in
kernel objects cannot reach what the kernel itself runs on top of. If
that layer is hostile, nothing in this repository is relevant.

**The host itself.** Everything here confines the application. It does
not confine the machine's owner, or code already running as another user,
or anything that was already root. That was never the boundary being
drawn, and a tool that implied otherwise would be lying.

**Anything above the syscall interface.** An application that is
*permitted* to read your documents and *permitted* to reach port 443 can
send your documents to port 443. The boundary decides what an application
can touch. It does not decide what it does with what you gave it. That is
what "minimal grant" means and why the grant list is worth reading before
you accept it.

**Whatever is not measured.** The report covers 51 attempts. A surface
that is not in that list is not a surface that is proven closed — it is
one nobody has looked at yet. If you find one, it belongs in
`obsidian_hardenprobe.c`, where the next person's report will include it.

**Kernel bugs.** Landlock and seccomp are code. Code has defects. This
raises the cost of an escape; it does not make one impossible.

**Code the application wrote itself, loaded with `dlopen`.** The strict
boundary model asks for "no untrusted `dlopen`". This does not deliver
it, and the report now says so out loud rather than leaving the row
blank. Landlock checks its `EXECUTE` right when a file is opened *to be
executed*; a shared library is opened `O_RDONLY` and then mapped
`PROT_EXEC`, so any directory granted for writing is also a directory
the application can author code in and load. seccomp cannot rescue it
either: at `mmap` time it sees `PROT_EXEC` and a descriptor number,
never the path behind it, and refusing every file-backed executable
mapping would refuse every shared library in the process.

Closing it needs an LSM that is path-aware at mapping time - SELinux
`execmod`, or an AppArmor `m` rule - which is a different mechanism than
the two this enforcer is built on. What is left is narrowing the grant:
an application with no writable directory it can also read has nowhere
to stage the library, so the smaller the RW grant, the smaller this hole
gets. `obsidian --harden-test` measures it as **`execute a library it
wrote itself`** and reports it as still open, on purpose.

---

## 8. Known compatibility costs

Honest list of what the boundary is expected to break, so you find out
here rather than in a crash:

- **X11 clients** if IPC scoping is on. It is **off in `strict`** for
  exactly this reason and only on in `paranoid`; `OBSIDIAN_SCOPE_IPC=1`
  turns it on deliberately. Every X11 client reaches its display over an
  abstract unix socket, and some session buses are abstract too.
- **Chromium and Electron zygotes**, which build their own user
  namespaces. `OBSIDIAN_ALLOW_NESTED_NS=1` gives that back, at the cost
  of the namespace layer.
- **`xdg-open` and desktop integration**, which shell out to helpers in
  `/usr/bin`. Grant each helper explicitly or accept that "open in
  browser" stops working.
- **Anything that shells out.** That is the point of the execution layer,
  and it is also the most common thing to break.
- **`/proc/self/oom_score_adj`** and similar self-tuning writes: `/proc`
  is granted read-only. Usually non-fatal.
- **Kernels older than 5.13** have no Landlock. The syscall, capability,
  privilege and launch-state layers still apply; the filesystem, device
  and network-port layers do not. The enforcer says so on stderr rather
  than pretending.
