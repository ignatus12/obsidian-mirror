#!/usr/bin/env python3
"""
Regenerates the comparison tables in README.md and docs/FLATPAK-COMPARISON.md
from the raw probe output in this directory.

No hand-typed numbers appear in the documentation: every figure and every
cell comes out of these four TSV files, which were produced by running the
SAME probe in four environments on one machine in one session.

    python3 evidence/compare.py            print the tables
    python3 evidence/compare.py --check    verify the TSVs are self-consistent
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

FILES = {
    "host":     "probe-host.tsv",
    "fp_min":   "probe-flatpak-default.tsv",
    "fp_app":   "probe-flatpak-appperms.tsv",
    "obsidian": "probe-obsidian.tsv",
}

# Values that mean "this host has no such thing", so nothing can leak.
#
# "0" is included deliberately. A count of zero devices is not an
# identifier, and counting "0 == 0" as a leak would inflate the leak
# figure for BOTH tools with meaningless matches.
NULLISH = {"(none)", "(absent)", "(unset)", "(glxinfo absent)",
           "(fc-list absent)", "(stat absent)", "0", ""}


def load(name):
    d = {}
    with open(os.path.join(HERE, FILES[name]), encoding="utf-8") as fh:
        for line in fh:
            if "\t" in line:
                k, v = line.rstrip("\n").split("\t", 1)
                d[k] = v
    return d


def gradable(H):
    """Keys where the host actually exposes a real value.

    Network keys are excluded: neither tool claims that layer, so counting
    them would flatter one side or the other for no reason.
    """
    return [k for k in H
            if H[k] not in NULLISH and not k.startswith("net.")]


# The identifiers that matter most for cross-session tracking: stable,
# high-entropy, and readable without any special permission.
HIGH_VALUE = [
    ("id.machine_id",     "/etc/machine-id (permanent install UUID)"),
    ("id.boot_id",        "Kernel boot_id (per-boot session ID)"),
    ("id.hostname",       "Hostname"),
    ("id.uname_nodename", "uname nodename"),
    ("id.username",       "Login name (getpwuid)"),
    ("id.env_home",       "$HOME path"),
    ("id.uname_release",  "Kernel release"),
    ("os.proc_version",   "/proc/version build string"),
    ("os.proc_cmdline",   "/proc/cmdline (incl. root UUID)"),
    ("cpu.model",         "CPU model name"),
    ("cpu.bogomips",      "BogoMIPS"),
    ("cpu.cache",         "CPU cache size"),
    ("cpu.flags_len",     "CPU feature-flag count"),
    ("cpu.sysfs_dirs",    "Per-core sysfs topology"),
    ("mem.meminfo_total", "RAM total (/proc/meminfo)"),
    ("blk.devices",       "Block device list"),
    ("blk.serial",        "Disk serial"),
    ("dmi.product_uuid",  "DMI product UUID"),
    ("dmi.board_serial",  "DMI board serial"),
    ("time.zone_abbr",    "Timezone"),
    ("time.btime",        "Boot timestamp"),
    ("time.uptime",       "Uptime"),
    ("ts.mtime_nsec",     "File mtime nanoseconds"),
    ("fs.home_entries",   "/home contents"),
]


def cell(v, width=30):
    if v is None:
        return "(key absent)"
    if len(v) > width:
        return v[:width - 1] + "\u2026"
    return v


def verdict(host, other):
    if other is None:
        return "?"
    if host in NULLISH:
        return "n/t"          # not testable on this machine
    return "LEAK" if other == host else "changed"


def main():
    H = load("host")
    F = load("fp_min")
    A = load("fp_app")
    O = load("obsidian")
    G = gradable(H)

    print("# Measured comparison\n")
    print("Probe keys emitted: %d" % len(H))
    print("Keys where this host exposes a real value (network excluded): %d\n"
          % len(G))

    print("## Headline counts\n")
    print("| Environment | Identical to host | Changed | Altered |")
    print("|---|---|---|---|")
    for label, S in (("Host (control)", H),
                     ("Flatpak, default permissions", F),
                     ("Flatpak, typical app permissions", A),
                     ("Obsidian Mirror", O)):
        same = sum(1 for k in G if S.get(k) == H[k])
        diff = len(G) - same
        print("| %s | %d / %d | %d | %d%% |"
              % (label, same, len(G), diff, round(100 * diff / len(G))))

    print("\n## High-value identifiers, measured\n")
    print("| Identifier | Host (real) | Flatpak | Obsidian Mirror |")
    print("|---|---|---|---|")
    for k, label in HIGH_VALUE:
        h = H.get(k)
        if h is None:
            continue
        note = "" if h not in NULLISH else " *(absent on test host)*"
        print("| %s%s | `%s` | `%s` | `%s` |"
              % (label, note, cell(h), cell(F.get(k)), cell(O.get(k))))

    print("\n## Leaked by Flatpak, covered by Obsidian Mirror\n")
    only = sorted(k for k in G if F.get(k) == H[k] and O.get(k) != H[k])
    for k in only:
        print("- `%s` = `%s`" % (k, cell(H[k], 60)))
    print("\n**%d identifiers.**" % len(only))

    print("\n## Covered by Flatpak, leaked by Obsidian Mirror\n")
    rev = sorted(k for k in G if O.get(k) == H[k] and F.get(k) != H[k])
    for k in rev:
        print("- `%s`: host `%s` -> flatpak `%s`, obsidian `%s`"
              % (k, cell(H[k], 40), cell(F.get(k), 40), cell(O.get(k), 40)))
    print("\n**%d identifiers.** These are real and are documented in "
          "docs/COVERAGE.md; most follow from Flatpak's `pivot_root`, which "
          "Obsidian Mirror deliberately does not do." % len(rev))

    print("\n## Leaked by both\n")
    both = sorted(k for k in G if F.get(k) == H[k] and O.get(k) == H[k])
    for k in both:
        print("- `%s` = `%s`" % (k, cell(H[k], 60)))
    print("\n**%d identifiers.**" % len(both))


if __name__ == "__main__":
    if "--check" in sys.argv:
        sets = {n: set(load(n)) for n in FILES}
        base = sets["host"]
        for n, s in sets.items():
            print("%-10s %d keys  %s" % (n, len(s), "OK" if s == base
                                         else "KEY SET MISMATCH"))
    else:
        main()
