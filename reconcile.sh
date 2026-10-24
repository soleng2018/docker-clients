#!/usr/bin/env bash
# Generates, starts, and prunes every testbed VM defined in this clone's
# parameters.txt -- the single entry point replacing the old per-clone
# `script` + `up.sh` pair.
#
# One clone of this repo (e.g. /home/nova/docker-clients) now describes
# every testbed. Testbed folders (nw3, nw4, ...) are created as SIBLINGS of
# this clone -- one directory up -- each holding one subfolder per VM
# (docker-compose.yml + VM storage/data). Nothing but parameters.txt, this
# script, and the few committed files below live inside the clone itself.
#
# Re-running is the normal way to use this, and is what fixes a host
# reboot's stale USB hostbus/hostaddr (see README): every VM's
# docker-compose.yml is regenerated from parameters.txt + whatever's
# currently visible in /sys/bus/usb/devices, then `docker compose up -d`
# only recreates a container whose config actually changed.
#
# A VM line removed from parameters.txt is torn down (`docker compose
# down`) and its folder is moved into .trash/ (NOT deleted outright) the
# very next time this runs -- including the boot-triggered run. Restore by
# moving it back out of .trash/ and re-adding its line.
#
# Usage: bash reconcile.sh [--dry-run]
#   --dry-run   generate + validate + report, but run no docker command and
#               move nothing to .trash/
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAMETERS_FILE="$SCRIPT_DIR/parameters.txt"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
MANIFEST_FILE="$SCRIPT_DIR/.managed-pods.txt"
TRASH_DIR="$SCRIPT_DIR/.trash"

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

if [ ! -f "$PARAMETERS_FILE" ]; then
    echo "Error: parameters.txt not found in $SCRIPT_DIR" >&2
    echo "       Copy parameters.txt.example to parameters.txt and fill in your real testbeds first." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# USB device resolution (MAC address -> current hostbus/hostaddr)
# ---------------------------------------------------------------------------
find_usb_device() {
    local mac_address=$1
    [ -z "$mac_address" ] && { echo ""; return; }
    local mac_lower
    mac_lower=$(echo "$mac_address" | tr '[:upper:]' '[:lower:]')

    local interface=""
    interface=$(ip link show 2>/dev/null | grep -iB1 "$mac_lower" | head -1 | awk -F': ' '{print $2}' | awk '{print $1}')
    if [ -z "$interface" ]; then
        interface=$(ifconfig 2>/dev/null | grep -iB1 "$mac_lower" | head -1 | awk '{print $1}' | tr -d ':')
    fi
    if [ -z "$interface" ]; then
        for iface in /sys/class/net/*; do
            if [ -f "$iface/address" ]; then
                local iface_mac
                iface_mac=$(cat "$iface/address" 2>/dev/null | tr '[:upper:]' '[:lower:]')
                if [ "$iface_mac" = "$mac_lower" ]; then
                    interface=$(basename "$iface")
                    break
                fi
            fi
        done
    fi

    local usb_device_dir=""
    if [ -n "$interface" ]; then
        local device_path
        device_path=$(readlink -f "/sys/class/net/$interface/device" 2>/dev/null)
        if [ -n "$device_path" ] && [ -d "$device_path" ]; then
            local current_dir="$device_path"
            while [ -n "$current_dir" ] && [ "$current_dir" != "/" ]; do
                if [ -f "$current_dir/busnum" ] && [ -f "$current_dir/devnum" ]; then
                    usb_device_dir="$current_dir"
                    break
                fi
                current_dir=$(dirname "$current_dir")
            done
        fi
    fi

    # Fallback: device already bound to something else (e.g. mid-handoff) --
    # walk every USB device in sysfs looking for a net child with this MAC.
    if [ -z "$usb_device_dir" ]; then
        for usb_dev_link in /sys/bus/usb/devices/*; do
            local usb_dev
            usb_dev=$(readlink -f "$usb_dev_link" 2>/dev/null)
            [ -z "$usb_dev" ] || [ ! -d "$usb_dev" ] && continue
            for net_dir in "$usb_dev"/*/net/* "$usb_dev"/*/*/net/*; do
                if [ -d "$net_dir" ] && [ -f "$net_dir/address" ]; then
                    local net_mac
                    net_mac=$(cat "$net_dir/address" 2>/dev/null | tr '[:upper:]' '[:lower:]')
                    if [ "$net_mac" = "$mac_lower" ]; then
                        local current_dir="$net_dir"
                        while [ -n "$current_dir" ] && [ "$current_dir" != "/" ]; do
                            if [ -f "$current_dir/busnum" ] && [ -f "$current_dir/devnum" ]; then
                                usb_device_dir="$current_dir"
                                break 2
                            fi
                            current_dir=$(dirname "$current_dir")
                        done
                    fi
                fi
            done
        done
    fi

    if [ -z "$usb_device_dir" ] || [ ! -f "$usb_device_dir/busnum" ] || [ ! -f "$usb_device_dir/devnum" ]; then
        echo ""
        return
    fi
    local bus device
    bus=$(cat "$usb_device_dir/busnum" 2>/dev/null | xargs)
    device=$(cat "$usb_device_dir/devnum" 2>/dev/null | xargs)
    if [ -n "$bus" ] && [ -n "$device" ]; then
        echo "hostbus=$bus,hostaddr=$device"
    else
        echo ""
    fi
}

check_traefik_installed() {
    docker ps --format '{{.Names}}' | grep -qi traefik && return 0
    docker ps -a --format '{{.Names}}' | grep -qi traefik && return 0
    command -v traefik &> /dev/null && return 0
    return 1
}

# ---------------------------------------------------------------------------
# Global settings (UPPER_CASE = "value" lines in parameters.txt)
# ---------------------------------------------------------------------------
TRAEFIK_NETWORK="traefik"
TRAEFIK_SUBNET=""
CERT_RESOLVER="letsencrypt"
AUTH_MIDDLEWARE="authentik@file"
ENTRYPOINT="websecure"
REQUIRE_TRAEFIK="false"

is_global_key() { [[ "$1" == [[:upper:]]* && "$1" != *[![:upper:][:digit:]_]* ]]; }

apply_global() {
    local key=$1 value=$2
    case "$key" in
        TRAEFIK_NETWORK|TRAEFIK_SUBNET|CERT_RESOLVER|AUTH_MIDDLEWARE|ENTRYPOINT|REQUIRE_TRAEFIK)
            printf -v "$key" '%s' "$value" ;;
        *) echo "WARNING: unknown setting '$key' in parameters.txt (ignored)" >&2 ;;
    esac
}

get_option() {
    local key=$1 tok
    shift
    for tok in "$@"; do
        tok=$(echo "$tok" | tr -d '"' | xargs)
        if [[ "$tok" == "$key="* ]]; then
            echo "${tok#"$key="}"
            return
        fi
    done
}

ensure_traefik_network() {
    if ! docker network inspect "$TRAEFIK_NETWORK" &> /dev/null; then
        echo "Creating $TRAEFIK_NETWORK network..."
        if [ -n "$TRAEFIK_SUBNET" ]; then
            docker network create --subnet "$TRAEFIK_SUBNET" "$TRAEFIK_NETWORK"
        else
            docker network create "$TRAEFIK_NETWORK"
        fi
    elif [ -n "$TRAEFIK_SUBNET" ]; then
        local actual
        actual=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$TRAEFIK_NETWORK" 2>/dev/null)
        if [[ " $actual " != *" $TRAEFIK_SUBNET "* ]]; then
            echo "WARNING: network '$TRAEFIK_NETWORK' already exists with subnet(s) [${actual% }], not the configured TRAEFIK_SUBNET $TRAEFIK_SUBNET." >&2
        fi
    fi
}

# ---------------------------------------------------------------------------
# docker-compose.yml generation
# ---------------------------------------------------------------------------
generate_docker_compose() {
    local docker_name=$1 os_type=$2 version=$3 ram_size=$4 cpu_cores=$5
    local username=$6 password=$7 port1=$8 port2=$9 url=${10} mac1=${11} mac2=${12}
    local traefik_installed=${13} static_ip=${14}

    local project_name
    project_name=$(echo "$docker_name" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_\n-' '-')

    local remote_port="3389"
    [ "$os_type" = "macos" ] && remote_port="5900"

    local usb1 usb2
    usb1=$(find_usb_device "$mac1")
    usb2=$(find_usb_device "$mac2")

    local arguments="" usb_device_line=""
    if [ -n "$mac1" ]; then
        if [ -n "$usb1" ]; then
            arguments="-device usb-host,$usb1"
            [ -n "$mac2" ] && [ -n "$usb2" ] && arguments="$arguments -device usb-host,$usb2"
        else
            if [ -n "$mac2" ]; then
                arguments="-device usb-host,hostbus=X,hostaddr=Y -device usb-host,hostbus=X,hostaddr=Y # TODO: Configure USB devices for MAC $mac1 and $mac2."
            else
                arguments="-device usb-host,hostbus=X,hostaddr=Y # TODO: Configure USB device for MAC $mac1."
            fi
        fi
        usb_device_line="      - /dev/bus/usb # This line is only needed when passing USB"
    fi

    cat <<EOF
name: ${project_name}
services:
  ${os_type}:
    image: dockurr/${os_type}
    container_name: ${docker_name}
    environment:
      VERSION: "${version}"
      RAM_SIZE: "${ram_size}"
      CPU_CORES: "${cpu_cores}"
EOF
    if [ "$os_type" = "windows" ]; then
        cat <<EOF
      USERNAME: "${username}"
      PASSWORD: "${password}"
EOF
    fi
    cat <<EOF
      #DHCP: "Y" # If using Static IP remove this line
EOF
    [ -n "$arguments" ] && echo "      ARGUMENTS: \"${arguments}\" # Passing USB Wireless NIC. Remove this line if no WiFi. Use lsusb to get vendorid and productid"
    cat <<EOF
    devices:
      - /dev/kvm
      - /dev/net/tun
      #- /dev/vhost-net # Only needed if DHCP="Y". For static remove this line
EOF
    [ -n "$usb_device_line" ] && echo "$usb_device_line"
    cat <<EOF
    #device_cgroup_rules: # Uncomment along with the rule below if DHCP="Y"
      #- 'c *:* rwm' # Only needed if DHCP="Y". For static remove this line
    cap_add:
      - NET_ADMIN
    ports:
      - ${port1}:8006
      - ${port2}:${remote_port}/tcp
      - ${port2}:${remote_port}/udp
    volumes:
      - ./${os_type}:/storage
EOF
    [ "$os_type" = "windows" ] && echo "      - ./data:/data"
    cat <<EOF
    restart: always
    stop_grace_period: 2m
EOF

    if [ "$traefik_installed" = "true" ]; then
        cat <<EOF
    labels:
      - traefik.enable=true
      # Main web interface route (with Authentik)
      - traefik.http.routers.${docker_name}-web.rule=Host(\`${url}\`) && !PathPrefix(\`/websockify\`)
      - traefik.http.routers.${docker_name}-web.entrypoints=${ENTRYPOINT}
      - traefik.http.routers.${docker_name}-web.tls=true
      - traefik.http.routers.${docker_name}-web.tls.certresolver=${CERT_RESOLVER}
      - traefik.http.routers.${docker_name}-web.service=${docker_name}-svc
      - traefik.http.routers.${docker_name}-web.middlewares=${AUTH_MIDDLEWARE}
      # WebSocket route (without Authentik)
      - traefik.http.routers.${docker_name}-ws.rule=Host(\`${url}\`) && PathPrefix(\`/websockify\`)
      - traefik.http.routers.${docker_name}-ws.entrypoints=${ENTRYPOINT}
      - traefik.http.routers.${docker_name}-ws.tls=true
      - traefik.http.routers.${docker_name}-ws.tls.certresolver=${CERT_RESOLVER}
      - traefik.http.routers.${docker_name}-ws.service=${docker_name}-svc
      - traefik.http.routers.${docker_name}-ws.middlewares=${docker_name}-ws-headers
      # Service definition
      - traefik.http.services.${docker_name}-svc.loadBalancer.server.port=8006
      - traefik.http.services.${docker_name}-svc.loadBalancer.server.scheme=http
      # WebSocket headers middleware
      - traefik.http.middlewares.${docker_name}-ws-headers.headers.customrequestheaders.Connection=upgrade
      - traefik.http.middlewares.${docker_name}-ws-headers.headers.customrequestheaders.Upgrade=websocket
      - traefik.http.middlewares.${docker_name}-ws-headers.headers.customrequestheaders.Sec-WebSocket-Version=13
EOF
        if [ -n "$static_ip" ]; then
            cat <<EOF
    networks:
      ${TRAEFIK_NETWORK}:
        ipv4_address: ${static_ip}
EOF
        else
            cat <<EOF
    networks:
      - ${TRAEFIK_NETWORK}
EOF
        fi
        cat <<EOF

networks:
  ${TRAEFIK_NETWORK}:
    external: true
EOF
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Load global settings first
# ---------------------------------------------------------------------------
while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^([^=]+)=(.+)$ ]]; then
        key=$(echo "${BASH_REMATCH[1]}" | xargs)
        is_global_key "$key" && apply_global "$key" "$(echo "${BASH_REMATCH[2]}" | tr -d '"' | xargs)"
    fi
done < "$PARAMETERS_FILE"

TRAEFIK_INSTALLED="false"
if check_traefik_installed; then
    TRAEFIK_INSTALLED="true"
    echo "Traefik is installed. Including traefik labels and network."
    ensure_traefik_network
elif [ "$REQUIRE_TRAEFIK" = "true" ]; then
    echo "ERROR: REQUIRE_TRAEFIK is true but no Traefik was found." >&2
    exit 1
else
    echo "WARNING: Traefik is not installed. Generated VMs will have NO web routes."
fi

# ---------------------------------------------------------------------------
# Full validation pass -- catches typos before anything is touched.
# ---------------------------------------------------------------------------
declare -A used_ports used_urls used_ips seen_keys
validation_errors=0
lineno=0

echo "Validating parameters.txt..."

while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^([^=]+)=(.+)$ ]] || { echo "ERROR line $lineno: cannot parse '$line'"; validation_errors=$((validation_errors+1)); continue; }

    key=$(echo "${BASH_REMATCH[1]}" | xargs)
    is_global_key "$key" && continue
    # Save the params capture now -- any further regex match on a plain
    # variable (not "$line") below would overwrite BASH_REMATCH otherwise.
    params=$(echo "${BASH_REMATCH[2]}" | xargs)

    if [[ ! "$key" =~ ^[a-z0-9_-]+/[a-z0-9_-]+$ ]]; then
        echo "ERROR line $lineno: '$key' must be <testbed>/<vm> (e.g. nw3/win1) -- missing or malformed testbed prefix."
        validation_errors=$((validation_errors+1))
        continue
    fi
    if [[ -n "${seen_keys[$key]:-}" ]]; then
        echo "ERROR line $lineno: '$key' is defined more than once."
        validation_errors=$((validation_errors+1))
        continue
    fi
    seen_keys[$key]=1

    IFS=',' read -ra PARAMS <<< "$params"

    if [ "${#PARAMS[@]}" -lt 9 ]; then
        echo "ERROR line $lineno: '$key' has too few fields (expected at least os,version,ram,cpu,username,password,web_port,remote_port,url; mac1 is optional)."
        validation_errors=$((validation_errors+1))
        continue
    fi

    os_type=$(echo "${PARAMS[0]}" | tr -d '"' | xargs)
    if [ "$os_type" != "windows" ] && [ "$os_type" != "macos" ]; then
        echo "ERROR line $lineno: '$key' has os '$os_type' (expected 'windows' or 'macos')."
        validation_errors=$((validation_errors+1))
    fi

    host_port1=$(echo "${PARAMS[6]}" | tr -d '"' | xargs)
    host_port2=$(echo "${PARAMS[7]}" | tr -d '"' | xargs)
    for p in "$host_port1" "$host_port2"; do
        if [[ ! "$p" =~ ^[0-9]+$ ]]; then
            echo "ERROR line $lineno: '$key' has a non-numeric port '$p'."
            validation_errors=$((validation_errors+1))
        elif [[ -n "${used_ports[$p]:-}" ]]; then
            echo "ERROR line $lineno: port $p is already used by '${used_ports[$p]}'; '$key' cannot reuse it."
            validation_errors=$((validation_errors+1))
        else
            used_ports[$p]="$key"
        fi
    done

    url=$(echo "${PARAMS[8]}" | tr -d '"' | xargs)
    if [[ ! "$url" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
        echo "ERROR line $lineno: '$key' has an invalid url '$url' (expected a hostname like nw3-win1.example.com)."
        validation_errors=$((validation_errors+1))
    elif [[ -n "${used_urls[$url]:-}" ]]; then
        echo "ERROR line $lineno: url '$url' is already used by '${used_urls[$url]}'; '$key' cannot reuse it."
        validation_errors=$((validation_errors+1))
    else
        used_urls[$url]="$key"
    fi

    mac_count=0
    for ((i = 9; i < ${#PARAMS[@]}; i++)); do
        tok=$(echo "${PARAMS[$i]}" | tr -d '"' | xargs)
        [ -z "$tok" ] && continue
        if [[ "$tok" == ip=* ]]; then
            vm_ip="${tok#ip=}"
            if [[ ! "$vm_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                echo "ERROR line $lineno: '$key' has an invalid ip= value '$vm_ip'."
                validation_errors=$((validation_errors+1))
            elif [[ -n "${used_ips[$vm_ip]:-}" ]]; then
                echo "ERROR line $lineno: ip $vm_ip is already used by '${used_ips[$vm_ip]}'; '$key' cannot reuse it."
                validation_errors=$((validation_errors+1))
            else
                used_ips[$vm_ip]="$key"
            fi
        elif [[ "$tok" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
            mac_count=$((mac_count+1))
            if [ "$mac_count" -gt 2 ]; then
                echo "ERROR line $lineno: '$key' lists more than two MAC addresses."
                validation_errors=$((validation_errors+1))
            fi
        else
            echo "ERROR line $lineno: '$key' has an unrecognized token '$tok' (expected a MAC address or ip=<address>)."
            validation_errors=$((validation_errors+1))
        fi
    done
done < "$PARAMETERS_FILE"

if [ $validation_errors -gt 0 ]; then
    echo ""
    echo "Validation failed with $validation_errors error(s). Fix parameters.txt and re-run -- nothing was generated or changed."
    exit 1
fi
echo "Validation passed."
echo ""

# ---------------------------------------------------------------------------
# Generate + start every VM
# ---------------------------------------------------------------------------
generated=()
skipped=()
defined_keys=()
declare -A pod_dir_of docker_name_of

while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^([^=]+)=(.+)$ ]] || continue
    key=$(echo "${BASH_REMATCH[1]}" | xargs)
    is_global_key "$key" && continue

    defined_keys+=("$key")
    testbed="${key%%/*}"
    vm="${key#*/}"

    params=$(echo "${BASH_REMATCH[2]}" | xargs)
    IFS=',' read -ra PARAMS <<< "$params"

    os_type=$(echo "${PARAMS[0]}" | tr -d '"' | xargs)
    version=$(echo "${PARAMS[1]}" | tr -d '"' | xargs)
    ram_size=$(echo "${PARAMS[2]}" | tr -d '"' | xargs)
    cpu_cores=$(echo "${PARAMS[3]}" | tr -d '"' | xargs)
    username=$(echo "${PARAMS[4]}" | tr -d '"' | xargs)
    password=$(echo "${PARAMS[5]}" | tr -d '"' | xargs)
    port1=$(echo "${PARAMS[6]}" | tr -d '"' | xargs)
    port2=$(echo "${PARAMS[7]}" | tr -d '"' | xargs)
    url=$(echo "${PARAMS[8]}" | tr -d '"' | xargs)

    mac1="" mac2="" static_ip=""
    for ((i = 9; i < ${#PARAMS[@]}; i++)); do
        tok=$(echo "${PARAMS[$i]}" | tr -d '"' | xargs)
        [ -z "$tok" ] && continue
        if [[ "$tok" == ip=* ]]; then
            static_ip="${tok#ip=}"
        elif [ -z "$mac1" ]; then
            mac1="$tok"
        else
            mac2="$tok"
        fi
    done

    usb_devices_found=true
    missing_macs=""
    if [ -n "$mac1" ] && [ -z "$(find_usb_device "$mac1")" ]; then
        usb_devices_found=false; missing_macs="$mac1"
    fi
    if [ -n "$mac2" ] && [ -z "$(find_usb_device "$mac2")" ]; then
        usb_devices_found=false
        missing_macs="${missing_macs:+$missing_macs, }$mac2"
    fi
    if [ "$usb_devices_found" = "false" ]; then
        echo "WARNING: Skipping '$key' - USB device(s) not found for MAC address(es): $missing_macs"
        skipped+=("$key (USB device not found: $missing_macs)")
        continue
    fi

    pod_dir="$BASE_DIR/$testbed/$vm"
    docker_name="${testbed}-$(echo "$vm" | tr '/' '-')"
    pod_dir_of[$key]="$pod_dir"
    docker_name_of[$key]="$docker_name"

    if [ "$DRY_RUN" = "true" ]; then
        echo "DRY RUN: would generate $pod_dir/docker-compose.yml ($docker_name)"
        generated+=("$key")
        continue
    fi

    mkdir -p "$pod_dir"
    generate_docker_compose "$docker_name" "$os_type" "$version" "$ram_size" "$cpu_cores" \
        "$username" "$password" "$port1" "$port2" "$url" "$mac1" "$mac2" "$TRAEFIK_INSTALLED" \
        "$static_ip" > "$pod_dir/docker-compose.yml"
    echo "Generated $pod_dir/docker-compose.yml"
    generated+=("$key")
done < "$PARAMETERS_FILE"

echo ""
echo "Starting VMs..."
started=0
failed_starts=()
for key in "${generated[@]}"; do
    [ "$DRY_RUN" = "true" ] && continue
    pod_dir="${pod_dir_of[$key]}"
    docker_name="${docker_name_of[$key]}"
    [ -z "$pod_dir" ] && continue
    echo "==> $docker_name"
    if (cd "$pod_dir" && docker compose -p "$docker_name" up -d); then
        started=$((started+1))
    else
        failed_starts+=("$key")
    fi
done

# ---------------------------------------------------------------------------
# Prune: any key this tool previously managed but that's no longer in
# parameters.txt gets torn down and moved to .trash/ (not deleted outright).
# ---------------------------------------------------------------------------
pruned=()
if [ -f "$MANIFEST_FILE" ]; then
    while IFS= read -r old_key || [ -n "$old_key" ]; do
        [ -z "$old_key" ] && continue
        still_defined=false
        for k in "${defined_keys[@]}"; do
            [ "$k" = "$old_key" ] && { still_defined=true; break; }
        done
        if [ "$still_defined" = "false" ]; then
            testbed="${old_key%%/*}"
            vm="${old_key#*/}"
            pod_dir="$BASE_DIR/$testbed/$vm"
            docker_name="${testbed}-$(echo "$vm" | tr '/' '-')"
            if [ "$DRY_RUN" = "true" ]; then
                echo "DRY RUN: would remove '$old_key' ($pod_dir) -- line no longer in parameters.txt"
            elif [ -d "$pod_dir" ]; then
                echo "Removing '$old_key': no longer in parameters.txt"
                (cd "$pod_dir" && docker compose -p "$docker_name" down) || true
                mkdir -p "$TRASH_DIR"
                dest="$TRASH_DIR/$(echo "$old_key" | tr '/' '-')-$(date +%Y%m%d%H%M%S)"
                mv "$pod_dir" "$dest"
                echo "  moved to $dest (not deleted -- restore by moving it back and re-adding the line)"
                # Clean up an empty testbed folder left behind.
                rmdir --ignore-fail-on-non-empty "$BASE_DIR/$testbed" 2>/dev/null || true
            fi
            pruned+=("$old_key")
        fi
    done < "$MANIFEST_FILE"
fi

if [ "$DRY_RUN" != "true" ]; then
    printf '%s\n' "${defined_keys[@]}" > "$MANIFEST_FILE"
fi

echo ""
echo "Done. Generated ${#generated[@]}, skipped ${#skipped[@]}, pruned ${#pruned[@]}, started $started."
[ ${#skipped[@]} -gt 0 ] && { echo "Skipped (existing docker-compose.yml, if any, left as-is):"; for s in "${skipped[@]}"; do echo "  - $s"; done; }
[ ${#pruned[@]} -gt 0 ] && { echo "Pruned (moved to .trash/):"; for p in "${pruned[@]}"; do echo "  - $p"; done; }
if [ ${#failed_starts[@]} -gt 0 ]; then
    echo "FAILED to start:"
    for f in "${failed_starts[@]}"; do echo "  - $f"; done
    exit 1
fi
