# Methodology

How the numbers in [`../README.md`](../README.md) and
[`FLATPAK-COMPARISON.md`](FLATPAK-COMPARISON.md) were produced, so that you can reproduce them
or prove them wrong.

---

## 1. Principle

One probe, four environments, one machine, one session.

The comparison is only meaningful if the *same* measurement instrument runs in every
environment. A hand-written list of "things Flatpak leaks" would be an assertion. Running the
identical 166-point script inside a real Flatpak sandbox and inside Obsidian Mirror, on the
same host, minutes apart, is a measurement.

The probe is [`../evidence/obsidian-probe.sh`](../evidence/obsidian-probe.sh) — POSIX sh, no
dependencies beyond coreutils/busybox, side-effect free, unprivileged. It emits one
`KEY<TAB>VALUE` line per observable metadata item and never fails on a missing file.

---

## 2. Environment under test

| Component | Version |
|---|---|
| Host OS | Debian GNU/Linux 13 (trixie), kernel 6.1.158+ |
| Host type | cloud VM, 2 vCPU (Intel Xeon @ 2.60 GHz), 2 GB RAM |
| Flatpak | 1.16.6 |
| bubblewrap | 0.11.0 |
| Flatpak runtime | `org.freedesktop.Platform//24.08` (Flathub) |
| Obsidian Mirror | v2.0 |

---

## 3. Exact commands

### Setup

```sh
# Obsidian Mirror
sudo sh Universal-Obsidian-installer-script.sh

# Flatpak
sudo apt-get install -y flatpak bubblewrap        # or: apk add flatpak bubblewrap
flatpak remote-add --user --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user -y flathub org.freedesktop.Platform//24.08
```

### A — host baseline (control)

```sh
PROBE=/opt/obsidian/scripts/obsidian-probe.sh
sh $PROBE > probe-host.tsv
```

### B — Flatpak, default permissions

Running the runtime directly gives the *minimum* permission set — the best case for Flatpak.

```sh
flatpak run --command=sh org.freedesktop.Platform//24.08 -c "$(cat $PROBE)" \
    > probe-flatpak-default.tsv
```

### C — Flatpak, typical desktop-app permissions

The permission set a mainstream Flatpak (browser, media player) commonly requests:

```sh
flatpak run \
  --share=network --share=ipc --socket=wayland --socket=fallback-x11 \
  --socket=pulseaudio --device=dri --filesystem=xdg-download \
  --command=sh org.freedesktop.Platform//24.08 -c "$(cat $PROBE)" \
  > probe-flatpak-appperms.tsv
```

### D — Obsidian Mirror

```sh
obsidian sh $PROBE > probe-obsidian.tsv
```

### Supporting evidence

```sh
# the sandbox's own mount table, read from inside it
flatpak run --command=sh org.freedesktop.Platform//24.08 \
    -c 'cat /proc/self/mountinfo' > flatpak-sandbox-mountinfo.txt

# the machine-id claim, three ways
cat /etc/machine-id
flatpak run --command=sh org.freedesktop.Platform//24.08 -c 'cat /etc/machine-id'
obsidian cat /etc/machine-id

# /sys passthrough
ls /sys/class | wc -l
flatpak run --command=sh org.freedesktop.Platform//24.08 -c 'ls /sys/class | wc -l; ls /sys/block'
obsidian sh -c 'ls /sys/class | wc -l; ls /sys/block'
```

### Analysis

```sh
python3 evidence/compare.py --check    # confirm all four datasets share a key set
python3 evidence/compare.py            # regenerate every table
```

---

## 4. Counting rules

These decide the headline percentages, so they are stated explicitly rather than buried in
code.

An identifier is **counted** only if:

1. the host exposes a **non-empty** value for it — you cannot leak what does not exist; and
2. it is not `0` — a count of zero devices is not an identifier, and scoring `0 == 0` as a leak
   would inflate the figure for *both* tools with meaningless matches; and
3. it is not a `net.*` key — the network layer is disclaimed by both projects, so including it
   would arbitrarily punish whichever tool was measured on a noisier network.

On this host that leaves **82** of the 166 probe keys.

An identifier is scored as **leaked** if the sandbox value is byte-identical to the host value.

### Known bias in this rule — and its direction

A byte-comparison cannot distinguish a *successful spoof that happens to equal reality* from a
*passthrough*. Obsidian Mirror deliberately reports uid 1000, gid 1000, 2 CPU cores,
`GenuineIntel` and `x86_64`. This host genuinely has all of those. Those five are therefore
scored as leaks for Obsidian Mirror even though the spoof worked exactly as designed.

**The bias runs against Obsidian Mirror, not in its favour.** Its real figure is better than
the reported one. The rule is kept because the alternative — special-casing the results of the
tool that wrote the measurement script — is how benchmarks become marketing.

---

## 5. What this machine could not test

This is the most important section in the document.

The test host is a **cloud VM**. It has:

- no DMI/SMBIOS table → no product UUID, no board/chassis/BIOS serials
- no TPM
- no battery
- no discrete or integrated GPU → no `/dev/dri`, no `/sys/class/drm`, no monitor EDID
- no USB devices, no input devices, no sound card, no thermal zones
- no physical disk with a firmware serial (virtio `vda` only)

Those fields therefore read `(none)` in **all four** columns of the raw data. They are excluded
from every count and are labelled *"absent on test host"* wherever they appear in a table.

**They are not claimed as wins for anybody.** What *is* established for those categories is the
mechanism, not the values: the live mount table shows `/sys/class`, `/sys/block`, `/sys/bus`,
`/sys/dev` and `/sys/devices` mounted as read-only `sysfs` inside the Flatpak sandbox, and a
read-only bind mount of `/sys/class` necessarily exposes `/sys/class/dmi` on a machine that has
one. That is an inference from a measured fact, and it is flagged as an inference every time it
is used.

**No code change is needed to measure them.** The probe already emits the relevant keys — the full `dmi.*` set (`product_uuid`, `product_serial`, `board_serial`, `chassis_serial`, …), `gpu.drm_*`, `gpu.edid_bytes`, `gpu.dri_*`, `tpm.*` and `thermal.*` — so the moment someone runs it on real hardware, `compare.py` counts those identifiers automatically. (One honest gap remains in the *probe* itself: there is no dedicated `battery.*` key yet, because this VM has no battery to model one from; adding one is a small, welcome patch.)

**What we expect, and why (from the already-measured mechanism):**

| Identifier | Flatpak (predicted) | Obsidian Mirror (predicted) | Why |
|---|---|---|---|
| `dmi.product_uuid` / `board_serial` / `chassis_serial` | identical to host (leak) | masked / `(none)` | Flatpak bind-mounts the host `sysfs`, so `/sys/class/dmi/id` is the real hardware; Obsidian empties those paths |
| `gpu.drm_*` / `gpu.edid_bytes` (monitor EDID) | identical to host (leak) | masked | same `sysfs` passthrough vs Obsidian's synthetic DRM view |
| `tpm.*` | identical to host (leak) | hidden | TPM is a `sysfs` node, passed through by Flatpak |
| `thermal.*` | identical to host (leak) | masked | `sysfs` passthrough vs synthetic |

These are *predictions from a proven mechanism*, not measurements — they are marked as such on purpose. The mount table that forces them is in `evidence/flatpak-sandbox-mountinfo.txt`.

**Reproducibility check (2026-07-31):** the host probe was re-run standalone on this VM; it emitted all 166 keys and `/etc/machine-id` was byte-identical to the committed `probe-host.tsv` (`67549745dd1a4564be928e47dca271fd`). The §3 commands are valid and reproducible.


### This is the single most useful contribution anyone can make

If you have a **physical laptop or desktop** — DMI table, TPM, battery, real GPU, real disk — running the commands in §3 takes five minutes and closes the largest evidentiary gap in this repository. **No code change is required:** the probe already emits the `dmi.*`, `gpu.drm_*`, `gpu.edid_bytes`, `tpm.*` and `thermal.*` keys, so `compare.py` will fold the new identifiers into every table automatically (the one probe gap to close is a `battery.*` key — see above). Please open an issue with your four TSVs attached, whichever way the result goes; the predicted outcome is in the table above.


Specifically worth checking on real hardware:

```sh
for f in product_uuid product_serial board_serial chassis_serial; do
    echo "host:    $f = $(cat /sys/class/dmi/id/$f 2>/dev/null)"
done
flatpak run --command=sh org.freedesktop.Platform//24.08 \
    -c 'for f in product_uuid product_serial board_serial chassis_serial; do
          echo "flatpak: $f = $(cat /sys/class/dmi/id/$f 2>/dev/null)"; done'
obsidian sh -c 'for f in product_uuid product_serial board_serial chassis_serial; do
          echo "obsidian: $f = $(cat /sys/class/dmi/id/$f 2>/dev/null)"; done'

# monitor serial number and manufacture week
wc -c /sys/class/drm/*/edid
flatpak run --command=sh org.freedesktop.Platform//24.08 -c 'wc -c /sys/class/drm/*/edid'
obsidian sh -c 'wc -c /sys/class/drm/*/edid'
```

---

## 6. Other limitations of this measurement

- **One host, one session.** Single-machine results. The mechanisms are architectural and
  should generalise, but the specific counts will differ on hardware with more to leak — in
  practice, *more* differences, because a physical machine exposes far more identifiers than a
  VM does.
- **Runtime, not an application.** Environment B/C run the freedesktop runtime rather than a
  packaged app, so no vendor-specific `--filesystem=home` grants are present. Real applications
  usually have **more** permissions, not fewer. This is again the best case for Flatpak.
- **The probe is ours.** It was written for Obsidian Mirror's own audit, before this comparison
  existed, and it is checked in so its coverage can be criticised. If it systematically
  measures things Obsidian Mirror happens to be good at, that is a fair objection — open an
  issue with the keys you think are missing.
- **Flatpak version specificity.** Measured against 1.16.6 / runtime 24.08. The `/sys` and
  machine-id behaviour is long-standing and documented, but if a future release changes it,
  this document is wrong and should be corrected rather than defended.
- **No claim about Flatpak's actual security.** Containment, portals, CVE history and the
  permission model were not tested here at all. This measures metadata exposure and nothing
  else.

---

## 7. Raw data

| File | Contents |
|---|---|
| `evidence/probe-host.tsv` | environment A, control |
| `evidence/probe-flatpak-default.tsv` | environment B |
| `evidence/probe-flatpak-appperms.tsv` | environment C |
| `evidence/probe-obsidian.tsv` | environment D |
| `evidence/flatpak-sandbox-mountinfo.txt` | mount table captured inside a live Flatpak sandbox |
| `evidence/sample-audit-report.txt` | a real `obsidian --test` run |
| `evidence/obsidian-probe.sh` | the measurement instrument itself |
| `evidence/compare.py` | the analysis; regenerates every table |
| `evidence/RESULTS.md` | generated output of `compare.py` |

Every table in this repository is generated from those files. No figure in the documentation
was typed by hand.
