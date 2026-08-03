# Changelog

Measured figures come from the development box (Linux 6.1, x86_64,
Landlock ABI 2) unless stated otherwise. Every one of them re-prints on
your own machine with the command named next to it.

---

## Unreleased

- **Self-test regression fixed (root cause).** The persistent-home change
  reordered the launcher so `chmod 700 "/home/$FAKE_USER"` ran *before* the
  `mkdir -p` that creates that directory. Under `set -e` in the middle
  `sh -c`, the `chmod` on the not-yet-existing directory aborted the whole
  script before the application was exec'd -- which wiped argv integrity,
  exit-status, hostname spoof and stdin passthrough (all reported empty
  output / exit 1, and `obsidian --harden-test` printed
  `chmod: cannot access '/home/user'`). The `chmod` now runs after the
  directory is created; the store bind is also best-effort so it can never
  abort a launch.

- **Non-root users can now run the audits.** The launcher's `chmod` on the
  fake home directory is now non-fatal. Previously, when a normal (non-root)
  user ran `obsidian --test` / `obsidian --harden-test`, that `chmod` failed
  with EPERM inside the user namespace and `set -e` aborted the launch, so the
  probe produced no output. (The hardware manifest at /etc/obsidian is already
  world-readable, so the blocker was the home-dir chmod, not the manifest.)

- **New analysis tool: `bin/Obsidian-Mirror-Scanner.sh`** (third-phase,
  testing). Logs all traffic leaving the application (external view) to a file
  for analysis of internal-application threat models. See the script header.

- **`OBSIDIAN_HARDEN=2` — next-level dynamic network hardening.** Builds on
  `OBSIDIAN_HARDEN=1` by running the app inside its own network namespace
  (per-app veth), automatically logging its traffic with the scanner, and
  applying a **default-deny egress firewall** that allows only what a prior
  run proved necessary (everything else is denied). Implemented by
  `bin/obsidian-netblock.sh`; requires root + iproute2 + nftables and
  degrades to logging-only when those are unavailable. Not a hacking tool:
  it only restricts what *your* app may send out.

- **README rewritten as a simple introductory presentation.** A
  summary-up-front plus comparison and data tables, under 30 sections,
  titled "Obsidian Mirror Project — A Real Universal Application-data
  Privacy / Protection".
- **Network is allowed by default under the strict boundary.** A hardened
  application (`OBSIDIAN_HARDEN=1`) previously could not open `AF_INET` /
  `AF_INET6` sockets at all, so DNS and the web were dead. The boundary
  now leaves the network layer open by default so a hardened app can
  actually reach the internet; opt out per application with
  `OBSIDIAN_DENY_NET=1` (or `opt.deny_net=1` in a profile).
- **Per-application preferences persist by default.** The launcher no
  longer wipes `/home` on every launch: each app keeps its preferences,
  caches and config under `/opt/obsidian/var/homes/<app>` across runs.
  Set `OBSIDIAN_FRESH=1` for the old throwaway behaviour.
- **Maintainership testament added** to the README (see the document).
- **Installer scope clarified.** The installer never configures
  dnscrypt-proxy, unbound or nftables, and never writes
  `/etc/resolv.conf`; a host DNS failure after reboot is outside its
  responsibility.

## Strict boundary: correct denied-path message + wrapper launch support

### Fixed

- **The execution-denied message named the wrong path.** When the
  boundary refused to run a `#!` wrapper (LibreWolf, Firefox and many
  others ship as a shell wrapper around the real binary), the advice
  printed the wrapper's own path -- which was already granted, so
  following it could not work and pointed at nothing the user had typed.
  The message now names the *resolved* binary (`binpath`, what
  `command -v` + `readlink -f` actually resolve to) and, for a script,
  its interpreter; the `build` step writes both paths into the profile
  as active `allow.exec=` lines, so the hardened run shows the same
  correct path the `learn` step recorded.
- **Wrapper applications failed on the first hardened run even when
  correctly profiled.** A `#!` script needs its interpreter executable
  too, but the interpreter is named *inside the file*, not on the command
  line, so the kernel denied it on a path the user never saw. The
  enforcer now discovers and grants the interpreter before the ruleset
  loads -- following `/usr/bin/env` to its real binary and a few wrapper
  links. This is the minimal grant the model asks for: it is *read from
  the application*, not guessed, and it is provably required for the
  named target to start at all.
- **`OBSIDIAN_ALLOW_PATHS_RX` on a symlink directory silently did
  nothing.** `ll_add_path` opened the path with `O_NOFOLLOW`, which does
  not fail on a symlink -- it binds the rule to the link inode, which
  governs nothing. It now follows the link, so a grant on `/bin` (where
  `/bin -> usr/bin`) actually covers what lives beneath it.

### Measured

- `obsidian --profile learn fakewolf` -> `build` -> `OBSIDIAN_HARDEN=1
  obsidian fakewolf` runs the app. The denied case now reports
  `resolves to: /usr/bin/fakewolf` / `started by: /usr/bin/dash` /
  `OBSIDIAN_ALLOW_EXEC=/usr/bin/fakewolf:/usr/bin/dash`, and that exact
  value runs it.
- `tools/verify-installer.sh`: 24 passed, 0 failed; the launcher's
  middle `sh -c` still carries zero single quotes.

---

## The strict boundary release

The project used to answer one question: **what can an application
*learn* about this machine?** It now answers a second: **what can an
application *do* to it?**

### Added

**The strict boundary** — default-deny at every layer, with a minimal
per-application grant. Off unless `OBSIDIAN_HARDEN` is set, so nothing
that already worked changes.

- `obsidian_harden.c` — the enforcer. Landlock ruleset built default-deny
  with the ABI probed at runtime (1 to 6, degrading gracefully), a
  hand-assembled seccomp-bpf program covering memory, namespaces, kernel
  surfaces and address families, capability dropping,
  `PR_SET_NO_NEW_PRIVS`, and a `close_range` descriptor scrub. Links no
  external library, so it does not disappear when `libseccomp` is absent.
- `obsidian_hardenprobe.c` — the measurement. 51 attempts plus 6 positive
  controls, each run twice: once as the launcher ships, once inside the
  boundary.
- `obsidian_learn.c` + `obsidian-profile` — record what an application
  actually touches, then collapse that recording into the smallest grant
  that still runs it. The allow-list is discovered, not guessed.
- `obsidian --harden-test`, `--profile`, `--harden-plan` subcommands.
- `docs/STRICT-BOUNDARY.md`, `docs/CONFORMANCE.md`.

### Measured

| | |
|---|---|
| surfaces the boundary closed | **29** |
| already shut by the base launcher | 18 |
| **still open under the boundary** | **1** |
| application capabilities broken | **0** (6 of 6 positive controls kept) |
| present but unreachable | 2 |
| inconclusive on this machine | 1 |

`obsidian --test` is unchanged: 64 to 68 of 74 checks (86% to 91%,
redrawn each launch), and the
installer self-test verifies that the default path still behaves exactly
as it did.

### Fixed

- **Per-app profiles never loaded.** The launcher mounts a fresh tmpfs
  over `/home`, which is what keeps real user data out of the sandbox, so
  a profile under `~/.config` was unreachable by the time the enforcer
  ran. It warned, fell back to its defaults, and ran the application
  inside a boundary the user believed had been tailored to it. The
  launcher now reads the profile out before entering the sandbox and
  passes the text down in `OBSIDIAN_HARDEN_PROFILE_DATA`. Two checks in
  `verify-installer.sh` guard the hand-off so it cannot regress quietly.
- **`--harden-plan` misreported `paranoid`.** It overwrote
  `OBSIDIAN_HARDEN` with `plan`, so the plan described the strict
  boundary no matter which mode was asked for. Enforcement was always
  correct; only the report was wrong.
- **`IOCTL_DEV` withheld** on already-granted device nodes, which breaks
  terminals, DRM and sound for no gain. Now granted with every kind.
- **IPC scoping was auto-detected from `DISPLAY`** and guessed wrong
  whenever `DISPLAY` was set late — which takes out every X11 client on
  the machine. Now off in `strict`, on in `paranoid`, and
  `OBSIDIAN_SCOPE_IPC` forces it either way.
- `obsidian --test` no longer fails from a nested-namespace error; the
  audit is dispatched through `/bin/sh`.

### Corrected claims

Three rows of the model are **not** fully delivered by the code. They are
named in `docs/CONFORMANCE.md` with the same prominence as the seven that
are:

- **Execution — `dlopen`.** The docs claimed "no untrusted `dlopen`".
  Measured, it is open: Landlock checks its `EXECUTE` right when a file
  is opened *to be executed*, and a shared library is opened read-only
  then mapped executable. Any directory an application may write and read
  is a directory it can author code in and load. seccomp sees `PROT_EXEC`
  and a descriptor number at `mmap` time, never the path, so it cannot
  close it either. Closing it needs a path-aware LSM (SELinux `execmod`,
  AppArmor `m`). It is now probe `exec.wx_file` and appears in every
  report as **still open**, which is why the count moved from 0 to 1.
- **IPC — no D-Bus name filtering.** Per-name brokering needs a proxy in
  the connection path. What exists is bus-level: the whole system bus, or
  none of it. `/dev/shm` is granted from the base list, not per-app.
- **Filesystem — a base allow-list exists.** The default is not literally
  "only the app's own data dir": 66 grants (fonts, CA certificates,
  locale, `ld.so.cache`) exist so applications start at all.
  `OBSIDIAN_HARDEN_NO_DEFAULTS=1` gives the literal reading.

### Changed

- The installer is now **`Universal-Obsidian-Mirror-installer-script.sh`**.
  `Universal-Obsidian-installer-script.sh` is written by the same build
  with the same bytes, so existing links keep working.
- The build is **reproducible**: `installer/base.sh` is the payload-free
  installer and the only file edited by hand;
  `python3 tools/embed-harden.py` splices `src/` and `bin/` into the
  shipped script, and running it twice produces an identical file. The C
  sources in this repository are the same bytes the installer compiles.
- `tools/verify-installer.sh` — 24 structural checks, including that the
  launcher's middle `sh -c` script contains zero single quotes and that
  the hardening path stays behind an off-by-default guard.
- README rewritten to be understandable before you decide whether to care,
  with the verification commands next to every claim.

### Not closed, and not closable here

Side channels — cache timing, branch prediction, power, acoustic,
electromagnetic — are not syscalls, so no kernel policy sees them.
Anything below the kernel, including the management engine on the
processor, sits underneath every mechanism used here. Both are permanent
gaps rather than pending work.

And the standing rule: a surface that is not in `obsidian_hardenprobe.c`
is not a surface proven closed. It is one nobody has looked at yet.

---

## Earlier

The metadata layer: a synthetic host identity per launch — `machine-id`,
hostname, DMI, CPU/RAM profile, zeroed nanosecond timestamps, font list —
measured against a bare host and against Flatpak with the same 166-point
probe. See `docs/FLATPAK-COMPARISON.md` and `evidence/`.
