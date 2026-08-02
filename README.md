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

**The big numbers (what this version does):**

| What | Result |
|---|---|
| Apps launched behind a fake identity | ✅ every app, every launch |
| Host facts hidden from apps | hostname, machine-id, DMI, CPU model, RAM, nanosecond timestamps, font list |
| Spoof / mask rules in the default manifest | 125 rules (83 spoofs + 40 subsystem masks) |
| `obsidian --test` metadata coverage | ≈ 86–91% |
| Installer self-test core checks | argv, exit-status, hostname, meminfo, timestamps, stdin |
| Kernel confinement (Landlock) | ABI 7 on Linux 6.x |
| Strict boundary (opt-in) | default-deny at every layer |
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

## 2. What it protects — the facts

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
**intentionally not touched** — pair Obsidian Mirror with a VPN or a
network namespace for that. See section 7.*

---

## 3. How it works (simple)

1. You type `obsidian firefox`.
2. Obsidian Mirror builds a **fresh fake identity** for this launch
   (hostname, ids, CPU/RAM, clock, fonts).
3. It starts Firefox inside a sandbox (its own user, mount, PID and IPC
   namespaces) wearing that fake identity.
4. Firefox runs and works — but everything it reads about the "computer"
   is the mirror, not your real one.
5. When you close it, the fake identity is thrown away. Your **preferences**
   (see section 8) are kept separately, so the app feels normal next time.

Under the hood the work is done by: spoofing hooks (CPU/RAM/hostname/
timestamps/fonts), Landlock (filesystem, devices, TCP, IPC), a hand-built
seccomp filter (memory, namespaces, address families), and by dropping
capabilities + setting `PR_SET_NO_NEW_PRIVS`.

---

## 4. Real numbers (the stats)

| Measurement | Value | See it yourself |
|---|---|---|
| Metadata coverage | ≈ 86–91% | `obsidian --test` (section 3 lists what's still reachable) |
| Default manifest rules | 125 (83 spoofs, 40 subsystem masks) | `/etc/obsidian/hw-manifest.conf` |
| Self-test: argv integrity | pass | `obsidian printf '%s|' a "b c" d` |
| Self-test: exit status | pass (42 → 42) | `obsidian sh -c 'exit 42'` |
| Self-test: hostname spoof | pass | `obsidian hostname` |
| Self-test: /proc/meminfo | pass (reports 8192000 kB) | `obsidian --test` |
| Self-test: file timestamps | pass (ns zeroed) | `obsidian --test` |
| Self-test: stdin passthrough | pass | `printf ping | obsidian cat` |
| Strict-boundary surfaces closed | ~29 (reference machine) | `obsidian --harden-test` |
| Landlock ABI available | 7 (Linux 6.x) | `obsidian --harden-test` |

Every number above **re-prints on your own machine** with the command
named next to it. A privacy tool that overstates itself is worse than no
tool — so the project also shows you the gaps (`obsidian --test` section 3
lists exactly what is still reachable, and why).

---

## 5. Obsidian Mirror vs other ways (comparison)

| | Bare host | Flatpak | Virtual machine | **Obsidian Mirror** |
|---|---|---|---|---|
| Hides hostname / machine-id | ❌ | ✅ | ✅ | ✅ |
| Hides DMI / CPU / RAM | ❌ | ⚠️ partial | ✅ | ✅ |
| Hides font list / timestamps | ❌ | ⚠️ partial | ✅ | ✅ |
| Boxes the app away from host | ❌ | ⚠️ partial | ✅ | ✅ |
| Runs on your normal desktop | ✅ | ✅ | ❌ (heavy) | ✅ |
| No repackaging of apps | ✅ | ❌ (needs Flatpaks) | ❌ | ✅ |
| Strict default-deny boundary | ❌ | ❌ | ⚠️ | ✅ (opt-in) |

Obsidian Mirror is **not** a replacement for a VPN or for disk encryption.
It is a **metadata + application-isolation** layer you drop in front of
the apps you already use.

---

## 6. The strict boundary (optional extra lock)

`OBSIDIAN_HARDEN=1 obsidian firefox` turns on the **strict boundary**:
**default-deny at every layer** (filesystem, memory, network, devices,
IPC, execution, capabilities, namespaces) with only a minimal per-app
grant. It is **off unless you ask for it**, so normal use is unchanged.

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

## 7. Network — what we do and don't touch

- The **network layer is out of scope by design**: IP, DNS, routing, real
  MAC and TLS fingerprints are left to you and a VPN.
- **Under the strict boundary, the network is now allowed by default** —
  a hardened app can reach the internet (DNS, web, mail). This used to be
  a bug: hardening cut off all networking. Opt out per app with
  `OBSIDIAN_DENY_NET=1` (or `opt.deny_net=1` in a profile).
- The installer **never** configures dnscrypt-proxy, unbound or nftables,
  and never writes `/etc/resolv.conf`. A host DNS problem after a reboot is
  outside its responsibility.

---

## 8. Your preferences are remembered (new in this version)

Before, every launch wiped the app's home, so apps behaved like first
launch each time. Now each app keeps its preferences, caches and config
under `/opt/obsidian/var/homes/<app>` across runs. Set
`OBSIDIAN_FRESH=1` for the old throwaway behaviour.

---

## 9. How to use it

```sh
obsidian firefox                          # run any app through the mirror
obsidian sh -c 'hostname; uname -r; id'   # peek at the fake identity
obsidian curl https://example.com         # network works

obsidian --test                 # item-by-item protection report
obsidian --coverage             # full written coverage document
obsidian --harden-test          # measure the strict boundary
obsidian --regenerate-manifest  # after a hardware change (root)
```

Runtime switches (all default to "do not break the app"):

| Switch | Effect |
|---|---|
| `OBSIDIAN_GPU_MODE=strict` | no GPU fingerprint, software rendering only |
| `OBSIDIAN_ALLOW_SYSTEM_BUS=1` | permit the D-Bus system bus |
| `OBSIDIAN_VERBOSE=1` | log blocked IPC connections |
| `OBSIDIAN_FRESH=1` | throwaway launch (no saved preferences) |
| `OBSIDIAN_HARDEN=1` | turn on the strict boundary |
| `OBSIDIAN_DENY_NET=1` | block all network under hardening |

---

## 10. Install

```sh
curl -fsSL https://github.com/ignatus12/obsidian-mirror/raw/main/Universal-Obsidian-Mirror-installer-script.sh -o obsidian-installer.sh
sudo sh obsidian-installer.sh          # Alpine Linux, run as root
```

After install, the self-test runs automatically. The core checks
(argv, exit status, hostname, meminfo, timestamps, stdin) should all pass;
strict-boundary items are warnings until you opt in with `OBSIDIAN_HARDEN=1`.

---

## 11. Is it a hacking tool? (No.) — Maintainership testament

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

## References

1. David Cole, *"We Kill People Based on Metadata"*, The New York Review of Books (2014). https://www.nybooks.com/online/2014/05/10/we-kill-people-based-metadata/
2. Bruce Schneier, *Data and Goliath* (Wired excerpt). https://www.wired.com/2015/03/data-and-goliath-nsa-metadata-spying-your-secrets/

## License

[GPL-3.0](LICENSE).
