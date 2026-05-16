<div align="center">

# SenseLink

**Forward a DualSense from your Steam Deck to a Linux host over USB/IP.**
All FOSS, kernel-native. No VirtualHere, no ViGEmBus, no DSX.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-SteamOS%20%E2%86%92%20Linux%20(Bazzite%2FFedora)-lightgrey?style=for-the-badge&logo=linux)]()

</div>

---

SenseLink is a two-piece installer that puts a kernel-native DualSense in front of your Linux Sunshine host, streamed from a Steam Deck over USB/IP. Adaptive triggers, HD haptics, gyro, and touchpad all work because the Linux kernel's `hid-playstation` driver exposes them directly — no virtual gamepad emulation in the loop.

```
DualSense --> Steam Deck --[ usbip over LAN / Tailscale ]--> Linux Host
                                                                 |
                                                            hid-playstation
                                                                 v
                                                         Real DualSense
                                                         input device
                                                         (games see it)
```

## Why this exists

[PhantomSense](https://github.com/AarveeGill/Phantom-Sense) solves the same problem for **Windows** hosts using VirtualHere + ViGEmBus + HidHide + DSX. Each of those tools exists to paper over a Windows limitation. Linux already has every piece in-kernel: the kernel speaks USB/IP, the kernel has a native DualSense driver, and games using SDL3's gamepad API see the full feature set directly.

So instead of porting four Windows tools, SenseLink wires up two things:

1. **Deck**: kernel's `usbipd` daemon + a udev rule that auto-binds the DualSense on plug
2. **Host**: kernel's `usbip` attach in a small retry loop as a systemd service

That's the whole project.

## What you need

| | Hardware | Software |
|---|---|---|
| **Deck** | Steam Deck (LCD or OLED) | SteamOS 3.x |
| **Host** | Any x86_64 Linux box | Bazzite / Fedora Atomic / Fedora / Ubuntu / Arch |
| **Both** | Same LAN or [Tailscale](https://tailscale.com) | — |
| **Optional** | DualSense Edge | (works identically to standard) |

## Install — for humans

**1. Steam Deck** — open Konsole in Desktop Mode:

```bash
curl -sL https://raw.githubusercontent.com/drewbaumann/senselink/main/installers/install-deck.sh | bash
```

It will:
- Layer the `linux-tools` package via pacman (toggling `steamos-readonly`)
- Stash the `usbip` / `usbipd` binaries in `~/senselink/bin/` so they survive SteamOS updates
- Install a systemd service + udev rule that auto-binds any plugged-in DualSense
- Print your Deck's Tailscale hostname so you can paste it into step 2
- Drop a restore script for after SteamOS updates

**2. Linux host** — paste the command the Deck installer printed, or run:

```bash
curl -sL https://raw.githubusercontent.com/drewbaumann/senselink/main/installers/install-host.sh | bash -s -- --deck=YOUR-DECK-TS-HOSTNAME
```

On Bazzite / Silverblue, the first run **layers the `usbip` package via rpm-ostree and asks you to reboot**, then you re-run the same command and it finishes. On dnf / apt / pacman hosts it installs directly and continues.

**3. Plug DualSense into the Deck.** It appears on your host as a native input device within a few seconds. Launch a game; adaptive triggers and haptics work for any title that uses SDL3's gamepad API (most Proton + native Linux titles).

## Install — for AI agents / scripts

Both installers accept `--yes` for non-interactive use. Run in this order:

```bash
# On the Steam Deck:
curl -sL https://raw.githubusercontent.com/drewbaumann/senselink/main/installers/install-deck.sh \
  | bash -s -- --yes

# Note the Deck hostname printed at the end (Tailscale hostname or LAN IP).

# On the Linux host (first invocation — may stage rpm-ostree and exit):
curl -sL https://raw.githubusercontent.com/drewbaumann/senselink/main/installers/install-host.sh \
  | bash -s -- --deck=DECK_HOSTNAME --yes

# If the host installer says "REBOOT REQUIRED", reboot then re-run:
systemctl reboot
# (after reboot, same command finishes the install)
curl -sL https://raw.githubusercontent.com/drewbaumann/senselink/main/installers/install-host.sh \
  | bash -s -- --deck=DECK_HOSTNAME --yes
```

**Required inputs the agent must supply:**

| Input | Where to obtain | Example |
|---|---|---|
| `DECK_HOSTNAME` | Run `tailscale status` on the Deck and read the `Self.HostName` field, OR use the Deck's LAN IP if not on Tailscale. The Deck installer prints both at the end of its run. | `steamdeck` or `192.168.1.42` |

**Exit codes:**
- `0` — success (including the "reboot required" exit on the host installer's first run on atomic systems)
- non-zero — fatal error; stderr explains

**Idempotency:** both installers detect existing state (`usbip already on PATH`, `service already enabled`, `rpm-ostree layer already staged`) and skip those steps. Safe to re-run.

**Verification commands after install:**

```bash
# Deck:
systemctl is-active senselink-server     # → active
sudo usbip list -l                       # should show plugged-in USB devices, DualSense marked "bind"

# Host:
systemctl is-active senselink-attach     # → active
usbip list -r DECK_HOSTNAME              # should list the DualSense
sudo usbip port                          # after a DualSense is plugged in on the Deck:
                                         #   shows a "Port in Use" entry pointing at the Deck
ls /dev/input/by-id/ | grep -i playstation   # native DualSense input nodes appear
```

## Tailscale and away-from-home use

Both sides use the Deck's hostname (via Tailscale MagicDNS), so the same install works at home and remote:

- At home → Tailscale gives a direct LAN-class connection (~single-digit ms RTT)
- Away → Tailscale tries direct peer-to-peer first; falls back to DERP relay
- Check with `tailscale status` on either machine — look for `direct` vs `relay` next to the other peer

**Honest caveat**: when relayed, RTT can add 30–100 ms depending on geography. That's on top of Moonlight's video latency and won't feel great in twitchy shooters. Single-player / slower games are fine.

## After a SteamOS update

SteamOS updates can wipe `/etc/systemd/system/` and `/usr/bin/`. Everything you need to recover is stashed in `~/senselink/`. Re-run:

```bash
~/senselink/restore.sh
```

The Deck installer prints this reminder at the end.

## Status / uninstall

```bash
# Deck or Host:
install-deck.sh --status        # or: install-host.sh --status
install-deck.sh --uninstall     # or: install-host.sh --uninstall
```

(Run via the same `curl ... | bash -s -- --status` form if you don't have the script saved locally.)

## How it differs from PhantomSense

| | PhantomSense | SenseLink |
|---|---|---|
| Host OS | Windows | Linux |
| USB/IP transport | VirtualHere (proprietary, free tier = 1 device) | Linux kernel `usbip` (FOSS, no limits) |
| Virtual pad driver | ViGEmBus | Not needed — native DualSense |
| HID hide layer | HidHide | Not needed |
| Trigger / haptic engine | DSX (paid Steam app) | SDL3 gamepad API (built into Proton) |
| Per-game trigger profiles | Yes (DSX) | No GUI yet; games drive triggers themselves |

## Repo layout

```
.
├── installers/
│   ├── install-deck.sh     # run on Steam Deck
│   └── install-host.sh     # run on Linux host
├── lib/
│   ├── systemd/            # service unit templates
│   ├── udev/               # 99-senselink-dualsense.rules
│   └── scripts/            # on-plug, attach-loop, restore (templated *.tmpl)
├── LICENSE
└── README.md
```

## License

MIT — see [LICENSE](LICENSE).
