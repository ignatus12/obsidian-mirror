# The Obsidian Mirror Project

### Real metadata privacy protection against application metadata leaks

Every program you run can read who you are. Not your files — your **machine**.
Your permanent install UUID, your motherboard serial, your CPU stepping, your monitor's
serial number, your exact RAM size, your timezone, your username, your kernel build string.
None of that requires a permission prompt. None of it is logged. All of it is stable across
reboots, reinstalls of the app, VPNs and private browsing windows.

Obsidian Mirror is a single shell script that installs a host ↔ application isolation layer
on Alpine Linux. After it runs, you launch anything through it:

```sh
obsidian firefox
```

…and the application sees a coherent, plausible, **different** computer.

```sh
obsidian --test
```

…and you get a four-section report telling you exactly which identifiers were hidden, which
were not, and **why not**.

---

## Table of contents

- [Why this exists](#why-this-exists)
- [Measured proof: Flatpak vs Obsidian Mirror](#measured-proof-flatpak-vs-obsidian-mirror)
- [What it actually does](#what-it-actually-does)
- [Install](#install)
- [Use](#use)
- [The audit](#the-audit)
- [What it does NOT do](#what-it-does-not-do)
- [Reproduce every number on this page](#reproduce-every-number-on-this-page)
- [FAQ](#faq)

---

## Why this exists

Ask most Linux users how an application identifies their machine and you will hear "cookies"
or "IP address". Those are the network layer. The layer underneath is worse, because it is
**stable**:

| What the app reads | Where it comes from | Changes when? |
|---|---|---|
| `/etc/machine-id` | generated once at OS install | never |
| DMI product UUID | burned into the motherboard | never |
| Disk serial, WWID | the drive's firmware | never |
| Monitor EDID | the panel's EEPROM (serial + manufacture week) | never |
| TPM endorsement key | the security chip | never — that is its purpose |
| CPU model, cache, flags | the silicon | never |
| Installed font list | your machine's history | rarely |
| Timezone | you | rarely |

Clear your cookies, change your IP, reinstall the app — every one of those survives. Combined,
they are far more than enough to re-identify a single machine out of a population of millions.

There is no permission prompt for any of it. There is no equivalent of "Allow location access?"
for "Allow this text editor to read your motherboard serial number?"

Obsidian Mirror is an attempt to add one, retroactively, at the operating-system level.

---

## Measured proof: Flatpak vs Obsidian Mirror

### Read this part first

**Flatpak is not the villain here, and this is not a hit piece.** Flatpak is a *security*
sandbox and a good one: it controls what an application can *do* to your files, your devices
and your session, and it does that through a genuinely well-engineered design (`pivot_root`,
portals, a per-app data store, D-Bus filtering). Nothing below contradicts that.

The problem is a mismatch between what Flatpak protects and what people believe it protects.
"Sandboxed" gets read as "anonymous". It is not. Flatpak's threat model is *containment*, not
*unlinkability* — and its documentation is honest about the mechanism, even if the marketing
around sandboxing in general is not.

So the claim being tested here is narrow and falsifiable:

> **A Flatpak sandbox passes the host's stable hardware and installation identity through to
> the application, by design and by default.**

Here is the measurement.

### Method in one paragraph

One machine, one session. The same 166-point metadata probe (`evidence/obsidian-probe.sh`)
was executed in four environments: bare on the host, inside a real Flatpak sandbox with
default permissions, inside a real Flatpak sandbox with the permission set a typical desktop
app requests, and inside Obsidian Mirror. Raw output for all four is in
[`evidence/`](evidence/). Full method and exact commands:
[`docs/METHODOLOGY.md`](docs/METHODOLOGY.md).

Software: Flatpak **1.16.6**, bubblewrap **0.11.0**, runtime `org.freedesktop.Platform//24.08`,
Obsidian Mirror **v2.0**.

### Headline

Of **82** identifiers this test machine actually exposes with a non-empty value (network layer
excluded, since neither tool claims it; zero-valued counts excluded, since a count of zero
devices cannot identify anybody):

| Environment | Identical to host | Changed | Altered |
|---|---|---|---|
| Host (control) | 82 / 82 | 0 | 0 % |
| **Flatpak, default permissions** | **49 / 82** | 33 | 40 % |
| **Flatpak, typical app permissions** | **47 / 82** | 35 | 43 % |
| **Obsidian Mirror** | **24 / 82** | 58 | 71 % |

Percentages are a blunt instrument, though. What matters is *which* identifiers.

### The identifiers that actually track you

| Identifier | Host (real) | Flatpak | Obsidian Mirror |
|---|---|---|---|
| `/etc/machine-id` — permanent install UUID | `67549745dd1a4564…` | 🔴 `67549745dd1a4564…` | 🟢 `7f96d11360c37262…` |
| Kernel `boot_id` — session ID | `2bb79165-136a-4b63…` | 🔴 `2bb79165-136a-4b63…` | 🟢 `f8f9854f-db84-b9a0…` |
| Hostname | `e2b.local` | 🔴 `e2b.local` | 🟢 `workstation-0f6678` |
| `uname` nodename | `e2b.local` | 🔴 `e2b.local` | 🟢 `workstation-0f6678` |
| Login name | `user` | 🔴 `user` | 🟢 `guest` |
| `$HOME` | `/home/user` | 🔴 `/home/user` | 🟢 `/home/guest` |
| Kernel release | `6.1.158+` | 🔴 `6.1.158+` | 🟢 `6.5.6-300.fc39.x86_64` |
| `/proc/version` build string | `Linux version 6.1.158+ …` | 🔴 identical | 🟢 matching fake distro |
| `/proc/cmdline` (incl. root UUID) | `clocksource=kvm-clock …` | 🔴 identical | 🟢 synthetic |
| CPU model | `Intel(R) Xeon(R) @ 2.60GHz` | 🔴 identical | 🟢 `Intel(R) Core(TM) i5-8250U` |
| BogoMIPS | `5200.05` | 🔴 `5200.05` | 🟢 `3600.00` |
| CPU cache | `55296 KB` | 🔴 `55296 KB` | 🟢 `6144 KB` |
| CPU feature-flag count | `106` | 🔴 `106` | 🟢 `47` |
| Per-core sysfs topology | `2` | 🔴 `2` | 🟢 `0` (masked) |
| RAM total | `2032608 kB` | 🔴 `2032608 kB` | 🟢 `8192000 kB` |
| Block device list | `loop0…loop7 vda` | 🔴 identical | 🟢 `(none)` |
| Boot timestamp | `1785480903` | 🔴 `1785480903` | 🟢 randomised |
| Uptime | `151` | 🔴 `151` | 🟢 randomised |
| Timezone | `UTC` | 🔴 `UTC` | 🟢 forced UTC |
| File mtime **nanoseconds** | `506246762` | 🔴 `118246762` (full resolution) | 🟢 `0` |

🔴 = the application receives the real host value. 🟢 = it receives a spoofed or masked value.

**34 identifiers** are leaked by Flatpak and covered by Obsidian Mirror. The full list is
generated from the raw data in [`evidence/RESULTS.md`](evidence/RESULTS.md).

### The single most important line

```
$ cat /etc/machine-id
67549745dd1a4564be928e47dca271fd

$ flatpak run --command=sh org.freedesktop.Platform//24.08 -c 'cat /etc/machine-id'
67549745dd1a4564be928e47dca271fd        # ← identical

$ obsidian cat /etc/machine-id
21f69f259014ba3307f8e49d6b873fbf        # ← new every launch
```

And from the sandbox's own mount table, captured inside the running Flatpak sandbox
([`evidence/flatpak-sandbox-mountinfo.txt`](evidence/flatpak-sandbox-mountinfo.txt)):

```
131 110 254:0 /etc/machine-id /etc/machine-id ro,nosuid,nodev,relatime - ext4 /dev/root rw
```

That is not a copy and not a synthetic value. It is the host's real file, on the host's real
root filesystem, bind-mounted into the sandbox read-only. This is **documented, intended
behaviour** — Flatpak's own wiki lists "machine-id bind mounted from host" in the sandbox
description.

`/etc/machine-id` is a 128-bit value written once when the operating system is installed and
never changed afterwards. Every Flatpak application on your system can read the same one. It
is a hardware-grade tracking cookie that no permission toggle in the Flatpak permission model
covers, that survives clearing every cache, and that is identical across every "isolated" app.

### `/sys` is the host's `/sys`

Also from the live sandbox mount table:

```
/sys/block     sysfs
/sys/bus       sysfs
/sys/class     sysfs
/sys/dev       sysfs
/sys/devices   sysfs
```

Not tmpfs. Not a filtered view. Five read-only bind mounts of the real kernel sysfs. Measured
consequence on the test machine:

| | host | Flatpak | Obsidian Mirror |
|---|---|---|---|
| `/sys/class` subsystems | 31 | **31** | 31 (present but emptied) |
| `/sys/block` contents | `loop0…loop7 vda` | **identical** | *empty* |
| `/sys/devices/system/cpu` entries | 16 | **16** | *0* |
| `/sys/class/net/eth0/address` | `02:fc:00:00:00:05` | **identical** | out of scope (see below) |

On a physical machine, that same passthrough covers `/sys/class/dmi/id/*` (system, board,
chassis and BIOS serials, product UUID), `/sys/class/drm/*/edid` (monitor serial and
manufacture date), `/sys/class/power_supply/BAT*/serial_number`, `/sys/class/tpm/*` and every
disk's `device/serial` and `wwid`.

**This test machine is a VM with no DMI, no TPM, no battery and no discrete GPU**, so those
specific fields read `(none)` in all four columns and are honestly marked "absent on test
host" in the raw results. The mechanism is proven by the mount table; the specific values were
not measurable here. That distinction is kept everywhere in this repository — see
[`docs/METHODOLOGY.md`](docs/METHODOLOGY.md#5-what-this-machine-could-not-test).

### Where Flatpak wins

Nine identifiers go the other way — Flatpak covers them and Obsidian Mirror does not:

| Identifier | Why Flatpak wins |
|---|---|
| Root filesystem source, host distro release files, `/opt` visibility | Flatpak does a real `pivot_root` onto a private tmpfs. Obsidian Mirror deliberately does not, because pivoting breaks applications that read their own installation directory. This is documented as a known limitation in [`docs/COVERAGE.md`](docs/COVERAGE.md#52-inherent-to-sharing-the-host) |
| Font count / family set | The Flatpak runtime ships its own fonts, so the set is runtime-constant rather than host-specific. Genuinely better for this one vector. Obsidian Mirror instead pins `FONTCONFIG_FILE` so the enumeration is deterministic and drops per-user fonts, which is weaker |
| `$SHELL`, `/etc/localtime` symlink form | Runtime defaults happen to differ from the host's |

Obsidian Mirror's own audit reports these as gaps, with reasons, without being asked to. That
is the standard this project holds itself to, and Flatpak deserves the same fairness.

### The honest conclusion

Flatpak and Obsidian Mirror solve **different problems**:

|  | Flatpak | Obsidian Mirror |
|---|---|---|
| Threat model | A malicious or careless app damaging or exfiltrating **your data** | An app **identifying your machine** |
| Protects | Files, devices, session services, syscalls | Hardware and installation identity |
| Filesystem | `pivot_root` onto private tmpfs — strong | mount masks only — weaker |
| Hardware identity | passthrough by design | spoofed / masked |
| Machine-id | host's, bind-mounted | randomised per launch |
| Permission model | rich (portals, per-app grants) | none — it is not an access-control tool |
| Network | per-app toggle | **out of scope entirely** |

If you install a Flatpak app expecting containment, you get containment. If you install it
expecting anonymity, **you do not get anonymity**, and nothing in the installation flow tells
you that. That gap between expectation and delivery is the thing worth naming — not Flatpak
itself.

They are not mutually exclusive in principle. Composing them has not been tested and is not
currently supported; see [FAQ](#faq).

---

## What it actually does

Six independent layers. Most identifiers are covered by more than one, which is what makes the
layer hard to peel back.

| # | Layer | Mechanism | Defeats |
|---|---|---|---|
| 1 | **libc interposition** | `LD_PRELOAD` × 3 hook libraries | `uname()`, `sysinfo()`, `getpwuid()`, `stat`/`statx`, `glGetString()`, `eglQueryString()`, `connect()` |
| 2 | **Mount namespace** | ~65 bind mounts and tmpfs masks over `/proc`, `/sys`, `/etc`, `/dev` | direct file reads that bypass libc |
| 3 | **UTS / PID / IPC / user namespaces** | `unshare` | hostname, process table, SysV IPC, credentials |
| 4 | **seccomp-bpf** | 24-rule filter | `ptrace`, `perf_event_open`, `iopl`, module loading, and the self-escape syscalls |
| 5 | **Environment + affinity clamp** | export engine, `taskset`, `sched_getaffinity()` hook | env-var identity leaks, core-count fingerprinting |
| 6 | **Fontconfig pinning** | private `fonts.conf` | installed-font-set fingerprinting |

**The Top-10 engine.** Every launch picks one of ten complete, internally coherent Linux
identities at random — Ubuntu 22.04, Debian 12, Fedora 39, Arch, Mint, Pop!_OS, Manjaro,
openSUSE Tumbleweed, Alpine 3.19, RHEL 9.3. Kernel release, `/proc/version` build string, boot
cmdline and `os-release` always agree with each other, because a mismatched profile is itself
a fingerprint.

**The hardware scanner.** At install time it reads your real hardware and writes a per-host
manifest of spoof and mask rules to `/etc/obsidian/hw-manifest.conf` — including mapping your
real GPU PCI ID to a *plausible* Mesa string rather than a fixed lie. Any `/sys/class/*`
subsystem it does not recognise is masked by default (fail-closed).

Full detail: [`docs/COVERAGE.md`](docs/COVERAGE.md).

---

## Install

Target: **Alpine Linux**, any release, x86_64 or aarch64, as root. It also installs on glibc
distributions when the toolchain is present.

```sh
wget https://raw.githubusercontent.com/ignatus12/obsidian-mirror/main/Universal-Obsidian-installer-script.sh
sudo sh Universal-Obsidian-installer-script.sh
```

One file, ~150 KB, no network access required at install time, no dependencies to clone. Every
C source, shell stage, fontconfig file and this documentation are embedded in it as
here-documents. It installs the toolchain (`apk`), unpacks and compiles the sources, scans your
hardware, installs the `obsidian` command and runs a seven-point self-test.

```sh
sudo sh Universal-Obsidian-installer-script.sh --uninstall   # complete removal
sudo sh Universal-Obsidian-installer-script.sh --help
```

If `libseccomp-dev` is unavailable, layer 4 is skipped with a warning and the other five still
install — the script degrades, it does not abort.

---

## Use

```sh
obsidian firefox
obsidian curl https://example.com
obsidian sh -c 'hostname; uname -r; id; cat /etc/machine-id'
```

Runtime switches. **Every one defaults to the setting that does not break applications** — that
is a hard design rule of this project, and `obsidian --test` section 4 verifies it on every run.

| Variable | Default | Effect |
|---|---|---|
| `OBSIDIAN_GPU_MODE` | `compat` | `strict` masks `/dev/dri` and `/sys/class/drm` completely — zero GPU fingerprint, software rendering only |
| `OBSIDIAN_GL_EXTENSIONS` | blanked | `preserve` passes the real GL extension list through, if an app refuses to start without it |
| `OBSIDIAN_ALLOW_SYSTEM_BUS` | blocked | `1` permits `connect()` to the D-Bus system bus |
| `OBSIDIAN_VERBOSE` | off | `1` logs every blocked IPC connection |

```sh
OBSIDIAN_GPU_MODE=strict obsidian curl https://example.com
```

Why is the strongest GPU setting not the default? Because Mesa selects its driver by reading
`/sys/class/drm/card0/device/vendor`. Mask it and hardware acceleration silently collapses to
software rendering, or the app fails to create a GL context at all. The reasoning is written
out in [`docs/COVERAGE.md` §4](docs/COVERAGE.md#4-why-devdri-is-still-reachable-by-default).

---

## The audit

```sh
obsidian --test
```

Runs the 166-point probe twice — once natively, once through the isolation layer — and prints
four sections:

1. **Protected metadata summary** — per-category graded / protected / coverage table.
2. **Real vs protected** — every item side by side: what the host is, what the app is given.
3. **Host metadata NOT protected — and why** — every remaining item with a written reason and,
   where one exists, the switch that covers it.
4. **Application compatibility** — live checks that the layer did not break the thing it wraps:
   argv integrity, exit-status propagation, stdin passthrough, Wayland socket reachability, GPU
   render node.

A real report is checked in at
[`evidence/sample-audit-report.txt`](evidence/sample-audit-report.txt). Section 3 is the point
of the tool. If you only read one part, read that one.

---

## What it does NOT do

Put here, near the top, not buried in an appendix.

**Out of scope by design — the network layer.** IP addresses, routing, DNS, real MAC addresses
read over netlink, TLS/JA3 fingerprints, HTTP headers, NTP. `getifaddrs()` is hooked, but
anything using netlink directly — `ip`, `ss`, most language runtimes — sees the truth. **Pair
this with a VPN or a network namespace.**

**Inherent to sharing the host.** Wayland passthrough means `wl_output` still reports your real
resolution, refresh rate and monitor make. PulseAudio/PipeWire passthrough means real device
names. In default GPU mode, Vulkan and DRM ioctls see the real adapter model. There is no
`pivot_root`, so `/root`, `/var`, `/srv` and other users' files remain visible subject to normal
permissions (`/home` *is* replaced with tmpfs).

**Cannot be fixed at this layer.** The `CPUID` instruction executes in userspace and returns the
real CPU — only a hypervisor can mask it. `RDTSC` timing and clock skew are physical. Raw
syscalls bypass `LD_PRELOAD` entirely, so Go binaries, static binaries and hand-written assembly
see the real kernel release (mount-level spoofs still apply to them). The loader drops
`LD_PRELOAD` for setuid binaries.

**Detectability.** An application *can* tell it is being mirrored: `LD_PRELOAD` is in
`/proc/self/environ`, `OBSIDIAN_*` variables are exported, `/proc/self/mountinfo` lists every
bind mount, `/opt/obsidian` exists, and the PID namespace is suspiciously empty.

> **Obsidian Mirror makes you anonymous, not invisible.**

Against passive fingerprinting — the actual threat model for application metadata leaks — the
layer is strong. Against an adversary specifically probing for a sandbox, it is detectable, and
`obsidian --test` will tell you so in its own report.

---

## Reproduce every number on this page

Nothing here is hand-typed. The tables are generated from raw probe output that is checked in.

```sh
python3 evidence/compare.py            # regenerate the comparison tables
python3 evidence/compare.py --check    # verify the four datasets are aligned
```

To re-run the measurement yourself from scratch, including the Flatpak side:
[`docs/METHODOLOGY.md`](docs/METHODOLOGY.md). It is about ten commands. If your numbers differ
from ours, that is a finding — please open an issue with your `evidence/` output attached.

Repository layout:

```
Universal-Obsidian-installer-script.sh   the whole thing, one file
docs/COVERAGE.md                         what is and is not protected, in detail
docs/FLATPAK-COMPARISON.md               the full deep dive
docs/METHODOLOGY.md                      how to reproduce the measurement
evidence/probe-*.tsv                     raw probe output, four environments
evidence/flatpak-sandbox-mountinfo.txt   mount table captured inside a live Flatpak sandbox
evidence/sample-audit-report.txt         a real `obsidian --test` run
evidence/compare.py                      generates the tables from the raw data
src/*.c                                  the hook libraries, unbundled for review
```

---

## FAQ

**Is this a replacement for Flatpak?**
No. Different threat models — see the table above. Flatpak controls what an app can *do*;
Obsidian Mirror controls what an app can *learn*.

**Can I use both together?**
Not currently. Both build namespaces, and nesting them has not been tested. In principle the
right architecture is one sandbox doing both jobs; this project exists partly to show what that
sandbox would have to cover.

**Does it slow applications down?**
The hooks are a handful of string operations on calls that were already syscalls. The mount
setup happens once at launch. There is no measurable steady-state cost. The one real
performance decision is `OBSIDIAN_GPU_MODE=strict`, which trades hardware acceleration for a
clean GPU fingerprint, and is therefore opt-in.

**Will it break my application?**
That is the one thing the project treats as non-negotiable. Every privacy fix that conflicted
with application behaviour became an opt-in switch instead of a default, and `obsidian --test`
section 4 runs live compatibility checks — argv integrity, exit status, stdin, Wayland socket,
GPU node — on every audit. If any of those reports `BROKEN`, that is a bug, and an issue with
the output attached is the most useful thing you can send.

**Why Alpine?**
It was the development target, and musl plus busybox is the harshest environment for this kind
of interposition — if it works there it tends to work anywhere. The installer runs on glibc
distributions too when a toolchain is present.

**Why does the audit sometimes report the distro as "leaked"?**
Because the OS identity is drawn at random from ten profiles on every launch, so roughly one
run in ten happens to draw your real distribution. The audit prints exactly that explanation
next to the result rather than hiding it.

**Is this production-ready?**
It is a working tool that installs, self-tests and audits itself, and it has been exercised
end to end. It has not been independently reviewed, and the honest position is that a privacy
tool nobody has audited should be treated as a strong prototype. Read
[`docs/COVERAGE.md`](docs/COVERAGE.md) §5 before relying on it for anything that matters.

---

## Contributing

The most valuable contributions, in order:

1. **Run `obsidian --test` on real hardware** — especially a physical laptop with DMI, a TPM,
   a battery and a real GPU — and open an issue with the section 3 output. This test machine
   was a VM and could not measure those fields.
2. **Report anything that breaks.** A `BROKEN` line in section 4 outranks every feature request.
3. **Challenge the Flatpak measurement.** The raw data and the exact commands are checked in
   specifically so that someone can prove them wrong.
4. Never strip section 3 or `docs/COVERAGE.md` §5 to make the tool sound stronger than it is.

> A tool that overstates itself is worse than no tool.

That sentence is the design rule of this project, and it applies to this README as much as to
the code.
