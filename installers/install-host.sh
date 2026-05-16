#!/bin/bash
# ============================================================================
# SenseLink Host Installer
# https://github.com/drewbaumann/senselink
#
# Pulls a DualSense controller from a SteamOS Deck (running the SenseLink
# server) into this Linux host over USB/IP. Designed for Bazzite/Fedora
# Atomic but tolerates other Fedora/Ubuntu/Arch hosts.
#
# Usage (interactive):
#   curl -sL https://raw.githubusercontent.com/drewbaumann/senselink/main/installers/install-host.sh | bash
#
# Usage (non-interactive — AI agent / scripted):
#   curl -sL .../install-host.sh | bash -s -- --deck=steamdeck --yes
#
# Flags:
#   --deck=HOST    hostname or IP of the Deck (default: steamdeck)
#   --yes          assume yes to all prompts (non-interactive)
#   --status       show install status and exit
#   --uninstall    remove the SenseLink service and helpers
#   --help         show this help
#
# Notes for rpm-ostree (Bazzite, Silverblue, Kinoite, SteamOS-clones):
#   This installer layers the `usbip` package via rpm-ostree, which REQUIRES
#   A REBOOT before the binary becomes available. On first run the script
#   stages the layer and exits with a "please reboot" message. Re-run after
#   reboot and it picks up where it left off.
# ============================================================================

set -euo pipefail

VERSION="0.1.0"
GH_OWNER="drewbaumann"
GH_REPO="senselink"
RAW_BASE="https://raw.githubusercontent.com/${GH_OWNER}/${GH_REPO}/main"

DECK_HOST="steamdeck"
YES=0
ACTION="install"

SERVICE_NAME="senselink-attach"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
HELPER_DIR="/etc/senselink"
ATTACH_SCRIPT="$HELPER_DIR/attach-loop.sh"
MODULE_FILE="/etc/modules-load.d/senselink-vhci.conf"

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

${BOLD}SenseLink Host Installer v${VERSION}${NC}
  USB/IP client: pulls DualSense from your Deck.
  https://github.com/${GH_OWNER}/${GH_REPO}

EOF
}

show_help() { banner; sed -n '4,28p' "$0" 2>/dev/null || true; }

# ── Argument parsing ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deck=*)        DECK_HOST="${1#*=}" ;;
    --deck)          shift; DECK_HOST="$1" ;;
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
  if ! command -v sudo >/dev/null; then die "sudo required"; fi
  if ! sudo -v; then die "sudo authentication failed"; fi
  ( while true; do sudo -v; sleep 50; done ) & local sudo_pid=$!
  trap "kill $sudo_pid 2>/dev/null || true" EXIT
  ok "sudo ok"

  info "Deck hostname: $DECK_HOST"
  if ! getent hosts "$DECK_HOST" >/dev/null 2>&1; then
    warn "'$DECK_HOST' does not resolve. With Tailscale + MagicDNS this should resolve to your Deck."
    warn "Continuing — service will keep retrying until the Deck is reachable."
  else
    ok "'$DECK_HOST' resolves"
  fi
}

# ── Detect package manager and install usbip ──────────────────────────────
install_usbip() {
  step "Installing usbip userspace tools"

  if command -v usbip >/dev/null; then
    ok "usbip already on PATH at $(command -v usbip)"
    return 0
  fi

  if command -v rpm-ostree >/dev/null; then
    info "rpm-ostree detected (Bazzite/Silverblue) — layering 'usbip'"
    if sudo rpm-ostree install --idempotent --allow-inactive usbip; then
      cat <<EOF

${YELLOW}========================================${NC}
${BOLD}REBOOT REQUIRED${NC}

The usbip package has been layered into the next deployment. Reboot, then
re-run this installer to finish:

  systemctl reboot
  curl -sL ${RAW_BASE}/installers/install-host.sh | bash -s -- --deck=${DECK_HOST} --yes
${YELLOW}========================================${NC}

EOF
      exit 0
    else
      die "rpm-ostree install failed"
    fi
  elif command -v dnf >/dev/null; then
    sudo dnf install -y usbip
  elif command -v apt-get >/dev/null; then
    sudo apt-get update && sudo apt-get install -y linux-tools-generic
  elif command -v pacman >/dev/null; then
    sudo pacman -Sy --noconfirm linux-tools
  else
    die "No supported package manager found. Install 'usbip' manually and re-run."
  fi

  command -v usbip >/dev/null || die "usbip still not on PATH after install"
  ok "usbip installed"
}

# ── Kernel module + persistence ────────────────────────────────────────────
setup_module() {
  step "Loading vhci-hcd kernel module"
  if ! lsmod | grep -q '^vhci_hcd'; then
    sudo modprobe vhci-hcd || die "failed to load vhci-hcd"
  fi
  echo "vhci-hcd" | sudo tee "$MODULE_FILE" >/dev/null
  ok "vhci-hcd loaded and persisted"
}

# ── Fetch templated file ──────────────────────────────────────────────────
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

# ── Install attach-loop helper + systemd unit ─────────────────────────────
install_unit() {
  step "Installing attach-loop helper and systemd unit"

  sudo install -d -m 0755 "$HELPER_DIR"
  local loop_script
  loop_script=$(fetch_template "lib/scripts/attach-loop.sh.tmpl" "__DECK_HOST__" "$DECK_HOST")
  echo "$loop_script" | sudo tee "$ATTACH_SCRIPT" >/dev/null
  sudo chmod 0755 "$ATTACH_SCRIPT"

  local unit
  unit=$(fetch_template "lib/systemd/senselink-attach.service")
  echo "$unit" | sudo tee "$SERVICE_FILE" >/dev/null
  sudo chmod 0644 "$SERVICE_FILE"

  sudo touch /var/log/senselink.log
  sudo chmod 0664 /var/log/senselink.log
  ok "service and helper installed"
}

activate() {
  step "Enabling and starting service"
  sudo systemctl daemon-reload
  sudo systemctl enable --now "$SERVICE_NAME.service"
  ok "service active"
}

print_done() {
  cat <<EOF

============================================================
${BOLD}Host side ready.${NC}

The attach loop is running. Plug a DualSense into the Deck; it'll appear
here within a few seconds.

  systemctl status senselink-attach
  sudo usbip port               # show attached remote devices
  tail -f /var/log/senselink.log

Test directly:
  usbip list -r ${DECK_HOST}    # what is the Deck exporting?

If you reboot, the service comes back automatically.
============================================================
EOF
}

# ── Status / uninstall ─────────────────────────────────────────────────────
do_status() {
  banner
  echo "Service:"
  systemctl status "$SERVICE_NAME.service" --no-pager 2>/dev/null || echo "  (not installed)"
  echo
  echo "Attached USB/IP devices:"
  sudo usbip port 2>/dev/null || echo "  (none)"
  echo
  echo "Deck-exported devices (via $DECK_HOST):"
  usbip list -r "$DECK_HOST" 2>/dev/null || echo "  (Deck unreachable)"
}

do_uninstall() {
  banner
  confirm "Remove SenseLink from this host?" || die "aborted"
  sudo systemctl disable --now "$SERVICE_NAME.service" 2>/dev/null || true
  sudo rm -f "$SERVICE_FILE" "$ATTACH_SCRIPT" "$MODULE_FILE"
  sudo rm -rf "$HELPER_DIR"
  sudo systemctl daemon-reload
  ok "uninstalled (usbip package left in place)"
}

# ── Main ──────────────────────────────────────────────────────────────────
banner
case "$ACTION" in
  status)    do_status ;;
  uninstall) do_uninstall ;;
  install)
    preflight
    install_usbip
    setup_module
    install_unit
    activate
    print_done
    ;;
esac
