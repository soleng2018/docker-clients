#!/usr/bin/env bash
# Generate docker-compose.yml files and start every VM in THIS workshop clone,
# then report which VMs are actually running -- including any that were skipped
# because their USB dongle wasn't found (nothing is started for those).
#
# Safe to re-run: `docker compose up -d` only recreates a VM whose generated
# config really changed.
#
# Usage: bash up.sh [--dry-run] [--no-generate]
#   --dry-run      generate (unless --no-generate) and report, but start nothing
#   --no-generate  don't run ./script first; use the compose files already on disk
#
# Rebuild everything on a fresh host (after restoring each parameters.txt):
#   for d in /home/nova/nw*/; do bash "$d/up.sh"; done
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSHOP="$(basename "$DIR")"
DRY_RUN=false
GENERATE=true
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --no-generate) GENERATE=false ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

if [ ! -f "$DIR/parameters.txt" ]; then
    echo "Error: $DIR/parameters.txt not found (restore this workshop's real parameters.txt first)." >&2
    exit 1
fi

if [ "$GENERATE" = "true" ]; then
    echo "==> Generating compose files for $WORKSHOP"
    (cd "$DIR" && bash script) || { echo "Generation failed; nothing started." >&2; exit 1; }
    echo
fi

declare -a names=() results=()
failed=0

while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^([^=]+)=(.+)$ ]] || continue
    vm=$(echo "${BASH_REMATCH[1]}" | xargs)
    # UPPER_CASE keys are global settings, not VMs
    if [[ "$vm" == [[:upper:]]* && "$vm" != *[![:upper:][:digit:]_]* ]]; then continue; fi

    pod_dir="$DIR/$vm"
    docker_name="${WORKSHOP}-${vm//\//-}"
    names+=("$vm")

    if [ ! -f "$pod_dir/docker-compose.yml" ]; then
        results+=("NOT STARTED  no docker-compose.yml (USB dongle not found?)")
        failed=$((failed + 1))
        continue
    fi

    # Compose files from newer generators carry their own `name:`; for older
    # ones pin the project explicitly so same-named VMs in other workshops
    # (win1, win2, ...) can never be replaced by mistake.
    proj=()
    grep -q '^name:' "$pod_dir/docker-compose.yml" || proj=(-p "$docker_name")

    if [ "$DRY_RUN" = "true" ]; then
        results+=("DRY RUN      would run: docker compose ${proj[*]:-} up -d")
        continue
    fi

    echo "==> Starting $docker_name"
    if ! (cd "$pod_dir" && docker compose "${proj[@]}" up -d); then
        results+=("FAILED       docker compose up -d returned an error")
        failed=$((failed + 1))
        continue
    fi
    state=$(docker inspect -f '{{.State.Status}}' "$docker_name" 2>/dev/null || echo "missing")
    if [ "$state" = "running" ]; then
        results+=("running")
    else
        results+=("NOT RUNNING  container state: $state")
        failed=$((failed + 1))
    fi
done < "$DIR/parameters.txt"

echo
echo "==> $WORKSHOP summary"
for i in "${!names[@]}"; do
    printf '  %-28s %s\n' "${WORKSHOP}-${names[$i]//\//-}" "${results[$i]}"
done

if [ "$failed" -gt 0 ]; then
    echo
    echo "$failed VM(s) are not running -- see above." >&2
    exit 1
fi
