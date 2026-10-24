#!/usr/bin/env bash
# Installs the systemd service that runs reconcile.sh once at every boot,
# fixing stale USB hostbus/hostaddr (which Linux reassigns on every reboot)
# for every testbed VM defined in parameters.txt. Idempotent -- safe to
# re-run.
#
# Usage: sudo bash install.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_USER="${SUDO_USER:-$(id -un)}"
RUN_GROUP="$(id -gn "$RUN_USER")"

if [ ! -f "$REPO_DIR/parameters.txt" ]; then
    echo "WARNING: $REPO_DIR/parameters.txt not found."
    echo "         Copy parameters.txt.example to parameters.txt and fill in your real testbeds first."
fi

echo "==> Installing docker-clients-reconcile.service (runs as $RUN_USER:$RUN_GROUP)"
sed -e "s#__REPO_DIR__#$REPO_DIR#g" \
    -e "s#__RUN_USER__#$RUN_USER#g" \
    -e "s#__RUN_GROUP__#$RUN_GROUP#g" \
    "$REPO_DIR/systemd/docker-clients-reconcile.service.template" > /usr/lib/systemd/system/docker-clients-reconcile.service

systemctl daemon-reload
systemctl enable docker-clients-reconcile.service

echo
echo "==> Done. $REPO_DIR/reconcile.sh will run once at every boot (after docker + network-online)."
echo "    Run it now instead of waiting for a reboot: sudo systemctl start docker-clients-reconcile.service"
echo "    Check status:                               systemctl status docker-clients-reconcile.service"
echo "    Check logs:                                 journalctl -u docker-clients-reconcile.service"
