# Measured comparison

Probe keys emitted: 166
Keys where this host exposes a real value (network excluded): 82

## Headline counts

| Environment | Identical to host | Changed | Altered |
|---|---|---|---|
| Host (control) | 82 / 82 | 0 | 0% |
| Flatpak, default permissions | 49 / 82 | 33 | 40% |
| Flatpak, typical app permissions | 47 / 82 | 35 | 43% |
| Obsidian Mirror | 24 / 82 | 58 | 71% |

## High-value identifiers, measured

| Identifier | Host (real) | Flatpak | Obsidian Mirror |
|---|---|---|---|
| /etc/machine-id (permanent install UUID) | `67549745dd1a4564be928e47dca27…` | `67549745dd1a4564be928e47dca27…` | `7f96d11360c37262f44b104a98c9a…` |
| Kernel boot_id (per-boot session ID) | `2bb79165-136a-4b63-829d-17027…` | `2bb79165-136a-4b63-829d-17027…` | `f8f9854f-db84-b9a0-7a5b-8e026…` |
| Hostname | `e2b.local` | `e2b.local` | `workstation-0f6678` |
| uname nodename | `e2b.local` | `e2b.local` | `workstation-0f6678` |
| Login name (getpwuid) | `user` | `user` | `guest` |
| $HOME path | `/home/user` | `/home/user` | `/home/guest` |
| Kernel release | `6.1.158+` | `6.1.158+` | `6.5.6-300.fc39.x86_64` |
| /proc/version build string | `Linux version 6.1.158+ (root@…` | `Linux version 6.1.158+ (root@…` | `Linux version 6.5.6-300.fc39.…` |
| /proc/cmdline (incl. root UUID) | `clocksource=kvm-clock i8042.n…` | `clocksource=kvm-clock i8042.n…` | `BOOT_IMAGE=(hd0,gpt2)/vmlinuz…` |
| CPU model name | `Intel(R) Xeon(R) Processor @ …` | `Intel(R) Xeon(R) Processor @ …` | `Intel(R) Core(TM) i5-8250U CP…` |
| BogoMIPS | `5200.05` | `5200.05` | `3600.00` |
| CPU cache size | `55296 KB` | `55296 KB` | `6144 KB` |
| CPU feature-flag count | `106` | `106` | `47` |
| Per-core sysfs topology | `2` | `2` | `0` |
| RAM total (/proc/meminfo) | `2032608` | `2032608` | `8192000` |
| Block device list | `loop0 loop1 loop2 loop3 loop4…` | `loop0 loop1 loop2 loop3 loop4…` | `(none)` |
| Disk serial *(absent on test host)* | `(none)` | `(none)` | `(none)` |
| DMI product UUID *(absent on test host)* | `(none)` | `(none)` | `(none)` |
| DMI board serial *(absent on test host)* | `(none)` | `(none)` | `(none)` |
| Timezone | `UTC` | `UTC` | `GMT` |
| Boot timestamp | `1785480903` | `1785480903` | `1785416361` |
| Uptime | `151` | `151` | `64709` |
| File mtime nanoseconds | `506246762` | `118246762` | `0` |
| /home contents | `user` | `user` | `.fake guest` |

## Leaked by Flatpak, covered by Obsidian Mirror

- `blk.count` = `9`
- `blk.devices` = `loop0 loop1 loop2 loop3 loop4 loop5 loop6 loop7 vda`
- `blk.vendor` = `0x0000`
- `cpu.bogomips` = `5200.05`
- `cpu.cache` = `55296 KB`
- `cpu.flags_len` = `106`
- `cpu.mhz` = `2600.028`
- `cpu.model` = `Intel(R) Xeon(R) Processor @ 2.60GHz`
- `cpu.online` = `0-1`
- `cpu.possible` = `0-1`
- `cpu.sysfs_dirs` = `2`
- `fs.home_count` = `1`
- `fs.home_entries` = `user`
- `id.boot_id` = `2bb79165-136a-4b63-829d-17027b0a8e40`
- `id.env_home` = `/home/user`
- `id.env_logname` = `user`
- `id.env_user` = `user`
- `id.groupname` = `user`
- `id.hostname` = `e2b.local`
- `id.machine_id` = `67549745dd1a4564be928e47dca271fd`
- `id.uname_nodename` = `e2b.local`
- `id.uname_release` = `6.1.158+`
- `id.uname_version` = `#1 SMP PREEMPT_DYNAMIC Fri Jul 17 14:31:34 UTC 2026`
- `id.username` = `user`
- `mem.meminfo_lines` = `53`
- `mem.meminfo_total` = `2032608`
- `mem.sysinfo_total` = `2032608`
- `os.kernel_osrelease` = `6.1.158+`
- `os.proc_cmdline` = `clocksource=kvm-clock i8042.noaux i8042.nokbd init=/sbin/in…`
- `os.proc_version` = `Linux version 6.1.158+ (root@runnervm3jd5f) (gcc (Ubuntu 13…`
- `time.btime` = `1785480903`
- `time.loadavg` = `0.58 0.27 0.10`
- `time.uptime` = `151`
- `time.zone_abbr` = `UTC`

**34 identifiers.**

## Covered by Flatpak, leaked by Obsidian Mirror

- `blk.root_source`: host `/dev/root` -> flatpak `tmpfs`, obsidian `/dev/root`
- `det.opt_obsidian`: host `visible` -> flatpak `hidden`, obsidian `visible`
- `fs.font_count`: host `38` -> flatpak `126`, obsidian `38`
- `fs.font_families`: host `18` -> flatpak `43`, obsidian `18`
- `fs.font_family_sig`: host `3565277771` -> flatpak `327639698`, obsidian `3565277771`
- `fs.hostlocal_font_dirs`: host `/usr/local/share/fonts /etc/fonts/conf.d` -> flatpak `/etc/fonts/conf.d`, obsidian `/usr/local/share/fonts /etc/fonts/conf.d`
- `id.shell`: host `/bin/bash` -> flatpak `/bin/sh`, obsidian `/bin/bash`
- `os.distro_file_names`: host `debian_version` -> flatpak `(none)`, obsidian `debian_version`
- `time.localtime`: host `/usr/share/zoneinfo/Etc/UTC` -> flatpak `../usr/share/zoneinfo/Etc/UTC`, obsidian `/usr/share/zoneinfo/Etc/UTC`

**9 identifiers.** These are real and are documented in docs/COVERAGE.md; most follow from Flatpak's `pivot_root`, which Obsidian Mirror deliberately does not do.

## Leaked by both

- `cpu.count_cpuinfo` = `2`
- `cpu.nproc` = `2`
- `cpu.vendor` = `GenuineIntel`
- `fw.dtb_present` = `no`
- `fw.efi_present` = `no`
- `id.gid` = `1000`
- `id.uid` = `1000`
- `id.uname_machine` = `x86_64`
- `id.uname_sysname` = `Linux`
- `ipc.compositor_ctl` = `absent`
- `ipc.dbus_session` = `absent`
- `ipc.wayland_disp` = `absent`
- `sec.cap_effective` = `0000000000000000`
- `time.stat_cpulines` = `2`
- `time.utc_offset` = `+0000`

**15 identifiers.**
