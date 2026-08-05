#!/bin/sh
# =====================================================================
# Obsidian Mirror Scanner  -  network traffic logger / learner (v2)
# =====================================================================
#
# The "external view" approach to the internal-application threat model.
#
# Instead of inspecting or blocking threats from *inside* an application
# (fragile, breaks apps), we watch everything the application tries to
# send *out* -- between the application and the real network -- log it,
# and learn from it. This is the "EXTERNAL SUPER-BLOCKER" vantage point.
#
# WHAT IT CAPTURES
# -----------------
# All IP and ethernet-layer traffic on every interface: ethernet, wifi,
# VPN/tunnels, ARP, and every IP protocol (TCP/UDP/ICMP/GRE/ESP/SCTP/...),
# on every port -- including ports we do not recognise. A "magical mystery"
# destination simply appears as "dst port N". The only class tcpdump cannot
# see is Bluetooth, which is captured separately by `btmon` (auto-spawned).
#
# MODES
# -----
#   capture  : run an app and log all its traffic        (default)
#   learn    : parse a log -> list of endpoints the app used
#   background: capture only, to a per-app file, print PID (for the launcher)
#
# Usage (capture):
#   Obsidian-Mirror-Scanner.sh [options] -- <application> [args...]
#   Obsidian-Mirror-Scanner.sh -k firefox -d 120 -- firefox
#   Obsidian-Mirror-Scanner.sh -n -- chromium          # run via obsidian
#
# Usage (learn):
#   Obsidian-Mirror-Scanner.sh learn -l Obsidian-scanner.log
#
# Options:
#   -l FILE   log file                  (default: Obsidian-scanner.log)
#   -d SECS   capture duration          (default: until the app exits)
#   -i IFACE  capture interface         (default: any)
#   -k KEY    per-app key -> /opt/obsidian/var/scan/<KEY>.log
#   -n        also run the app through obsidian (isolation)
#   -b        background capture only (no app launch); prints PID
#
# Environment: OBSIDIAN_SCANNER_LOG / _DURATION / _IFACE / _SCANDIR
# =====================================================================

set -u

DEFAULT_SCANDIR="/opt/obsidian/var/scan"
SCANDIR="${OBSIDIAN_SCANDIR:-$DEFAULT_SCANDIR}"
LOG="${OBSIDIAN_SCANNER_LOG:-Obsidian-scanner.log}"
DURATION="${OBSIDIAN_SCANNER_DURATION:-}"
IFACE="${OBSIDIAN_SCANNER_IFACE:-any}"
VIA_OBSIDIAN=0
BG=0
KEY=""
APP=""
MODE="capture"

# ---- parse arguments -------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        learn)  MODE="learn"; shift ;;
        -l) LOG="$2"; shift 2 ;;
        -d) DURATION="$2"; shift 2 ;;
        -i) IFACE="$2"; shift 2 ;;
        -k) KEY="$2"; shift 2 ;;
        -n) VIA_OBSIDIAN=1; shift ;;
        -b) BG=1; shift ;;
        --) shift; APP="$*"; break ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
         *)  APP="$*"; break ;;
    esac
done

if [ -n "$KEY" ]; then
    mkdir -p "$SCANDIR" 2>/dev/null || true
    LOG="$SCANDIR/$KEY.log"
fi

# ---- pick a capture engine -------------------------------------------
pick_engine() {
    if command -v tcpdump >/dev/null 2>&1; then echo tcpdump
    elif command -v tshark >/dev/null 2>&1; then echo tshark
    elif command -v dumpcap >/dev/null 2>&1; then echo dumpcap
    else echo none; fi
}

if [ "$MODE" = "learn" ]; then
    CAP="none"
else
    CAP="$(pick_engine)"
    if [ "$CAP" = "none" ]; then
        echo "ERROR: no packet capture tool found (need tcpdump, tshark or dumpcap)." >&2
        exit 1
    fi
fi

# ---- learn mode ------------------------------------------------------
if [ "$MODE" = "learn" ]; then
    if [ ! -f "$LOG" ]; then
        echo "ERROR: log not found: $LOG" >&2
        exit 1
    fi
    echo "# endpoints observed in $LOG (dir ip.port proto) -- out = app->net, in = net->app"
    # tcpdump verbose lines look like:
    #   IP 10.42.0.2.44122 > 93.184.216.34.443: Flags [P.], ...
    #   IP 51.38.1.2.12345 > 10.42.0.2.443: ...   (incoming)
    awk -v appip="10.42.0.2" '
        /[>]/ {
            n = split($0, a, ">")
            left = a[1]; right = a[n]
            lpos = match(left,  /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?/)
            l = substr(left,  RSTART, RLENGTH)
            rpos = match(right, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?/)
            r = substr(right, RSTART, RLENGTH)
            if (l ~ /10\.42\.0\.2/)      { dir="out"; ext=r }
            else if (r ~ /10\.42\.0\.2/)  { dir="in";  ext=l }
            else { next }
            print dir" "ext" "proto_of($0)
        }
        function proto_of(line,   p) {
            if (line ~ /ICMP/) return "icmp"
            if (line ~ /UDP/) return "udp"
            if (line ~ /Flags \[/) return "tcp"
            return "ip"
        }
    ' "$LOG" | sort -u
    exit 0
fi

# ---- background capture mode (for the launcher) ----------------------
if [ "$BG" -eq 1 ]; then
    case "$CAP" in
        tcpdump)
            tcpdump -n -tttt -v -s 0 -i "$IFACE" \
                "not (host 127.0.0.1 or host ::1)" -w "$LOG" 2>/dev/null &
            ;;
        tshark|dumpcap)
            tshark -i "$IFACE" -w "$LOG" >/dev/null 2>&1 &
            ;;
    esac
    CAP_PID=$!
    # also capture Bluetooth if btmon exists
    if command -v btmon >/dev/null 2>&1; then
        BTLOG="$SCANDIR/${KEY:-bt}.btmon.log"
        btmon -w "$BTLOG" >/dev/null 2>&1 &
        BTPID=$!
    fi
    echo "$CAP_PID ${BTPID:-}"
    exit 0
fi

# ---- foreground capture mode -----------------------------------------
echo "Obsidian Mirror Scanner"
echo "  application : ${APP:-<none>}"
echo "  capture     : $CAP on interface '$IFACE'"
echo "  log file    : $LOG"
[ -n "$DURATION" ] && echo "  duration    : ${DURATION}s"

case "$CAP" in
    tcpdump)
        tcpdump -n -tttt -v -s 0 -i "$IFACE" \
            "not (host 127.0.0.1 or host ::1)" \
            > "$LOG" 2>&1 &
        CAP_PID=$!
        ;;
    tshark|dumpcap)
        tshark -i "$IFACE" -w "$LOG" >/dev/null 2>&1 &
        CAP_PID=$!
        ;;
esac
if command -v btmon >/dev/null 2>&1; then
    btmon -w "${LOG%.log}.btmon.log" >/dev/null 2>&1 &
    BTPID=$!
fi

if [ -n "$APP" ]; then
    if [ "$VIA_OBSIDIAN" -eq 1 ] && command -v obsidian >/dev/null 2>&1; then
        obsidian $APP &
    else
        $APP &
    fi
    APP_PID=$!
fi

if [ -n "$DURATION" ]; then
    sleep "$DURATION"
elif [ -n "$APP_PID" ]; then
    wait "$APP_PID" 2>/dev/null
fi

kill "$CAP_PID" 2>/dev/null
sleep 1
kill -9 "$CAP_PID" 2>/dev/null
[ -n "${BTPID:-}" ] && { kill "$BTPID" 2>/dev/null; kill -9 "$BTPID" 2>/dev/null; }

LINES=$(wc -l < "$LOG" 2>/dev/null || echo '?')
echo
echo "Capture stopped. log=$LOG lines=$LINES"
echo "Next: Obsidian-Mirror-Scanner.sh learn -l $LOG"
echo "Bluetooth (if any): ${LOG%.log}.btmon.log"
