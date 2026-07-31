# Metadata vs the popular privacy tools

### Why VPN, Tor and Tor Browser don't close the application-metadata leak — and what does

---

## 0. The intuition this document takes seriously

> *"If I use a VPN, or Tor, or the Tor Browser, I'm anonymous / private / protected."*

That belief is half-right and dangerously half-wrong. A VPN, Tor and the Tor Browser **do** protect one thing: **the network path your traffic takes.** What they do **not** protect is the thing mass surveillance actually runs on — **the metadata your own applications read about your machine**, locally, before any packet leaves.

This is not a fringe claim. It is what the people who run the surveillance systems say themselves.

---

## 1. The surveillance tool that matters is metadata, not your IP

> *"We kill people based on metadata."* — Gen. Michael Hayden, former director of **both** the NSA and the CIA, at a Johns Hopkins debate (2014). [1]

Hayden immediately qualified it — *"but that's not what we do with this metadata"* — but the mechanism he confirmed is the point: the identifying signal is the metadata, not the content, and not the IP.

Why metadata beats content (and IP) for tracking:

- **It scales.** As former NSA General Counsel Stewart Baker put it: *"Metadata absolutely tells you everything about somebody's life. If you have enough metadata, you don't really need content."* [2]
- **It survives IP changes.** Your IP is the easiest identifier to rotate — reconnect, travel, VPN, Tor. The metadata an app reads from your local OS is the opposite: stable and unique.
- **It is durable across reinstalls.** `/etc/machine-id` is a permanent install UUID. It persists across reboots *and* OS reinstalls unless you explicitly wipe it. Combine it with DMI serials, CPU model, RAM size and filesystem-clock skew and you have a **device fingerprint** that re-identifies you on every network.

Bruce Schneier, in *Data and Goliath*:

> *"The truth is, though, that the difference [between content and metadata] is largely illusory. It's all data about us."* [2]

So the "popular" mental model — *hide my IP and I'm safe* — ignores the vector that matters. The application on your machine is still handing out your real device identity to every service it contacts. **The VPN hides the envelope; it does nothing about the letter inside.**

---

## 2. What "application metadata" means here (with real values)

"Metadata" in this project means the **host identity an application can read from the local machine**, without any special permission:

| Source | Example (measured on the test host) |
|---|---|
| `/etc/machine-id` | `67549745dd1a4564be928e47dca271fd` (permanent install UUID) |
| hostname / uname nodename | `e2b.local` |
| login name / `$HOME` | `user` / `/home/user` |
| CPU model | `Intel(R) Xeon(R) Processor @ 2.60GHz` |
| RAM total | `2032608` KiB |
| file mtime nanoseconds | `506246762` (full resolution) |
| DMI `product_uuid` / `board_serial` | *(absent on this VM; present on real hardware)* |
| monitor EDID | *(absent on this VM; present on real hardware)* |

None of these travel over the network to be hidden by a VPN. They are read from `/etc`, `/proc`, `/sys` and the filesystem **by the application itself**, and then — if the app phones home, as most do — sent *alongside* your (VPN-tunnelled) request. The tunnel protects the request; it does not touch what the app put in the request body.

---

## 3. The layering that people miss

```
┌─────────────────────────────────────────────────────────────┐
│  APPLICATION  ── reads /etc, /proc, /sys, fs  ── HOST METADATA │  ← this project's vector
├─────────────────────────────────────────────────────────────┤
│  OS / kernel                                                   │
├─────────────────────────────────────────────────────────────┤
│  NETWORK  ── IP, routing, encryption  ── VPN / Tor / Tor Br.   │  ← what those tools protect
└─────────────────────────────────────────────────────────────┘
```

VPN, Tor and Tor Browser operate in the **bottom** box. The leak this project is about lives in the **top** box and is read *before* the network box is ever reached. Different layers; different tools.

---

## 4. Tool by tool — fairly

### VPN
**Protects:** the tunnel between your device and the VPN server; the destination sees the VPN's IP, not yours; your ISP can't read the payload.
**Does not touch:** anything the application reads locally. `machine-id`, DMI, CPU, hostname, filesystem clock and installed fonts are all unchanged. Any app that sends telemetry still reports your **real** device identity — just routed through the VPN.
**Verdict for this vector:** ❌ no effect.

### Tor
**Protects:** origin IP from the destination (traffic exits via a random relay); resists traffic analysis better than a single VPN.
**Does not touch:** local host metadata, for the same reason as a VPN — Tor is a network-layer router, not a host-identity spoofer.
**Verdict for this vector:** ❌ no effect.

### Tor Browser
**Protects:** *browser* fingerprinting — uniform user-agent, canvas, screen size and font set via its sandboxed profile and prefs, so sites have a harder time telling Tor Browser sessions apart.
**Does not touch:** the **OS-level** device identifiers (`machine-id`, DMI, …) that the browser process *and every other application* can still read; and it only helps the one browser, not the other 95% of your software. Browser-fingerprint resistance and host-metadata resistance are related but **distinct** vectors; Tor Browser addresses the first, not the second.
**Verdict for this vector:** ⚠️ minimal / partial.

### Firefox + uBlock Origin (or any content blocker)
**Protects:** ads and known trackers *in the page*.
**Does not touch:** host metadata (the browser still reads `machine-id`/DMI if a page or extension asks) and does nothing for any other app.
**Verdict for this vector:** ❌ no effect.

### Flatpak (sandbox)
**Protects:** what an app *can do* — filesystem, devices, sockets — via portals and permissions.
**Does not touch:** host *identity*. Measured: 49/82 host identifiers reported byte-identical to the host (see below). Its sandbox is about **capabilities**, not **identity**.
**Verdict for this vector:** ❌ leaks by design.

### Obsidian Mirror
**Protects:** what an app *can learn* about the host — feeds it a synthetic `machine-id`, hostname, DMI, CPU/RAM profile, zeroed nanosecond timestamps, emptied `/sys/class/dmi/id` and a deterministic font list.
**Verdict for this vector:** ✅ addresses it (remaining gaps documented honestly in `COVERAGE.md`).

---

## 5. The comparison, in one table

| Tool | Layer it protects | Stops apps reading your real host metadata? | This vector |
|---|---|---|---|
| Bare host | — | No | ❌ 82/82 exposed |
| **VPN** | network path / destination IP | **No** | ❌ 82/82 exposed |
| **Tor** | origin IP / routing | **No** | ❌ 82/82 exposed |
| **Tor Browser** | browser fingerprint (in-browser only) | **Partial** | ⚠️ minimal |
| Firefox + uBlock | in-page ads/trackers | **No** | ❌ 82/82 exposed |
| **Flatpak** | app capabilities | **No — by design** | ❌ 49/82 identical *(measured)* |
| **Obsidian Mirror** | host identity an app reads | **Yes** | ✅ 24/82 identical *(measured)* |

The Flatpak and Obsidian rows are **measured** on one machine (82 gradable identifiers). The VPN / Tor / Tor Browser / Firefox rows are **architectural**: those tools operate at the network layer and do not modify the local files an app reads, so none of the 82 host identifiers change — by design, not by measurement.

---

## 6. The measured proof that this is real, not theoretical

Flatpak is the "private" way to run desktop apps, yet measured on the same host:

| Environment | Identical to host | Altered |
|---|---|---|
| Host (control) | 82 / 82 | 0 % |
| Flatpak, default permissions | 49 / 82 | 40 % |
| Flatpak, typical app permissions | 47 / 82 | 43 % |
| **Obsidian Mirror** | **24 / 82** | **71 %** |

A VPN or Tor is **not even a sandbox** — it changes zero of those 82 identifiers. Flatpak at least *tries* and still leaks ~60%. The tools people actually trust for "privacy" don't try at all.

Full ledger, mount table and counting rules: [`FLATPAK-COMPARISON.md`](FLATPAK-COMPARISON.md).

---

## 7. Fairness: keep using VPN / Tor

This document is **not** an argument against VPNs or Tor. They stop your ISP and local network from reading your traffic, and they hide your origin from the servers you visit — genuinely valuable, and necessary for anyone who cares about privacy. They are simply **necessary but not sufficient**: they close the network layer and leave the host-metadata layer open. Obsidian Mirror is the layer they don't provide. Use them **together**.

---

## 8. Limitations & how to help

- **Not anonymity.** Reduces *device* fingerprinting by local apps. Does not hide traffic, accounts or behavior.
- **Network layer out of scope by design.** No routing, no IP hiding.
- **DMI / TPM / EDID / battery not yet measured.** This was built on a headless VM with no DMI table, TPM, battery or GPU; those keys read `(none)` and are excluded from counts (see [`METHODOLOGY.md` §5](METHODOLOGY.md#5-what-this-machine-could-not-test)). The probe already emits the `dmi.*`, `gpu.drm_*`, `gpu.edid_bytes`, `tpm.*` and `thermal.*` keys — we only need someone with real hardware to run it. **PRs welcome.**

---

## References

1. David Cole, *"We Kill People Based on Metadata"*, The New York Review of Books (2014) — Hayden's Johns Hopkins statement, with the qualifier. https://www.nybooks.com/online/2014/05/10/we-kill-people-based-metadata/
2. Bruce Schneier, *Data and Goliath* (Baker & Schneier on metadata; Wired excerpt). https://www.wired.com/2015/03/data-and-goliath-nsa-metadata-spying-your-secrets/
3. UK Parliament written evidence on drone targeting — *"We're targeting a cell phone… based on metadata"* (context for Hayden's point). https://committees.parliament.uk/writtenevidence/36962/html/
