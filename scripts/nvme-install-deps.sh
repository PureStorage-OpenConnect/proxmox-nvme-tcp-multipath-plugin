#!/bin/bash
# Install NVMe-TCP dependencies on Proxmox VE nodes
# Supports PVE 9.2+ (Debian Trixie) and PVE 8.x (Debian Bookworm)

set -e

SCRIPT_NAME=$(basename "$0")
LOG_TAG="nvme-install"

log() {
    logger -t "$LOG_TAG" "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    logger -t "$LOG_TAG" -p user.err "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
    exit 1
}

warn() {
    logger -t "$LOG_TAG" -p user.warn "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1" >&2
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root"
fi

# Detect PVE and Debian version
detect_version() {
    PVE_MAJOR=0
    PVE_MINOR=0
    DEBIAN_CODENAME="unknown"

    if [ -f /etc/debian_version ]; then
        DEBIAN_VERSION=$(cat /etc/debian_version | cut -d. -f1)
        DEBIAN_CODENAME=$(grep VERSION_CODENAME /etc/os-release 2>/dev/null | cut -d= -f2 || echo "unknown")
    fi

    if command -v pveversion &>/dev/null; then
        local pve_full
        pve_full=$(pveversion 2>/dev/null | grep -oP 'pve-manager/\K[0-9]+\.[0-9]+' || echo "0.0")
        PVE_MAJOR=$(echo "$pve_full" | cut -d. -f1)
        PVE_MINOR=$(echo "$pve_full" | cut -d. -f2)
        log "Detected PVE ${PVE_MAJOR}.${PVE_MINOR} on Debian ${DEBIAN_CODENAME}"
    else
        warn "pveversion not found - not a Proxmox VE node, or PVE not in PATH"
        log "Detected Debian ${DEBIAN_CODENAME}"
    fi
}

detect_version

# Check if running on Proxmox VE
if [ ! -f /etc/pve/local/pve-ssl.pem ]; then
    warn "This doesn't appear to be a Proxmox VE node - /etc/pve/local/pve-ssl.pem not found"
fi

log "Installing NVMe-TCP dependencies for PVE ${PVE_MAJOR}.${PVE_MINOR} (Debian ${DEBIAN_CODENAME})..."

# Install nvme-cli if not already present
# PVE 9.x (Trixie): nvme-cli 2.x is available
# PVE 8.x (Bookworm): nvme-cli 1.x or 2.x depending on backports
if dpkg -l nvme-cli 2>/dev/null | grep -q '^ii'; then
    log "nvme-cli already installed, skipping apt"
else
    log "Updating package list..."
    apt-get update
    log "Installing nvme-cli..."
    apt-get install -y nvme-cli
fi

NVME_VERSION=$(nvme version 2>/dev/null | grep -oP 'version \K[0-9]+' | head -1 || echo "0")
log "nvme-cli major version: ${NVME_VERSION}"

# Note: LVM2 is expected to be already installed on Proxmox VE
# We do not install or update it to avoid conflicts

# Load NVMe-TCP kernel modules
log "Loading NVMe kernel modules..."
modprobe nvme
modprobe nvme-tcp
modprobe nvme-core

# Enable NVMe native multipath
log "Enabling NVMe native multipath..."
if [ -f /sys/module/nvme_core/parameters/multipath ]; then
    echo 'Y' | tee /sys/module/nvme_core/parameters/multipath > /dev/null 2>&1 || {
        log "Note: Could not enable multipath at runtime (may already be set or require reboot)"
    }
fi

# Make modules load at boot
log "Configuring modules to load at boot..."
cat > /etc/modules-load.d/nvme-tcp.conf << 'EOF'
nvme
nvme-tcp
nvme-core
EOF

# Configure NVMe multipath at boot
log "Configuring NVMe multipath at boot..."
cat > /etc/modprobe.d/nvme-multipath.conf << 'EOF'
options nvme_core multipath=Y
EOF

# Generate hostnqn if not exists
if [ ! -f /etc/nvme/hostnqn ]; then
    log "Generating host NQN..."
    mkdir -p /etc/nvme
    nvme gen-hostnqn > /etc/nvme/hostnqn
fi

HOSTNQN=$(cat /etc/nvme/hostnqn)
log "Host NQN: $HOSTNQN"

# Generate hostid if not exists
if [ ! -f /etc/nvme/hostid ]; then
    log "Generating host ID..."
    uuidgen > /etc/nvme/hostid
fi

# Update initramfs to include NVMe modules
log "Updating initramfs..."
update-initramfs -u

log "NVMe-TCP dependencies installed successfully!"
log ""
log "  PVE version:     ${PVE_MAJOR}.${PVE_MINOR}"
log "  Debian release:  ${DEBIAN_CODENAME}"
log "  nvme-cli major:  ${NVME_VERSION}"
log "  Host NQN:        ${HOSTNQN}"
log ""
log "Next steps:"
log "1. Copy the NVMeTCPPlugin.pm to /usr/share/perl5/PVE/Storage/Custom/"
log "2. Configure storage in /etc/pve/storage.cfg"
log "3. Restart pvedaemon: systemctl restart pvedaemon"
log ""
log "Example storage.cfg entry:"
log "  nvmetcp: nvme-storage"
log "      portal 192.168.1.100:8009,192.168.1.101:8009"
log "      subnqn nqn.2024-01.com.example:storage"
log "      vgname nvme-vg"
log "      content images,rootdir"
log "      shared 1"
