#!/bin/bash
# Proxmox NVMe-TCP Storage Plugin Uninstaller
# Run this script on each Proxmox VE node to remove the plugin

set -e

PLUGIN_DIR="/usr/share/perl5/PVE/Storage/Custom"
SCRIPT_INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
CONF_DIR="/etc/nvme-tcp"
BACKUP_DIR="/var/lib/nvme-tcp-plugin"
PVEMANAGERLIB="/usr/share/pve-manager/js/pvemanagerlib.js"
BACKUP_FILE="$BACKUP_DIR/pvemanagerlib.js.original"
MARKER_START="// ========== NVME-TCP-PLUGIN-START =========="
MARKER_END="// ========== NVME-TCP-PLUGIN-END =========="

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1" >&2
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root"
    exit 1
fi

log "Uninstalling Proxmox NVMe-TCP Storage Plugin..."

# Stop and disable any active nvme-tcp-connect services
log "Stopping NVMe-TCP connection services..."
for service in /etc/systemd/system/multi-user.target.wants/nvme-tcp-connect@*.service; do
    if [ -L "$service" ]; then
        instance=$(basename "$service" | sed 's/nvme-tcp-connect@\(.*\)\.service/\1/')
        log "Stopping nvme-tcp-connect@$instance..."
        systemctl stop "nvme-tcp-connect@$instance" 2>/dev/null || true
        systemctl disable "nvme-tcp-connect@$instance" 2>/dev/null || true
    fi
done

# Remove systemd service
log "Removing systemd service..."
if [ -f "$SYSTEMD_DIR/nvme-tcp-connect@.service" ]; then
    rm -f "$SYSTEMD_DIR/nvme-tcp-connect@.service"
    systemctl daemon-reload
fi

# Remove plugin
log "Removing NVMeTCPPlugin.pm..."
if [ -f "$PLUGIN_DIR/NVMeTCPPlugin.pm" ]; then
    rm -f "$PLUGIN_DIR/NVMeTCPPlugin.pm"
fi

# Remove helper scripts
log "Removing helper scripts..."
rm -f "$SCRIPT_INSTALL_DIR/nvme-connect.sh"
rm -f "$SCRIPT_INSTALL_DIR/nvme-cluster-sync.sh"
rm -f "$SCRIPT_INSTALL_DIR/nvme-rescan.sh"

# Ask about configuration directory
if [ -d "$CONF_DIR" ]; then
    echo ""
    read -p "Remove configuration directory $CONF_DIR? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Removing configuration directory..."
        rm -rf "$CONF_DIR"
    else
        log "Keeping configuration directory $CONF_DIR"
    fi
fi

# Check for active NVMe-TCP connections
log "Checking for active NVMe-TCP connections..."
if command -v nvme &> /dev/null; then
    active_subsys=$(nvme list-subsys 2>/dev/null | grep -c "tcp" || echo "0")
    if [ "$active_subsys" -gt 0 ]; then
        warn "There are still $active_subsys active NVMe-TCP connection(s)."
        warn "These were not disconnected. To disconnect manually, use:"
        warn "  nvme disconnect -n <subsystem-nqn>"
        warn "  or: nvme disconnect-all"
    fi
fi

# Check for storage definitions
if [ -f /etc/pve/storage.cfg ]; then
    nvme_storage=$(grep -c "^nvmetcp:" /etc/pve/storage.cfg 2>/dev/null | head -1 | tr -d '\n' || echo "0")
    nvme_storage=${nvme_storage:-0}
    if [ "$nvme_storage" -gt 0 ] 2>/dev/null; then
        warn ""
        warn "Found $nvme_storage NVMe-TCP storage definition(s) in /etc/pve/storage.cfg"
        warn "These were not removed. Please remove them manually if needed."
    fi
fi

# Restart pvedaemon to unload the plugin
log "Restarting pvedaemon..."
systemctl restart pvedaemon 2>/dev/null || warn "Failed to restart pvedaemon"

# Restore GUI (pvemanagerlib.js)
log "Checking for GUI modifications..."
if [ -f "$PVEMANAGERLIB" ] && grep -q "$MARKER_START" "$PVEMANAGERLIB"; then
    if [ -f "$BACKUP_FILE" ]; then
        log "Restoring original pvemanagerlib.js from backup..."
        cp "$BACKUP_FILE" "$PVEMANAGERLIB"
        log "Restarting pveproxy..."
        systemctl restart pveproxy 2>/dev/null || warn "Failed to restart pveproxy"
    else
        log "Removing appended NVMe-TCP GUI code..."
        # Remove everything between markers (inclusive)
        sed -i "/$MARKER_START/,/$MARKER_END/d" "$PVEMANAGERLIB"
        log "Restarting pveproxy..."
        systemctl restart pveproxy 2>/dev/null || warn "Failed to restart pveproxy"
    fi
else
    log "No GUI modifications found"
fi

# Clean up backup directory
if [ -d "$BACKUP_DIR" ]; then
    echo ""
    read -p "Remove backup directory $BACKUP_DIR? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Removing backup directory..."
        rm -rf "$BACKUP_DIR"
    else
        log "Keeping backup directory $BACKUP_DIR"
    fi
fi

log ""
log "============================================"
log "Uninstallation complete!"
log "============================================"
log ""
log "Note: The following were NOT removed:"
log "  - NVMe kernel modules (nvme, nvme-tcp, nvme-core)"
log "  - /etc/modules-load.d/nvme-tcp.conf"
log "  - /etc/modprobe.d/nvme-multipath.conf"
log "  - /etc/nvme/hostnqn and /etc/nvme/hostid"
log "  - nvme-cli package"
log "  - Any active NVMe-TCP connections"
log "  - Storage definitions in /etc/pve/storage.cfg"
log ""
log "To fully remove NVMe-TCP support, also run:"
log "  rm -f /etc/modules-load.d/nvme-tcp.conf"
log "  rm -f /etc/modprobe.d/nvme-multipath.conf"
log "  apt-get remove nvme-cli"
log ""

