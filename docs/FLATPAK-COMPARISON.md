# Deep dive: what a Flatpak sandbox tells an application about you

*A measured comparison against Obsidian Mirror. All figures produced on one machine in one
session; raw data in [`../evidence/`](../evidence/).*

> **Context:** this page measures *one* tool (Flatpak) to prove the mechanism. The broader point — that the privacy tools people actually trust (**VPN, Tor, Tor Browser**) don't close this vector either — is in [`METADATA-VS-POPULAR-PRIVACY-TOOLS.md`](METADATA-VS-POPULAR-PRIVACY-TOOLS.md).

---

## 0. The claim being tested

> A Flatpak sandbox passes the host's stable hardware and installation identity through to the
> application, by design and by default.

Narrow, falsifiable, and — as it turns out — true. What follows is the evidence, and then the
part most critiques skip: where Flatpak is *better* than the tool making the accusation.

**What is not being claimed:** that Flatpak is insecure, badly built, or dishonest. Flatpak's
own wiki documents the machine-id bind mount and the `/sys` bind mounts in plain text. Nobody
is hiding anything. The problem is that "sandboxed" has come to mean "private" in ordinary
usage, and for metadata it does not.

---

## 1. What Flatpak actually builds

Flatpak constructs its sandbox with `bubblewrap`. From Flatpak's own sandbox documentation, and
confirmed against a live sandbox on the test machine:

- `/` is a private tmpfs, **`pivot_root`ed** — all host mounts are genuinely unmounted from the
  namespace. This is stronger filesystem isolation than Obsidian Mirror achieves.
- `/usr` is the runtime; `/app` is the application.
- `/proc` is a fresh procfs; the PID namespace hides other processes.
- `/dev` is a minimal synthetic devtmpfs: `full`, `null`, `random`, `urandom`, `tty`, `zero`.
- **`/sys` is a read-only bind mount of the host `/sys`.**
- `/etc/passwd` and `/etc/group` are synthesised (good), but **`/etc/machine-id` is bind-mounted
  from the host** (not good, for this purpose).
- Host fonts are bind-mounted to `/run/host/fonts`.
- The D-Bus session bus is proxied and filtered by `xdg-dbus-proxy`.
- A seccomp filter is applied.

The design is coherent for its purpose. Its purpose is not anonymity.

### The mount table, captured from inside a running sandbox

`evidence/flatpak-sandbox-mountinfo.txt`, filtered:

```
/sys/block      sysfs
/sys/bus        sysfs
/sys/class      sysfs
/sys/dev        sysfs
/sys/devices    sysfs
/etc/machine-id ext4 /dev/root
/etc/passwd     tmpfs
/etc/group      tmpfs
/proc           proc
/dev            tmpfs
/run/host/fonts ext4 /dev/root
/usr            ext4 /dev/root
```

Note the filesystem types. `/etc/passwd` is `tmpfs` — synthesised, discarded at exit.
`/etc/machine-id` is `ext4 /dev/root` — the host's real file on the host's real disk. Five
separate `sysfs` mounts. That single column is the whole argument.

---

## 2. `/etc/machine-id`: a hardware-grade tracking cookie

```
host:      67549745dd1a4564be928e47dca271fd
flatpak:   67549745dd1a4564be928e47dca271fd
obsidian:  7f96d11360c37262f44b104a98c9a3e1   (different on every launch)
```

Mount line, read from `/proc/self/mountinfo` inside the sandbox:

```
131 110 254:0 /etc/machine-id /etc/machine-id ro,nosuid,nodev,relatime master:1 - ext4 /dev/root rw,discard
```

`/etc/machine-id` is a 128-bit identifier generated once when the operating system is installed
and never changed. Properties that make it the ideal tracking token:

| Property | Value |
|---|---|
| Uniqueness | 128 bits, effectively globally unique |
| Stability | survives reboots, updates, app reinstalls, cache clears, VPNs |
| Readability | plain file, no permission required |
| Consistency | **the same value for every Flatpak app on the machine** |
| User control | none exposed in the Flatpak permission model |

That last two rows are the important ones. Two unrelated Flatpak applications from two
unrelated vendors can read the identical value and correlate their user bases with no
cooperation and no network-level information at all. Deleting an app's data directory does not
change it. Reinstalling the app does not change it. Only reinstalling the operating system
does.

For comparison, this is a stronger identifier than a browser cookie, an advertising ID, or a
canvas fingerprint — and it is handed over silently.

Obsidian Mirror generates a fresh random machine-id per launch and binds it over both
`/etc/machine-id` and `/var/lib/dbus/machine-id`.

---

## 3. `/sys`: the hardware bill of materials

Measured on the test machine:

| Observation | host | Flatpak | Obsidian Mirror |
|---|---|---|---|
| `/sys/class` subsystem count | 31 | **31** | 31 (directories present, contents emptied) |
| `/sys/block` | `loop0…loop7 vda` | **identical** | *empty* |
| `/sys/devices/system/cpu` entries | 16 | **16** | *0* |
| `/sys/class/net/eth0/address` | `02:fc:00:00:00:05` | **identical** | out of scope by design |

Because the bind is of the whole subtree, everything the kernel exposes there follows. On a
physical machine that includes:

| Path | Leaks |
|---|---|
| `/sys/class/dmi/id/product_uuid` | motherboard UUID — permanent, unique |
| `/sys/class/dmi/id/{product,board,chassis}_serial` | OEM serial numbers |
| `/sys/class/dmi/id/{sys_vendor,product_name,board_name}` | exact laptop model |
| `/sys/class/dmi/id/bios_{vendor,version,date}` | firmware build |
| `/sys/class/drm/*/edid` | **monitor serial number and manufacture week** |
| `/sys/class/drm/card0/device/subsystem_device` | OEM board pin — identifies the exact model |
| `/sys/block/*/device/serial`, `*/wwid` | **disk serial numbers** |
| `/sys/class/power_supply/BAT*/serial_number` | battery serial |
| `/sys/class/tpm/tpm0/*` | TPM presence and version |
| `/sys/class/bluetooth/hci*/address` | Bluetooth MAC |
| `/sys/devices/system/cpu/*` | exact core/thread topology |

**Honesty note:** the test machine is a cloud VM. It has no DMI table, no TPM, no battery and
no discrete GPU, so those specific fields read `(none)` in *all four* columns of the raw data
and are marked "absent on test host" rather than counted as wins for anybody. The *mechanism*
is proven by the mount table above — a read-only bind mount of `/sys/class` necessarily exposes
`/sys/class/dmi` on a machine that has one. The *values* were not measurable here, and this
document does not pretend otherwise. Someone with a physical laptop can close that gap in five
minutes; please open an issue with the output.

Obsidian Mirror generates a per-host manifest at install time and masks or spoofs each of these
individually, with a fail-closed sweep that tmpfs-masks any `/sys/class/*` subsystem the
scanner does not recognise.

---

## 4. `/proc`: fresh procfs, real kernel

Flatpak mounts a new procfs and a PID namespace, so the process table is genuinely isolated —
a real and useful protection. But a fresh procfs still reports the real kernel:

| File | host | Flatpak | Obsidian Mirror |
|---|---|---|---|
| `/proc/cpuinfo` model | `Intel(R) Xeon(R) @ 2.60GHz` | **identical** | `Intel(R) Core(TM) i5-8250U` |
| `/proc/cpuinfo` bogomips | `5200.05` | **identical** | `3600.00` |
| `/proc/cpuinfo` cache | `55296 KB` | **identical** | `6144 KB` |
| `/proc/cpuinfo` flag count | `106` | **identical** | `47` |
| `/proc/meminfo` MemTotal | `2032608 kB` | **identical** | `8192000 kB` |
| `/proc/version` | real build string | **identical** | matching fake distro |
| `/proc/cmdline` | real, incl. root UUID | **identical** | synthetic |
| `/proc/sys/kernel/random/boot_id` | real | **identical** | random per launch |
| `/proc/stat` btime | `1785480903` | **identical** | randomised |
| `/proc/uptime` | `151` | **identical** | randomised |

The CPU flag count deserves a note: 106 versus 47. The exact set of CPU feature flags is close
to a unique identifier for a CPU stepping and microcode revision. Obsidian Mirror reports a
plausible, older, much more common set.

`/proc/cmdline` deserves another: it contains your **root filesystem UUID** on most
distributions. That is a stable disk identifier in a world-readable file.

---

## 5. Timestamps at nanosecond resolution

| | host | Flatpak | Obsidian Mirror |
|---|---|---|---|
| `stat` mtime nanoseconds | `506246762` | `118246762` | `0` |
| mtime second-within-hour | random | random | `0` |

Flatpak's value differs from the host's only because it is a different file at a different
instant — the *resolution* is untouched. Every file an application touches carries a
~30-bit-entropy nanosecond timestamp. Correlate a handful of them and you have a per-event
tracking identifier and a precise activity timeline.

Obsidian Mirror hooks `stat`, `lstat`, `fstat`, `fstatat` **and `statx`** — the last one matters
because modern glibc and musl route through `statx` internally — flooring `tv_sec` to the hour
and zeroing `tv_nsec`.

This is not a criticism of Flatpak so much as an illustration of how much of the fingerprinting
surface nobody is looking at.

---

## 6. The permission model does not cover any of this

Flatpak's permission system is genuinely good at what it covers:

```sh
flatpak override --nofilesystem=home org.example.App
flatpak override --unshare=network org.example.App
```

There is no equivalent of:

```sh
flatpak override --no-machine-id org.example.App     # does not exist
flatpak override --no-dmi         org.example.App     # does not exist
flatpak override --fake-cpu       org.example.App     # does not exist
```

Because metadata identity was never in scope. The permission model is about *access*, and
reading your motherboard serial is not modelled as an access at all.

A related, widely-discussed weakness: many popular Flatpaks ship with `--filesystem=home` or
`--filesystem=host`, which nullifies most of the filesystem isolation that is the sandbox's
main selling point. That is an ecosystem problem rather than a Flatpak-the-technology problem,
but it compounds the expectation gap: users see "sandboxed" on the store page and infer far
more than is being offered. Checking what you actually granted is worth doing:

```sh
flatpak info --show-permissions org.example.App
```

---

## 7. The full measured ledger

Generated from the raw TSVs by `evidence/compare.py`. Of **82** identifiers this host exposes
with a non-empty value (network excluded; zero-valued counts excluded, because a count of zero
devices cannot identify anybody):

| | count |
|---|---|
| Leaked by Flatpak, covered by Obsidian Mirror | **34** |
| Covered by Flatpak, leaked by Obsidian Mirror | **9** |
| Leaked by both | 15 |
| Covered by both | 24 |

### Leaked by Flatpak, covered by Obsidian Mirror (34)

`blk.count`, `blk.devices`, `blk.vendor`, `cpu.bogomips`, `cpu.cache`, `cpu.flags_len`,
`cpu.mhz`, `cpu.model`, `cpu.online`, `cpu.possible`, `cpu.sysfs_dirs`, `fs.home_count`,
`fs.home_entries`, `id.boot_id`, `id.env_home`, `id.env_logname`, `id.env_user`,
`id.groupname`, `id.hostname`, `id.machine_id`, `id.uname_nodename`, `id.uname_release`,
`id.uname_version`, `id.username`, `mem.meminfo_lines`, `mem.meminfo_total`,
`mem.sysinfo_total`, `os.kernel_osrelease`, `os.proc_cmdline`, `os.proc_version`, `time.btime`,
`time.loadavg`, `time.uptime`, `time.zone_abbr`

### Covered by Flatpak, leaked by Obsidian Mirror (9)

| Key | host | Flatpak | Obsidian |
|---|---|---|---|
| `blk.root_source` | `/dev/root` | `tmpfs` | `/dev/root` |
| `os.distro_file_names` | `debian_version` | `(none)` | `debian_version` (emptied, name remains) |
| `det.opt_obsidian` | `visible` | `hidden` | `visible` |
| `fs.font_count` | `38` | `126` | `38` |
| `fs.font_families` | `18` | `43` | `18` |
| `fs.font_family_sig` | `3565277771` | `327639698` | `3565277771` |
| `fs.hostlocal_font_dirs` | 2 dirs | 1 dir | 2 dirs |
| `id.shell` | `/bin/bash` | `/bin/sh` | `/bin/bash` |
| `time.localtime` | `/usr/share/zoneinfo/Etc/UTC` | `../usr/share/…` | same as host |

Six of these nine follow from one architectural decision: Flatpak `pivot_root`s and Obsidian
Mirror does not. That is a real advantage for Flatpak and it is documented as a known
limitation in [`COVERAGE.md` §5.2](COVERAGE.md#52-inherent-to-sharing-the-host). The cost of
pivoting is that applications which read their own installation directory break — which is why
Flatpak can do it (it *ships* the application's whole runtime) and a wrapper for arbitrary
host binaries cannot.

The font rows are also a genuine, if accidental, Flatpak win: the runtime ships a fixed font
set, so the enumeration is constant across every machine running that runtime. That is
strictly better anti-fingerprinting than Obsidian Mirror's approach of pinning
`FONTCONFIG_FILE` to drop per-user directories. Worth stealing.

### Leaked by both (15)

`cpu.count_cpuinfo`, `cpu.nproc`, `cpu.vendor`, `fw.dtb_present`, `fw.efi_present`, `id.gid`,
`id.uid`, `id.uname_machine`, `id.uname_sysname`, `ipc.compositor_ctl`, `ipc.dbus_session`,
`ipc.wayland_disp`, `sec.cap_effective`, `time.stat_cpulines`, `time.utc_offset`

**A methodological confession, counted against Obsidian Mirror rather than hidden.** Most of
these are not leaks at all — they are *coincidences*. Obsidian Mirror deliberately reports uid
1000, gid 1000, 2 CPU cores, `GenuineIntel` and `x86_64`; this test host genuinely has uid
1000, 2 cores and an Intel CPU, so the spoofed value happens to equal the real one. A
byte-comparison cannot tell a successful spoof from a passthrough, so all of them are scored
as leaks. The true figure is therefore *better* than the one reported here, and the reported
one is kept because a metric that quietly flatters the tool that defined it is worthless.

The genuinely unfixable entries in this list are `x86_64` and `Linux` — every binary on the
machine is built for them — and the three `absent` socket rows, where there was nothing to
protect. And the whole network layer, which is excluded from the count and disclaimed by both
projects.

---

## 8. Summary

|  | Flatpak | Obsidian Mirror |
|---|---|---|
| **Purpose** | contain what an app can *do* | limit what an app can *learn* |
| Filesystem isolation | `pivot_root`, private tmpfs — **strong** | mount masks — weaker |
| Process isolation | PID + IPC namespaces | PID + IPC namespaces |
| Syscall filtering | seccomp | seccomp, 24 rules |
| Permission model | rich: portals, per-app grants | **none** |
| Machine-id | **host's, bind-mounted** | randomised per launch |
| `/sys` hardware identity | **host's, bind-mounted read-only** | scanned, spoofed, masked, fail-closed |
| `/proc` kernel identity | **real** | coherent synthetic profile, 10 variants |
| Timestamp resolution | **full nanosecond** | floored to the hour, nanoseconds zeroed |
| Fonts | runtime-constant set — **good** | deterministic, per-user dirs dropped |
| Network | per-app toggle | **out of scope entirely** |
| Detectable by the app | yes | yes, and it says so |

Two tools, two threat models. The failure is not that Flatpak does its job badly. The failure
is that nothing in the desktop Linux stack does the *other* job at all, and users reasonably
assume somebody does.

That absence is what this project is pointing at.
