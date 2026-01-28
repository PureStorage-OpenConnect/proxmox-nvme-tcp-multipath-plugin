#!/bin/bash
# NVMe-TCP Rescan Script
# Rescans NVMe subsystems for new namespaces (LUNs) and refreshes LVM
#
# Usage: nvme-rescan.sh [subsystem-nqn]
#        nvme-rescan.sh --all
#        nvme-rescan.sh --storage <storage-id>

set -e

SCRIPT_NAME=$(basename "$0")

usage() {
    echo "Usage: $SCRIPT_NAME [OPTIONS] [NQN]"
    echo ""
    echo "Rescan NVMe-oF subsystems for new namespaces and refresh LVM."
    echo ""
    echo "Options:"
    echo "  --all              Rescan all connected NVMe-oF subsystems"
    echo "  --storage NAME     Rescan the subsystem used by storage NAME"
    echo "  -h, --help         Show this help message"
    echo ""
    echo "Examples:"
    echo "  $SCRIPT_NAME nqn.2024-01.com.example:storage"
    echo "  $SCRIPT_NAME --all"
    echo "  $SCRIPT_NAME --storage my-nvme-storage"
    exit 1
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

rescan_subsystem() {
    local nqn="$1"
    local count=0
    
    log "Rescanning subsystem: $nqn"
    
    # Find all controllers for this subsystem
    for subsys in /sys/class/nvme-subsystem/nvme-subsys*; do
        [ -d "$subsys" ] || continue
        
        subsys_nqn=$(cat "$subsys/subsysnqn" 2>/dev/null || echo "")
        if [ "$subsys_nqn" = "$nqn" ]; then
            # Rescan each controller
            for ctrl in "$subsys"/nvme*; do
                [ -d "$ctrl" ] || continue
                ctrl_name=$(basename "$ctrl")
                
                # Skip namespace entries (nvmeXnY), only want controllers (nvmeX)
                [[ "$ctrl_name" =~ ^nvme[0-9]+$ ]] || continue
                
                rescan_path="/sys/class/nvme/$ctrl_name/rescan_controller"
                if [ -w "$rescan_path" ]; then
                    log "  Rescanning controller: $ctrl_name"
                    echo 1 > "$rescan_path"
                    ((count++))
                fi
            done
        fi
    done
    
    if [ $count -eq 0 ]; then
        error "No controllers found for subsystem: $nqn"
        return 1
    fi
    
    log "  Rescanned $count controller(s)"
    return 0
}

rescan_all() {
    log "Rescanning all NVMe-oF subsystems..."
    
    local count=0
    local seen_nqns=""
    
    for subsys in /sys/class/nvme-subsystem/nvme-subsys*; do
        [ -d "$subsys" ] || continue
        
        nqn=$(cat "$subsys/subsysnqn" 2>/dev/null || echo "")
        [ -n "$nqn" ] || continue
        
        # Skip if we've already processed this NQN
        if echo "$seen_nqns" | grep -qF "$nqn"; then
            continue
        fi
        seen_nqns="$seen_nqns $nqn"
        
        # Skip local NVMe devices (they have different NQN format)
        if [[ "$nqn" != nqn.* ]]; then
            continue
        fi
        
        rescan_subsystem "$nqn" && ((count++))
    done
    
    log "Rescanned $count subsystem(s)"
}

get_storage_nqn() {
    local storage_id="$1"
    
    if [ ! -f /etc/pve/storage.cfg ]; then
        error "Storage config not found: /etc/pve/storage.cfg"
        return 1
    fi
    
    # Parse storage.cfg to find the NQN for this storage
    awk -v storage="$storage_id" '
        /^nvmetcp:/ { current = $2 }
        current == storage && /nvme_subnqn/ { print $2; exit }
    ' /etc/pve/storage.cfg
}

# Parse arguments
if [ $# -eq 0 ]; then
    usage
fi

case "$1" in
    -h|--help)
        usage
        ;;
    --all)
        rescan_all
        ;;
    --storage)
        [ -n "$2" ] || { error "Missing storage name"; usage; }
        nqn=$(get_storage_nqn "$2")
        [ -n "$nqn" ] || { error "Storage '$2' not found or has no NQN"; exit 1; }
        rescan_subsystem "$nqn"
        ;;
    nqn.*)
        rescan_subsystem "$1"
        ;;
    *)
        error "Unknown option or invalid NQN: $1"
        usage
        ;;
esac

# Always refresh LVM after rescan
log "Refreshing LVM..."
pvscan --cache 2>/dev/null || true
vgscan --cache 2>/dev/null || true

log "Rescan complete. New namespaces:"
lsblk | grep -E "^nvme" || echo "  (none found)"

