#!/usr/bin/env bash
# ============================================================================
# SenseLink — EXPORTER installer
#
# Run this on the small Linux box that the controller physically plugs into
# (e.g. a Raspberry Pi by the TV). It sets up the kernel USB/IP server so the
# controller can be forwarded over the network to your gaming PC.
#
#   curl -fsSL https://raw.githubusercontent.com/drewbaumann/senselink/main/install-exporter.sh | sudo bash
#
# What it does:
#   - installs usbip (apt / dnf / pacman)
#   - runs usbipd as a systemd service (auto-starts on boot)
#   - udev rule auto-binds a DualSense (or DualSense Edge) whenever it's
#     plugged in, and disables USB autosuspend for it (prevents idle resets)
#
# Pair it with Tailscale (recommended) so the gaming PC can reach it from
# anywhere and so the connection survives finicky home routers. After this
# runs, install Tailscale on this box ( curl -fsSL https://tailscale.com/install.sh | sh
# && sudo tailscale up ) and note its tailnet name for the host installer.
# ============================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)."; exit 1; }

say() { printf '\n=== %s ===\n' "$*"; }

# ── 1. install usbip ────────────────────────────────────────────────────────
say "Installing usbip"
if command -v apt-get >/dev/null; then
  apt-get update -qq && apt-get install -y usbip
elif command -v dnf >/dev/null; then
  dnf install -y usbip
elif command -v pacman >/dev/null; then
  pacman -Sy --noconfirm usbip || pacman -Sy --noconfirm linux-tools
else
  echo "No supported package manager (apt/dnf/pacman). Install 'usbip' manually."; exit 1
fi

# usbip / usbipd may be in /usr/sbin (Debian) or /usr/bin
USBIP="$(command -v usbip || echo /usr/sbin/usbip)"
USBIPD="$(command -v usbipd || echo /usr/sbin/usbipd)"
[[ -x "$USBIP" && -x "$USBIPD" ]] || { echo "usbip binaries not found after install"; exit 1; }
echo "usbip:  $USBIP"
echo "usbipd: $USBIPD"

# ── 2. kernel module ─────────────────────────────────────────────────────────
say "Loading usbip_host module"
modprobe usbip_host 2>/dev/null || modprobe usbip-host
echo "usbip_host" > /etc/modules-load.d/senselink-usbip.conf

# ── 3. usbipd systemd service ────────────────────────────────────────────────
say "Installing usbipd service"
cat > /etc/systemd/system/senselink-usbipd.service <<UNIT
[Unit]
Description=SenseLink USB/IP host daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStartPre=/sbin/modprobe usbip_host
ExecStart=$USBIPD -D
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

# ── 4. auto-bind helper + udev rule ──────────────────────────────────────────
say "Installing auto-bind helper + udev rule"
install -d /usr/local/bin
cat > /usr/local/bin/senselink-bind <<BIND
#!/bin/bash
# Bind a just-plugged controller to usbip-host. Retries until usbipd is ready.
BUSID="\$1"
USBIP="$USBIP"
for i in 1 2 3 4 5 6 7 8; do
  "\$USBIP" bind -b "\$BUSID" >>/var/log/senselink.log 2>&1 && exit 0
  sleep 1
done
exit 0
BIND
chmod +x /usr/local/bin/senselink-bind

# DualSense (054c:0ce6) and DualSense Edge (054c:0df2):
#   - disable autosuspend for the device (power/control=on) so it won't reset
#   - auto-bind it to usbip on plug
cat > /etc/udev/rules.d/99-senselink-exporter.rules <<'UDEV'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="054c", ATTR{idProduct}=="0ce6", ATTR{power/control}="on", RUN+="/usr/local/bin/senselink-bind %k"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="054c", ATTR{idProduct}=="0df2", ATTR{power/control}="on", RUN+="/usr/local/bin/senselink-bind %k"
UDEV

# ── 5. enable everything + bind anything already plugged in ──────────────────
say "Enabling service + udev"
touch /var/log/senselink.log; chmod 0664 /var/log/senselink.log
systemctl daemon-reload
systemctl enable --now senselink-usbipd.service
udevadm control --reload-rules
udevadm trigger --subsystem-match=usb --action=add 2>/dev/null || true
sleep 2

# bind any DualSense already attached
for d in /sys/bus/usb/devices/*; do
  [[ -f "$d/idVendor" && -f "$d/idProduct" ]] || continue
  v=$(cat "$d/idVendor"); p=$(cat "$d/idProduct")
  if [[ "$v" == "054c" && ( "$p" == "0ce6" || "$p" == "0df2" ) ]]; then
    busid=$(basename "$d")
    echo "Binding controller at $busid"
    echo on > "$d/power/control" 2>/dev/null || true
    "$USBIP" bind -b "$busid" 2>&1 || true
  fi
done

say "Exporter ready"
"$USBIP" list -l 2>/dev/null | grep -iA1 "054c:0ce6\|054c:0df2" || echo "(plug in the controller; it will auto-bind)"

cat <<EOF

Next:
  1. Install Tailscale on THIS box if you haven't:
       curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up
  2. Note this box's tailnet name:  tailscale status   (the 'Self' hostname)
  3. On your gaming PC, run install-host.sh with --exporter=<that-name>
EOF
