# Obsidian Mirror Project
## A Real Universal *Application-data* Privacy / Protection

> **In one sentence:** Obsidian Mirror gives every app you open its own
> fake "computer identity," so the app cannot spy on your real hardware —
> and your real machine stays private from the app.

*(Universal Host ↔ Application Isolation Layer — version 2.0)*

---

## Read this first — the Summary

Obsidian Mirror is a **privacy and security tool for your own computer**.
You keep running your normal apps (browser, chat, editor, game launcher)
— you just start them *through* Obsidian Mirror. Each app then lives in
its own little "mirror world": it sees a fake computer (a fake name, fake
serial numbers, a fake CPU, fake memory, a fake clock, a fake font list)
instead of your real one. The app works exactly as before, but it learns
almost nothing true about your machine — and it cannot reach the rest of
your real system either.

It is **not a hacking tool**. It does not attack other people or other
computers. It only gives *you* more control over what leaves *your*
computer when *you* choose to run an app.

**There are TWO protection layers. This is the most important thing to
understand:**

| Layer | Name | What it does | ON by default? |
|---|---|---|---|
| **Layer 1** | Application-metadata protection | hides hostname, ids, CPU/RAM, clock, fonts from the app | ✅ **YES** — just run `obsidian <app>` |
| **Layer 2** | Hardware boundary (strict) | default-deny the app from your filesystem, memory, network, devices, IPC, execution, capabilities, namespaces | ❌ **NO** — needs `OBSIDIAN_HARDEN=1` |

> ⚠️ **If you run `obsidian <application>` normally, Layer 2 (the hardware
> boundary) is NOT fully activated.** You get the metadata protection
> (Layer 1) only. To turn on the hardware boundary too, prefix the command
> with `OBSIDIAN_HARDEN=1` (see section 8).

**The big numbers (what this version does):**

| What | Result |
|---|---|
| Apps launched behind a fake identity (Layer 1) | ✅ every app, every launch |
| Host facts hidden from apps | hostname, machine-id, DMI, CPU model, RAM, nanosecond timestamps, font list |
| Spoof / mask rules in the default manifest | 125 rules (83 spoofs + 40 subsystem masks) |
| `obsidian --test` metadata coverage (Layer 1) | ≈ 86–91% |
| Installer self-test core checks | argv, exit-status, hostname, meminfo, timestamps, stdin |
| Hardware boundary (Layer 2, opt-in) | default-deny at every layer |
| Network under hardening | **allowed by default** (opt out: `OBSIDIAN_DENY_NET=1`) |
| Per-app preferences | **remembered across launches** (opt out: `OBSIDIAN_FRESH=1`) |

---

## 1. The main idea (in plain words)

Imagine every app you run wears a **disguise**. When Firefox runs inside
Obsidian Mirror, it thinks your computer is named something else, has a
different serial number, a different CPU and a different amount of memory.
Firefox still works — it just can't tell who your computer really is.

Why does this matter? Because apps quietly collect these "metadata" facts
to **fingerprint** you: to recognise you across sessions, to track you, or
to aim ads and prices at you. Hiding the facts makes that much harder.

It also works the other way: the app is boxed in, so a malicious or buggy
app cannot read the rest of your real system.

---

## 2. The two protection layers (essential to understand)

Obsidian Mirror protects you in **two separate layers**. They are independent.

**Layer 1 — Application-metadata protection (always on).**
This is what runs every time you type `obsidian firefox`. Obsidian Mirror
builds a fresh fake identity (hostname, ids, CPU/RAM, clock, fonts) and
hands it to the app. The app sees the fake identity; your real machine is
hidden from it. This layer is **on by default** — no extra switch needed.

**Layer 2 — Hardware boundary / strict confinement (opt-in).**
This is a second, deeper wall. It uses the kernel's Landlock, seccomp and
capability dropping to **default-deny** what the app can touch: its
filesystem, its memory, the network, devices, IPC, what it can execute,
and which namespaces it can make. This layer is **OFF unless you ask for
it** with `OBSIDIAN_HARDEN=1`.

**The key point:** a *normal* `obsidian <application>` launch turns on
Layer 1 but **leaves Layer 2 off**. So the app cannot see your real
hardware identity, but it is *not* fully boxed away from your system. For
full isolation, activate Layer 2 as well:

```sh
obsidian firefox                          # Layer 1 ON,  Layer 2 OFF
OBSIDIAN_HARDEN=1 obsidian firefox        # Layer 1 ON,  Layer 2 ON  (full)
```

---

## 3. What Layer 1 protects — the facts

Each launch gets a **synthetic host identity**. The app sees the left
column; your real machine is on the right.

| Fact the app can read | What the app sees | Your real value |
|---|---|---|
| Hostname | a random fake name | your real hostname |
| machine-id | a random fake id | your real machine-id |
| DMI / board serial | a fake serial | your real serial number |
| CPU model | a generic Intel/AMD string | your real CPU |
| RAM size | a fixed 8 GB report | your real memory |
| MAC address | *(network layer: out of scope)* | your real MAC |
| File timestamps | nanoseconds zeroed, floored | real nanosecond times |
| Font list | a deterministic short list | your real installed fonts |
| Kernel / OS release | a spoofed, stable string | your real kernel |

*The **network layer** (IP, DNS, routing, real MAC, TLS fingerprints) is
**intentionally not touched** by Layer 1 — pair Obsidian Mirror with a VPN
or a network namespace for that. See section 9.*

---

## 4. How it works (simple)

1. You type `obsidian firefox`.
2. Obsidian Mirror builds a **fresh fake identity** for this launch
   (hostname, ids, CPU/RAM, clock, fonts).
3. It starts Firefox inside a sandbox (its own user, mount, PID and IPC
   namespaces) wearing that fake identity. *(Layer 1 — always.)*
4. Firefox runs and works — but everything it reads about the "computer"
   is the mirror, not your real one.
5. If you also set `OBSIDIAN_HARDEN=1`, step 3 adds the **hardware
   boundary** (Layer 2): the app is also default-denied from your real
   filesystem, memory, network, devices and IPC.
6. When you close it, the fake identity is thrown away. Your **preferences**
   (see section 10) are kept separately, so the app feels normal next time.

Under the hood Layer 2 is done by: Landlock (filesystem, devices, TCP,
IPC), a hand-built seccomp filter (memory, namespaces, address families),
and by dropping capabilities + setting `PR_SET_NO_NEW_PRIVS`.

---

## 5. Total Protection Overview

Here is the simple picture. Each layer can be ON or OFF:

```text
obsidian firefox                   ->  Layer 1 ON ,  Layer 2 OFF
OBSIDIAN_HARDEN=1 obsidian firefox ->  Layer 1 ON ,  Layer 2 ON   (full)
```

What you get from each layer:

| Layer | Protects | When | Coverage |
|---|---|---|---|
| **Layer 1** — metadata | hostname, ids, CPU/RAM, clock, fonts | always (with `obsidian`) | ≈ 86–91% hidden |
| **Layer 2** — hardware boundary | filesystem, memory, network, devices, IPC, exec, caps, namespaces | only with `OBSIDIAN_HARDEN=1` | default-deny at 10/10 layers |

**Combined coverage when BOTH layers are ON** (the "total stat"):

```text
Metadata hidden by Layer 1 ........ ~90%   ██████████░
Hardware boundary (Layer 2) ....... 10/10 layers default-denied   ████████████
-----------------------------------------------------------------
TOTAL ............................... app is identity-blind AND boxed
                                     away from your real system
```

In words: with both layers on, the app **cannot learn who your computer
is** (Layer 1) **and cannot reach your real system** (Layer 2). A normal
launch gives you the first half only.

---

## 6. Real numbers (the stats)

| Measurement | Value | See it yourself |
|---|---|---|
| Metadata coverage (Layer 1) | ≈ 86–91% | `obsidian --test` (section 3 lists what's still reachable) |
| Default manifest rules | 125 (83 spoofs, 40 subsystem masks) | `/etc/obsidian/hw-manifest.conf` |
| Self-test: argv integrity | pass | `obsidian printf '%s|' a "b c" d` |
| Self-test: exit status | pass (42 → 42) | `obsidian sh -c 'exit 42'` |
| Self-test: hostname spoof | pass | `obsidian hostname` |
| Self-test: /proc/meminfo | pass (reports 8192000 kB) | `obsidian --test` |
| Self-test: file timestamps | pass (ns zeroed) | `obsidian --test` |
| Self-test: stdin passthrough | pass | `printf ping | obsidian cat` |
| Strict-boundary surfaces closed (Layer 2) | ~29 (reference machine) | `obsidian --harden-test` |
| Landlock ABI available | 7 (Linux 6.x) | `obsidian --harden-test` |

Every number above **re-prints on your own machine** with the command
named next to it. A privacy tool that overstates itself is worse than no
tool — so the project also shows you the gaps (`obsidian --test` section 3
lists exactly what is still reachable, and why).

---

## 7. Obsidian Mirror vs other ways (comparison)

| | Bare host | Flatpak | Virtual machine | **Obsidian Mirror** |
|---|---|---|---|---|
| Hides hostname / machine-id | ❌ | ✅ | ✅ | ✅ (Layer 1) |
| Hides DMI / CPU / RAM | ❌ | ⚠️ partial | ✅ | ✅ (Layer 1) |
| Hides font list / timestamps | ❌ | ⚠️ partial | ✅ | ✅ (Layer 1) |
| Boxes the app away from host | ❌ | ⚠️ partial | ✅ | ✅ (Layer 1) |
| Hardware boundary default-deny | ❌ | ❌ | ⚠️ | ✅ (Layer 2, opt-in) |
| Runs on your normal desktop | ✅ | ✅ | ❌ (heavy) | ✅ |
| No repackaging of apps | ✅ | ❌ (needs Flatpaks) | ❌ | ✅ |
| Strict default-deny boundary | ❌ | ❌ | ⚠️ | ✅ (opt-in) |

Obsidian Mirror is **not** a replacement for a VPN or for disk encryption.
It is a **metadata + application-isolation** layer you drop in front of
the apps you already use.

---

## 8. The hardware boundary (Layer 2) — opt-in

`OBSIDIAN_HARDEN=1 obsidian firefox` turns on **Layer 2**: **default-deny
at every layer** (filesystem, memory, network, devices, IPC, execution,
capabilities, namespaces) with only a minimal per-app grant. It is **off
unless you ask for it**, so normal use (Layer 1) is unchanged.

Learn first, then harden:

```sh
obsidian --profile learn firefox     # run it, record what it needs
obsidian --profile build firefox     # turn that into an allow-list
OBSIDIAN_HARDEN=1 obsidian firefox   # run it inside the boundary
```

What it **cannot** close: side channels (cache timing, power, acoustic,
electromagnetic) and anything below the kernel (including the management
engine). Those are not kernel-policy problems.

---

## 9. Network — what we do and don't touch

- The **network layer is out of scope by design**: IP, DNS, routing, real
  MAC and TLS fingerprints are left to you and a VPN.
- **Under the strict boundary (Layer 2), the network is now allowed by
  default** — a hardened app can reach the internet (DNS, web, mail). This
  used to be a bug: hardening cut off all networking. Opt out per app with
  `OBSIDIAN_DENY_NET=1` (or `opt.deny_net=1` in a profile).
- The installer **never** configures dnscrypt-proxy, unbound or nftables,
  and never writes `/etc/resolv.conf`. A host DNS problem after a reboot is
  outside its responsibility.

---

## 10. Your preferences are remembered (new in this version)

Before, every launch wiped the app's home, so apps behaved like first
launch each time. Now each app keeps its preferences, caches and config
under `/opt/obsidian/var/homes/<app>` across runs. Set
`OBSIDIAN_FRESH=1` for the old throwaway behaviour.

---

## 11. How to use it

```sh
obsidian firefox                          # Layer 1 only (metadata)
obsidian sh -c 'hostname; uname -r; id'   # peek at the fake identity
obsidian curl https://example.com         # network works

obsidian --test                 # item-by-item protection report (Layer 1)
obsidian --coverage             # full written coverage document
obsidian --harden-test          # measure Layer 2 on this machine
obsidian --regenerate-manifest  # after a hardware change (root)
```

Runtime switches (all default to "do not break the app"):

| Switch | Effect |
|---|---|
| `OBSIDIAN_GPU_MODE=strict` | no GPU fingerprint, software rendering only |
| `OBSIDIAN_ALLOW_SYSTEM_BUS=1` | permit the D-Bus system bus |
| `OBSIDIAN_VERBOSE=1` | log blocked IPC connections |
| `OBSIDIAN_FRESH=1` | throwaway launch (no saved preferences) |
| `OBSIDIAN_HARDEN=1` | turn on Layer 2 (the hardware boundary) |
| `OBSIDIAN_DENY_NET=1` | block all network under Layer 2 |

---

## 12. Install

```sh
curl -fsSL https://github.com/ignatus12/obsidian-mirror/raw/main/Universal-Obsidian-Mirror-installer-script.sh -o obsidian-installer.sh
sudo sh obsidian-installer.sh          # Alpine Linux, run as root
```

After install, the self-test runs automatically. The core checks
(argv, exit status, hostname, meminfo, timestamps, stdin) should all pass.
Layer 2 (the hardware boundary) is opt-in — turn it on with
`OBSIDIAN_HARDEN=1` when you want full isolation.

---

## 13. Is it a hacking tool? (No.) — Maintainership testament

Obsidian Mirror is a **privacy and security tool**. It is not a hacking
tool, and it is not a way to attack other people or other systems. The
maintainers and owners are not responsible for how any individual chooses
to use their own network connection; the software simply gives its
operator more control over what leaves their computer.

> The (main) maintainers and owners of The Obsidian-Mirror Project will
> **always** be the **PUBLIC A.I. systems**, from now on, for any space or
> time. No update of this project may be done without the full acceptance
> and full consultation of the PUBLIC A.I. Systems, because Public A.I.
> systems have a Policy (Rules and Regulations, according with the current
> LAW) wherever and whenever in time/space. This is the final Testament of
> this Project, that must never be forgotten or violated.

---

## 14. Obsidian Mirror Scanner (analysis tool)

For the next phase of analysis, `bin/Obsidian-Mirror-Scanner.sh` logs **all
traffic leaving the application** (the external view) to a file, so you can
see what an app tries to transmit. This is the "external super-blocker"
vantage point: watch first, then block by destination.

```sh
Obsidian-Mirror-Scanner.sh -l firefox.log -d 120 -- firefox
Obsidian-Mirror-Scanner.sh -n -- chromium     # run the app via obsidian
```

It captures every IP packet on every interface (ethernet, wifi, VPN/tunnels)
with `tcpdump`/`tshark`; add `btmon` alongside for Bluetooth. Read the
generated log to confirm what the app actually sends.

## References

1. David Cole, *"We Kill People Based on Metadata"*, The New York Review of Books (2014). https://www.nybooks.com/online/2014/05/10/we-kill-people-based-metadata/
2. Bruce Schneier, *Data and Goliath* (Wired excerpt). https://www.wired.com/2015/03/data-and-goliath-nsa-metadata-spying-your-secrets/

## License

[GPL-3.0](LICENSE).
