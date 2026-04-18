#!/bin/bash
# start.sh — swap a Proxmox VM config profile into /etc/pve/qemu-server and start the VM.
# See README.md for workflow and profile conventions.

set -u

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
VMCONFIGS_DIR="${VMCONFIGS_DIR:-${SCRIPT_DIR}/vmconfigs}"
SETTINGS_FILE="${VMCONFIGS_DIR}/settings"

if [[ ! -f "$SETTINGS_FILE" ]]; then
    cat >&2 <<EOF
Error: settings file not found at:
  $SETTINGS_FILE

Copy the template and edit it:
  cp ${VMCONFIGS_DIR}/settings.example ${SETTINGS_FILE}
  \$EDITOR $SETTINGS_FILE
EOF
    exit 1
fi

source "$SETTINGS_FILE"

# Number of per-VM backups to keep in $BACKUP_DIR. Older ones are pruned
# after each successful backup. Override via settings or env var.
BACKUP_KEEP="${BACKUP_KEEP:-10}"

# Optional USB hotplug helper (proxmox-usb-hotplug) — only needed by the 'auto' profile.
USB_HELPER="${USB_HELPER:-/usr/local/bin/usb-mapping-helper.sh}"
[[ -f "$USB_HELPER" ]] && source "$USB_HELPER"

VALID_PROFILES=(full minimal testing auto default)

is_valid_profile() {
    local p=$1
    local valid
    for valid in "${VALID_PROFILES[@]}"; do
        [[ "$p" == "$valid" ]] && return 0
    done
    return 1
}

if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    cat <<EOF
Usage: ./start.sh [VMID] [PROFILE]
       ./start.sh --set-default-vm VMID         (or -sdv)
       ./start.sh --set-default-profile PROFILE (or -sdp)

Arguments:
  VMID     VM ID to start (default: ${DEFAULT:-unset})
  PROFILE  Configuration profile (default: ${DEFAULT_PROFILE:-unset})

Profiles:
  full     Load {VMID}_full.conf
  minimal  Load {VMID}_minimal.conf
  testing  Load {VMID}_testing.conf
  auto     Load {VMID}_auto.conf and add currently connected USB mappings
           (requires proxmox-usb-hotplug installed)
  default  Use whatever is in /etc/pve/qemu-server/{VMID}.conf (no load)

Examples:
  ./start.sh                  Start default VM with default profile
  ./start.sh 110              Start VM 110 with default profile
  ./start.sh 110 minimal      Start VM 110 with minimal config
  ./start.sh 110 auto         Start VM 110 with auto config + USB detection

Settings management (writes to $SETTINGS_FILE):
  ./start.sh --set-default-vm 110
  ./start.sh --set-default-profile minimal

Available VMs:
EOF
    for dir in "${VMCONFIGS_DIR}"/*/; do
        if [[ -d "$dir" ]]; then
            vmid=$(basename "$dir")
            [[ "$vmid" == "backups" ]] && continue
            echo "  ${vmid}:"
            ls -1 "${dir}"/*.conf 2>/dev/null | xargs -n1 basename | sed 's/^/    /'
        fi
    done
    exit 0
fi

if [[ "${1:-}" == "--set-default-vm" ]] || [[ "${1:-}" == "-sdv" ]]; then
    NEW_DEFAULT="${2:-}"
    if [[ -z "$NEW_DEFAULT" ]]; then
        echo "Error: missing VMID" >&2
        echo "Usage: ./start.sh --set-default-vm VMID" >&2
        exit 1
    fi
    if [[ ! -d "${VMCONFIGS_DIR}/${NEW_DEFAULT}" ]]; then
        echo "Error: VM ${NEW_DEFAULT} not found in ${VMCONFIGS_DIR}" >&2
        exit 1
    fi
    sed -i "s/^DEFAULT=.*/DEFAULT=${NEW_DEFAULT}/" "${SETTINGS_FILE}"
    echo "Default VM set to: ${NEW_DEFAULT}"
    exit 0
fi

if [[ "${1:-}" == "--set-default-profile" ]] || [[ "${1:-}" == "-sdp" ]]; then
    NEW_PROFILE="${2:-}"
    if [[ -z "$NEW_PROFILE" ]]; then
        echo "Error: missing PROFILE" >&2
        echo "Usage: ./start.sh --set-default-profile PROFILE" >&2
        echo "Valid profiles: ${VALID_PROFILES[*]}" >&2
        exit 1
    fi
    if ! is_valid_profile "$NEW_PROFILE"; then
        echo "Error: invalid profile '${NEW_PROFILE}'" >&2
        echo "Valid profiles: ${VALID_PROFILES[*]}" >&2
        exit 1
    fi
    sed -i "s/^DEFAULT_PROFILE=.*/DEFAULT_PROFILE=${NEW_PROFILE}/" "${SETTINGS_FILE}"
    echo "Default profile set to: ${NEW_PROFILE}"
    exit 0
fi

VMID="${1:-${DEFAULT:-}}"
PROFILE="${2:-${DEFAULT_PROFILE:-}}"

if [[ -z "$VMID" ]]; then
    echo "Error: no VMID specified and no DEFAULT set in ${SETTINGS_FILE}" >&2
    exit 1
fi
if [[ -z "$PROFILE" ]]; then
    echo "Error: no PROFILE specified and no DEFAULT_PROFILE set in ${SETTINGS_FILE}" >&2
    exit 1
fi
if ! is_valid_profile "$PROFILE"; then
    echo "Error: invalid profile '${PROFILE}'" >&2
    echo "Valid profiles: ${VALID_PROFILES[*]}" >&2
    exit 1
fi

VM_CONFIG_DIR="${VMCONFIGS_DIR}/${VMID}"
PVE_CONFIG="/etc/pve/qemu-server/${VMID}.conf"
BACKUP_DIR="${VMCONFIGS_DIR}/backups"
BACKUP_FILE="${BACKUP_DIR}/${VMID}_$(date +%Y%m%d_%H%M%S).conf"

if [[ -f "$PVE_CONFIG" ]]; then
    mkdir -p "$BACKUP_DIR"
    cp "$PVE_CONFIG" "$BACKUP_FILE"
    echo "Backed up current config to: $BACKUP_FILE"

    # Prune older backups for this VMID, keeping the newest $BACKUP_KEEP
    pruned=$(ls -1t "${BACKUP_DIR}/${VMID}_"*.conf 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)))
    if [[ -n "$pruned" ]]; then
        count=$(echo "$pruned" | wc -l)
        echo "$pruned" | xargs -r rm -f --
        echo "Pruned $count old backup(s) for VM ${VMID} (keeping newest ${BACKUP_KEEP})"
    fi
fi

if [[ "$PROFILE" == "default" ]]; then
    echo "Using existing config (no load)"
elif [[ "$PROFILE" == "auto" ]]; then
    if ! declare -f add_available_mappings_to_config >/dev/null; then
        echo "Error: 'auto' profile requires proxmox-usb-hotplug installed." >&2
        echo "See: https://github.com/codemonkeying/proxmox-usb-hotplug" >&2
        exit 1
    fi

    CONFIG_FILENAME="${VMID}_${PROFILE}.conf"
    VM_CONFIG_FILE="${VM_CONFIG_DIR}/${CONFIG_FILENAME}"

    if [[ ! -f "$VM_CONFIG_FILE" ]]; then
        echo "Auto config not found: ${VM_CONFIG_FILE}"
        MINIMAL_CONFIG="${VM_CONFIG_DIR}/${VMID}_minimal.conf"
        if [[ -f "$MINIMAL_CONFIG" ]]; then
            cp "$MINIMAL_CONFIG" "$VM_CONFIG_FILE"
            echo "Created ${CONFIG_FILENAME} from minimal config"
        else
            echo "Error: neither ${CONFIG_FILENAME} nor ${VMID}_minimal.conf found in ${VM_CONFIG_DIR}" >&2
            exit 1
        fi
    fi

    cp "$VM_CONFIG_FILE" "$PVE_CONFIG"
    echo "Loaded auto config: ${VMID} (${CONFIG_FILENAME})"

    add_available_mappings_to_config "$VMID" "$PVE_CONFIG"
else
    CONFIG_FILENAME="${VMID}_${PROFILE}.conf"
    VM_CONFIG_FILE="${VM_CONFIG_DIR}/${CONFIG_FILENAME}"

    if [[ ! -f "$VM_CONFIG_FILE" ]]; then
        echo "Error: config file not found: ${VM_CONFIG_FILE}" >&2
        echo "" >&2
        echo "Available configs for VM ${VMID}:" >&2
        ls -1 "${VM_CONFIG_DIR}"/*.conf 2>/dev/null | xargs -n1 basename >&2
        exit 1
    fi

    cp "$VM_CONFIG_FILE" "$PVE_CONFIG"
    echo "Loaded config: ${VMID} (${CONFIG_FILENAME})"
fi

echo "Starting VM ${VMID}..."
qm start "$VMID"

if [[ "$PROFILE" == "auto" ]]; then
    echo "${VMID}" > /var/run/usb-hotplug-auto-vm.state
    echo "VM ${VMID} marked for USB auto-monitoring"
else
    rm -f /var/run/usb-hotplug-auto-vm.state 2>/dev/null
fi

sleep 2
qm status "$VMID"
