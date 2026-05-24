<div align="center">

# SenseLink

**Forward a DualSense from a small Linux box to your Linux gaming PC over the network — natively, no proprietary software.**

Adaptive triggers, HD haptics, gyro, and touchpad all work, because the gaming
PC sees a *real* USB DualSense via the kernel's `hid-playstation` driver.

</div>

---

## What this is

You plug a DualSense into a cheap always-on Linux box (a Raspberry Pi works great).
That box shares the controller over the network with your gaming PC using the
Linux kernel's built-in **USB/IP**. Your PC sees a real, wired DualSense — so
every feature works, and it behaves identically in native games and in
game-streaming setups.

```
DualSense ──USB──> Pi (exporter) ──usbip over Tailscale──> Gaming PC (host) ──> games
                   usbipd                                   usbip attach + hid-playstation
```

This is the **all-Linux, all-FOSS** counterpart to [PhantomSense](https://github.com/AarveeGill/Phantom-Sense)
(which targets Windows hosts with VirtualHere + ViGEmBus + DSX). On Linux you
need none of that — the kernel already speaks USB/IP and already has a native
DualSense driver.

## Why not just plug the controller into the gaming PC?

Because the point is to use it **away** from the gaming PC — on the couch, at the
TV — while streaming the game with Sunshine/Moonlight. Normally Moonlight
translates your controller into a generic Xbox pad and strips adaptive
triggers, haptics, gyro, and touchpad. SenseLink forwards the *raw USB device*
straight to the gaming PC instead, so the game gets a native DualSense while
Moonlight only carries video. (See [Game streaming](#game-streaming-sunshine--moonlight).)

## Requirements

| Role | What | Notes |
|------|------|-------|
| **Exporter** | Any always-on Linux box | Raspberry Pi 3/4/5, an old laptop, etc. Needs a USB port + network. |
| **Host** | Your Linux gaming PC | Bazzite / Fedora / Arch / Ubuntu — anything with `usbip` + `vhci-hcd`. |
| **Both** | [Tailscale](https://tailscale.com) (recommended) | Free. Makes it work across rooms / networks and sidesteps router quirks (see [Troubleshooting](#troubleshooting)). |
| Controller | DualSense or DualSense Edge | `054c:0ce6` / `054c:0df2`. |

## Setup

### 1. Exporter (the box the controller plugs into)

```bash
curl -fsSL https://raw.githubusercontent.com/drewbaumann/senselink/main/install-exporter.sh | sudo bash
```

Then put it on Tailscale and note its name:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale status      # note the 'Self' name, e.g. livingroom-pi
```

Plug in the DualSense — it auto-binds.

### 2. Host (your gaming PC)

```bash
curl -fsSL https://raw.githubusercontent.com/drewbaumann/senselink/main/install-host.sh \
  | sudo bash -s -- --exporter=livingroom-pi
```

Replace `livingroom-pi` with your exporter's Tailscale name (or its IP).

> **Bazzite / Silverblue (rpm-ostree):** the first run layers `usbip` and asks
> you to **reboot**, then you re-run the same command. That's expected on atomic
> distros.

Make sure the host is on Tailscale too (`sudo tailscale up`). That's it — the
controller auto-attaches on boot and re-attaches if it ever drops.

### Verify

- **System Settings → Game Controller** (KDE) shows the DualSense and lets you test buttons/sticks/gyro.
- or open **gamepad-tester.com** in a browser and press buttons.
- or `usbip port` (host) shows the attached remote device.

## Game streaming (Sunshine / Moonlight)

This is the intended use case, and it's better than Moonlight's built-in
controller forwarding:

```
Video/audio:  Gaming PC (Sunshine) ──Moonlight──> client at the TV ──> screen
Controller:   DualSense → exporter → usbip/Tailscale → Gaming PC (game reads it directly)
```

The game runs on the gaming PC and sees the DualSense as a **local, native**
controller — full gyro/touchpad/triggers/haptics. Moonlight only carries the
picture, so its controller-translation (which strips those features) is never
in the path. The two paths are independent, so controller latency is just the
usbip/Tailscale hop (single-digit ms on a direct connection), separate from
video latency.

**Important:** in the **Moonlight client** at the TV, turn **off** its gamepad
input. Otherwise, if that client has its own controller, Sunshine spins up a
second (virtual Xbox) pad on the gaming PC and you get double input.

## How it works

- **Exporter** runs `usbipd` (systemd service) and a udev rule that, on plug,
  disables USB autosuspend for the controller and `usbip bind`s it so it's
  exportable.
- **Host** runs a tiny systemd service that finds the controller the exporter
  is sharing (matched by USB vendor/product), `usbip attach`es it over the
  network, and re-attaches automatically if the link drops. A udev rule grants
  your desktop user access to the controller's input/hidraw nodes.
- The kernel's `hid-playstation` driver does the rest — the controller appears
  exactly as if it were plugged into the gaming PC directly.

## Troubleshooting

Lessons learned the hard way:

- **Controller connects but drops after ~10s / games can't reach it, even though
  `ping` works.** Many consumer mesh routers (Eero, etc.) allow pings and
  multicast between Wi-Fi clients but quietly break *sustained* client-to-client
  TCP. **Fix: use Tailscale.** Point `--exporter` at the exporter's Tailscale
  name; the WireGuard tunnel rides right past the router's client isolation and
  usually negotiates a direct, low-latency peer connection (`tailscale ping <name>`
  shows `direct` vs `relay`).
- **Controller worked, then detached on its own.** USB autosuspend on the
  exporter resets idle devices, which breaks the USB/IP bind. The exporter
  installer disables autosuspend for the controller (`power/control=on`); if you
  rolled your own, do the same.
- **KDE / SDL says "no game controllers found" even though it's attached.** The
  attached device's nodes need a `uaccess` tag so your logged-in user can open
  them — the host installer adds this udev rule. Re-plug or re-attach after
  installing.
- **Raspberry Pi 3 B+ won't join your 5 GHz Wi-Fi.** It can't use 5 GHz **DFS**
  channels (52–144). Put it on 2.4 GHz, or on 5 GHz non-DFS channels
  (36/40/44/48/149/153/157/161/165), or wire it.
- **VirtualHere times out claiming the DualSense.** VirtualHere claims each USB
  interface separately, and the DualSense's audio interfaces make that slow
  enough to time out. Kernel `usbip` binds the whole composite device at once
  and handles it cleanly — which is why this project uses usbip.
- **A second HID interface fails to probe in `dmesg`** (`Invalid byte count… pairing info`).
  Harmless — the main gamepad interface registers fine.

## Repo layout

```
install-exporter.sh   # run on the controller box (Pi)
install-host.sh       # run on the gaming PC
docs/                 # design notes (incl. a parked Pico-firmware experiment)
```

## Credits

Inspired by [PhantomSense](https://github.com/AarveeGill/Phantom-Sense) (the
Windows-host equivalent). Built on Linux's kernel USB/IP, `hid-playstation`,
and [Tailscale](https://tailscale.com).

## License

MIT — see [LICENSE](LICENSE).
