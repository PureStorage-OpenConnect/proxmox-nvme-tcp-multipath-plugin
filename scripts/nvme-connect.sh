#!/bin/bash
# NVMe-TCP Connection Script
# Connect to NVMe-TCP targets with multipath support

set -e

SCRIPT_NAME=$(basename "$0")
LOG_TAG="nvme-connect"

# Default values
CTRL_LOSS_TMO=1800
RECONNECT_DELAY=10
IO_POLICY="queue-depth"
HOST_IFACE=""
HOST_TRADDR=""

log() {
    logger -t "$LOG_TAG" "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    logger -t "$LOG_TAG" -p user.err "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS] -n <subnqn> -a <address>[,<address>...]

Connect to NVMe-TCP target with optional multipath support.

Options:
    -n, --nqn <subnqn>          Target subsystem NQN (required)
    -a, --address <addr>        Target address(es), comma-separated for multipath
    -p, --port <port>           Target port (default: 8009)
    -t, --ctrl-loss-tmo <sec>   Controller loss timeout (default: 1800)
    -r, --reconnect-delay <sec> Reconnect delay (default: 10)
    -i, --iopolicy <policy>     IO policy: round-robin, numa, queue-depth (default: queue-depth)
    -I, --host-iface <iface>    Host network interface(s), comma-separated (e.g., 'eth0,eth1')
    -T, --host-traddr <addr>    Host transport address(es)/IP(s), comma-separated
    -d, --disconnect            Disconnect from target
    -s, --status                Show connection status
    -h, --help                  Show this help

Examples:
    # Connect to single target
    $SCRIPT_NAME -n nqn.2024-01.com.example:storage -a 192.168.1.100

    # Connect with multipath (two paths)
    $SCRIPT_NAME -n nqn.2024-01.com.example:storage -a 192.168.1.100,192.168.1.101

    # Connect with specific host interfaces
    $SCRIPT_NAME -n nqn.2024-01.com.example:storage -a 192.168.1.100,192.168.2.100 -I eth0,eth1

    # Connect with specific host IP addresses
    $SCRIPT_NAME -n nqn.2024-01.com.example:storage -a 192.168.1.100 -T 192.168.1.10

    # Disconnect
    $SCRIPT_NAME -d -n nqn.2024-01.com.example:storage
EOF
    exit 1
}

# Enable NVMe native multipath
enable_multipath() {
    local mp_file="/sys/module/nvme_core/parameters/multipath"
    if [ -f "$mp_file" ]; then
        current=$(cat "$mp_file")
        if [ "$current" != "Y" ]; then
            log "Enabling NVMe native multipath"
            echo 'Y' | tee "$mp_file" > /dev/null 2>&1 || {
                log "Note: Could not enable multipath (may require reboot)"
            }
        fi
    fi
}

# Set IO policy for subsystem
set_iopolicy() {
    local subnqn=$1
    local policy=$2
    
    for subsys in /sys/class/nvme-subsystem/nvme-subsys*; do
        if [ -f "$subsys/subsysnqn" ]; then
            nqn=$(cat "$subsys/subsysnqn")
            if [ "$nqn" = "$subnqn" ]; then
                if [ -f "$subsys/iopolicy" ]; then
                    log "Setting IO policy to $policy for $subnqn"
                    echo "$policy" > "$subsys/iopolicy" 2>/dev/null || true
                fi
            fi
        fi
    done
}

# Check if already connected
is_connected() {
    local subnqn=$1
    
    for subsys in /sys/class/nvme-subsystem/nvme-subsys*; do
        if [ -f "$subsys/subsysnqn" ]; then
            nqn=$(cat "$subsys/subsysnqn")
            if [ "$nqn" = "$subnqn" ]; then
                return 0
            fi
        fi
    done
    return 1
}

# Connect to target
connect() {
    local subnqn=$1
    local addresses=$2
    local port=${3:-8009}

    enable_multipath

    IFS=',' read -ra ADDRS <<< "$addresses"
    IFS=',' read -ra IFACES <<< "$HOST_IFACE"
    IFS=',' read -ra TRADDRS <<< "$HOST_TRADDR"

    local idx=0
    for addr in "${ADDRS[@]}"; do
        # Get corresponding interface/address (round-robin if fewer than portals)
        local iface=""
        local traddr=""
        if [ ${#IFACES[@]} -gt 0 ]; then
            iface="${IFACES[$((idx % ${#IFACES[@]}))]}"
        fi
        if [ ${#TRADDRS[@]} -gt 0 ]; then
            traddr="${TRADDRS[$((idx % ${#TRADDRS[@]}))]}"
        fi

        log "Connecting to $addr:$port for $subnqn (iface: ${iface:-auto}, traddr: ${traddr:-auto})"

        # Build command
        local cmd="nvme connect -t tcp -n $subnqn -a $addr -s $port --ctrl-loss-tmo=$CTRL_LOSS_TMO --reconnect-delay=$RECONNECT_DELAY"

        if [ -n "$iface" ]; then
            cmd="$cmd --host-iface=$iface"
        fi
        if [ -n "$traddr" ]; then
            cmd="$cmd --host-traddr=$traddr"
        fi

        eval "$cmd" 2>&1 || {
            error "Failed to connect to $addr:$port"
        }

        ((idx++))
    done

    # Wait for device to appear
    sleep 2

    # Set IO policy
    set_iopolicy "$subnqn" "$IO_POLICY"

    log "Connection complete"
}

# Disconnect from target
disconnect() {
    local subnqn=$1
    log "Disconnecting from $subnqn"
    nvme disconnect -n "$subnqn" 2>&1 || {
        error "Failed to disconnect from $subnqn"
        return 1
    }
    log "Disconnected successfully"
}

# Show status
show_status() {
    echo "=== NVMe Subsystems ==="
    nvme list-subsys 2>/dev/null || echo "No subsystems found"
    echo ""
    echo "=== NVMe Devices ==="
    nvme list 2>/dev/null || echo "No devices found"
}

# Parse arguments
SUBNQN=""
ADDRESSES=""
PORT=8009
DO_DISCONNECT=0
DO_STATUS=0

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--nqn) SUBNQN="$2"; shift 2 ;;
        -a|--address) ADDRESSES="$2"; shift 2 ;;
        -p|--port) PORT="$2"; shift 2 ;;
        -t|--ctrl-loss-tmo) CTRL_LOSS_TMO="$2"; shift 2 ;;
        -r|--reconnect-delay) RECONNECT_DELAY="$2"; shift 2 ;;
        -i|--iopolicy) IO_POLICY="$2"; shift 2 ;;
        -I|--host-iface) HOST_IFACE="$2"; shift 2 ;;
        -T|--host-traddr) HOST_TRADDR="$2"; shift 2 ;;
        -d|--disconnect) DO_DISCONNECT=1; shift ;;
        -s|--status) DO_STATUS=1; shift ;;
        -h|--help) usage ;;
        *) error "Unknown option: $1"; usage ;;
    esac
done

# Execute
if [ $DO_STATUS -eq 1 ]; then
    show_status
    exit 0
fi

if [ -z "$SUBNQN" ]; then
    error "Subsystem NQN is required"
    usage
fi

if [ $DO_DISCONNECT -eq 1 ]; then
    disconnect "$SUBNQN"
else
    if [ -z "$ADDRESSES" ]; then
        error "Target address is required"
        usage
    fi
    connect "$SUBNQN" "$ADDRESSES" "$PORT"
fi

