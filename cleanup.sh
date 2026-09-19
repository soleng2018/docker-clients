#!/usr/bin/env bash
# Unregisters THIS workshop folder from the shared usbip-net-regen bridge.
#
# By default this only removes this folder's own entry from the shared
# registry (/etc/usbip-net-regen/repos.txt) -- other registered workshop
# folders keep working, and it does NOT touch running VMs, their disks, or
# generated docker-compose.yml files in this folder either, so you can
# safely reinstall later.
#
#   --wipe-pods      also stop and remove every container this folder's
#                    generator produced (`docker compose down`, per pod
#                    directory listed in parameters.txt); VM storage/data
#                    directories are left on disk.
#   --wipe-data      implies --wipe-pods, and additionally deletes each
#                    pod's directory entirely (including VM disks) --
#                    destructive.
#   --purge-shared   also remove the shared usbip-net-regen systemd units
#                    and worker script entirely. Refuses if any other
#                    workshop folder is still registered, unless combined
#                    with --force.
#   --force          allow --purge-shared even if other folders are still
#                    registered (breaks the bridge for them).
#
# Usage: sudo bash cleanup.sh [--wipe-pods] [--wipe-data] [--purge-shared] [--force]
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

WIPE_PODS=false
WIPE_DATA=false
PURGE_SHARED=false
FORCE=false
for arg in "$@"; do
    case "$arg" in
        --wipe-pods) WIPE_PODS=true ;;
        --wipe-data) WIPE_PODS=true; WIPE_DATA=true ;;
        --purge-shared) PURGE_SHARED=true ;;
        --force) FORCE=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="/etc/usbip-net-regen/repos.txt"

if [ -f "$REGISTRY" ]; then
    echo "==> Unregistering $REPO_DIR from the shared bridge"
    grep -vxF "$REPO_DIR" "$REGISTRY" > "$REGISTRY.tmp" 2>/dev/null || true
    mv "$REGISTRY.tmp" "$REGISTRY"
fi

if [ "$WIPE_PODS" = "true" ] && [ -f "$REPO_DIR/parameters.txt" ]; then
    echo "==> Tearing down generated pods in $REPO_DIR (docker compose down)"
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

if [ "$PURGE_SHARED" = "true" ]; then
    remaining=0
    if [ -f "$REGISTRY" ]; then
        remaining=$(grep -cvE '^[[:space:]]*$' "$REGISTRY" 2>/dev/null || true)
    fi
    if [ "${remaining:-0}" -gt 0 ] && [ "$FORCE" != "true" ]; then
        echo "Refusing --purge-shared: ${remaining} other workshop folder(s) still registered:"
        sed 's/^/  - /' "$REGISTRY"
        echo "Re-run with --force to purge anyway (breaks the bridge for those folders)."
        exit 1
    fi
    echo "==> Purging the shared usbip-net-regen bridge"
    systemctl disable --now usbip-net-regen.path 2>/dev/null || true
    rm -f /usr/lib/systemd/system/usbip-net-regen.path /usr/lib/systemd/system/usbip-net-regen.service
    rm -f /usr/local/sbin/usbip-net-regen.sh
    rm -f "$REGISTRY"
    systemctl daemon-reload
fi

echo
echo "==> Done."
if [ "$WIPE_PODS" = "false" ]; then
    echo "    Pods/VM data in $REPO_DIR were left untouched."
fi
if [ "$PURGE_SHARED" = "false" ]; then
    echo "    Shared bridge left installed for other workshop folders (if any)."
fi
