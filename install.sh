#!/bin/bash
# Proxmox NVMe-TCP Storage Plugin Installer
# Supports PVE 9.2+ (Debian Trixie) and PVE 8.x (Debian Bookworm, API warning expected)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="/usr/share/perl5/PVE/Storage/Custom"
SCRIPT_INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
CONF_DIR="/etc/nvme-tcp"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
    exit 1
}

warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1" >&2
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root"
fi

# Detect PVE version
detect_pve_version() {
    if ! command -v pveversion &>/dev/null; then
        warn "pveversion not found - this may not be a Proxmox VE node"
        PVE_MAJOR=0
        PVE_MINOR=0
        return
    fi

    local pve_full
    pve_full=$(pveversion 2>/dev/null | grep -oP 'pve-manager/\K[0-9]+\.[0-9]+' || echo "0.0")
    PVE_MAJOR=$(echo "$pve_full" | cut -d. -f1)
    PVE_MINOR=$(echo "$pve_full" | cut -d. -f2)

    log "Detected PVE version: ${PVE_MAJOR}.${PVE_MINOR} ($(pveversion 2>/dev/null | head -1))"
}

detect_pve_version

if [ "$PVE_MAJOR" -lt 9 ] && [ "$PVE_MAJOR" -gt 0 ]; then
    warn "This plugin is built for PVE 9.2+ (APIVER 13)."
    warn "On PVE ${PVE_MAJOR}.${PVE_MINOR} the storage daemon will log a plugin API version warning."
    warn "The plugin will still function, but upgrading to PVE 9.2+ is recommended."
    echo ""
fi

log "Installing Proxmox NVMe-TCP Storage Plugin..."

# Install dependencies first
log "Installing dependencies..."
"$SCRIPT_DIR/scripts/nvme-install-deps.sh"

# Create plugin directory
log "Creating plugin directory..."
mkdir -p "$PLUGIN_DIR"

# Install plugin
log "Installing NVMeTCPPlugin.pm..."
cp "$SCRIPT_DIR/src/PVE/Storage/Custom/NVMeTCPPlugin.pm" "$PLUGIN_DIR/"
chmod 644 "$PLUGIN_DIR/NVMeTCPPlugin.pm"

# Patch plugin APIVER to match this host's PVE storage library version.
# PVE rejects plugins that claim a newer API than it knows, and warns when
# the plugin API is older, so we set it to exactly what this host expects.
PVE_STORAGE_APIVER=$(grep -oP '^use constant APIVER => \K[0-9]+' \
    /usr/share/perl5/PVE/Storage.pm 2>/dev/null || echo "")

if [ -n "$PVE_STORAGE_APIVER" ] && [ "$PVE_STORAGE_APIVER" -gt 0 ] 2>/dev/null; then
    log "Patching plugin APIVER to match host PVE storage library: $PVE_STORAGE_APIVER"
    sed -i "s/^use constant APIVER => [0-9]*;/use constant APIVER => $PVE_STORAGE_APIVER;/" \
        "$PLUGIN_DIR/NVMeTCPPlugin.pm"
else
    log "Could not detect PVE storage APIVER from /usr/share/perl5/PVE/Storage.pm, using plugin default"
fi

# Install helper scripts
log "Installing helper scripts..."
cp "$SCRIPT_DIR/scripts/nvme-connect.sh" "$SCRIPT_INSTALL_DIR/"
cp "$SCRIPT_DIR/scripts/nvme-cluster-sync.sh" "$SCRIPT_INSTALL_DIR/"
cp "$SCRIPT_DIR/scripts/nvme-rescan.sh" "$SCRIPT_INSTALL_DIR/"
chmod 755 "$SCRIPT_INSTALL_DIR/nvme-connect.sh"
chmod 755 "$SCRIPT_INSTALL_DIR/nvme-cluster-sync.sh"
chmod 755 "$SCRIPT_INSTALL_DIR/nvme-rescan.sh"

# Install systemd service
log "Installing systemd service..."
cp "$SCRIPT_DIR/systemd/nvme-tcp-connect@.service" "$SYSTEMD_DIR/"
systemctl daemon-reload

# Create configuration directory
log "Creating configuration directory..."
mkdir -p "$CONF_DIR"
if [ ! -f "$CONF_DIR/example.conf" ]; then
    cp "$SCRIPT_DIR/conf/nvme-tcp-example.conf" "$CONF_DIR/example.conf"
fi

# Restart PVE services to load the plugin
log "Restarting pvedaemon..."
systemctl restart pvedaemon

log "Restarting pvestatd (for cluster status updates)..."
systemctl restart pvestatd

# Install GUI (optional) - only prompt when running interactively
if [ -f "$SCRIPT_DIR/www/install-gui.sh" ] && [ -t 0 ]; then
    echo ""
    read -p "Install web GUI components? (experimental) [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Installing GUI components..."
        bash "$SCRIPT_DIR/www/install-gui.sh"
    else
        log "Skipping GUI installation"
    fi
fi

log ""
log "============================================"
log "Installation complete!"
log "PVE version: ${PVE_MAJOR}.${PVE_MINOR}"
log "============================================"
log ""
log "Step 1: Add NVMe-TCP connection:"
log ""
log "  pvesm add nvmetcp my-nvme-connection \\"
log "    --nvme_portal 192.168.1.100:8009 \\"
log "    --nvme_subnqn nqn.2024-01.com.example:storage \\"
log "    --shared 1"
log ""
log "Step 2: Create LVM on NVMe namespace:"
log ""
log "  pvcreate /dev/nvme0n1"
log "  vgcreate my-vg /dev/nvme0n1"
log ""
log "Step 3: Add LVM storage:"
log ""
log "  pvesm add lvm my-lvm-storage --vgname my-vg --shared 1"
log ""
log "Verify: pvesm status"
log ""
log "Host NQN: $(cat /etc/nvme/hostnqn 2>/dev/null || echo 'Not generated')"
log ""
