#!/bin/bash
# ============================================================================
# SenseLink Deck Installer
# https://github.com/__GH_OWNER__/senselink
#
# Forwards a DualSense controller from a Steam Deck (SteamOS) to a Linux
# Sunshine host over USB/IP. FOSS-only path: kernel usbip, no VirtualHere.
#
# Usage (interactive):
#   curl -sL https://raw.githubusercontent.com/__GH_OWNER__/senselink/main/installers/install-deck.sh | bash
#
# Usage (non-interactive — for automation / AI agents):
#   curl -sL .../install-deck.sh | bash -s -- --yes
#
# Flags:
#   --yes          assume yes to all prompts (non-interactive)
#   --status       show install status and exit
#   --uninstall    remove the SenseLink service, udev rule, and helper
#   --help         show this help
# ============================================================================

set -euo pipefail

VERSION="0.1.0"
GH_OWNER="__GH_OWNER__"
GH_REPO="senselink"
RAW_BASE="https://raw.githubusercontent.com/${GH_OWNER}/${GH_REPO}/main"

INSTALL_DIR="$HOME/senselink"
BIN_DIR="$INSTALL_DIR/bin"
SERVICE_NAME="senselink-server"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
UDEV_FILE="/etc/udev/rules.d/99-senselink-dualsense.rules"
HELPER_DIR="/etc/senselink"

YES=0
ACTION="install"

# ── Logging ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step() { echo -e "\n${BOLD}--- $* ---${NC}"; }
die()  { err "$*"; exit 1; }

banner() {
  cat <<EOF

${BOLD}SenseLink Deck Installer v${VERSION}${NC}
  USB/IP server: forwards DualSense to your Linux host.
  https://github.com/${GH_OWNER}/${GH_REPO}

EOF
}

show_help() {
  banner
  sed -n '4,20p' "$0" 2>/dev/null || true
  cat <<'EOF'

Flags:
  --yes          assume yes to all prompts
  --status       show install status and exit
  --uninstall    remove SenseLink and exit
  --help         show this help

EOF
}

# ── Argument parsing ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)        YES=1 ;;
    --status)        ACTION="status" ;;
    --uninstall)     ACTION="uninstall" ;;
    -h|--help)       show_help; exit 0 ;;
    *) die "unknown flag: $1 (use --help)" ;;
  esac
  shift
done

confirm() {
  local prompt="$1"
  if (( YES == 1 )); then return 0; fi
  read -rp "$prompt [y/N]: " reply
  [[ "$reply" =~ ^[Yy] ]]
}

# ── Preflight ──────────────────────────────────────────────────────────────
preflight() {
  step "Preflight"

  if [[ ! -f /etc/os-release ]] || ! grep -qi 'steamos\|holo\|arch' /etc/os-release; then
    warn "This script targets SteamOS. Detected:"
    grep -E '^(ID|NAME)=' /etc/os-release || true
    confirm "Continue anyway?" || die "aborted"
  fi

  if ! command -v sudo >/dev/null; then die "sudo required"; fi
  if ! sudo -v; then die "sudo authentication failed (run 'passwd' first if you've never set one)"; fi
  ( while true; do sudo -v; sleep 50; done ) & local sudo_pid=$!
  trap "kill $sudo_pid 2>/dev/null || true" EXIT
  ok "sudo ok"
}

# ── Install usbip (Arch/SteamOS) ───────────────────────────────────────────
install_usbip() {
  step "Installing usbip userspace tools"

  if command -v usbip >/dev/null && command -v usbipd >/dev/null; then
    ok "usbip already present at $(command -v usbip)"
    return 0
  fi

  info "Installing 'linux-tools' (provides usbip) via pacman"
  if command -v steamos-readonly >/dev/null; then
    sudo steamos-readonly disable
  fi
  sudo pacman-key --init 2>/dev/null || true
  sudo pacman -Sy --noconfirm linux-tools \
    || die "pacman failed to install linux-tools"
  if command -v steamos-readonly >/dev/null; then
    sudo steamos-readonly enable
  fi

  command -v usbip >/dev/null  || die "usbip not on PATH after install"
  command -v usbipd >/dev/null || die "usbipd not on PATH after install"
  ok "usbip installed"
}

# ── Stash binaries in $HOME so they survive SteamOS updates ────────────────
stash_binaries() {
  step "Stashing binaries in $BIN_DIR (survives SteamOS updates)"
  mkdir -p "$BIN_DIR"
  install -m 0755 "$(command -v usbip)"  "$BIN_DIR/usbip"
  install -m 0755 "$(command -v usbipd)" "$BIN_DIR/usbipd"
  ok "stashed"
}

# ── Fetch a templated lib file, substitute placeholders, return content ────
fetch_template() {
  local relpath="$1"; shift
  local content
  content=$(curl -fsSL "$RAW_BASE/$relpath") \
    || die "failed to fetch $RAW_BASE/$relpath"
  while [[ $# -gt 0 ]]; do
    local key="$1" val="$2"; shift 2
    content="${content//$key/$val}"
  done
  printf '%s\n' "$content"
}

# ── Install systemd unit, udev rule, on-plug helper ────────────────────────
install_unit_and_udev() {
  step "Installing systemd unit, udev rule, and on-plug helper"

  # 1. systemd unit
  local unit
  unit=$(fetch_template "lib/systemd/senselink-server.service" "__BINDIR__" "$BIN_DIR")
  echo "$unit" | sudo tee "$SERVICE_FILE" >/dev/null
  sudo chmod 0644 "$SERVICE_FILE"

  # Also stash a copy for restore
  echo "$unit" > "$INSTALL_DIR/senselink-server.service"

  # 2. udev rule
  local udev_rule
  udev_rule=$(fetch_template "lib/udev/99-senselink-dualsense.rules")
  echo "$udev_rule" | sudo tee "$UDEV_FILE" >/dev/null
  sudo chmod 0644 "$UDEV_FILE"
  echo "$udev_rule" > "$INSTALL_DIR/99-senselink-dualsense.rules"

  # 3. on-plug helper
  sudo install -d -m 0755 "$HELPER_DIR"
  local on_plug
  on_plug=$(fetch_template "lib/scripts/on-plug.sh.tmpl" "__BINDIR__" "$BIN_DIR")
  echo "$on_plug" | sudo tee "$HELPER_DIR/on-plug.sh" >/dev/null
  sudo chmod 0755 "$HELPER_DIR/on-plug.sh"
  echo "$on_plug" > "$INSTALL_DIR/on-plug.sh"
  chmod 0755 "$INSTALL_DIR/on-plug.sh"

  # 4. log file
  sudo touch /var/log/senselink.log
  sudo chmod 0664 /var/log/senselink.log

  ok "service, udev rule, helper installed"
}

# ── Install restore script ────────────────────────────────────────────────
install_restore_script() {
  step "Installing SteamOS-update restore script"
  local restore
  restore=$(fetch_template "lib/scripts/restore-deck.sh.tmpl" "__INSTALL_DIR__" "$INSTALL_DIR")
  echo "$restore" > "$INSTALL_DIR/restore.sh"
  chmod 0755 "$INSTALL_DIR/restore.sh"
  ok "restore script at $INSTALL_DIR/restore.sh"
}

# ── Enable + start the service, trigger udev ───────────────────────────────
activate() {
  step "Enabling and starting service"
  sudo systemctl daemon-reload
  sudo systemctl enable --now "$SERVICE_NAME.service"
  sudo udevadm control --reload-rules
  sudo udevadm trigger
  ok "service active"
}

# ── Print Tailscale identity for the host installer ───────────────────────
print_identity() {
  step "Tailscale identity"
  local ts_hostname=""
  if command -v tailscale >/dev/null && tailscale status >/dev/null 2>&1; then
    ts_hostname=$(tailscale status --json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin); print(d.get("Self",{}).get("HostName",""))
except: pass
' 2>/dev/null || true)
  fi
  local lan_ip
  lan_ip=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)

  cat <<EOF

============================================================
${BOLD}Deck side ready.${NC}

Identity for the host installer:
  Tailscale hostname:  ${ts_hostname:-<not detected>}
  LAN IP:              ${lan_ip:-<unknown>}

On your Linux host, run:
  curl -sL ${RAW_BASE}/installers/install-host.sh | bash -s -- --deck=${ts_hostname:-<deck-hostname>}

Plug in the DualSense via USB-C. Check status with:
  systemctl status senselink-server
  sudo ${BIN_DIR}/usbip list -l
  tail -f /var/log/senselink.log

After a SteamOS update, run:
  $INSTALL_DIR/restore.sh
============================================================
EOF
}

# ── Status ────────────────────────────────────────────────────────────────
do_status() {
  banner
  echo "Service:"
  systemctl status "$SERVICE_NAME.service" --no-pager 2>/dev/null || echo "  (not installed)"
  echo
  echo "Bound USB devices (visible to remote hosts):"
  if command -v usbip >/dev/null; then
    sudo usbip list -l 2>/dev/null || true
  fi
  echo
  echo "udev rule:"
  ls -la "$UDEV_FILE" 2>/dev/null || echo "  (not installed)"
}

# ── Uninstall ─────────────────────────────────────────────────────────────
do_uninstall() {
  banner
  confirm "Remove SenseLink from this Deck?" || die "aborted"
  sudo systemctl disable --now "$SERVICE_NAME.service" 2>/dev/null || true
  sudo rm -f "$SERVICE_FILE" "$UDEV_FILE"
  sudo rm -rf "$HELPER_DIR"
  sudo systemctl daemon-reload
  sudo udevadm control --reload-rules
  rm -rf "$INSTALL_DIR"
  ok "uninstalled (binaries left in pacman if installed there)"
}

# ── Main ──────────────────────────────────────────────────────────────────
banner
case "$ACTION" in
  status)    do_status ;;
  uninstall) do_uninstall ;;
  install)
    preflight
    install_usbip
    stash_binaries
    install_unit_and_udev
    install_restore_script
    activate
    print_identity
    ;;
esac
