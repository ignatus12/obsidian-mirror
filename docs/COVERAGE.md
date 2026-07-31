# Obsidian Mirror v2 — Metadata Protection Coverage

What an application actually sees when you run `obsidian <application>`, how each item is
enforced, and — just as importantly — what is *not* covered.

**Scope:** Host ↔ Application layer only. The network stack is excluded by design.

**Hard rule this version was built under:** nothing may change the behaviour of a program
launched with `obsidian <application>`. Where a privacy fix and that rule collided, the fix
became an opt-in runtime mode rather than a forced default. Those switches are listed in §6.

---

## 1. The six enforcement layers

| # | Layer | Implemented by | Defeats |
|---|---|---|---|
| 1 | **libc interposition** | `LD_PRELOAD` → `obsidian_core.so`, `obsidian_gpu.so`, `obsidian_wayland.so` | `uname()`, `sysinfo()`, `getpwuid()`, `stat`/`statx`, `glGetString()`, `eglQueryString()`, `connect()` |
| 2 | **Mount namespace** | ~65 bind-mounts + tmpfs masks over `/proc`, `/sys`, `/etc`, `/dev` | Direct file reads that bypass libc |
| 3 | **UTS / PID / IPC / user namespaces** | `unshare --uts --pid --ipc --user` | Hostname, process table, SysV IPC, credentials |
| 4 | **seccomp-bpf filter** | `seccomp_enforcer` (24 rules) | Syscall-level introspection and sandbox escape |
| 5 | **Environment scrubbing + affinity clamp** | Export engine, `taskset -c 0,1`, `sched_getaffinity()` hook | Env-var identity leaks, core-count fingerprinting |
| 6 | **Fontconfig pinning** | `FONTCONFIG_FILE` → private `fonts.conf` | Installed-font-set fingerprinting |

Layer 2 is driven by `/etc/obsidian/hw-manifest.conf`, generated per host by
`generate-manifest.sh`. Regenerate it after a hardware change:

```sh
obsidian --regenerate-manifest      # as root
```

---

## 2. Closed in v2

Every item in this table was listed as a *known gap* in v1 §3.2.

| v1 gap | v2 status | How |
|---|---|---|
| `/proc/meminfo` not bind-mounted | **Closed** | A full 30-field synthetic `meminfo` is generated in the private tmpfs and bind-mounted over `/proc/meminfo`, kept numerically consistent with the `sysinfo()` hook (8 GB RAM, 2 GB swap) |
| `statx()` not hooked | **Closed** | `statx()` is hooked in `obsidian_core.c`; `stx_atime/mtime/ctime/btime` are floored to the hour and their nanosecond fields zeroed, matching the four `stat` variants |
| DMI `product_version`, `board_serial`, `chassis_*` missing | **Closed** | `generate-manifest.sh` §7 now emits the complete 23-field DMI set at both `/sys/class/dmi/id` and `/sys/devices/virtual/dmi/id` |
| Font list readable | **Closed** | `FONTCONFIG_FILE` restored, pointing at a config that scans only `/usr/share/fonts`, drops every per-user and host-local font directory, and pins the cache into the private tmpfs |
| Only `sway-ipc` blocked | **Closed** | The `connect()` block now matches sway, Hyprland, i3, Wayfire, River, labwc and niri control sockets |
| D-Bus system bus unmasked | **Closed (default-on)** | `connect()` to `dbus/system_bus_socket` returns `ECONNREFUSED`. Re-enable with `OBSIDIAN_ALLOW_SYSTEM_BUS=1` |
| `/dev/dri`, `/sys/class/drm` exposed | **Partly closed** | Monitor EDID masked, DRM OEM board pins spoofed, `eglQueryString(EGL_VENDOR)` spoofed. Full masking is opt-in: `OBSIDIAN_GPU_MODE=strict`. See §4 for why it is not the default |

---

## 3. What is protected

### 3.1 Machine & user identity

| Item | Application sees | Mechanism |
|---|---|---|
| Hostname / `uname` nodename | `laptop-a3f2c1` — random prefix + 6 hex, new every launch | UTS ns + bind |
| `/etc/machine-id`, D-Bus machine-id | random 32-hex, new every launch | bind mount |
| Kernel `boot_id` | random UUID, new every launch | bind mount |
| `$USER` / `$LOGNAME` / `$HOME` | one of `user`/`admin`/`guest`/`dev`, home on a fresh tmpfs | env export |
| `getpwuid()` / `getgrgid()` | `Generic User`, uid/gid 1000, `/bin/sh` | libc hook |
| `/etc/passwd`, `/etc/group` | exactly 3 synthetic lines each | bind mount |
| UID / GID | 1000 / 1000 | nested user ns |

### 3.2 Operating system identity — the Top-10 engine

Every launch picks one of **10 complete, internally coherent Linux identities** at random:
Ubuntu 22.04, Debian 12, Fedora 39, Arch, Mint 21.3, Pop!_OS 22.04, Manjaro 23.1.3,
openSUSE Tumbleweed, Alpine 3.19, RHEL 9.3. Kernel release, `/proc/version` build string, boot
cmdline and `os-release` all agree with each other — a profile mismatch would itself be a
fingerprint.

`/etc/issue`, `/etc/lsb-release` and every distro release file are emptied; `/etc/apk` and
`/lib/apk` become tmpfs, which hides the installed-package list — close to a unique fingerprint
of a machine.

### 3.3 Processor

Synthetic 2 × `Intel(R) Core(TM) i5-8250U @ 1.60GHz`; `nproc()` = 2 via
`sched_getaffinity()` hook plus `taskset -c 0,1`; `cpu/online`, `cpu/possible`, `cpu/present`
redirected to `0-1`; `/sys/devices/system/cpu` masked; `/proc/stat` trimmed to 2 CPU rows.

### 3.4 Memory — *new in v2*

| Item | Application sees | Mechanism |
|---|---|---|
| `sysinfo()` totalram / freeram / swap | 8 192 000 kB / derived / 2 097 152 kB | libc hook |
| `/proc/meminfo` **MemTotal / MemFree / MemAvailable / SwapTotal** | 8192000 / 4096000 / 6144000 / 2097152 kB | **bind mount (v2)** |
| Full `meminfo` body (Slab, PageTables, Committed_AS, …) | synthetic, internally consistent | bind mount |

Both paths now agree. In v1, `free` was clean but `cat /proc/meminfo` told the truth.

### 3.5 Time, clock and file timestamps

| Item | Application sees | Mechanism |
|---|---|---|
| Timezone | **UTC always** | `getenv("TZ")` hook + `/etc/timezone` + `/etc/localtime` binds |
| `localtime()` / `localtime_r()` | redirected to `gmtime()` | libc hook |
| `gettimeofday()` µs field | zeroed | libc hook |
| `/proc/uptime` | random 600–90 600 s per launch | bind mount |
| `/proc/stat` btime | derived from the fake uptime | awk rewrite |
| File `atime`/`mtime`/`ctime` | floored to the hour | `stat`, `lstat`, `fstat`, `fstatat` hooks |
| File timestamps via **`statx()`** | floored to the hour, **nanoseconds zeroed** | **`statx` hook (v2)** |

Nanosecond timestamps are a per-file, per-event tracking identifier — roughly 30 bits of
entropy attached to every file the application touches. The audit measures this directly:
`ts.mtime_nsec` and `ts.mtime_mod3600` must both read `0`.

### 3.6 DMI / SMBIOS — *complete in v2*

Spoofed at **both** `/sys/class/dmi/id/` and `/sys/devices/virtual/dmi/id/`:

| Field group | Application sees |
|---|---|
| `sys_vendor`, `board_vendor`, `bios_vendor`, `chassis_vendor`, `product_family`, `product_sku` | `Generic` |
| `product_name` / `board_name` | `Generic Laptop` / `Generic Board` |
| `product_version`, `board_version`, `chassis_version`, `bios_release`, `ec_firmware_release` | `1.0` |
| `product_serial`, `board_serial`, `chassis_serial`, `board_asset_tag`, `chassis_asset_tag` | `To Be Filled By O.E.M.` |
| `product_uuid` | all-zero UUID |
| `bios_version` / `bios_date` | `1.0.0` / `01/01/2020` |
| `chassis_type` | `10` (generic laptop) |
| `modalias` | rebuilt from the spoofed fields, so it cannot contradict them |
| `/sys/firmware/acpi` | tmpfs — OEM-signed ACPI tables hidden |

`modalias` matters: it concatenates the DMI fields into one string, so leaving it real would
have undone the other 22 spoofs on its own.

### 3.7 Storage, TPM, sensors, peripherals

`/sys/block` masked entirely; disk vendor/model/serial/WWID rewritten; SCSI and ATA classes
masked. TPM sysfs classes masked and `/dev/tpm*` bound to `/dev/null` — a TPM endorsement key
is a permanent, unforgeable hardware serial. Battery, hwmon, thermal, cooling, Bluetooth MAC,
RTC and backlight all normalised. `/sys/class/input`, `/dev/input`, `/proc/bus/input`,
`/sys/class/sound`, `/dev/snd`, `/proc/asound`, `/sys/class/hidraw`, `/dev/hidraw*`,
`/dev/video*`, `/dev/media*`, `/sys/bus/usb`, `/dev/bus/usb` and `/run/udev` are masked or
nulled.

### 3.8 GPU

| Item | Application sees |
|---|---|
| `glGetString(GL_VENDOR)` / `(GL_RENDERER)` | manifest values — a Mesa string chosen to match your real PCI generation |
| `glGetString(GL_VERSION)` | `OpenGL ES 3.2 Mesa 21.0.0` |
| `glGetString(GL_EXTENSIONS)`, `glGetStringi()` | **empty** (extension sets are near-unique per driver build) |
| `GL_NUM_EXTENSIONS` | `0`, kept consistent with the blanked list |
| `eglQueryString(EGL_VENDOR)` | spoofed — *new in v2* |
| `GL_MAX_*` limits | fixed 16384 / 16 values |
| DRM `subsystem_vendor` / `subsystem_device` / `label` | `0x8086` / `0x0000` / `Generic Graphics` — *new in v2* |
| Monitor **EDID** | masked to empty — *new in v2* (EDID carries the display serial and manufacture week) |

### 3.9 Fonts — *new in v2*

`FONTCONFIG_FILE` points at `/opt/obsidian/fake_root/fonts/fonts.conf`, which scans only
`/usr/share/fonts`, drops `~/.fonts`, `~/.local/share/fonts`, `/usr/local/share/fonts` and any
`/etc/fonts/conf.d` layering, pins the cache inside the private tmpfs, and fixes the
generic-family preference order and hinting/subpixel settings.

Fonts are deliberately **not removed** — an application with no fonts cannot draw text, which
would break it. What changes is that the enumeration becomes impersonal and deterministic.

### 3.10 Process, IPC and compositor sockets

PID namespace, IPC namespace, private `/tmp` and private `/home`.

`connect()` to an `AF_UNIX` path returns `ECONNREFUSED` when the path matches any of:
`sway-ipc`, `/hypr/`, `.hyprland`, `i3/ipc-socket`, `/tmp/i3-`, `wayfire`, `river-control`,
`labwc`, `niri.`, `hyprcursor`, or `dbus/system_bus_socket`. Compositor control sockets
otherwise hand out window titles, output models, workspace layout and the full input-device
inventory.

`XDG_RUNTIME_DIR` is replaced with a tmpfs containing **only** the Wayland socket,
`pulse/native` and `pipewire-0`. Everything else that normally accumulates there — systemd,
gnupg, keyring, the D-Bus session bus, per-app sockets — is simply not there.

**seccomp-bpf** — killed outright: `iopl`, `ioperm`. Returned `EPERM`: `ptrace`,
`process_vm_readv`, `process_vm_writev`, `kcmp`, `syslog`, `perf_event_open`, `init_module`,
`finit_module`, `delete_module`, `settimeofday`, `clock_settime`, `keyctl`, `add_key`,
`request_key`, `unshare`, `setns`, `pivot_root`, `mount`, `umount2`, `bpf`, `kexec_load`,
`acct`. The `unshare`/`setns`/`pivot_root`/`mount` denials are the self-escape blocks.

### 3.11 Fail-closed sweep

Any `/sys/class/*` subsystem the scanner does not recognise is masked with tmpfs. New or exotic
hardware is hidden by default rather than exposed by default.

---

## 4. Why `/dev/dri` is still reachable by default

This is the one v1 gap that v2 does **not** close by default, and the reason is the hard rule
at the top of this document.

Mesa and libdrm select the kernel driver by reading `/sys/class/drm/card0/device/vendor` and
`device/device`. Mask the DRM class, or lie about those two files, and one of two things
happens: hardware acceleration silently collapses to software rendering, or the application
fails to create a GL/Vulkan context at all. Electron apps, browsers, video players and anything
using `wgpu` are affected.

So the default (`OBSIDIAN_GPU_MODE=compat`) keeps the driver path intact and removes everything
around it that identifies *your specific machine*: the OEM subsystem IDs, the device label, the
monitor EDID, the GL vendor/renderer/version strings, the GL extension list, and the EGL vendor.
What remains readable is the GPU *model* — shared with every other owner of that model.

If you want the model gone too:

```sh
OBSIDIAN_GPU_MODE=strict obsidian <application>
```

That masks `/dev/dri` and `/sys/class/drm` completely. Zero GPU fingerprint, software rendering
only. It is the right choice for a text-mode or network tool, and the wrong choice for a
browser.

---

## 5. What is still NOT protected

### 5.1 Out of scope by design — the network layer

Untouched, deliberately: IP addresses, routing, DNS resolver config, real NIC MACs in
`/sys/class/net/*/address`, TLS/JA3 fingerprints, HTTP headers, NTP, mDNS.

`getifaddrs()` *is* hooked (renames to `eth0`, rewrites IPv4 to `10.0.2.15`), but anything using
netlink directly — `ip`, `ss`, most language runtimes — sees the truth. Do not rely on it.

**Pair Obsidian Mirror with a VPN or a network namespace for network-layer privacy.**

### 5.2 Inherent to sharing the host

| Limitation | Effect | Why it stays |
|---|---|---|
| Wayland socket passthrough | `wl_output` reports real resolution, refresh rate, physical size and monitor make/model | Removing it removes the display. Only a nested compositor (`cage`, headless wlroots) fixes this, and that changes how the app is presented |
| PulseAudio / PipeWire passthrough | Real device names and card serials travel over the protocol | Same trade-off: cutting it removes audio |
| GPU model readable in compat mode | Vulkan and DRM ioctls see the real adapter | §4. Opt in to `OBSIDIAN_GPU_MODE=strict` |
| No `pivot_root` | Host filesystem outside the masked paths is still visible, subject to normal permissions: `/root`, `/var`, `/srv`, other users' files | `/home` *is* tmpfs, so user data is covered. A real pivot breaks applications that read their own installation directory |

### 5.3 Hard limits — cannot be fixed at this layer

| Limit | Why |
|---|---|
| **`CPUID` instruction** | Executed in userspace directly. Real CPU vendor, family, model, stepping and feature bits are readable by any program. `/proc/cpuinfo` is spoofed; the instruction is not. Only a hypervisor can mask this |
| **`RDTSC` / timing** | Clock skew, TSC frequency and boot-time correlation are physical properties |
| **Raw syscalls bypass `LD_PRELOAD`** | `syscall(SYS_uname)` returns the real kernel release. Go binaries, static binaries and hand-written assembly skip libc entirely. Mount-level spoofs still apply; libc hooks do not |
| **setuid/setgid binaries** | The dynamic loader drops `LD_PRELOAD` for them |
| **glibc symbol aliases** | Programs using `__xstat`/`__fxstat` (gcompat, glibc containers) miss the `stat` hooks |
| **Detectability** | An application can tell it is being mirrored: `LD_PRELOAD` is in `/proc/self/environ`, `OBSIDIAN_*` vars are exported, `/proc/self/mountinfo` lists every bind, `/opt/obsidian` exists, and the PID namespace is suspiciously empty |

That last row is the honest headline. Against passive fingerprinting — the actual threat model
for application metadata leaks — this layer is very strong. Against an adversary specifically
probing for a sandbox, it is detectable. **Obsidian Mirror makes you anonymous, not invisible.**

---

## 6. Runtime switches

Every switch defaults to the setting that does not break applications.

| Variable | Default | Effect |
|---|---|---|
| `OBSIDIAN_GPU_MODE` | `compat` | `strict` masks `/dev/dri` and `/sys/class/drm` entirely. Zero GPU fingerprint, software rendering only |
| `OBSIDIAN_GL_EXTENSIONS` | *(blanked)* | `preserve` passes the real GL extension list through. Use only if an application refuses to start; every other GPU protection stays on |
| `OBSIDIAN_ALLOW_SYSTEM_BUS` | *(blocked)* | `1` permits `connect()` to the D-Bus system bus |
| `OBSIDIAN_VERBOSE` | *(off)* | `1` logs every blocked IPC connection and the seccomp rule count to stderr |
| `OBSIDIAN_MANIFEST` | `/etc/obsidian/hw-manifest.conf` | Alternate hardware manifest |

```sh
OBSIDIAN_GPU_MODE=strict obsidian curl https://example.com
OBSIDIAN_GL_EXTENSIONS=preserve obsidian some-picky-game
OBSIDIAN_VERBOSE=1 obsidian firefox
```

---

## 7. Testing it

```sh
obsidian --test          # the full four-section audit
obsidian --test -q       # summary, gaps and compatibility only
obsidian --test -a       # include informational rows
obsidian --test -v       # do not truncate values
obsidian --test --raw    # dump both probe outputs, ungraded
```

`obsidian --test` runs a ~165-point probe twice — once natively, once through the isolation
layer — and prints:

1. **Protected metadata summary** — per-category counts and a coverage percentage.
2. **Real vs protected** — every item side by side: what the host is, what the app is given.
3. **Host metadata not protected** — every remaining item with the reason, and the switch that
   covers it where one exists.
4. **Application compatibility** — argv integrity, exit-status propagation, stdin passthrough,
   Wayland socket reachability and the GPU render node. These are the guardrails on the hard
   rule; if any of them says `BROKEN`, the isolation layer is interfering with the application
   and that is a bug, not a feature.

Spot checks by hand:

```sh
obsidian sh -c 'hostname; echo $USER; id; cat /etc/machine-id'
obsidian sh -c 'grep -E "MemTotal|SwapTotal" /proc/meminfo'   # 8192000 / 2097152
obsidian sh -c 'touch /tmp/x; stat -c %y /tmp/x'              # .000000000
obsidian cat /sys/class/dmi/id/board_serial                   # To Be Filled By O.E.M.
obsidian ls /sys/block                                        # empty
obsidian sh -c 'grep Seccomp /proc/self/status'               # 2
for i in 1 2 3; do obsidian sh -c 'grep PRETTY /etc/os-release; uname -r'; done
```

Hostname, kernel and distro must change together on every launch, and the kernel must always
match the distro. A stable value that should change, or a kernel that does not match its
distro, is a bug.

---

## 8. Files installed

| Path | Purpose |
|---|---|
| `/usr/local/bin/obsidian` | CLI entry point (symlink) |
| `/opt/obsidian/bin/obsidian-launch` | Isolation launcher |
| `/opt/obsidian/bin/obsidian-inner` | Final execution stage (seccomp + affinity + exec) |
| `/opt/obsidian/bin/obsidian-audit` | Four-section protection audit |
| `/opt/obsidian/bin/seccomp_enforcer` | seccomp-bpf filter loader |
| `/opt/obsidian/bin/obsidian-ipcprobe` | Socket reachability probe used by the audit |
| `/opt/obsidian/lib/obsidian_core.so` | uname / sysinfo / stat / statx / open / affinity hooks |
| `/opt/obsidian/lib/obsidian_gpu.so` | GL and EGL string hooks |
| `/opt/obsidian/lib/obsidian_wayland.so` | `connect()` IPC block |
| `/opt/obsidian/scripts/generate-manifest.sh` | Hardware scanner |
| `/opt/obsidian/scripts/obsidian-probe.sh` | ~165-point metadata probe |
| `/opt/obsidian/fake_root/fonts/fonts.conf` | Deterministic font enumeration |
| `/opt/obsidian/COVERAGE.md` | This document |
| `/etc/obsidian/hw-manifest.conf` | Generated per-host spoof/mask manifest |
