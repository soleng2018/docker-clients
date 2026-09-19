#!/usr/bin/env bash
# Reacts to a USB/IP attach-state change: regenerates every pod's
# docker-compose.yml (via ../script) and reconciles it with `docker compose
# up -d`. Compose only recreates a container whose config actually
# changed, so this naturally limits the blast radius to whatever pod's
# hostbus/hostaddr actually moved -- everything else is a no-op.
#
# Triggered by usbip-net-regen.path watching
# /var/lib/usbip-net-client/attached.csv (written by usbip-net-toolkit's
# client only when its attach state changes). Safe to also run by hand.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="/run/lock/usbip-net-regen.lock"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "usbip-net-regen: another run is already in progress, skipping"
    exit 0
fi

cd "$REPO_DIR"

if [ ! -f parameters.txt ]; then
    echo "usbip-net-regen: no parameters.txt in $REPO_DIR, nothing to do"
    exit 0
fi

echo "usbip-net-regen: regenerating docker-compose files"
bash "$REPO_DIR/script"

while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^([^=]+)=(.+)$ ]]; then
        container_name=$(echo "${BASH_REMATCH[1]}" | xargs)
        pod_dir="$REPO_DIR/$container_name"
        if [ -f "$pod_dir/docker-compose.yml" ]; then
            echo "usbip-net-regen: reconciling $container_name"
            if ! (cd "$pod_dir" && docker compose up -d); then
                echo "usbip-net-regen: WARNING failed to reconcile $container_name" >&2
            fi
        fi
    fi
done < parameters.txt

echo "usbip-net-regen: done"
