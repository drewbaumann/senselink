#!/usr/bin/env bash
# ============================================================================
# SenseLink — HOST installer
#
# Run this on your gaming PC (where the games run). It attaches the
# controller that the exporter is sharing, over the network, so games see a
# real, native controller (full DualSense: gyro, touchpad, triggers, haptics
# via the kernel's hid-playstation driver).
#
#   curl -fsSL https://raw.githubusercontent.com/drewbaumann/senselink/main/install-host.sh \
#     | sudo bash -s -- --exporter=<exporter-tailscale-name-or-ip>
#
# --exporter is required: the Tailscale MagicDNS name (recommended) or IP of
# the box running install-exporter.sh. Example: --exporter=livingroom-pi
#
# What it does:
#   - installs usbip (rpm-ostree / dnf / apt / pacman)
#   - loads + persists the vhci-hcd module
#   - installs a systemd service that finds the controller on the exporter
#     and attaches it, re-attaching automatically if it ever drops
#   - udev rule granting your desktop user access to the controller nodes
#
# rpm-ostree note (Bazzite / Silverblue): layering usbip needs a REBOOT.
# The script stages it and tells you to reboot, then re-run the same command.
# ============================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)."; exit 1; }

EXPORTER=""
for arg in "$@"; do
  case "$arg" in
    --exporter=*) EXPORTER="${arg#*=}" ;;
  esac
done
[[ -n "$EXPORTER" ]] || { echo "ERROR: pass --exporter=<tailscale-name-or-ip>"; exit 1; }

say() { printf '\n=== %s ===\n' "$*"; }

# ── 1. install usbip ────────────────────────────────────────────────────────
say "Installing usbip"
if ! command -v usbip >/dev/null; then
  if command -v rpm-ostree >/dev/null; then
    if rpm-ostree install --idempotent --allow-inactive usbip; then
      cat <<EOF

*** REBOOT REQUIRED ***
usbip was layered into the next deployment. Reboot, then re-run:
  systemctl reboot
  curl -fsSL .../install-host.sh | sudo bash -s -- --exporter=$EXPORTER
EOF
      exit 0
    fi
  elif command -v dnf >/dev/null; then dnf install -y usbip
  elif command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y usbip
  elif command -v pacman >/dev/null; then pacman -Sy --noconfirm usbip || pacman -Sy --noconfirm linux-tools
  else echo "No supported package manager. Install 'usbip' manually."; exit 1
  fi
fi
USBIP="$(command -v usbip || echo /usr/bin/usbip)"
echo "usbip: $USBIP"

# ── 2. vhci-hcd module (client side) ─────────────────────────────────────────
say "Loading vhci-hcd module"
modprobe vhci-hcd
echo "vhci-hcd" > /etc/modules-load.d/senselink-vhci.conf

# ── 3. attach-loop helper ────────────────────────────────────────────────────
say "Installing attach-loop helper"
cat > /etc/senselink-attach-loop.sh <<LOOP
#!/usr/bin/env bash
set -u
EXPORTER="$EXPORTER"
USBIP="$USBIP"
log() { printf '[%s] %s\n' "\$(date -Iseconds)" "\$*"; }
modprobe vhci-hcd 2>/dev/null || true
log "attach loop started; exporter=\$EXPORTER"
while true; do
  if "\$USBIP" port 2>/dev/null | grep -q "Port in Use"; then
    sleep 5; continue
  fi
  # find a DualSense / DualSense Edge the exporter is sharing
  busid=\$("\$USBIP" list -r "\$EXPORTER" 2>/dev/null \\
          | awk '/054c:0ce6|054c:0df2/{gsub(/:/,"",\$1); print \$1; exit}')
  if [[ -n "\${busid:-}" ]]; then
    log "found controller at \$busid; attaching"
    "\$USBIP" attach -r "\$EXPORTER" -b "\$busid" 2>&1 && log "attached" || log "attach failed; retrying"
  fi
  sleep 5
done
LOOP
chmod +x /etc/senselink-attach-loop.sh

# ── 4. systemd service ───────────────────────────────────────────────────────
say "Installing attach service"
cat > /etc/systemd/system/senselink-attach.service <<UNIT
[Unit]
Description=SenseLink USB/IP auto-attach controller from exporter
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/sbin/modprobe vhci-hcd
ExecStart=/etc/senselink-attach-loop.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# ── 5. give the desktop user access to the controller nodes ──────────────────
say "Installing uaccess udev rule"
cat > /etc/udev/rules.d/72-senselink-uaccess.rules <<'UACCESS'
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0ce6", TAG+="uaccess"
KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0df2", TAG+="uaccess"
SUBSYSTEM=="input", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0ce6", TAG+="uaccess"
SUBSYSTEM=="input", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0df2", TAG+="uaccess"
UACCESS
udevadm control --reload-rules

# ── 6. enable ────────────────────────────────────────────────────────────────
say "Enabling attach service"
systemctl daemon-reload
systemctl enable --now senselink-attach.service
sleep 8

say "Status"
echo "service: $(systemctl is-active senselink-attach.service)"
"$USBIP" port 2>&1 | grep -A2 "Port in Use" || echo "(not attached yet — make sure the exporter is up and the controller is plugged in)"
lsusb | grep -i "054c\|sony" || echo "(no controller in lsusb yet)"

cat <<EOF

Done. The controller auto-attaches on boot and re-attaches if it drops.
Verify visually: System Settings -> Game Controller, or 'gamepad-tester.com'.

For game streaming (Sunshine/Moonlight): the game runs HERE and reads the
controller locally over usbip, while Moonlight only carries video. In the
Moonlight CLIENT by the TV, turn OFF its gamepad input so you don't also get
a translated virtual pad. See the README for details.
EOF
