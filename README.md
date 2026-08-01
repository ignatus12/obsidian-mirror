# Obsidian Mirror

## Your apps read your computer's name tag. This gives them a fake one.

**And the apps keep working.**

Every program you open quietly reads *who your computer is*: a permanent
ID number, its name, its exact chips and serial numbers. It reads this
**on your machine, before it touches the internet** — which is why a VPN
or Tor never sees it, and never stops it.

Obsidian Mirror shows the program **a different computer**. A new fake
one every single time you launch.

| | Without this | With this |
|---|---|---|
| Who the app thinks you are | **you, exactly** | a stranger, new every launch |
| Your permanent install ID | handed over | swapped |
| Hostname, CPU, RAM, serial numbers | handed over | swapped |
| **Does your app still work?** | yes | **yes** |

```sh
obsidian firefox     # same Firefox. different computer, as far as it can tell.
```

---

### It has two layers. The first is on, the second you switch on.

| | What it stops | Status | Measured right now |
|---|---|---|---|
| 🪞 **The Mirror** | what an app can **learn** about your machine | **on by default** | **68 of 74** identity checks faked — **91%** |
| 🔒 **The Boundary** | what an app can **do** to your machine | **off** until you ask | **29** ways in shut, **1** still open, **0** apps broken |

The Boundary is off by default on purpose: nothing you already run
changes until you type `OBSIDIAN_HARDEN=1` yourself.

---

### Install (one file, Linux)

```sh
wget https://raw.githubusercontent.com/ignatus12/obsidian-mirror/main/Universal-Obsidian-Mirror-installer-script.sh
sudo sh Universal-Obsidian-Mirror-installer-script.sh

obsidian firefox     # then just put "obsidian" in front of anything
```

No dependencies to hunt down, no runtime, no daemon. The installer
compiles what it needs, installs it, and then **tests itself in front of
you** — it prints nine checks and refuses to claim success if one fails.

---

### Don't believe me. Check it yourself.

Every number above prints on *your* machine, from *your* hardware, in
under a minute. Nothing here is hand-typed:

```sh
obsidian --test          # the 91%: what got faked, what leaked
obsidian --harden-test   # the 29 / 1 / 0: every attempt, tried twice
obsidian --coverage      # what is NOT covered, and why
```

`--harden-test` runs each attack **twice** — once without the boundary,
once with it — and prints both columns side by side. If a row says
`ALLOWED ALLOWED`, the boundary did nothing, and it says so.
**One row does say that.** See below.

---

### What it does *not* do (the short list)

- It is **not** anonymity, and **not** a VPN replacement. It hides *which
  computer you are*, not *what you do*.
- **Side channels** (timing, power, sound, radio) are not something any
  kernel can close. Not closed here. Never will be.
- **Below the operating system** — the management engine baked into your
  CPU — is out of reach of every tool on this page, including this one.
- **One boundary hole is open and measured:** an app can write a library
  and load it back. Explained honestly in
  [`docs/CONFORMANCE.md`](docs/CONFORMANCE.md).

---

<details>
<summary><b>The long version — the vector, the proof, the comparisons</b> (click)</summary>

<br>

*This project is presented from the **application-metadata-leak** perspective: why the privacy tools people actually trust — **VPN, Tor, Tor Browser** — do **not** protect your device's identity, and what does. The Flatpak comparison further below is the concrete measurement that proves the mechanism; it is no longer the lead story.*

> *"We kill people based on metadata."* — Gen. Michael Hayden, former director of **both** the NSA and the CIA, at a Johns Hopkins debate (2014) [1]

Most people who care about privacy buy a **VPN**, open **Tor**, or use the **Tor Browser** and feel protected. They are not — at least not against the attack vector this project is about.

A VPN, Tor and the Tor Browser change **how your traffic travels**. They do *nothing* about **what your own applications read about your machine** before they ever touch the network: your permanent install UUID (`/etc/machine-id`), your DMI serial numbers, your CPU model, your hostname, your filesystem clock, the fonts you have installed. Those are read locally, by every app, on every launch — and they form a device fingerprint that survives IP changes, VPNs, Tor, *and* OS reinstalls.

**Obsidian Mirror** is the missing layer: it spoofs the host metadata that applications can read, so the telemetry your apps emit carries a synthetic device identity instead of your real one.

---

## The misconception, in one picture

| What you reach for | What it actually protects | Stops apps from reading your real host metadata? | This vector |
|---|---|---|---|
| Nothing (bare host) | — | No | ❌ fully exposed |
| **VPN** | your IP from the destination server | **No** | ❌ fully exposed |
| **Tor** | your origin IP from the destination | **No** | ❌ fully exposed |
| **Tor Browser** | *browser* fingerprint, inside that one browser | **Partial** — only inside Tor Browser; OS `machine-id`/DMI still readable by the browser *and* every other app | ⚠️ minimal |
| Firefox + uBlock Origin | ads/trackers in the page | **No** | ❌ fully exposed |
| **Flatpak** (sandbox) | what an app *can do* (files, devices) | **No — by design** (see measured proof below) | ❌ 49/82 identical |
| **Obsidian Mirror** | what an app *can learn* about the host | **Yes** | ✅ 24/82 identical |

*"Identical" = the environment reported the host's real value byte-for-byte (a leak). The Flatpak and Obsidian rows are **measured**; the VPN/Tor/Tor Browser rows are **architectural** — those tools operate at the network layer and do not modify the local files an app reads, so all 82 host identifiers remain exposed by design.*

---

## Why "metadata" is the real surveillance tool

Hayden's point is not rhetoric. The former NSA General Counsel Stewart Baker put it plainly:

> *"Metadata absolutely tells you everything about somebody's life. If you have enough metadata, you don't really need content."* — Stewart Baker [2]

And Bruce Schneier, in *Data and Goliath*:

> *"The truth is, though, that the difference [between content and metadata] is largely illusory. It's all data about us."* — Bruce Schneier [2]

Your IP address is the *easy* thing to hide and the *least* durable identifier you have — it changes when you reconnect, when you travel, when you use a VPN or Tor. The metadata an application reads from your **local machine** is the opposite: stable, high-entropy, and unique. A `machine-id` is a permanent install UUID that persists across reboots *and* OS reinstalls unless explicitly wiped. Combine it with your DMI serial, CPU model, RAM size, and filesystem-clock skew and you have a device fingerprint that re-identifies you no matter which network you're on.

> So when people say *"I use a VPN, I'm anonymous,"* they are willfully ignorant of the vector that matters: **the application on their machine is still handing out their real device identity to every service it contacts.** The VPN hides the envelope; it does nothing about the letter inside.

The full, fair breakdown of VPN / Tor / Tor Browser vs this vector is in [`docs/METADATA-VS-POPULAR-PRIVACY-TOOLS.md`](docs/METADATA-VS-POPULAR-PRIVACY-TOOLS.md).

---

## The measured proof: even a sandbox leaks by design

Flatpak is the "private" way to run desktop apps. We ran the *same* 166-point probe in four environments on one machine and counted how many of the 82 identifiers this host actually exposes were reported byte-identically to the host (a leak):

| Environment | Identical to host | Changed | Altered |
|---|---|---|---|
| Host (control) | 82 / 82 | 0 | 0 % |
| **Flatpak, default permissions** | **49 / 82** | 33 | 40 % |
| **Flatpak, typical app permissions** | **47 / 82** | 35 | 43 % |
| **Obsidian Mirror** | **24 / 82** | 58 | 71 % |

A few of the 82, measured on this host:

| Identifier | Host (real) | Flatpak | Obsidian Mirror |
|---|---|---|---|
| `/etc/machine-id` (permanent install UUID) | `67549745dd1a4564…` | `67549745dd1a4564…` 🔴 | `7f96d11360c37262…` 🟢 |
| Hostname | `e2b.local` | `e2b.local` 🔴 | `workstation-0f6678` 🟢 |
| CPU model name | `Intel(R) Xeon(R) @ 2.60GHz` | `Intel(R) Xeon(R) @ 2.60GHz` 🔴 | `Intel(R) Core(TM) i5-8250U` 🟢 |
| RAM total (/proc/meminfo) | `2032608` | `2032608` 🔴 | `8192000` 🟢 |
| File mtime nanoseconds | `506246762` | `118246762` 🔴 (full res leaked) | `0` 🟢 |

🔴 = identical to host (leaked). 🟢 = altered (protected).

Flatpak passes `/etc/machine-id`, the host's real `sysfs` (`/sys/class`, `/sys/block`, …), the CPU model, RAM total and nanosecond `mtime` straight through — because its sandbox is about *capabilities*, not *identity*. The full ledger, the sandbox mount table, and how we counted are in [`docs/FLATPAK-COMPARISON.md`](docs/FLATPAK-COMPARISON.md).

> A VPN or Tor is **not even a sandbox** — it changes zero of those 82 identifiers. Flatpak at least *tries* (and still leaks ~60%). The popular "privacy" tools people actually trust don't even try.

---

</details>

---

## What Obsidian Mirror does

Obsidian Mirror wraps an application and feeds it a **synthetic host identity**: a fresh per-launch `machine-id`, a randomized hostname, spoofed DMI, a believable but fake CPU/RAM profile, zeroed nanosecond timestamps, an emptied `/sys/class/dmi/id`, and a deterministic font list. The application runs normally — it just can't fingerprint the real machine.

```sh
# install (single file, Linux/Alpine)
wget https://raw.githubusercontent.com/ignatus12/obsidian-mirror/main/Universal-Obsidian-Mirror-installer-script.sh
sudo sh Universal-Obsidian-Mirror-installer-script.sh

# run any app under the mirror
obsidian firefox
obsidian --test        # show what is protected vs leaked
obsidian --audit       # full protected / leaked / not-protected report
obsidian --harden-test # measure the strict boundary (opt-in, see below)
```

See [`docs/COVERAGE.md`](docs/COVERAGE.md) for exactly what is covered and what is *honestly* not, and how every number above was produced (reproducible from `evidence/` by `compare.py`).

---

## The second layer: the strict boundary

Everything above is about what an application can *learn*. That is one
half of the problem. The other half is what an application can *do* —
and wrapping an app in a box that "allows these things and denies those
things" is a list, not a boundary.

The strict boundary is the other discipline, applied to the same
machine:

> **Default-deny at every layer, allow only a minimal per-application
> grant.** Not "deny these specific paths." Deny everything; permit only
> what the app provably needs.

| Layer | Default | Allowed |
|---|---|---|
| Filesystem | deny ALL host paths | the app's own data dir + granted paths |
| Memory | its own address space only | no `ptrace`, no peer `/proc/PID/mem`, no `/dev/mem`, no `/proc/kcore` |
| Network | deny all | a granted port, or none |
| Devices | deny all | only what is needed; hard-deny `/dev/mem`, `/dev/sd*`, `/dev/nvme*` |
| IPC | socket paths deny-all, via the filesystem layer | the granted socket paths; abstract sockets and signals are scoped only under `paranoid` or `OBSIDIAN_SCOPE_IPC=1` |
| Execution | the app binary + legitimate JIT | no shell, no `python -c`, no `node -e`, no memfd exec. *Loading a library the app wrote itself is **not** closed — measured, see below* |
| Capabilities | drop all | none |
| Privilege | `NoNewPrivs` | none |
| Namespaces | deny `unshare`/`mount` | none |

**It is off by default**, and the installer's self-test verifies that
`obsidian <app>` with hardening unset behaves identically to before.

```sh
obsidian --harden-test               # measure what it closes, on your machine
obsidian --profile learn firefox     # run it, record what it actually needs
obsidian --profile build firefox     # collapse that into a minimal allow-list
OBSIDIAN_HARDEN=1 obsidian firefox   # run it inside the boundary
```

Measured on the development machine — 51 attempts, the same probe and
the same launcher, run twice: once with the boundary and once without.

| | |
|---|---|
| surfaces the boundary closed | **29** |
| surfaces already shut by the base launcher | 18 |
| surfaces **still open** under the boundary | **1** |
| application capabilities broken | **0** (6 of 6 positive controls kept) |
| present but unreachable | 2 |
| inconclusive on this machine | 1 |

**About that 1.** The model asks for "no untrusted `dlopen`". The code
does not deliver it. Landlock checks its `EXECUTE` right when a file is
opened *to be executed*; a shared library is opened read-only and then
mapped executable, which is a different path through the kernel — so any
directory an app may write **and** read is a directory it can write code
into and load back. seccomp cannot see the path behind a file descriptor
at `mmap` time, so it cannot close it either. Closing it properly needs a
path-aware LSM (SELinux `execmod`, AppArmor `m`), which is not one of the
two mechanisms this enforcer is built on.

It is left **in the report as a failing row** rather than deleted from
the claim. The number went from 0 open to 1 open because the honest
number is 1. Row-by-row audit of all ten layers, including the two other
places the code falls short of the model:
[`docs/CONFORMANCE.md`](docs/CONFORMANCE.md).

The enumeration is not there to list denials. It is there to **discover
what the application legitimately needs**, grant exactly that, and deny
the rest — the same method that produced the metadata result without
breaking applications.

It does **not** close side channels (cache timing, power, acoustic,
electromagnetic) and it cannot reach below the kernel, which includes the
management engine on your own processor. Those are not kernel-policy
problems and this does not pretend to solve them. The full account,
including every known compatibility cost, is in
[`docs/STRICT-BOUNDARY.md`](docs/STRICT-BOUNDARY.md).

---

## Honest limits (read this)

- **This is not anonymity.** It reduces *device* fingerprinting by local apps. It does not hide your traffic, your accounts, or your behavior. Use it **with** a VPN/Tor, not instead of one.
- **VPN / Tor are still necessary.** They stop your ISP and the local network from reading your traffic and hide your origin from servers. Obsidian Mirror is the layer they *don't* provide.
- **The DMI/TPM/EDID/battery gap.** This was measured on a headless VM with no DMI table, TPM, battery, or GPU, so those identifiers read `(none)` on all four environments and are excluded from the counts. The probe already measures those keys; we just need someone with real hardware to run it. **PRs welcome** — if you contribute probe data, redact `id.machine_id` / `dmi.*` / `net.mac_addresses` / `bt.addresses` / `net.resolv_conf` first (GitHub issues are public).
- **Network layer is out of scope by design.** No traffic routing, no IP hiding. (The strict boundary can deny an application the network entirely, which is a different thing from hiding traffic.)
- **The strict boundary is not a solved problem either.** It closes 29 measured surfaces and breaks nothing in the positive-control set, but **one measured surface stays open** (an app loading a library it wrote itself), side channels and sub-kernel silicon are outside what any kernel policy can reach, and a surface nobody has probed is not a surface anybody has closed. Three of the ten layers fall short of the model in some way; all three are named in [`docs/CONFORMANCE.md`](docs/CONFORMANCE.md) rather than left for you to discover.
- **Numbers vary by machine.** The 91% is 68 of 74 checks on the development box; the boundary figures are from Landlock ABI 2 there. Your hardware and kernel will produce different totals — that is why every figure has a command next to it instead of a footnote.

---

## Where to go next

- The deep dive on *why* VPN/Tor/Tor Browser don't close this vector, with the full fair comparison: [`docs/METADATA-VS-POPULAR-PRIVACY-TOOLS.md`](docs/METADATA-VS-POPULAR-PRIVACY-TOOLS.md)
- The measured Flatpak ledger: [`docs/FLATPAK-COMPARISON.md`](docs/FLATPAK-COMPARISON.md)
- Coverage & limits: [`docs/COVERAGE.md`](docs/COVERAGE.md)
- The strict boundary, layer by layer, measured: [`docs/STRICT-BOUNDARY.md`](docs/STRICT-BOUNDARY.md)
- **Does the code actually match the model? Row-by-row audit, including where it does not:** [`docs/CONFORMANCE.md`](docs/CONFORMANCE.md)
- Raw data + the probe + the analysis: [`evidence/`](evidence/)

---

## Building the installer yourself

The shipped script is generated, not hand-edited, so you can rebuild it
and compare:

```sh
python3 tools/embed-harden.py     # installer/base.sh + src/ + bin/  ->  the script
sh tools/verify-installer.sh      # 24 structural checks on the result
```

`installer/base.sh` is the payload-free installer and the only part
edited by hand. Everything in `src/` and `bin/` is spliced in by the
embedder, so the C sources in this repository are the same bytes the
installer compiles on your machine. The build is deterministic — running
it twice gives an identical file.

`Universal-Obsidian-installer-script.sh` (the old name) is written by the
same build with the same bytes, so existing links keep working.

---

## License

[GPL-3.0](LICENSE). No hand-typed numbers: the Flatpak comparison figures are generated from the raw probe data by `evidence/compare.py`, the metadata figure is printed by `obsidian --test`, and the boundary figures are printed by `obsidian --harden-test`. Every one of them re-runs on your machine.

### References

1. David Cole, *"We Kill People Based on Metadata"*, The New York Review of Books (2014) — Hayden's Johns Hopkins statement. https://www.nybooks.com/online/2014/05/10/we-kill-people-based-metadata/
2. Bruce Schneier, *Data and Goliath* (Baker & Schneier on metadata; Wired excerpt). https://www.wired.com/2015/03/data-and-goliath-nsa-metadata-spying-your-secrets/
