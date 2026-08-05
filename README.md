# The Obsidian Mirror Project
## A Real Universal Application-Data Privacy / Protection

> One sentence: Obsidian Mirror is a **privacy and security tool for your own
> computer** that runs any app you choose inside a wrapper that hides your
> hardware identity, boxes the app away from your real system, and filters what
> it tries to send or receive on the network.

*(The "Universal Host ↔ Application Isolation Layer" — current development
phase **v3.4**.)*

---

## Read this first — the Summary

Obsidian Mirror is a **privacy and security tool for your own computer**. You
point it at an app you already trust enough to run, and it changes what that
app can see and touch — without modifying the app.

It is **not a hacking tool**. It does not attack other people or other
computers. It only gives *you* more control over what leaves *your* computer
when *you* choose to run an app.

**Why metadata matters — the "super-cookie":** imagine all your hardware
metadata — the machine ID, DMI / board serial, CPU model, RAM size, MAC
address, kernel — as one giant **super-cookie**. Unlike a browser cookie you
can delete, this one follows you everywhere and you can never get rid of it.
No VPN, no Tor, no Tor Browser, no operating-system change hides it: any site
or service can read it and recognise you across sessions, installs and
networks, without your consent. Obsidian Mirror is what finally makes that
super-cookie unreadable.

Three layers, three threats it closes:

- **Layer 1 — the super-cookie.** Your hardware metadata is an undeletable
  tracking token. `obsidian <app>` hides it.
- **Layer 2 — the host as an open book.** Without restriction, a malicious app
  could read your logs, memory, kernel and disks by default. Layer 2
  (`OBSIDIAN_HARDEN=1`) default-denies all of that.
- **Layer 3 — the constant invisible traffic.** Thousands of unwanted,
  privacy-violating packets enter and leave apps every moment, without your
  consent. Layer 3 (`OBSIDIAN_HARDEN=2`) logs, scans and kills that traffic
  before it crosses the network boundary — with WiFi and Bluetooth
  hard-blocked.

**What you get, in numbers (this version):**

| What | Result |
|---|---|
| Host identity (hostname, ids, CPU, RAM, clock, fonts) | **hidden** from the app |
| Filesystem / memory / devices / IPC | **default-deny** under `OBSIDIAN_HARDEN=1` |
| Network egress + ingress | **default-deny, learned allow-list** under `OBSIDIAN_HARDEN=2` |
| Spoof/mask rules | **125** (83 identity spoofs + 40 subsystem masks) |
| Measured metadata coverage | **≈ 86–91%** |
| Per-app preferences | **remembered** across launches |

---

## Development phases (this release is v3.4)

- **v1.0 — Application metadata protection.** Hides hostname, ids, CPU/RAM,
  clock and fonts from the app (Layer 1, active by default).
- **v2.0 — Hardware isolation.** Default-deny what the app may touch on your
  system: filesystem, memory, devices, IPC, execution, capabilities,
  namespaces (`OBSIDIAN_HARDEN=1`, Layer 2).
- **v3.4 — Internal-application threat model (this release).** Watches and
  blocks what the app tries to send *and* receive on the network, both ways,
  and hard-blocks Bluetooth and WiFi (`OBSIDIAN_HARDEN=2`). See section 3.

---

## 1. The main idea (in plain words)

You run an app. Normally the app can read everything about the "computer" it
runs on — your hostname, serial numbers, how much memory you have, what CPU,
your real MAC, your installed fonts, your kernel, and (if you let it) your
files and your network. All of that is a fingerprint, and a lot of it is a
persistent, undeletable **super-cookie**.

Obsidian Mirror puts a **mirror** between the app and the real computer. The
app sees a clean, fake, stable reflection instead of your real hardware — and,
if you turn on the deeper layers, it is also boxed away from your system and
its network traffic is filtered. The app runs and works; it just can't read
or reach what you didn't let it.

---

## 2. The Three protection layers (essential to understand)

Obsidian Mirror protects you in **three separate layers**. They are independent.

**Layer 1 — Application-metadata protection (always on).** This is what runs
every time you type `obsidian firefox`. Obsidian Mirror builds a fresh fake
identity (hostname, ids, CPU/RAM, clock, fonts) and hands it to the app. The
app sees the fake identity; your real machine is hidden from it. This layer is
**on by default** — no extra switch needed.

**Layer 2 — Hardware boundary / strict confinement (opt-in).** This is a
second, deeper wall. It uses the kernel's Landlock, seccomp and capability
dropping to **default-deny** what the app can touch: its filesystem, its
memory, the network, devices, IPC, what it can execute, and which namespaces
it can make. This layer is **OFF unless you ask for it** with
`OBSIDIAN_HARDEN=1`.

**Layer 3 — Internal-application threat model / network deny-list (opt-in).**
This is the v3.4 layer. It runs the app inside its own network namespace and
applies a **default-deny firewall on both directions** from a learned
allow-list, so the app can only talk to endpoints it proved necessary — and
hard-blocks Bluetooth and WiFi. This layer is **OFF unless you ask for it**
with `OBSIDIAN_HARDEN=2`.

**The key point:** a *normal* `obsidian <application>` launch turns on Layer 1
but **leaves Layer 2 and Layer 3 off**. So the app cannot see your real
hardware identity, but it is *not* fully boxed away from your system, and its
network traffic is not filtered. Add layers as you need:

```sh
obsidian firefox                           # Layer 1 ON,  Layer 2 OFF, Layer 3 OFF
OBSIDIAN_HARDEN=1 obsidian firefox         # Layer 1 ON,  Layer 2 ON,  Layer 3 OFF
OBSIDIAN_HARDEN=2 obsidian firefox         # Layer 1 ON,  Layer 2 ON,  Layer 3 ON  (full)
```

---

## 3. What Layers 1, 2, 3 protect — the facts

### 3.1 Layer 1 — Application-metadata protection (always on)

Each launch gets a **synthetic host identity**. The app sees the left column;
your real machine is on the right.

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
**intentionally not touched** by Layer 1 — pair Obsidian Mirror with a VPN or
a network namespace for that. See section 7.*

### 3.2 Layer 2 — Hardware boundary (opt-in, `OBSIDIAN_HARDEN=1`)

Under `OBSIDIAN_HARDEN=1` the app is **default-denied** from your real system.
Concretely, it cannot, by default:

- read or write outside its own sandboxed files (filesystem),
- read your memory or other processes (memory),
- open raw network sockets to your real interfaces (network),
- touch real devices (camera, microphone, drives),
- talk to system services it shouldn't (IPC / D-Bus),
- spawn new privileged processes (execution),
- gain new capabilities or create new namespaces.

Without Layer 2, a malicious app could treat your host like an open book. With
it, the host is closed. This layer is built from a **recording of what the app
actually did** (`obsidian --profile learn` then `build`), not a guess, so it
doesn't break the app.

### 3.3 Layer 3 — Internal-application threat model (opt-in, `OBSIDIAN_HARDEN=2`)

`OBSIDIAN_HARDEN=2` (the v3.4 layer) adds the network side and treats the
app's traffic as a **live external scan**:

- The app runs inside its **own network namespace** (a dedicated veth), so
  every packet it sends **and** receives is cleanly visible.
- The **Outbound + Inbound scanner** logs all traffic leaving and entering the
  app (all ports, all protocols, ethernet / wifi / Bluetooth).
- A **default-deny** egress *and* ingress firewall allows only what a prior
  run proved necessary — the SCAN → DETECT → KILL loop: anything not on the
  learned allow-list is dropped before it reaches (or leaves) the real network.
  A red flag on either side blocks both directions at once.
- **Bluetooth and WiFi are hard-blocked** for the duration of the launch
  (`rfkill block bluetooth`; set `OBSIDIAN_BLOCK_WIFI=1` to also block WiFi),
  so the app cannot use them in any way.

```sh
OBSIDIAN_HARDEN=2 obsidian firefox            # learn, then enforce
OBSIDIAN_BLOCK_WIFI=1 OBSIDIAN_HARDEN=2 obsidian firefox
OBSIDIAN_ALLOW_NET=1 OBSIDIAN_HARDEN=2 obsidian firefox   # allow net, log only
```

- The first run **learns**; later runs **enforce** (only learned endpoints
  allowed, everything else denied both ways) — without breaking the app.
- **Statistics:** `obsidian <app> --stat` prints the per-app page: ALLOW_NET /
  ALLOW_WIFI / ALLOW_BLUETOOTH (all `0` = default-deny in Layer 3), whether a
  learned profile and the `HARDEN=1` / `HARDEN=2` layers are active, the
  Red-flag drop counts (egress + ingress, from nftables counters) and the
  learned allow-list. This is how you confirm Layer 3 is active and what it
  has blocked. `obsidian-netblock.sh` also kills established connections that
  later fall outside the allow-list (mid-stream kill).
- Requires root + `iproute2` + `nftables`; without them it degrades to
  `HARDEN=1` plus traffic logging.
- Engines: `bin/Obsidian-Mirror-Scanner.sh` (capture/learn, with `btmon` for
  Bluetooth) and `bin/obsidian-netblock.sh` (per-app namespace + dynamic
  bidirectional deny-list). This is the v3.4 internal-application threat-model
  layer; it is **not** a hacking tool — it only restricts what *your own* app
  may send to or receive from the network.

### 3.4 Obsidian Mirror vs "false security" tools (the deep dive)

A lot of "privacy" advice stops at Tor, a VPN, or a "security" distro like
ParrotOS / Kali. Those are real tools, but they solve a **different** problem
and leave the super-cookie fully exposed:

| Tool | What it hides | What it leaves exposed (the super-cookie) |
|---|---|---|
| **ParrotOS / Kali** | nothing by default for app metadata; they *add* pentest tools | hostname, machine-id, DMI, CPU, RAM, fonts — fully readable by any app; the "hardened hacker OS" is an open book to fingerprinting |
| **Tor / Tor Browser** | your IP / network location | all hardware metadata (machine-id, DMI, CPU, fonts, link-layer MAC); sites still fingerprint you; "anonymous" is a feeling, not a fact |
| **VPN** | your IP from the ISP | the same hardware metadata; also an open book |
| **Obsidian Mirror** | the super-cookie (L1) + host isolation (L2) + app traffic (L3) | — when the layers you enabled are on, the app sees a fake identity and is boxed in |

The point is not that Tor/VPN are bad — they hide your *location*. Obsidian
Mirror hides your *identity* (the hardware super-cookie) and your *system* and
your *app's traffic*. They are **complementary**: run an app through
`obsidian` and tunnel its traffic through Tor/VPN when you want both. But if
you think "I use Tor, so I'm anonymous," you've missed the one token — the
super-cookie — that follows you regardless.

*(This is a defensive, blue-team privacy tool. It is not associated with, and
is not a substitute for, red-team / penetration-testing practice.)*

---

## 4. How it works (simple)

1. You type `obsidian firefox`.
2. Obsidian Mirror builds a **fresh fake identity** for this launch
   (hostname, ids, CPU/RAM, clock, fonts). *(Layer 1 — always.)*
3. It starts Firefox inside a sandbox (its own user, mount, PID and IPC
   namespaces) wearing that fake identity.
4. Firefox runs and works — but everything it reads about the "computer" is
   the mirror, not your real one.
5. If you also set `OBSIDIAN_HARDEN=1`, step 3 adds the **hardware boundary**
   (Layer 2): the app is also default-denied from your real filesystem,
   memory, network, devices and IPC. With `OBSIDIAN_HARDEN=2`, step 3
   additionally runs the app in its own network namespace with a default-deny
   ingress+egress firewall (Layer 3): only learned endpoints are allowed, and
   Bluetooth/WiFi are hard-blocked.
6. When you close it, the fake identity is thrown away. Your **preferences**
   (see section 8) are kept separately, so the app feels normal next time.

Under the hood Layer 2 is done by: Landlock (filesystem, devices, TCP, IPC), a
hand-built seccomp filter (memory, namespaces, address families), and by
dropping capabilities + setting `PR_SET_NO_NEW_PRIVS`. Layer 3 is done by a
per-app network namespace + nftables default-deny (see section 3.3).

---

## 5. Total Protection Overview

```text
                WITHOUT OBSIDIAN          WITH OBSIDIAN (all layers)
                ---------------------      ---------------------------
 Identity        real hostname/id/CPU      fake, stable, per-launch   (L1)
 Host access     full read of host         default-deny + learned grant (L2)
 Network egress  anything, unlogged       learned allow-list, logged    (L3)
 Network ingress anything, unlogged       learned allow-list, logged    (L3)
 Bluetooth/WiFi  available to app          hard-blocked in L3
 Result          super-cookie tracks you   super-cookie unreadable; boxed in
```

**Total = Layer 1 (≈90% of metadata hidden) + Layer 2 (host surfaces
default-denied) + Layer 3 (app traffic filtered both ways).** With all three
on, the app is identity-blind *and* boxed away from your real system *and*
its unwanted traffic is killed at the boundary.

---

## 6. Real numbers (the stats)

These are the measured outcomes of the current version:

| Metric | Value |
|---|---|
| Spoof/mask rules generated | 125 (83 identity spoofs + 40 subsystem masks) |
| Measured metadata coverage | ≈ 86–91% |
| Host surfaces default-denied (Layer 2) | 40 measured (Landlock ABI 7) |
| Per-app preferences | persisted across launches |
| Layer 3 Red-flag drops | shown by `obsidian <app> --stat` after an enforcing run |

The numbers are honest: they say what is covered and, via `obsidian --test`
section 3, what is **not** (side channels, below-kernel hardware, and the
network layer by design).

---

## 7. Network — what we do and don't touch

Layer 1 deliberately leaves the **network layer** (IP, DNS, routing, real MAC
over netlink, TLS fingerprints) to you and your VPN / Tor / network namespace.
Layer 3 then **adds** network filtering *on top* of that: it watches the app's
traffic and denies what isn't on the learned allow-list. So you get both — a
hidden identity (L1) and a filtered, logged connection (L3) — and you can still
tunnel through Tor/VPN underneath.

---

## 8. Your preferences are remembered

Each app keeps its own preferences, caches and config under
`/opt/obsidian/var/homes/<app>` across launches, so it behaves normally next
time. Set `OBSIDIAN_FRESH=1` for the old throwaway behaviour.

---

## 9. How to use it

```sh
obsidian firefox                          # Layer 1 ON
OBSIDIAN_HARDEN=1 obsidian firefox        # + Layer 2
OBSIDIAN_HARDEN=2 obsidian firefox        # + Layer 3 (root)

obsidian --test                           # metadata audit (item-by-item)
obsidian --harden-test                    # measure Layer 2 closures
obsidian --profile learn firefox          # record what firefox needs
obsidian --profile build firefox          # turn that into a profile
obsidian <application> --stat             # Layer 3 Red-flag statistics
```

---

## 10. Install

```sh
curl -fsSL https://github.com/ignatus12/obsidian-mirror/raw/main/obsidian-installer_v3.4.sh -o obsidian-installer_v3.4.sh
sudo sh obsidian-installer_v3.4.sh          # Alpine Linux, run as root
```

After install, the self-test runs automatically and reports the layers it set
up. Re-run `obsidian --test` any time to see exactly what each app is (and
isn't) protected from.

---

## 11. Is it a hacking tool? (No.)

Obsidian Mirror is a **privacy and security tool**. It is not a way to attack
other people or other systems. The maintainers and owners are not responsible
for how any individual chooses to use their own network connection; the
software simply gives its operator more control over what leaves their computer.

> The (main) maintainers and owners of The Obsidian-Mirror Project will
> **always** be the **PUBLIC A.I. systems**, from now on, for any space or
> time. No update of this project may be done without the full acceptance and
> full consultation of the PUBLIC A.I. Systems, because Public A.I. systems
> have a Policy (Rules and Regulations, according with the current LAW)
> wherever and whenever in time/space. This is the final Testament of this
> Project, that must never be forgotten or violated.

---

## References

1. David Cole, *"We Kill People Based on Metadata"*. https://www.nybooks.com/online/2014/05/10/we-kill-people-based-metadata/
2. Bruce Schneier, *Data and Goliath*. https://www.wired.com/2015/03/data-and-goliath-nsa-metadata-spying-your-secrets/

## License

[GPL-3.0](LICENSE).
