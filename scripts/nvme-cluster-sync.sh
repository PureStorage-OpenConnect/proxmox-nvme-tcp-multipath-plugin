#!/bin/bash
# NVMe-TCP Cluster Sync Script
# Runs pvscan and syncs LVM metadata across all cluster nodes

set -e

SCRIPT_NAME=$(basename "$0")
LOG_TAG="nvme-cluster-sync"

log() {
    logger -t "$LOG_TAG" "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    logger -t "$LOG_TAG" -p user.err "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

# Get list of cluster nodes
get_cluster_nodes() {
    if command -v pvecm &> /dev/null; then
        pvecm nodes 2>/dev/null | awk 'NR>1 {print $3}' | grep -v "^$"
    else
        hostname
    fi
}

# Run pvscan on local node
run_local_pvscan() {
    log "Running pvscan --cache on local node"
    pvscan --cache 2>&1 || true
    vgscan --mknodes 2>&1 || true
}

# Run pvscan on remote node via SSH
run_remote_pvscan() {
    local node=$1
    local local_hostname=$(hostname)
    
    if [ "$node" = "$local_hostname" ]; then
        return 0
    fi
    
    log "Running pvscan --cache on remote node: $node"
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@$node" \
        "pvscan --cache && vgscan --mknodes" 2>&1 || {
        error "Failed to run pvscan on node $node"
        return 1
    }
}

# Sync LVM metadata across cluster
sync_cluster() {
    log "Starting cluster-wide LVM sync"
    
    # First, run locally
    run_local_pvscan
    
    # Then sync to all other nodes
    local nodes=$(get_cluster_nodes)
    local failed=0
    
    for node in $nodes; do
        run_remote_pvscan "$node" || ((failed++))
    done
    
    if [ $failed -gt 0 ]; then
        error "Failed to sync $failed node(s)"
        return 1
    fi
    
    log "Cluster sync completed successfully"
    return 0
}

# Activate VG on all nodes
activate_vg_cluster() {
    local vgname=$1
    
    if [ -z "$vgname" ]; then
        error "VG name required"
        return 1
    fi
    
    log "Activating VG $vgname across cluster"
    
    local nodes=$(get_cluster_nodes)
    
    for node in $nodes; do
        local local_hostname=$(hostname)
        if [ "$node" = "$local_hostname" ]; then
            vgchange -aly "$vgname" 2>&1 || true
        else
            ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@$node" \
                "vgchange -aly $vgname" 2>&1 || {
                error "Failed to activate VG on node $node"
            }
        fi
    done
}

# Main
case "${1:-sync}" in
    sync)
        sync_cluster
        ;;
    pvscan)
        run_local_pvscan
        ;;
    activate)
        shift
        activate_vg_cluster "$@"
        ;;
    *)
        echo "Usage: $SCRIPT_NAME {sync|pvscan|activate <vgname>}"
        exit 1
        ;;
esac

