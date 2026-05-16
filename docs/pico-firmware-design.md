# DS5Dongle-Wi-Fi: firmware design sketch

A fork of [awalol/DS5Dongle](https://github.com/awalol/DS5Dongle) that uses the
Pico 2W's Wi-Fi (currently unused by DS5Dongle) to expose the bridged
DualSense as a `usbip`-compatible network device, in addition to (or instead
of) the USB port.

End result: a $7 Pico anywhere on your network — or anywhere a VPN-back-home
router reaches — becomes a transparent DualSense for a Linux host, with no
Steam Deck and no USB cable between the Pico and the host.

## Goals

1. **No Linux host changes.** The existing SenseLink host installer (or any
   stock `vhci-hcd`-equipped kernel) should "just attach" the Pico. That
   means speaking the Linux kernel's `usbip` wire protocol, not inventing
   a custom one.
2. **Keep the USB output path optional.** Build mode picks `usb` (current
   DS5Dongle behavior), `wifi`, or `both`.
3. **Survive Wi-Fi blips and host reboots** without manual pairing again.
4. **Single client at a time** is fine for v1; no multi-host arbitration.

## Why usbip and not a custom protocol

The Linux kernel ships `vhci-hcd` (virtual HCI host controller) which speaks
the `usbip` wire protocol. If the Pico speaks it too, the host needs nothing
new — just `usbip attach`. A custom UDP/uhid daemon on Linux would work and
the firmware would be simpler, but every host now needs custom userspace.
Trading firmware complexity for zero host friction is the right swap.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Pico 2W (RP2350)                   │
│                                                     │
│  Core 0                          Core 1             │
│  ┌─────────────────┐             ┌────────────────┐ │
│  │ BT stack        │             │ Wi-Fi (lwIP)   │ │
│  │ (BTstack +      │             │                │ │
│  │  CYW43)         │             │ TCP :3240      │ │
│  └────────┬────────┘             │ usbip server   │ │
│           │ HID reports          └────┬───────────┘ │
│           │ (in: gamepad state,       │             │
│           │  out: rumble/triggers)    │             │
│           ▼                           ▼             │
│  ┌───────────────────────────────────────────────┐  │
│  │       bridge.c — inter-core report queue      │  │
│  │       (SPSC ringbuffer, no locks)             │  │
│  └───────────────────────────────────────────────┘  │
│                                                     │
│  USB device stack (TinyUSB) — built but disabled    │
│  in MODE=wifi; runs in parallel in MODE=both        │
└─────────────────────────────────────────────────────┘

         │                              │
         │ Bluetooth                    │ Wi-Fi
         ▼                              ▼

      DualSense                      Network
                                        │
                                        ▼
                            Linux host: usbip attach
                                        │
                                  vhci-hcd kernel driver
                                        │
                                  /dev/input/eventN
                                  (native DualSense)
```

## Components: new vs. reused

**Reuse from DS5Dongle unchanged:**
- BTstack glue, DualSense pairing logic
- Input report parsing (controller → host direction)
- Output report assembly (host → controller: rumble, triggers, LED, audio
  passthrough for HD haptics)
- USB device descriptors (we'll feed these out over usbip instead of
  TinyUSB)

**New code (firmware):**

| File | Responsibility |
|------|---------------|
| `wifi.c/h` | CYW43 + lwIP init, station mode, reconnect-on-drop. Credentials read from flash. |
| `config.c/h` | Read/write SSID, PSK, optional static IP from a dedicated flash sector. First boot: AP-mode 192.168.4.1 with a tiny HTTP form, or a config file dropped onto BOOTSEL mass-storage. |
| `usbip_server.c/h` | TCP listener on port 3240; protocol state machine; URB queue management. |
| `usbip_protocol.h` | Wire format structs — opcode constants, packet headers, byte-order helpers. |
| `bridge.c/h` | Lockfree SPSC ringbuffers between BT and usbip cores. Two queues: BT→usbip (HID input reports), usbip→BT (output reports). |
| `descriptors.c/h` | Static USB descriptor blobs returned during `OP_REP_IMPORT` and emulated `GET_DESCRIPTOR` control transfers. |

**Host side:** nothing new. SenseLink host installer already loads
`vhci-hcd` and runs an attach loop. The attach-loop script's
`find_dualsense()` will pick the Pico up as long as we advertise the
DualSense VID:PID in `OP_REP_DEVLIST`.

## usbip protocol — what the firmware must implement

Source: Linux kernel `Documentation/usb/usbip_protocol.rst`. All fields
network byte order.

### Phase 1: handshake (TCP connection setup)

Client opens TCP to `pico:3240` and sends one of:

| Opcode | Name | What we do |
|--------|------|------------|
| `0x8005` | `OP_REQ_DEVLIST` | Send `OP_REP_DEVLIST` listing our single virtual DualSense. |
| `0x8003` | `OP_REQ_IMPORT` | Send `OP_REP_IMPORT` with that device's full descriptor blob, then transition to URB mode on this same TCP connection. |

### Phase 2: URB stream

After import, the same TCP socket carries an endless stream of
`usbip_header_basic` + payload messages:

| Direction | Command | Handling |
|-----------|---------|----------|
| Host → Pico | `USBIP_CMD_SUBMIT` on EP0 control IN | Synthesize control-transfer response (`GET_DESCRIPTOR`, `GET_STATUS`, etc.) from static tables. |
| Host → Pico | `USBIP_CMD_SUBMIT` on EP0 control OUT (e.g. SET_REPORT for feature reports) | Forward payload as a HID feature report to DualSense over BT. |
| Host → Pico | `USBIP_CMD_SUBMIT` on EP1 interrupt IN | Park the URB in a pending queue; reply with `USBIP_RET_SUBMIT` next time a BT input report arrives. |
| Host → Pico | `USBIP_CMD_SUBMIT` on EP2 interrupt OUT | Take the HID output report payload, push over BT to DualSense. Immediately reply with `USBIP_RET_SUBMIT` (length, status=0). |
| Host → Pico | `USBIP_CMD_UNLINK` | If there's a matching pending URB, complete it with status `-ECONNRESET`; reply with `USBIP_RET_UNLINK`. |

The key insight: interrupt-IN URBs are submitted *speculatively* by the
host — the kernel keeps a fresh one pending so the moment a HID report is
ready, we have somewhere to put it. Our firmware just maintains a small
queue (4–8 entries) of pending URBs and pops one for each BT report.

### What we don't implement in v1

- **Isochronous endpoints** — the DualSense exposes USB Audio Class
  interfaces for the speaker and mic. We strip those from the descriptor
  blob so the host doesn't try to use them. HD haptics still work because
  they're driven by HID feature reports, not the audio EPs.
- **Multi-client** — accept one TCP connection, refuse others.
- **TLS** — usbip itself has no TLS; trust the network or run over
  Tailscale.

## State machine

```
        (boot)
           │
           ▼
   ┌───────────────┐    config valid?  no ────► ┌──────────────────┐
   │  read flash   ├──────────────────────────► │  AP-mode config  │
   └─────┬─────────┘                            │  (reboot on save)│
         │ yes                                  └──────────────────┘
         ▼
   ┌───────────────┐
   │ connect Wi-Fi ├──── fail ────► retry w/ backoff
   └─────┬─────────┘
         │
         ▼
   ┌───────────────┐
   │ start BT      │
   │ pair / paired │
   └─────┬─────────┘
         │
         ▼
   ┌───────────────┐    client connects
   │ listen :3240  ├──────────────────────────► ┌──────────────────┐
   └───────────────┘                            │ usbip handshake  │
         ▲                                      └─────┬────────────┘
         │ client disconnect                          │
         │                                            ▼
         │                                      ┌──────────────────┐
         └──────────────────────────────────────│ URB pump         │
                                                │ (until close)    │
                                                └──────────────────┘
```

## Build / runtime configuration

`CMakeLists.txt` adds:

```
option(SENSELINK_MODE "usb | wifi | both" "both")
option(SENSELINK_WIFI_CONFIG "static | flash | apmode" "flash")
```

For `SENSELINK_WIFI_CONFIG=flash`: read `WIFI.TXT` from a dedicated flash
sector. For `apmode`: on first boot or when held BOOTSEL, start a 4-LED
captive portal at `192.168.4.1` with one HTML form. For `static`: hardcode
SSID/PSK at compile time (only useful for tinkering).

## Open questions / things to validate

1. **Radio coexistence latency.** CYW43439 time-slices BT and Wi-Fi on the
   same 2.4 GHz radio. With BT classic + Wi-Fi station + ~1 Mbps of HID
   traffic, expected added latency is small (<5 ms p99) — but worth
   measuring on real hardware before declaring victory.
2. **TinyUSB vs raw descriptor blobs.** Easiest path is to keep TinyUSB
   compiled in for `MODE=usb`/`both` and ship the descriptor blob it
   generates as a static array for usbip responses (offline-generated at
   build time). Avoids hand-maintaining descriptor tables.
3. **Reconnect-after-Wi-Fi-drop and the existing TCP socket.** vhci-hcd on
   the host doesn't tolerate the server vanishing well — it usually
   requires `usbip detach` + reattach. The SenseLink attach-loop already
   does this when the device disappears, so as long as the firmware
   gracefully closes the socket on Wi-Fi loss and listens again on
   recovery, the host loop puts it back without manual intervention.
4. **Power.** Pico 2W idle draws ~30 mA, ~120 mA with both radios busy. A
   wall-wart USB plug or a small powerbank covers it. Not a battery
   project.
5. **Discoverability.** mDNS announce as `_usbip._tcp.local` so
   `tailscale serve` / browsers can find it, and the host script can
   discover without hard-coding the IP. Optional but nice.

## Implementation milestones (first three PRs)

1. **PR 1 — Wi-Fi + skeleton usbip server.** Connects to the configured
   SSID, listens on 3240, answers `OP_REQ_DEVLIST` with a hardcoded
   "Hello DualSense" entry. Verify on the host with `usbip list -r
   pico.local`. No real device, no URB handling yet.

2. **PR 2 — Read-only device.** Implement `OP_REQ_IMPORT` and the URB
   pump for EP0 (descriptors) + EP1 (interrupt IN). Wire bridge.c so BT
   input reports get pushed into pending IN URBs. Result: `usbip attach`
   succeeds, the host sees a DualSense, sticks/buttons work. Rumble does
   not yet.

3. **PR 3 — Output reports.** Handle EP2 interrupt OUT URBs and pipe the
   payload back through BT. Now rumble, adaptive triggers, and the LED
   bar all work. v1 done.

## Useful references

- Linux kernel: `Documentation/usb/usbip_protocol.rst`
- `tools/usb/usbip/` in the kernel source — reference C implementation of
  client side; the server side (`usbipd`) is the closest map for what our
  firmware needs to do
- Pico SDK + `pico_cyw43_arch_lwip_threadsafe_background` for the
  Wi-Fi/TCP plumbing
- DualSense HID report tables: https://controllers.fandom.com/wiki/Sony_DualSense
- DS5Dongle source for the BT side
