#!/usr/bin/env bash
# Shared regen worker, installed once system-wide regardless of how many
# workshop clones exist (e.g. /home/nova/nw1, nw2, nw3, ...). Each clone's
# install.sh registers its own directory here; this script reacts to a
# single USB/IP attach-state change by regenerating + reconciling every
# registered clone in turn.
#
# For each registered directory: run its own ./script (regenerates every
# pod's docker-compose.yml; a pod is left untouched if any of its MACs
# isn't currently resolvable), then `docker compose up -d` per pod
# directory it produced. Compose only recreates a container whose config
# actually differs, so this naturally limits the blast radius to whatever
# pod's device mapping actually moved.
#
# Triggered by usbip-net-regen.path watching
# /var/lib/usbip-net-client/attached.csv. Safe to also run by hand.
#
# NOTE: usbip-net-attach.sh (usbip-net-toolkit's client) rewrites that CSV
# unconditionally on every ~30s reconciliation cycle, whether or not
# anything actually changed -- confirmed by reading its source (`} >
# "$DOC_CSV"` with no change-check). So PathModified= alone fires every
# cycle, not just on real attach changes. Gate on a content hash here
# instead, so a no-op cycle exits immediately without regenerating/
# reconciling anything.
set -euo pipefail

REGISTRY="/etc/usbip-net-regen/repos.txt"
LOCK_FILE="/run/lock/usbip-net-regen.lock"
STATE_DIR="/var/lib/usbip-net-regen"
LAST_HASH_FILE="$STATE_DIR/last-attached-hash"
ATTACHED_CSV="/var/lib/usbip-net-client/attached.csv"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "usbip-net-regen: another run is already in progress, skipping"
    exit 0
fi

mkdir -p "$STATE_DIR"
if [ -f "$ATTACHED_CSV" ]; then
    current_hash=$(sha256sum "$ATTACHED_CSV" | awk '{print $1}')
    last_hash=$(cat "$LAST_HASH_FILE" 2>/dev/null || true)
    if [ "$current_hash" = "$last_hash" ]; then
        echo "usbip-net-regen: attach state unchanged, nothing to do"
        exit 0
    fi
    echo "$current_hash" > "$LAST_HASH_FILE"
fi

if [ ! -f "$REGISTRY" ]; then
    echo "usbip-net-regen: no registry at $REGISTRY, nothing to do"
    exit 0
fi

while IFS= read -r repo_dir || [ -n "$repo_dir" ]; do
    [[ -z "$repo_dir" || "$repo_dir" =~ ^[[:space:]]*# ]] && continue

    if [ ! -d "$repo_dir" ]; then
        echo "usbip-net-regen: WARNING registered folder '$repo_dir' no longer exists, skipping" >&2
        continue
    fi
    if [ ! -f "$repo_dir/parameters.txt" ] || [ ! -f "$repo_dir/script" ]; then
        echo "usbip-net-regen: WARNING '$repo_dir' has no parameters.txt/script, skipping" >&2
        continue
    fi

    echo "usbip-net-regen: regenerating $repo_dir"
    (cd "$repo_dir" && bash script)

    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^([^=]+)=(.+)$ ]]; then
            container_name=$(echo "${BASH_REMATCH[1]}" | xargs)
            pod_dir="$repo_dir/$container_name"
            if [ -f "$pod_dir/docker-compose.yml" ]; then
                echo "usbip-net-regen: reconciling $repo_dir/$container_name"
                if ! (cd "$pod_dir" && docker compose up -d); then
                    echo "usbip-net-regen: WARNING failed to reconcile $pod_dir" >&2
                fi
            fi
        fi
    done < "$repo_dir/parameters.txt"
done < "$REGISTRY"

echo "usbip-net-regen: done"
