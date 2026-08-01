# The Obsidian Mirror project

### Real Metadata Privacy protection against application metadata-leaks

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

## What Obsidian Mirror does

Obsidian Mirror wraps an application and feeds it a **synthetic host identity**: a fresh per-launch `machine-id`, a randomized hostname, spoofed DMI, a believable but fake CPU/RAM profile, zeroed nanosecond timestamps, an emptied `/sys/class/dmi/id`, and a deterministic font list. The application runs normally — it just can't fingerprint the real machine.

```sh
# install (single file, Linux/Alpine)
wget https://raw.githubusercontent.com/ignatus12/obsidian-mirror/main/Universal-Obsidian-installer-script.sh
sudo sh Universal-Obsidian-installer-script.sh

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
| IPC | deny all | only the needed sockets |
| Execution | the app binary + legitimate JIT | no shell, no `python -c`, no `node -e`, no memfd exec |
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

Measured on the development machine — same probe, same launcher, run
twice, once with the boundary and once without:

| | |
|---|---|
| surfaces the boundary closed | **29** |
| surfaces already shut by the base launcher | 18 |
| surfaces still open under the boundary | **0** |
| application capabilities broken | **0** |

The enumeration is not there to list denials. It is there to **discover
what the application legitimately needs**, grant exactly that, and deny
the rest — the same method that produced the 93% metadata figure without
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
- **The strict boundary is not a solved problem either.** It closes 29 measured surfaces and breaks nothing in the positive-control set, but side channels and sub-kernel silicon are outside what any kernel policy can reach, and a surface nobody has probed is not a surface anybody has closed.

---

## Where to go next

- The deep dive on *why* VPN/Tor/Tor Browser don't close this vector, with the full fair comparison: [`docs/METADATA-VS-POPULAR-PRIVACY-TOOLS.md`](docs/METADATA-VS-POPULAR-PRIVACY-TOOLS.md)
- The measured Flatpak ledger: [`docs/FLATPAK-COMPARISON.md`](docs/FLATPAK-COMPARISON.md)
- Coverage & limits: [`docs/COVERAGE.md`](docs/COVERAGE.md)
- The strict boundary, layer by layer, measured: [`docs/STRICT-BOUNDARY.md`](docs/STRICT-BOUNDARY.md)
- Raw data + the probe + the analysis: [`evidence/`](evidence/)

---

## License

[GPL-3.0](LICENSE). Every figure in this repository is generated from the raw probe data by `evidence/compare.py` — no hand-typed numbers.

### References

1. David Cole, *"We Kill People Based on Metadata"*, The New York Review of Books (2014) — Hayden's Johns Hopkins statement. https://www.nybooks.com/online/2014/05/10/we-kill-people-based-metadata/
2. Bruce Schneier, *Data and Goliath* (Baker & Schneier on metadata; Wired excerpt). https://www.wired.com/2015/03/data-and-goliath-nsa-metadata-spying-your-secrets/
