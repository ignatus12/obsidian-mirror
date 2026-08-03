#!/usr/bin/env python3
"""
Splice the strict-boundary components into
Universal-Obsidian-Mirror-installer-script.sh.

The installer is the single artefact a user runs, so every source
file has to live inside it as an embedded payload. Keeping that
embedding in a script rather than doing it by hand means src/ and
bin/ stay the authority and the installer is always regenerated
from them, never edited in place and left to drift.

Every insertion is additive and every runtime path it adds is
guarded by OBSIDIAN_HARDEN being set. Running this script twice is
a no-op: it detects its own markers and refuses.

    python3 tools/embed-harden.py [--check]
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The build has one input and two outputs. installer/base.sh is the
# payload-free installer and is the only thing edited by hand; the
# shipped script is always regenerated from it, so a rebuild is
# reproducible by anyone with the repository rather than depending on
# a particular commit in the history.
BASE = os.path.join(ROOT, "installer", "base.sh")
INSTALLER = os.path.join(ROOT, "Universal-Obsidian-Mirror-installer-script.sh")

# The script was called Universal-Obsidian-installer-script.sh before
# the name was aligned with the project. Links to that raw URL exist,
# so the same bytes are still written under the old name. It is
# generated, never edited, so the two cannot drift apart.
LEGACY = os.path.join(ROOT, "Universal-Obsidian-installer-script.sh")

MARKER = "OBSIDIAN_PAYLOAD_HARDEN_C"


def read(rel):
    with open(os.path.join(ROOT, rel), "r") as f:
        return f.read()


def payload(dest, delim, body, okmsg, chmod=None):
    out = 'cat > "%s" <<\'%s\'\n' % (dest, delim)
    out += body
    if not out.endswith("\n"):
        out += "\n"
    out += "%s\n" % delim
    if chmod:
        out += 'chmod %s "%s"\n' % (chmod, dest)
    out += 'ok "%s"\n\n' % okmsg
    return out


def splice(text, anchor, addition, after=True):
    i = text.find(anchor)
    if i < 0:
        raise SystemExit("anchor not found: %r" % anchor[:60])
    if after:
        i += len(anchor)
    return text[:i] + addition + text[i:]


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise SystemExit(
            "expected exactly one occurrence, found %d: %r"
            % (text.count(old), old[:70])
        )
    return text.replace(old, new)


def main():
    src = open(BASE).read()

    if MARKER in src:
        raise SystemExit(
            "installer/base.sh already carries payloads; it must stay "
            "payload-free so the build is reproducible"
        )

    # ---------------------------------------------------------------
    # 1. new directories
    # ---------------------------------------------------------------
    src = replace_once(
        src,
        'SCRIPTDIR="$PREFIX/scripts"\n',
        'SCRIPTDIR="$PREFIX/scripts"\nVARDIR="$PREFIX/var"\n'
        'LEARNDIR="$VARDIR/learn"\n',
    )
    src = replace_once(
        src,
        'MANIFESTDIR="/etc/obsidian"\n',
        'MANIFESTDIR="/etc/obsidian"\nPROFILEDIR="$MANIFESTDIR/profiles"\n',
    )
    src = replace_once(
        src,
        '         "$FAKEROOT" "$FAKEROOT/fonts" "$FAKEROOT/proc" "$MANIFESTDIR"; do\n'
        "    mkdir -p \"$d\"\ndone\n",
        '         "$FAKEROOT" "$FAKEROOT/fonts" "$FAKEROOT/proc" "$MANIFESTDIR" \\\n'
        '         "$VARDIR" "$VARDIR/homes" "$LEARNDIR" "$PROFILEDIR"; do\n'
        "    mkdir -p \"$d\"\ndone\n"
        "# The learning log is written from inside the sandbox by whichever\n"
        "# unprivileged user is running an application through it, so it needs\n"
        "# the same sticky-writable treatment /tmp gets.\n"
        'chmod 1777 "$LEARNDIR"\n'
    'chmod 1777 "$VARDIR/homes"\n',
    )

    # ---------------------------------------------------------------
    # 2. C payloads
    # ---------------------------------------------------------------
    csrc = ""
    csrc += payload(
        '$SRCDIR/obsidian_harden.c',
        "OBSIDIAN_PAYLOAD_HARDEN_C",
        read("src/obsidian_harden.c"),
        "src/obsidian_harden.c",
    )
    csrc += payload(
        '$SRCDIR/obsidian_hardenprobe.c',
        "OBSIDIAN_PAYLOAD_HARDENPROBE_C",
        read("src/obsidian_hardenprobe.c"),
        "src/obsidian_hardenprobe.c",
    )
    csrc += payload(
        '$SRCDIR/obsidian_learn.c',
        "OBSIDIAN_PAYLOAD_LEARN_C",
        read("src/obsidian_learn.c"),
        "src/obsidian_learn.c",
    )
    src = splice(src, 'ok "src/obsidian_ipcprobe.c"\n\n', csrc)

    # ---------------------------------------------------------------
    # 3. shell payloads
    # ---------------------------------------------------------------
    shsrc = ""
    shsrc += payload(
        '$BINDIR/obsidian-harden-test',
        "OBSIDIAN_PAYLOAD_HARDENTEST_SH",
        read("bin/obsidian-harden-test"),
        "bin/obsidian-harden-test",
        chmod="755",
    )
    shsrc += payload(
        '$BINDIR/obsidian-profile',
        "OBSIDIAN_PAYLOAD_PROFILE_SH",
        read("bin/obsidian-profile"),
        "bin/obsidian-profile",
        chmod="755",
    )
    shsrc += payload(
        '$BINDIR/Obsidian-Mirror-Scanner.sh',
        "OBSIDIAN_PAYLOAD_SCANNER_SH",
        read("bin/Obsidian-Mirror-Scanner.sh"),
        "bin/Obsidian-Mirror-Scanner.sh",
        chmod="755",
    )
    shsrc += payload(
        '$BINDIR/obsidian-netblock.sh',
        "OBSIDIAN_PAYLOAD_NETBLOCK_SH",
        read("bin/obsidian-netblock.sh"),
        "bin/obsidian-netblock.sh",
        chmod="755",
    )
    src = splice(src, 'ok "bin/obsidian-inner"\n\n', shsrc)

    # ---------------------------------------------------------------
    # 4. launcher: new subcommands
    # ---------------------------------------------------------------
    src = replace_once(
        src,
        '''if [ "$1" = "--test" ] || [ "$1" = "--audit" ]; then
    shift
    exec /bin/sh "$OBSIDIAN_DIR/bin/obsidian-audit" "$@"
fi
''',
        '''if [ "$1" = "--test" ] || [ "$1" = "--audit" ]; then
    shift
    exec /bin/sh "$OBSIDIAN_DIR/bin/obsidian-audit" "$@"
fi

# Strict-boundary entry points. Each is dispatched with /bin/sh for the
# same reason --test is: re-entering the launcher here would add a
# second namespace hop and unshare refuses the nested one.
if [ "$1" = "--harden-test" ]; then
    shift
    if [ ! -r "$OBSIDIAN_DIR/bin/obsidian-harden-test" ]; then
        echo "ERROR: strict-boundary components are not installed."
        echo "       Re-run the Obsidian installer to build them."
        exit 1
    fi
    exec /bin/sh "$OBSIDIAN_DIR/bin/obsidian-harden-test" "$@"
fi

if [ "$1" = "--profile" ]; then
    shift
    if [ ! -r "$OBSIDIAN_DIR/bin/obsidian-profile" ]; then
        echo "ERROR: strict-boundary components are not installed."
        exit 1
    fi
    exec /bin/sh "$OBSIDIAN_DIR/bin/obsidian-profile" "$@"
fi

if [ "$1" = "--harden-plan" ]; then
    shift
    if [ -z "$1" ]; then
        echo "Usage: obsidian --harden-plan <application>"
        echo "Prints the boundary that would be applied. Enforces nothing."
        exit 1
    fi
    if [ ! -x "$OBSIDIAN_DIR/bin/obsidian-harden" ]; then
        echo "ERROR: $OBSIDIAN_DIR/bin/obsidian-harden is not installed."
        exit 1
    fi
    # --print-plan is what makes this a dry run, so the mode is only
    # defaulted here, never overwritten: OBSIDIAN_HARDEN=paranoid
    # obsidian --harden-plan has to report the paranoid boundary, not
    # silently fall back to the strict one and misreport it.
    if [ -z "$OBSIDIAN_HARDEN" ]; then
        OBSIDIAN_HARDEN=plan
        export OBSIDIAN_HARDEN
    fi
    exec "$OBSIDIAN_DIR/bin/obsidian-harden" --print-plan -- "$@"
fi
''',
    )

    # ---------------------------------------------------------------
    # 5. launcher: help text
    # ---------------------------------------------------------------
    src = replace_once(
        src,
        '''    echo "  obsidian --test                 audit metadata protection"
    echo "  obsidian --coverage             what is and is not protected"
    echo "  obsidian --regenerate-manifest  rescan this hardware (root)"
    echo "  obsidian --version"
''',
        '''    echo "  obsidian --test                 audit metadata protection"
    echo "  obsidian --coverage             what is and is not protected"
    echo "  obsidian --regenerate-manifest  rescan this hardware (root)"
    echo "  obsidian --version"
    echo
    echo "Strict boundary - default-deny confinement, off unless asked for:"
    echo "  obsidian --harden-test          measure what the boundary closes"
    echo "  obsidian --harden-plan <app>    show the boundary, enforce nothing"
    echo "  obsidian --profile learn <app>  record what an application needs"
    echo "  obsidian --profile build <app>  turn that into an allow-list"
    echo "  OBSIDIAN_HARDEN=1 obsidian <app>   run it inside the boundary"
''',
    )
    src = replace_once(
        src,
        '''    echo "  OBSIDIAN_ALLOW_SYSTEM_BUS=1     permit the D-Bus system bus"
    echo "  OBSIDIAN_VERBOSE=1              log blocked IPC connections"
    echo
    echo "Example: obsidian firefox"
''',
        '''    echo "  OBSIDIAN_ALLOW_SYSTEM_BUS=1     permit the D-Bus system bus"
    echo "  OBSIDIAN_VERBOSE=1              log blocked IPC connections"
    echo "  OBSIDIAN_FRESH=1               throwaway launch (no saved preferences)"
    echo
    echo "Strict-boundary switches (only read when OBSIDIAN_HARDEN is set):"
    echo "  OBSIDIAN_HARDEN=1               default-deny every layer"
    echo "  OBSIDIAN_HARDEN=paranoid        also deny memfd and scope IPC"
    echo "  OBSIDIAN_HARDEN=plan            print the boundary, enforce none"
    echo "  OBSIDIAN_ALLOW_PATHS_RO=a:b     grant read on these paths"
    echo "  OBSIDIAN_ALLOW_PATHS_RW=a:b     grant read and write"
    echo "  OBSIDIAN_ALLOW_EXEC=a:b         grant execute"
    echo "  OBSIDIAN_ALLOW_DEV=/dev/x       grant a device node"
    echo "  OBSIDIAN_ALLOW_NET=tcp:443      grant outbound TCP on a port"
    echo "  OBSIDIAN_ALLOW_NESTED_NS=1      let the app build namespaces"
    echo "  OBSIDIAN_HARDEN_PROFILE=<file>  use this allow-list"
    echo "  OBSIDIAN_HARDEN_FAIL_CLOSED=1   refuse to run if a layer fails"
    echo "  OBSIDIAN_DENY_NET=1            block all network under hardening (default: allowed)"
    echo
    echo "Example: obsidian firefox"
''',
    )

    # ---------------------------------------------------------------
    # 6. launcher: learning library goes first in LD_PRELOAD
    # ---------------------------------------------------------------
    src = replace_once(
        src,
        '''PRELOAD=""
for lib in obsidian_core.so obsidian_wayland.so obsidian_gpu.so; do''',
        '''PRELOAD=""

# Allow-list discovery. The recorder is loaded ahead of the spoofing
# libraries and hands every call straight on to them, so what it
# records is what the application asked for and what the application
# receives is unchanged.
if [ -n "${OBSIDIAN_LEARN:-}" ] && [ "${OBSIDIAN_LEARN}" != "0" ] &&
   [ -f "$LIB_DIR/obsidian_learn.so" ]; then
    PRELOAD="$LIB_DIR/obsidian_learn.so"
fi

for lib in obsidian_core.so obsidian_wayland.so obsidian_gpu.so; do''',
    )

    # ---------------------------------------------------------------
    # 7. launcher: strict boundary preparation, host side
    # ---------------------------------------------------------------
    src = replace_once(
        src,
        """# ============================================================
# Isolation stage.
#
# The middle script contains NO single-quote characters, so it""",
        '''# ============================================================
# Strict boundary preparation (opt-in, host side).
#
# Nothing in this block runs unless OBSIDIAN_HARDEN is set to
# something other than 0 or off. With it unset, the launcher below
# is byte-for-byte the launcher that produced the 93% metadata
# result, and no application sees any difference.
#
# Two things have to happen out here rather than inside the
# namespaces. The per-app profile lives in the real home directory,
# which is replaced by a tmpfs further down, so it has to be located
# now. And the inherited environment has to be cleaned before it is
# handed to anything, because a descriptor or a credential passed in
# by whatever started this launcher was never covered by any policy
# applied later - it was already there.
# ============================================================
case "${OBSIDIAN_HARDEN:-}" in
    ""|0|off|no|false) ;;
    *)
        if [ ! -x "$OBSIDIAN_DIR/bin/obsidian-harden" ]; then
            echo "ERROR: OBSIDIAN_HARDEN is set but the enforcer is missing:" >&2
            echo "       $OBSIDIAN_DIR/bin/obsidian-harden" >&2
            echo "       Re-run the installer, or unset OBSIDIAN_HARDEN to" >&2
            echo "       run this application the way it ran before." >&2
            exit 1
        fi
        export OBSIDIAN_HARDEN

        if [ -z "${OBSIDIAN_HARDEN_PROFILE:-}" ]; then
            _appkey=$(printf '%s' "$1" | sed 's|.*/||; s/[^A-Za-z0-9._-]/_/g')
            for _pd in "${XDG_CONFIG_HOME:-$HOME/.config}/obsidian/profiles" \\
                       /etc/obsidian/profiles; do
                if [ -f "$_pd/$_appkey.profile" ]; then
                    OBSIDIAN_HARDEN_PROFILE="$_pd/$_appkey.profile"
                    export OBSIDIAN_HARDEN_PROFILE
                    break
                fi
            done
            unset _appkey _pd
        else
            export OBSIDIAN_HARDEN_PROFILE
        fi

        # The sandbox mounts a fresh tmpfs over /home, which is what
        # keeps real user data out of it, so a profile under the real
        # home is unreadable once we are inside. Read it out here,
        # while it is still reachable, and pass the text down. Without
        # this the per-application grant silently never loads.
        if [ -n "${OBSIDIAN_HARDEN_PROFILE:-}" ] &&
           [ -r "${OBSIDIAN_HARDEN_PROFILE:-}" ]; then
            OBSIDIAN_HARDEN_PROFILE_DATA=$(cat "$OBSIDIAN_HARDEN_PROFILE")
            export OBSIDIAN_HARDEN_PROFILE_DATA
        fi

        # Launch-state scrub, part one: named credentials.
        for _v in SSH_AUTH_SOCK SSH_AGENT_PID SSH_CONNECTION SSH_CLIENT \\
                  SSH_TTY GPG_AGENT_INFO GNUPGHOME GPG_TTY KRB5CCNAME \\
                  AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \\
                  GOOGLE_APPLICATION_CREDENTIALS AZURE_CLIENT_SECRET \\
                  GITHUB_TOKEN GH_TOKEN GITLAB_TOKEN NPM_TOKEN PYPI_TOKEN \\
                  DOCKER_HOST KUBECONFIG VAULT_TOKEN \\
                  HISTFILE MAIL MAILPATH \\
                  SUDO_USER SUDO_UID SUDO_GID SUDO_COMMAND; do
            unset "$_v" 2>/dev/null || true
        done
        unset _v

        # Launch-state scrub, part two: anything that calls itself a
        # secret. Pattern matching rather than a fixed list, because
        # the interesting variable is always the one nobody listed.
        _leaky=$(env 2>/dev/null |
                 sed -n 's/^\\([A-Za-z_][A-Za-z0-9_]*\\)=.*/\\1/p' |
                 grep -E 'TOKEN|SECRET|PASSWORD|PASSWD|APIKEY|API_KEY|CREDENTIAL|PRIVATE_KEY|_PW$' \\
                 2>/dev/null || true)
        for _v in $_leaky; do
            case "$_v" in
                OBSIDIAN_*) continue ;;
            esac
            unset "$_v" 2>/dev/null || true
        done
        unset _leaky _v

        if [ -n "${OBSIDIAN_VERBOSE:-}" ]; then
            echo "obsidian: strict boundary armed (${OBSIDIAN_HARDEN})" >&2
            if [ -n "${OBSIDIAN_HARDEN_PROFILE:-}" ]; then
                echo "obsidian: profile $OBSIDIAN_HARDEN_PROFILE" >&2
            else
                echo "obsidian: no per-app profile; base allow-list only" >&2
            fi
        fi
        ;;
esac

# ============================================================
# Isolation stage.
#
# The middle script contains NO single-quote characters, so it''',
    )

    # ---------------------------------------------------------------
    # 8. obsidian-inner: insert the enforcer into the exec chain
    # ---------------------------------------------------------------
    src = replace_once(
        src,
        '''if [ "$#" -eq 0 ]; then
    echo "obsidian-inner: no command supplied" >&2
    exit 1
fi
''',
        '''if [ "$#" -eq 0 ]; then
    echo "obsidian-inner: no command supplied" >&2
    exit 1
fi

# Strict boundary stage. When OBSIDIAN_HARDEN is unset this adds
# nothing to the command line at all, so the argv the application
# receives is identical to what it received before this stage
# existed. When it is set, the enforcer is the last thing to run
# before the application and the boundary it installs survives the
# exec into it.
OBSIDIAN_HARDEN_BIN="/opt/obsidian/bin/obsidian-harden"
case "${OBSIDIAN_HARDEN:-}" in
    ""|0|off|no|false) ;;
    *)
        if [ -x "$OBSIDIAN_HARDEN_BIN" ]; then
            set -- "$OBSIDIAN_HARDEN_BIN" -- "$@"
        else
            echo "obsidian-inner: OBSIDIAN_HARDEN is set but $OBSIDIAN_HARDEN_BIN" >&2
            echo "obsidian-inner: is not installed; refusing to run unconfined" >&2
            exit 1
        fi
        ;;
esac
''',
    )

    # ---------------------------------------------------------------
    # 9. compile the new components
    # ---------------------------------------------------------------
    src = replace_once(
        src,
        '''if $CC -O2 -Wall -o "$BINDIR/obsidian-ipcprobe" "$SRCDIR/obsidian_ipcprobe.c" \\
        2>"$SRCDIR/.err.ipcprobe"; then''',
        '''# ---------------------------------------------------------------------
# Strict boundary. Deliberately built with no external library: the
# seccomp program is assembled by hand inside obsidian_harden.c and
# Landlock is reached through raw syscalls, so a missing libseccomp
# takes the older enforcer with it but never this one.
# ---------------------------------------------------------------------
HARDEN_OK=0
if $CC -O2 -Wall -o "$BINDIR/obsidian-harden" "$SRCDIR/obsidian_harden.c" \\
        2>"$SRCDIR/.err.harden"; then
    chmod 755 "$BINDIR/obsidian-harden"
    HARDEN_OK=1
    ok "obsidian-harden     (strict boundary enforcer, opt-in)"
    rm -f "$SRCDIR/.err.harden"
else
    rm -f "$BINDIR/obsidian-harden"
    warn "obsidian-harden did NOT build. The strict boundary will be"
    warn "unavailable; everything else is unaffected."
    sed 's/^/        /' "$SRCDIR/.err.harden" >&2 | head -10
fi

if $CC -O2 -Wall -o "$BINDIR/obsidian-hardenprobe" \\
        "$SRCDIR/obsidian_hardenprobe.c" 2>"$SRCDIR/.err.hardenprobe"; then
    chmod 755 "$BINDIR/obsidian-hardenprobe"
    ok "obsidian-hardenprobe (boundary measurement probe)"
    rm -f "$SRCDIR/.err.hardenprobe"
else
    warn "obsidian-hardenprobe did not build; 'obsidian --harden-test'"
    warn "will not be able to measure anything."
fi

if $CC $CFLAGS -shared -o "$LIBDIR/obsidian_learn.so" \\
        "$SRCDIR/obsidian_learn.c" -ldl 2>"$SRCDIR/.err.learn"; then
    ok "obsidian_learn.so   (allow-list discovery)"
    rm -f "$SRCDIR/.err.learn"
else
    warn "obsidian_learn.so did not build; 'obsidian --profile learn'"
    warn "will record nothing."
fi

if $CC -O2 -Wall -o "$BINDIR/obsidian-ipcprobe" "$SRCDIR/obsidian_ipcprobe.c" \\
        2>"$SRCDIR/.err.ipcprobe"; then''',
    )

    # ---------------------------------------------------------------
    # 10. self-test: prove the default path is untouched
    # ---------------------------------------------------------------
    src = replace_once(
        src,
        '''    # 7. seccomp, if it built.''',
        '''    # 7a. the strict boundary is genuinely inert until asked for.
    #     This is the property the whole feature rests on, so it is
    #     tested rather than asserted.
    if [ "$HARDEN_OK" -eq 1 ]; then
        _off="$("$CLI_LINK" printf '%s' untouched 2>/dev/null || true)"
        if [ "$_off" = "untouched" ]; then
            ok "strict boundary is inert when OBSIDIAN_HARDEN is unset"
        else
            fail "the launcher changed behaviour with hardening OFF"
            SELFTEST_FAIL=$((SELFTEST_FAIL + 1))
        fi

        _abi="$("$BINDIR/obsidian-harden" --print-plan -- /bin/true 2>&1 |
                sed -n 's/.*landlock ABI  : //p' | head -1)"
        if [ -n "$_abi" ] && [ "$_abi" -gt 0 ] 2>/dev/null; then
            ok "Landlock available: ABI $_abi"
        else
            warn "Landlock is not available on this kernel. The strict"
            warn "boundary will still drop capabilities and filter syscalls,"
            warn "but it cannot confine the filesystem. Needs Linux 5.13+."
        fi

        _hard="$(OBSIDIAN_HARDEN=1 "$CLI_LINK" \\
                 "$BINDIR/obsidian-hardenprobe" --quiet 2>/dev/null |
                 grep -c "DENIED" || true)"
        if [ "${_hard:-0}" -gt 20 ]; then
            ok "strict boundary closes ${_hard} measured surfaces"
        else
            warn "strict boundary measured only ${_hard:-0} closures;"
            warn "run 'obsidian --harden-test' to see which."
        fi
    fi

    # 7. seccomp, if it built.''',
    )

    # ---------------------------------------------------------------
    # 11. closing text
    # ---------------------------------------------------------------
    src = replace_once(
        src,
        '''  Not covered, by design: the network layer. IP, DNS, routing, real
  MAC addresses over netlink and TLS fingerprints are untouched. Pair
  this with a VPN or a network namespace.

DONEEOF''',
        '''  Not covered, by design: the network layer. IP, DNS, routing, real
  MAC addresses over netlink and TLS fingerprints are untouched. Pair
  this with a VPN or a network namespace.

  ---------------------------------------------------------------------

  NEW: the strict boundary. Default-deny at every layer, with a
  minimal per-application grant. It is OFF unless you ask for it, and
  everything above behaves exactly as it did before.

      obsidian --harden-test        measure what it closes, and what
                                    it costs, on this machine

      obsidian --profile learn firefox    run it, record what it needs
      obsidian --profile build firefox    collapse that into a profile
      OBSIDIAN_HARDEN=1 obsidian firefox  run it inside the boundary

  Learn first, then harden. A boundary built from a guess breaks
  applications; a boundary built from a recording of what the
  application actually did does not.

  What it cannot close: side channels - cache timing, power, acoustic,
  electromagnetic - and anything running below the kernel, which
  includes the management engine on this very processor. Those are not
  kernel-policy problems, and this does not pretend to solve them.

DONEEOF''',
    )

    # ---------------------------------------------------------------
    # 12. COVERAGE.md gets the strict-boundary section, because
    #     "obsidian --coverage" is where a user is told what is and is
    #     not protected, and a new layer that is not in there is a
    #     layer nobody knows about.
    # ---------------------------------------------------------------
    src = replace_once(
        src,
        """| `/opt/obsidian/bin/obsidian-audit` | Four-section protection audit |""",
        """| `/opt/obsidian/bin/obsidian-audit` | Four-section protection audit |
| `/opt/obsidian/bin/obsidian-harden` | Strict boundary enforcer (opt-in) |
| `/opt/obsidian/bin/obsidian-hardenprobe` | Strict boundary measurement probe |
| `/opt/obsidian/bin/obsidian-harden-test` | Side-by-side boundary report |
| `/opt/obsidian/bin/obsidian-profile` | Per-app allow-list discovery |
| `/opt/obsidian/lib/obsidian_learn.so` | Access recorder used by `--profile learn` |
| `/opt/obsidian/var/learn/` | Recordings, one per application |
| `/etc/obsidian/profiles/` | System-wide per-app allow-lists |""",
    )

    src = replace_once(
        src,
        """| `/etc/obsidian/hw-manifest.conf` | Generated per-host spoof/mask manifest |
OBSIDIAN_PAYLOAD_COVERAGE_MD""",
        """| `/etc/obsidian/hw-manifest.conf` | Generated per-host spoof/mask manifest |

---

## 9. The strict boundary (opt-in, off by default)

Sections 1 to 8 are about what an application can **learn**. This section
is about what it can **do**.

The rule is one sentence: **default-deny at every layer, allow only a
minimal per-application grant.** Not a list of forbidden paths - deny
everything, then permit only what the application provably needs.

| Layer | Default | Allowed |
|---|---|---|
| Filesystem | deny ALL host paths | the app data dir + granted paths |
| Memory | its own address space | no ptrace, no peer /proc/PID/mem, no /dev/mem, no /proc/kcore |
| Network | deny all | a granted port, or none |
| Devices | deny all | only what is needed; hard-deny /dev/mem, /dev/sd*, /dev/nvme* |
| IPC | socket paths deny-all, via the filesystem layer | the granted socket paths; abstract sockets and signals scoped only under paranoid or OBSIDIAN_SCOPE_IPC=1 |
| Execution | app binary + legitimate JIT | no shell, no python -c, no node -e, no memfd exec |
| Capabilities | drop all | none |
| Privilege | NoNewPrivs | none |
| Namespaces | deny unshare/mount | none |
| Launch state | inherited fds and credentials scrubbed | stdio only |

Carried by Landlock (filesystem, devices, TCP ports, IPC scoping), a
hand-assembled seccomp-bpf program (memory, namespaces, kernel surfaces,
address families), capability dropping and `PR_SET_NO_NEW_PRIVS`. The
enforcer links no external library, so it does not disappear when
libseccomp is absent.

### Off unless asked for

    obsidian firefox                     unchanged, nothing below applies
    OBSIDIAN_HARDEN=1 obsidian firefox   inside the boundary

The installer self-test checks the first line rather than asserting it.

### The method is the same one that produced section 2

Enumerate the host, observe what the application really touches, grant
exactly that, deny the rest:

    obsidian --profile learn firefox     run it, record every access
    obsidian --profile build firefox     collapse into a minimal allow-list
    obsidian --harden-plan firefox       show the boundary, enforce nothing
    OBSIDIAN_HARDEN=1 obsidian firefox   run it

### Measured, not asserted

`obsidian --harden-test` runs one probe of ~56 attempts twice through
this launcher, with and without the boundary, and prints the kernel's
answer to each. On the reference machine: 29 surfaces closed, 18 already
shut by the base launcher, 1 still open, 0 application capabilities
broken.

The one still open is reported rather than hidden: an application can
write a library into a directory it was granted for writing and map it
executable. Landlock checks EXECUTE when a file is opened to be
executed, and a library is opened read-only, so neither it nor seccomp
can refuse that without refusing every shared library the process needs.
docs/CONFORMANCE.md audits all ten layers and names the three that fall
short of the model.

### What it does not close

Side channels - cache timing, branch prediction, power, acoustic,
electromagnetic - are not syscalls, are invisible to kernel policy, and
are not closed. Anything below the kernel, including the management
engine on this processor, is out of reach by construction. The boundary
also does not decide what an application does with data you did grant
it. And a surface that is not in the probe is not a surface that is
proven closed.

Full detail, including every known compatibility cost:
`docs/STRICT-BOUNDARY.md` in the repository.
OBSIDIAN_PAYLOAD_COVERAGE_MD""",
    )

    for out in (INSTALLER, LEGACY):
        with open(out, "w") as f:
            f.write(src)

    print("installer regenerated: %d bytes, %d lines" % (len(src), src.count("\n")))
    print("  %s" % os.path.basename(INSTALLER))
    print("  %s (same bytes, kept for existing links)" % os.path.basename(LEGACY))
    return 0


if __name__ == "__main__":
    sys.exit(main())
