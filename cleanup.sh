#!/usr/bin/env bash
# Tears down the usbip-net-regen bridge installed by install.sh.
#
# By default this only removes the regen bridge itself (systemd units) --
# it does NOT touch running VMs, their disks, or generated
# docker-compose.yml files, so you can safely reinstall the bridge without
# disrupting a live lab.
#
#   --wipe-pods   also stop and remove every container this repo's
#                 generator produced (`docker compose down`, per pod
#                 directory listed in parameters.txt); VM storage/data
#                 directories are left on disk.
#   --wipe-data   implies --wipe-pods, and additionally deletes each pod's
#                 directory entirely (including VM disks) -- destructive.
#
# Usage: sudo bash cleanup.sh [--wipe-pods] [--wipe-data]
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

WIPE_PODS=false
WIPE_DATA=false
for arg in "$@"; do
    case "$arg" in
        --wipe-pods) WIPE_PODS=true ;;
        --wipe-data) WIPE_PODS=true; WIPE_DATA=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Disabling and removing usbip-net-regen systemd units"
systemctl disable --now usbip-net-regen.path 2>/dev/null || true
rm -f /usr/lib/systemd/system/usbip-net-regen.path /usr/lib/systemd/system/usbip-net-regen.service
systemctl daemon-reload

if [ "$WIPE_PODS" = "true" ] && [ -f "$REPO_DIR/parameters.txt" ]; then
    echo "==> Tearing down generated pods (docker compose down)"
    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^([^=]+)=(.+)$ ]]; then
            container_name=$(echo "${BASH_REMATCH[1]}" | xargs)
            pod_dir="$REPO_DIR/$container_name"
            if [ -f "$pod_dir/docker-compose.yml" ]; then
                echo "  - $container_name"
                (cd "$pod_dir" && docker compose down) || true
                if [ "$WIPE_DATA" = "true" ]; then
                    rm -rf "$pod_dir"
                    echo "    (removed $pod_dir, including VM storage/data)"
                else
                    rm -f "$pod_dir/docker-compose.yml"
                fi
            fi
        fi
    done < "$REPO_DIR/parameters.txt"
fi

echo
echo "==> Done."
if [ "$WIPE_PODS" = "false" ]; then
    echo "    Pods/VM data were left untouched. Re-run with --wipe-pods (and"
    echo "    optionally --wipe-data) to remove them too."
fi
