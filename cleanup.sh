#!/usr/bin/env bash
# Uninstalls the boot reconcile service installed by install.sh.
#
#   --wipe-pods   also `docker compose down` every VM currently defined in
#                 parameters.txt (VM storage/data directories are left on disk)
#   --wipe-data   implies --wipe-pods, and additionally deletes each VM's
#                 folder entirely (including its disk) -- destructive
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
BASE_DIR="$(dirname "$REPO_DIR")"

echo "==> Disabling docker-clients-reconcile.service"
systemctl disable --now docker-clients-reconcile.service 2>/dev/null || true
rm -f /usr/lib/systemd/system/docker-clients-reconcile.service
systemctl daemon-reload

if [ "$WIPE_PODS" = "true" ] && [ -f "$REPO_DIR/parameters.txt" ]; then
    echo "==> Tearing down every VM in parameters.txt"
    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^([^=]+)=(.+)$ ]]; then
            key=$(echo "${BASH_REMATCH[1]}" | xargs)
            [[ "$key" == [[:upper:]]* && "$key" != *[![:upper:][:digit:]_]* ]] && continue
            [[ "$key" =~ ^([a-z0-9_-]+)/(.+)$ ]] || continue
            testbed="${BASH_REMATCH[1]}"
            vm="${BASH_REMATCH[2]}"
            pod_dir="$BASE_DIR/$testbed/$vm"
            docker_name="${testbed}-$(echo "$vm" | tr '/' '-')"
            if [ -f "$pod_dir/docker-compose.yml" ]; then
                echo "  - $key"
                (cd "$pod_dir" && docker compose -p "$docker_name" down) || true
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
[ "$WIPE_PODS" = "false" ] && echo "    VMs/data were left untouched (pass --wipe-pods or --wipe-data to tear them down)."
