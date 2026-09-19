#!/usr/bin/env bash
# Installs the usbip-net-regen bridge: whenever usbip-net-toolkit's client
# (https://github.com/soleng2018/usbip-net-toolkit) reports a change in
# attached USB/IP devices, regenerate this repo's docker-compose.yml files
# and reconcile every pod directory -- so a re-attach's new hostbus/hostaddr
# actually reaches the running container instead of silently going stale.
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

if [ ! -f "$REPO_DIR/parameters.txt" ]; then
    echo "WARNING: $REPO_DIR/parameters.txt not found."
    echo "         Copy parameters.txt.example to parameters.txt and fill in your real values first."
fi

echo "==> Installing usbip-net-regen systemd units"
echo "    repo:    $REPO_DIR"
echo "    runs as: $REGEN_USER:$REGEN_GROUP"
sed -e "s#__REPO_DIR__#$REPO_DIR#g" \
    -e "s#__REGEN_USER__#$REGEN_USER#g" \
    -e "s#__REGEN_GROUP__#$REGEN_GROUP#g" \
    "$REPO_DIR/bridge/usbip-net-regen.service" > /usr/lib/systemd/system/usbip-net-regen.service
install -m 0644 "$REPO_DIR/bridge/usbip-net-regen.path" /usr/lib/systemd/system/usbip-net-regen.path

echo "==> Enabling the watch"
systemctl daemon-reload
systemctl enable --now usbip-net-regen.path

echo
echo "==> Done."
echo "    usbip-net-regen.service fires whenever"
echo "    /var/lib/usbip-net-client/attached.csv changes (i.e. whenever"
echo "    usbip-net-toolkit's client attaches/re-attaches a device)."
echo "    Check status: systemctl status usbip-net-regen.path"
echo "                  journalctl -u usbip-net-regen.service"
echo "    Force a run now: sudo systemctl start usbip-net-regen.service"
