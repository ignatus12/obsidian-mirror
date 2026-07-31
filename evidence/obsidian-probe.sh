#!/bin/sh
# ============================================================
# /opt/obsidian/scripts/obsidian-probe.sh
# Obsidian Mirror - metadata observation probe.
#
# Emits one "KEY<TAB>VALUE" line per observable metadata item.
# Side-effect free, unprivileged, POSIX sh + BusyBox only.
#
# Run it natively to see the REAL host identity, and run it
# under "obsidian" to see the SPOOFED identity. obsidian-audit
# does both and diffs them.
# ============================================================

# Deliberately no "set -e": a probe must survive every missing file.

NONE="(none)"

emit() {
    _k="$1"; shift
    _v="$*"
    _v=$(printf '%s' "$_v" | tr '\n\r\t' '   ' | sed 's/  */ /g; s/^ //; s/ *$//')
    [ -z "$_v" ] && _v="$NONE"
    printf '%s\t%s\n' "$_k" "$_v"
}

# read a file, first line only, bounded
rd1() {
    if [ -r "$1" ]; then
        head -n 1 "$1" 2>/dev/null | cut -c1-160
    else
        printf ''
    fi
}

# read whole file bounded
rdall() {
    if [ -r "$1" ]; then
        head -c 400 "$1" 2>/dev/null
    else
        printf ''
    fi
}

# list a glob, basenames, space separated
lsglob() {
    _o=""
    for _p in "$@"; do
        [ -e "$_p" ] || continue
        _o="$_o $(basename "$_p")"
    done
    printf '%s' "$_o"
}

countglob() {
    _n=0
    for _p in "$@"; do
        [ -e "$_p" ] || continue
        _n=$((_n + 1))
    done
    printf '%s' "$_n"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------
# IDENTITY
# ------------------------------------------------------------
emit id.hostname        "$(hostname 2>/dev/null)"
emit id.uname_nodename  "$(uname -n 2>/dev/null)"
emit id.uname_sysname   "$(uname -s 2>/dev/null)"
emit id.uname_release   "$(uname -r 2>/dev/null)"
emit id.uname_version   "$(uname -v 2>/dev/null)"
emit id.uname_machine   "$(uname -m 2>/dev/null)"
emit id.machine_id      "$(rd1 /etc/machine-id)"
emit id.dbus_machine_id "$(rd1 /var/lib/dbus/machine-id)"
emit id.boot_id         "$(rd1 /proc/sys/kernel/random/boot_id)"
emit id.env_user        "$USER"
emit id.env_logname     "$LOGNAME"
emit id.env_home        "$HOME"
emit id.uid             "$(id -u 2>/dev/null)"
emit id.gid             "$(id -g 2>/dev/null)"
emit id.username        "$(id -un 2>/dev/null)"
emit id.groupname       "$(id -gn 2>/dev/null)"
emit id.passwd_lines    "$(grep -c . /etc/passwd 2>/dev/null)"
emit id.group_lines     "$(grep -c . /etc/group 2>/dev/null)"
emit id.passwd_self     "$(grep "^$(id -un 2>/dev/null):" /etc/passwd 2>/dev/null | head -n1)"
emit id.shell           "$SHELL"

# ------------------------------------------------------------
# OPERATING SYSTEM
# ------------------------------------------------------------
if [ -r /etc/os-release ]; then
    emit os.id       "$(grep -E '^ID='          /etc/os-release 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\"')"
    emit os.pretty   "$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\"')"
    emit os.version  "$(grep -E '^VERSION_ID='  /etc/os-release 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\"')"
else
    emit os.id "$NONE"; emit os.pretty "$NONE"; emit os.version "$NONE"
fi
emit os.proc_version    "$(rd1 /proc/version)"
emit os.proc_cmdline    "$(rdall /proc/cmdline)"
emit os.kernel_osrelease "$(rd1 /proc/sys/kernel/osrelease)"
emit os.issue           "$(rdall /etc/issue)"
emit os.lsb_release     "$(rdall /etc/lsb-release)"
emit os.distro_files    "$(cat /etc/alpine-release /etc/debian_version /etc/redhat-release /etc/arch-release /etc/gentoo-release 2>/dev/null | head -c 200)"
emit os.distro_file_names "$(lsglob /etc/alpine-release /etc/debian_version /etc/redhat-release /etc/arch-release)"
emit os.apk_world       "$(grep -c . /etc/apk/world 2>/dev/null)"
emit os.apk_installed   "$(grep -c '^P:' /lib/apk/db/installed 2>/dev/null)"

# ------------------------------------------------------------
# CPU
# ------------------------------------------------------------
emit cpu.nproc          "$(nproc 2>/dev/null)"
emit cpu.model          "$(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2-)"
emit cpu.vendor         "$(grep -m1 '^vendor_id'  /proc/cpuinfo 2>/dev/null | cut -d: -f2-)"
emit cpu.count_cpuinfo  "$(grep -c '^processor'   /proc/cpuinfo 2>/dev/null)"
emit cpu.mhz            "$(grep -m1 '^cpu MHz'    /proc/cpuinfo 2>/dev/null | cut -d: -f2-)"
emit cpu.cache          "$(grep -m1 '^cache size' /proc/cpuinfo 2>/dev/null | cut -d: -f2-)"
emit cpu.bogomips       "$(grep -m1 '^bogomips'   /proc/cpuinfo 2>/dev/null | cut -d: -f2-)"
emit cpu.flags_len      "$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | wc -w)"
emit cpu.online         "$(rd1 /sys/devices/system/cpu/online)"
emit cpu.possible       "$(rd1 /sys/devices/system/cpu/possible)"
emit cpu.sysfs_dirs     "$(countglob /sys/devices/system/cpu/cpu[0-9]*)"

# ------------------------------------------------------------
# MEMORY
# ------------------------------------------------------------
mi() { grep -m1 "^$1" /proc/meminfo 2>/dev/null | tr -s ' ' | cut -d' ' -f2; }
emit mem.meminfo_total  "$(mi MemTotal)"
emit mem.meminfo_free   "$(mi MemFree)"
emit mem.meminfo_avail  "$(mi MemAvailable)"
emit mem.meminfo_swap   "$(mi SwapTotal)"
emit mem.meminfo_lines  "$(grep -c . /proc/meminfo 2>/dev/null)"
emit mem.sysinfo_total  "$(free -k 2>/dev/null | awk '/^Mem/{print $2; exit}')"
emit mem.sysinfo_swap   "$(free -k 2>/dev/null | awk '/^Swap/{print $2; exit}')"

# ------------------------------------------------------------
# TIME
# ------------------------------------------------------------
emit time.zone_abbr     "$(date +%Z 2>/dev/null)"
emit time.utc_offset    "$(date +%z 2>/dev/null)"
emit time.etc_timezone  "$(rd1 /etc/timezone)"
emit time.localtime     "$(readlink /etc/localtime 2>/dev/null)"
emit time.uptime        "$(cut -d. -f1 /proc/uptime 2>/dev/null)"
emit time.btime         "$(grep -m1 '^btime' /proc/stat 2>/dev/null | cut -d' ' -f2)"
emit time.loadavg       "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
emit time.stat_cpulines "$(grep -c '^cpu[0-9]' /proc/stat 2>/dev/null)"

# ------------------------------------------------------------
# FILE TIMESTAMP RESOLUTION
#
# Creates a throwaway file and reads its mtime back. The stat
# family and statx() are both hooked to floor tv_sec to the hour
# and zero tv_nsec, so a protected host reports 0 for both.
# A real host reports an essentially random second-within-hour
# and a nanosecond field with ~30 bits of entropy -- that is a
# per-file, per-event tracking identifier.
# ------------------------------------------------------------
_tsf="${TMPDIR:-/tmp}/.obsidian_ts_probe.$$"
: > "$_tsf" 2>/dev/null
if [ -f "$_tsf" ] && have stat; then
    _mt="$(stat -c %Y "$_tsf" 2>/dev/null)"
    _my="$(stat -c %y "$_tsf" 2>/dev/null)"
    case "$_mt" in
        ''|*[!0-9]*) emit ts.mtime_mod3600 "(stat unusable)" ;;
        *)           emit ts.mtime_mod3600 "$((_mt % 3600))" ;;
    esac
    _mns="$(printf '%s' "$_my" | sed -n 's/.*\.\([0-9][0-9]*\).*/\1/p')"
    [ -z "$_mns" ] && _mns=0
    # strip leading zeros without octal interpretation
    _mns="$(printf '%s' "$_mns" | sed 's/^0*//')"
    [ -z "$_mns" ] && _mns=0
    emit ts.mtime_nsec "$_mns"
    emit ts.mtime_raw  "$_my"
else
    emit ts.mtime_mod3600 "(stat absent)"
    emit ts.mtime_nsec    "(stat absent)"
    emit ts.mtime_raw     "(stat absent)"
fi
rm -f "$_tsf" 2>/dev/null

# ------------------------------------------------------------
# DMI / SMBIOS / FIRMWARE
# ------------------------------------------------------------
for f in sys_vendor product_name product_version product_serial product_uuid \
         product_family product_sku \
         board_vendor board_name board_version board_serial board_asset_tag \
         bios_vendor bios_version bios_date bios_release \
         chassis_vendor chassis_version chassis_serial chassis_asset_tag \
         chassis_type modalias; do
    v="$(rd1 /sys/class/dmi/id/$f)"
    [ -z "$v" ] && v="$(rd1 /sys/devices/virtual/dmi/id/$f)"
    emit "dmi.$f" "$v"
done
emit fw.acpi_tables     "$(countglob /sys/firmware/acpi/tables/*)"
emit fw.efi_present     "$([ -d /sys/firmware/efi ] && echo yes || echo no)"
emit fw.dtb_present     "$([ -e /sys/firmware/devicetree ] && echo yes || echo no)"

# ------------------------------------------------------------
# STORAGE
# ------------------------------------------------------------
emit blk.devices        "$(lsglob /sys/block/*)"
emit blk.count          "$(countglob /sys/block/*)"
_bmodel=""; _bserial=""; _bvendor=""; _bwwid=""
for d in /sys/block/sd* /sys/block/nvme* /sys/block/vd* /sys/block/hd*; do
    [ -e "$d" ] || continue
    [ -z "$_bmodel" ]  && _bmodel="$(rd1 "$d/device/model")"
    [ -z "$_bserial" ] && _bserial="$(rd1 "$d/device/serial")"
    [ -z "$_bvendor" ] && _bvendor="$(rd1 "$d/device/vendor")"
    [ -z "$_bwwid" ]   && _bwwid="$(rd1 "$d/wwid")"
done
emit blk.model          "$_bmodel"
emit blk.serial         "$_bserial"
emit blk.vendor         "$_bvendor"
emit blk.wwid           "$_bwwid"
emit blk.scsi_classes   "$(countglob /sys/class/scsi_device/* /sys/class/scsi_disk/* /sys/class/scsi_generic/* /sys/class/ata_device/* /sys/class/ata_port/*)"
emit blk.mount_count    "$(grep -c . /proc/mounts 2>/dev/null)"
emit blk.root_source    "$(awk '$2=="/"{print $1; exit}' /proc/mounts 2>/dev/null)"

# ------------------------------------------------------------
# TPM / CRYPTO HARDWARE
# ------------------------------------------------------------
emit tpm.class_nodes    "$(lsglob /sys/class/tpm/*)"
emit tpm.dev_nodes      "$(lsglob /dev/tpm*)"
emit tpm.version        "$(rd1 /sys/class/tpm/tpm0/tpm_version_major)"

# ------------------------------------------------------------
# POWER / THERMAL
# ------------------------------------------------------------
emit pwr.supplies       "$(lsglob /sys/class/power_supply/*)"
_bm=""; _bs=""
for b in /sys/class/power_supply/BAT*; do
    [ -e "$b" ] || continue
    [ -z "$_bm" ] && _bm="$(rd1 "$b/manufacturer")"
    [ -z "$_bs" ] && _bs="$(rd1 "$b/serial_number")"
done
emit pwr.bat_manufacturer "$_bm"
emit pwr.bat_serial       "$_bs"
_tz=""
for t in /sys/class/thermal/thermal_zone*; do
    [ -e "$t" ] || continue
    _tz="$_tz $(rd1 "$t/type")"
done
emit thermal.zone_types "$_tz"
_hw=""
for h in /sys/class/hwmon/hwmon*; do
    [ -e "$h" ] || continue
    _hw="$_hw $(rd1 "$h/name")"
done
emit hwmon.names        "$_hw"
_cd=""
for c in /sys/class/thermal/cooling_device*; do
    [ -e "$c" ] || continue
    _cd="$_cd $(rd1 "$c/type")"
done
emit thermal.cooling_types "$_cd"

# ------------------------------------------------------------
# PERIPHERALS
# ------------------------------------------------------------
_bt=""
for h in /sys/class/bluetooth/hci*; do
    [ -e "$h" ] || continue
    _bt="$_bt $(rd1 "$h/address")"
done
emit bt.addresses       "$_bt"
_rtc=""
for r in /sys/class/rtc/rtc*; do
    [ -e "$r" ] || continue
    _rtc="$_rtc $(rd1 "$r/name")"
done
emit rtc.names          "$_rtc"
_bl=""
for b in /sys/class/backlight/*; do
    [ -e "$b" ] || continue
    _bl="$_bl $(rd1 "$b/type")"
done
emit backlight.types    "$_bl"
emit input.proc_count   "$(grep -c '^N: Name' /proc/bus/input/devices 2>/dev/null)"
emit input.dev_count    "$(countglob /dev/input/*)"
emit input.class_count  "$(countglob /sys/class/input/*)"
emit snd.cards          "$(rdall /proc/asound/cards)"
emit snd.dev_count      "$(countglob /dev/snd/*)"
emit usb.device_count   "$(countglob /sys/bus/usb/devices/*)"
emit video.dev_nodes    "$(lsglob /dev/video* /dev/media*)"
emit hidraw.dev_nodes   "$(lsglob /dev/hidraw*)"
emit udev.db_entries    "$(countglob /run/udev/data/*)"

# ------------------------------------------------------------
# GPU / GRAPHICS
# ------------------------------------------------------------
emit gpu.dri_nodes      "$(lsglob /dev/dri/*)"
emit gpu.dri_count      "$(countglob /dev/dri/*)"
emit gpu.drm_class      "$(lsglob /sys/class/drm/*)"
emit gpu.drm_count      "$(countglob /sys/class/drm/*)"
emit gpu.pci_line       "$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -n1)"

# DRM board pins: these identify the exact laptop model. Spoofed in
# compat mode (the whole class is masked in strict mode).
_dsv=""; _dsd=""; _dlbl=""
for c in /sys/class/drm/card[0-9]*; do
    [ -e "$c" ] || continue
    [ -z "$_dsv" ]  && _dsv="$(rd1 "$c/device/subsystem_vendor")"
    [ -z "$_dsd" ]  && _dsd="$(rd1 "$c/device/subsystem_device")"
    [ -z "$_dlbl" ] && _dlbl="$(rd1 "$c/device/label")"
done
emit gpu.drm_subsys_vendor "$_dsv"
emit gpu.drm_subsys_device "$_dsd"
emit gpu.drm_label         "$_dlbl"

# Monitor EDID carries the display serial number and manufacture week.
_edid=0
for e in /sys/class/drm/*/edid; do
    [ -e "$e" ] || continue
    _sz="$(wc -c < "$e" 2>/dev/null)"
    case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
    _edid=$((_edid + _sz))
done
emit gpu.edid_bytes     "$_edid"

if have glxinfo; then
    emit gpu.gl_vendor   "$(glxinfo -B 2>/dev/null | grep -m1 -i 'OpenGL vendor'   | cut -d: -f2-)"
    emit gpu.gl_renderer "$(glxinfo -B 2>/dev/null | grep -m1 -i 'OpenGL renderer' | cut -d: -f2-)"
    emit gpu.gl_ext_count "$(glxinfo 2>/dev/null | tr ' ' '\n' | grep -c '^GL_')"
else
    emit gpu.gl_vendor    "(glxinfo absent)"
    emit gpu.gl_renderer  "(glxinfo absent)"
    emit gpu.gl_ext_count "(glxinfo absent)"
fi
emit gpu.env_vendor     "$OBSIDIAN_GPU_VENDOR"
emit gpu.env_renderer   "$OBSIDIAN_GPU_RENDERER"
emit gpu.mode           "${OBSIDIAN_GPU_MODE:-(unset)}"

# ------------------------------------------------------------
# PCI BUS
# ------------------------------------------------------------
emit pci.device_count   "$(countglob /sys/bus/pci/devices/*)"
_pv=""
for p in /sys/bus/pci/devices/*; do
    [ -e "$p" ] || continue
    _pv="$_pv$(rd1 "$p/vendor") "
done
emit pci.vendor_ids     "$(printf '%s' "$_pv" | tr ' ' '\n' | sort -u | tr '\n' ' ')"

# ------------------------------------------------------------
# NETWORK  (explicitly OUT OF SCOPE - audited to show the boundary)
# ------------------------------------------------------------
emit net.interfaces     "$(lsglob /sys/class/net/*)"
_mac=""
for n in /sys/class/net/*; do
    [ -e "$n" ] || continue
    case "$(basename "$n")" in lo) continue ;; esac
    _mac="$_mac $(rd1 "$n/address")"
done
emit net.mac_addresses  "$_mac"
emit net.resolv_conf    "$(rdall /etc/resolv.conf)"
emit net.hosts_lines    "$(grep -c . /etc/hosts 2>/dev/null)"

# ------------------------------------------------------------
# PROCESS / IPC / KERNEL SURFACE
# ------------------------------------------------------------
emit proc.pid1_comm     "$(rd1 /proc/1/comm)"
emit proc.visible_pids  "$(ls /proc 2>/dev/null | grep -c '^[0-9][0-9]*$')"
emit proc.self_pid      "$$"
emit ipc.shm_segments   "$(ipcs -m 2>/dev/null | grep -c '^0x')"
emit sec.seccomp_mode   "$(grep -m1 '^Seccomp:'   /proc/self/status 2>/dev/null | tr -s ' \t' ' ' | cut -d' ' -f2)"
emit sec.nonewprivs     "$(grep -m1 '^NoNewPrivs:' /proc/self/status 2>/dev/null | tr -s ' \t' ' ' | cut -d' ' -f2)"
emit sec.cap_effective  "$(grep -m1 '^CapEff:'    /proc/self/status 2>/dev/null | tr -s ' \t' ' ' | cut -d' ' -f2)"
emit sec.userns_uidmap  "$(rdall /proc/self/uid_map)"

# ------------------------------------------------------------
# FILESYSTEM EXPOSURE
# ------------------------------------------------------------
emit fs.home_entries    "$(ls -A /home 2>/dev/null | tr '\n' ' ')"
emit fs.home_count      "$(ls -A /home 2>/dev/null | grep -c .)"
emit fs.tmp_count       "$(ls -A /tmp 2>/dev/null | grep -c .)"
emit fs.userhome_count  "$(ls -A "$HOME" 2>/dev/null | grep -c .)"
emit fs.root_home       "$(ls -A /root 2>/dev/null | grep -c . 2>/dev/null)"

# ------------------------------------------------------------
# FONTS
#
# The installed font set is a strong, stable fingerprint. The
# mirrored view pins FONTCONFIG_FILE at a config that scans only
# the distribution font directory, drops every per-user and
# host-local directory and pins the cache into the private tmpfs.
# Fonts are NOT removed -- an app with no fonts cannot draw text.
# ------------------------------------------------------------
emit fs.fontconfig_file "${FONTCONFIG_FILE:-(unset)}"
if have fc-list; then
    emit fs.font_count      "$(fc-list 2>/dev/null | grep -c .)"
    emit fs.font_families   "$(fc-list : family 2>/dev/null | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -c .)"
    emit fs.font_family_sig "$(fc-list : family 2>/dev/null | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep . | sort -u | cksum 2>/dev/null | cut -d' ' -f1)"
else
    emit fs.font_count      "(fc-list absent)"
    emit fs.font_families   "(fc-list absent)"
    emit fs.font_family_sig "(fc-list absent)"
fi
_fdirs=""
for d in "$HOME/.fonts" "$HOME/.local/share/fonts" "$HOME/.config/fontconfig"; do
    [ -d "$d" ] && _fdirs="$_fdirs $d"
done
emit fs.user_font_dirs  "$_fdirs"
_hdirs=""
for d in /usr/local/share/fonts /opt/share/fonts /etc/fonts/conf.d; do
    [ -e "$d" ] && _hdirs="$_hdirs $d"
done
emit fs.hostlocal_font_dirs "$_hdirs"

# ------------------------------------------------------------
# IPC REACHABILITY  (measured, not assumed)
#
# obsidian-ipcprobe attempts a real connect() to each socket.
# Compositor control sockets and the D-Bus system bus must NOT be
# reachable from inside. The Wayland display socket MUST stay
# reachable -- that is the compatibility guarantee.
# ------------------------------------------------------------
IPCP="/opt/obsidian/bin/obsidian-ipcprobe"
ipc_state() {
    # $1 = one or more candidate globs; prints the first decisive state
    _st=""
    for _c in $1; do
        [ -e "$_c" ] || continue
        if [ -x "$IPCP" ]; then
            _r="$("$IPCP" "$_c" 2>/dev/null | head -n1 | cut -f2)"
        else
            _r="present(no-probe)"
        fi
        [ -n "$_r" ] && { _st="$_r"; break; }
    done
    [ -z "$_st" ] && _st="absent"
    printf '%s' "$_st"
}

_rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u 2>/dev/null)}"
emit ipc.compositor_ctl "$(ipc_state "$_rt/sway-ipc.* $_rt/hypr/*/.socket.sock /tmp/hypr/*/.socket.sock $_rt/i3/ipc-socket.* /tmp/i3-*/ipc-socket.* $_rt/wayfire-wayland-*.socket $_rt/niri.*.sock")"
emit ipc.dbus_system    "$(ipc_state "/run/dbus/system_bus_socket /var/run/dbus/system_bus_socket")"
emit ipc.dbus_session   "$(ipc_state "$_rt/bus")"
emit ipc.wayland_disp   "$(ipc_state "$_rt/${WAYLAND_DISPLAY:-wayland-0} $_rt/wayland-0 $_rt/wayland-1")"
emit ipc.runtime_dir_entries "$(ls -A "$_rt" 2>/dev/null | grep -c .)"

# ------------------------------------------------------------
# DETECTABILITY  (can the app tell it is being mirrored?)
# ------------------------------------------------------------
emit det.ld_preload     "$LD_PRELOAD"
emit det.obsidian_env   "$(env 2>/dev/null | grep -c '^OBSIDIAN_')"
emit det.mount_fakes    "$(grep -c 'home/\.fake' /proc/self/mountinfo 2>/dev/null)"
emit det.mountinfo_rows "$(grep -c . /proc/self/mountinfo 2>/dev/null)"
emit det.opt_obsidian   "$([ -d /opt/obsidian ] && echo visible || echo hidden)"
