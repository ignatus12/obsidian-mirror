#!/bin/sh
# ============================================================
# tools/verify-installer.sh
#
# Checks the properties the installer is not allowed to lose.
# Run it after any change to the launcher or to the embedded
# payloads. It does not need root and installs nothing.
#
#   1. the whole installer parses
#   2. every embedded shell payload parses on its own
#   3. every embedded C payload compiles
#   4. the middle sh -c script contains ZERO single quotes
#      - the launcher passes it as a single-quoted argument, so
#        one apostrophe anywhere inside terminates the string
#        early and the sandbox silently stops being a sandbox
#   5. the strict boundary is absent from the default path
# ============================================================

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INST="$ROOT/Universal-Obsidian-installer-script.sh"
WORK="${TMPDIR:-/tmp}/obsidian-verify.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); }

printf '\nVerifying %s\n\n' "$INST"

# ---- 1. whole installer -------------------------------------------
if sh -n "$INST" 2>"$WORK/e"; then
    ok "installer parses"
else
    bad "installer does not parse"
    sed 's/^/        /' "$WORK/e"
fi

# ---- 2 and 3. extract every payload -------------------------------
awk '
/^cat > "[^"]*" <<.OBSIDIAN_PAYLOAD_[A-Z_]*.$/ {
    match($0, /OBSIDIAN_PAYLOAD_[A-Z_]*/)
    delim = substr($0, RSTART, RLENGTH)
    match($0, /"[^"]*"/)
    dest = substr($0, RSTART + 1, RLENGTH - 2)
    sub(/.*\//, "", dest)
    out = dir "/" delim "__" dest
    while ((getline line) > 0) {
        if (line == delim) break
        print line > out
    }
    close(out)
    next
}
' dir="$WORK" "$INST"

for f in "$WORK"/OBSIDIAN_PAYLOAD_*; do
    [ -f "$f" ] || continue
    name=$(basename "$f" | sed 's/.*__//')
    case "$name" in
        *.c)
            if cc -fsyntax-only -Wall "$f" 2>"$WORK/e"; then
                ok "C payload compiles: $name"
            elif grep -q "No such file or directory" "$WORK/e"; then
                # A header this machine does not have is a fact about
                # this machine, not a defect in the payload.
                printf '  \033[33mskip\033[0m  %s (missing build header here: %s)\n' \
                    "$name" "$(sed -n 's/.*fatal error: \([^:]*\):.*/\1/p' "$WORK/e" | head -1)"
            else
                bad "C payload does not compile: $name"
                sed 's/^/        /' "$WORK/e" | head -8
            fi
            ;;
        *.conf|*.md) ok "data payload present: $name" ;;
        *)
            if sh -n "$f" 2>"$WORK/e"; then
                ok "shell payload parses: $name"
            else
                bad "shell payload does not parse: $name"
                sed 's/^/        /' "$WORK/e" | head -8
            fi
            ;;
    esac
done

# ---- 4. the single-quote rule -------------------------------------
LAUNCH="$WORK/OBSIDIAN_PAYLOAD_LAUNCH__obsidian-launch"
if [ -f "$LAUNCH" ]; then
    awk '
    /^exec unshare .*sh -c .$/ { inside = 1; next }
    inside && /^. -- "\$REAL_UID"/ { inside = 0; next }
    inside { print }
    ' "$LAUNCH" > "$WORK/middle.sh"

    if [ ! -s "$WORK/middle.sh" ]; then
        bad "could not locate the middle sh -c script"
    else
        QUOTES=$(tr -cd "'" < "$WORK/middle.sh" | wc -c | tr -d ' ')
        LINES=$(wc -l < "$WORK/middle.sh" | tr -d ' ')
        if [ "$QUOTES" -eq 0 ]; then
            ok "middle sh -c script: $LINES lines, 0 single quotes"
        else
            bad "middle sh -c script contains $QUOTES single quote(s)"
            grep -n "'" "$WORK/middle.sh" | head -10 | sed 's/^/        /'
        fi
        if sh -n "$WORK/middle.sh" 2>"$WORK/e"; then
            ok "middle sh -c script parses on its own"
        else
            bad "middle sh -c script does not parse"
            sed 's/^/        /' "$WORK/e" | head -8
        fi
    fi
else
    bad "launcher payload not found"
fi

# ---- 5. the default path stays default ----------------------------
INNER="$WORK/OBSIDIAN_PAYLOAD_INNER__obsidian-inner"
if [ -f "$INNER" ]; then
    if grep -q 'OBSIDIAN_HARDEN' "$INNER"; then
        # present, but it must be behind the guard
        if grep -q 'case "${OBSIDIAN_HARDEN:-}" in' "$INNER" &&
           grep -q '""|0|off|no|false) ;;' "$INNER"; then
            ok "obsidian-inner: hardening is behind an explicit off-by-default guard"
        else
            bad "obsidian-inner: hardening is not guarded"
        fi
    fi
fi

if [ -f "$LAUNCH" ]; then
    if grep -q 'case "${OBSIDIAN_HARDEN:-}" in' "$LAUNCH"; then
        ok "obsidian-launch: hardening is behind an explicit off-by-default guard"
    else
        bad "obsidian-launch: hardening guard missing"
    fi
    if grep -q 'exec /bin/sh "$OBSIDIAN_DIR/bin/obsidian-audit"' "$LAUNCH"; then
        ok "obsidian-launch: --test still dispatches through /bin/sh"
    else
        bad "obsidian-launch: the --test nested-namespace fix is gone"
    fi
fi

printf '\n  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
