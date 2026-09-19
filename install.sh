#!/usr/bin/env bash
# Registers THIS workshop folder (e.g. /home/nova/nw3) with the shared
# usbip-net-regen bridge, installing/refreshing it if needed.
#
# Safe to run from multiple clones (e.g. /home/nova/nw1, nw2, nw3, ...) --
# each run just adds its own directory to a shared registry
# (/etc/usbip-net-regen/repos.txt); the systemd units/worker script are
# shared and only really need installing once, but re-running install.sh
# from any clone re-installs them too (harmless, and picks up updates).
#
# Whenever usbip-net-toolkit's client (on this same machine) reports a
# change in attached USB/IP devices, every registered workshop folder gets
# its docker-compose.yml files regenerated and reconciled -- so a
# re-attach's new hostbus/hostaddr doesn't silently go stale in a running
# container.
#
# Requires usbip-net-toolkit's client/install.sh to already be installed on
# this machine (this only watches its
# /var/lib/usbip-net-client/attached.csv). Idempotent -- safe to re-run.
#
# Usage: sudo bash install.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGEN_USER="${SUDO_USER:-$(id -un)}"
REGEN_GROUP="$(id -gn "$REGEN_USER")"
REGISTRY_DIR="/etc/usbip-net-regen"
REGISTRY="$REGISTRY_DIR/repos.txt"

if [ ! -f "$REPO_DIR/parameters.txt" ]; then
    echo "WARNING: $REPO_DIR/parameters.txt not found."
    echo "         Copy parameters.txt.example to parameters.txt and fill in your real values first."
fi

echo "==> Installing shared usbip-net-regen worker script"
install -m 0755 "$REPO_DIR/bridge/usbip-net-regen.sh" /usr/local/sbin/usbip-net-regen.sh

echo "==> Installing shared systemd units (running as: $REGEN_USER:$REGEN_GROUP)"
sed -e "s#__REGEN_USER__#$REGEN_USER#g" \
    -e "s#__REGEN_GROUP__#$REGEN_GROUP#g" \
    "$REPO_DIR/bridge/usbip-net-regen.service" > /usr/lib/systemd/system/usbip-net-regen.service
install -m 0644 "$REPO_DIR/bridge/usbip-net-regen.path" /usr/lib/systemd/system/usbip-net-regen.path

echo "==> Registering this workshop folder ($REPO_DIR)"
mkdir -p "$REGISTRY_DIR"
touch "$REGISTRY"
if ! grep -qxF "$REPO_DIR" "$REGISTRY"; then
    echo "$REPO_DIR" >> "$REGISTRY"
fi

echo "==> Enabling the watch"
systemctl daemon-reload
systemctl enable --now usbip-net-regen.path

echo
echo "==> Done. Registered workshop folders:"
sed 's/^/      - /' "$REGISTRY"
echo "    usbip-net-regen.service fires whenever"
echo "    /var/lib/usbip-net-client/attached.csv changes, and reconciles"
echo "    every registered folder above."
echo "    Check status: systemctl status usbip-net-regen.path"
echo "                  journalctl -u usbip-net-regen.service"
echo "    Force a run now: sudo systemctl start usbip-net-regen.service"
