# Proxmox NVMe-TCP Storage Plugin

A Proxmox VE storage plugin for NVMe over TCP (NVMe-TCP) connection management. This plugin works like the built-in iSCSI plugin - it manages the NVMe-TCP connection and exposes namespaces as block devices. You can then layer Proxmox's native LVM or LVM-thin storage on top.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Proxmox VE Storage                       │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐    ┌─────────────────────────────────┐ │
│  │  nvmetcp:       │    │  lvm: my-lvm-storage            │ │
│  │  my-nvme-conn   │    │    vgname my-vg                 │ │
│  │  (connection    │───>│    shared 1                     │ │
│  │   only)         │    │  (volume management)            │ │
│  └─────────────────┘    └─────────────────────────────────┘ │
├─────────────────────────────────────────────────────────────┤
│                    NVMe Namespaces                          │
│            /dev/nvme0n1, /dev/nvme0n2, etc.                │
├─────────────────────────────────────────────────────────────┤
│                   NVMe-TCP Transport                        │
│              (multipath, iopolicy, etc.)                    │
└─────────────────────────────────────────────────────────────┘
```

## Features

- **NVMe-TCP Connection Management**: Connect to NVMe-TCP storage targets
- **Native Multipathing**: Linux kernel's native NVMe multipath for high availability
- **IO Policy Selection**: round-robin, NUMA, or queue-depth load balancing (default: queue-depth)
- **Namespace Discovery**: Lists NVMe namespaces like iSCSI lists LUNs
- **Cluster Support**: Shared connections across Proxmox VE cluster nodes
- **Auto-reconnect**: Configurable controller loss timeout and reconnect delay

## Requirements

- Proxmox VE 9.x
- Linux kernel 5.0+ (for NVMe-TCP support)
- nvme-cli package

---

## Quick Start Guide

This guide shows how to set up NVMe-TCP storage on a Proxmox cluster via this plugin.

### Prerequisites

**On your storage array:**
- Configure NVMe-TCP target with subsystem NQN
- Note the portal IP addresses and NQN
- Ensure host NQN is allowed to connect

**Information needed:**
- Portal IP(s): e.g., `10.21.140.60,10.21.140.61,10.21.140.62,10.21.140.63`
- Subsystem NQN: e.g., `nqn.2010-06.com.purestorage:flasharray.abc123`
- Host interfaces for NVME: e.g., `ens1f0np0,ens1f1np1` (You must have configured a single IP address on the interface(s) and the interface name(s) must be the same on all nodes)

### Step 1: Install Dependencies (All Nodes)

```bash
# Install nvme-cli
apt-get update
apt-get install -y nvme-cli

# Load kernel modules
modprobe nvme
modprobe nvme-tcp
modprobe nvme-core

# Make modules load on boot
cat >> /etc/modules-load.d/nvme.conf << 'EOF'
nvme
nvme-tcp
nvme-core
EOF

# Enable NVMe native multipath
echo 'Y' > /sys/module/nvme_core/parameters/multipath

# Make multipath persistent
cat > /etc/modprobe.d/nvme.conf << 'EOF'
options nvme_core multipath=Y
EOF

# Generate host NQN (if not exists)
if [ ! -f /etc/nvme/hostnqn ]; then
    mkdir -p /etc/nvme
    nvme gen-hostnqn > /etc/nvme/hostnqn
fi

# Show host NQN (register this with your storage array)
cat /etc/nvme/hostnqn
```

### Step 2: Install Plugin (All Nodes)

```bash
# Clone repository
git clone https://github.com/yourusername/proxmox-nvme-plugin.git
cd proxmox-nvme-plugin

./install.sh
```

## Manual Installation

```bash

# Create plugin directory
mkdir -p /usr/share/perl5/PVE/Storage/Custom

# Copy plugin
cp src/PVE/Storage/Custom/NVMeTCPPlugin.pm /usr/share/perl5/PVE/Storage/Custom/
chmod 644 /usr/share/perl5/PVE/Storage/Custom/NVMeTCPPlugin.pm

# Restart Proxmox services
systemctl restart pvedaemon
systemctl restart pveproxy
systemctl restart pvestatd

# Verify plugin is loaded
pvesm status
```

### Step 3: Add NVMe-TCP Connection (One Node Only)

**Note:** If the GUI was installed this is available via the GUI.  In the datacenter view select storage then click "Add" and select "NVMe-TCP" from the dropdown.  Fill in the form and click "Add".  Skip to Step 4.

```bash
# Add the NVMe-TCP connection storage
# This connects to the target and exposes namespaces
pvesm add nvmetcp my-nvme-connection \
    --nvme_portal 10.21.140.60,10.21.140.61,10.21.140.62,10.21.140.63 \
    --nvme_subnqn nqn.2010-06.com.purestorage:flasharray.abc123 \
    --nvme_multipath 1 \
    --nvme_iopolicy queue-depth \
    --nvme_host_iface ens1f0np0,ens1f1np1 \
    --shared 1

# Verify connection
nvme list-subsys
nvme list
```

### Step 4: Create LVM Volume Group (One Node Only)

```bash
# List available NVMe namespaces
lsblk | grep nvme

# Example output:
# nvme0n1     259:0    0   10T  0 disk

# Create LVM physical volume
pvcreate /dev/nvme0n1

# Create volume group
vgcreate my-nvme-vg /dev/nvme0n1

# Verify
vgs
pvs
```

### Step 5: Add LVM Storage (One Node Only)

```bash
# Add LVM storage for thick provisioning
pvesm add lvm my-nvme-datastore \
    --vgname my-nvme-vg \
    --content images,rootdir \
    --shared 1

# Verify all storage is active
pvesm status
```

### Step 6: Activate on Other Nodes

```bash
# On each additional node, scan for the VG
pvscan --cache
vgscan
vgchange -ay my-nvme-vg

# Verify
pvesm status
```

---

## Complete CLI Reference

### Plugin Installation Commands

```bash
# Install dependencies
apt-get update && apt-get install -y nvme-cli

# Load kernel modules
modprobe nvme nvme-tcp nvme-core

# Enable multipath (runtime)
echo 'Y' > /sys/module/nvme_core/parameters/multipath

# Enable multipath (persistent)
echo 'options nvme_core multipath=Y' > /etc/modprobe.d/nvme.conf

# Generate host NQN
mkdir -p /etc/nvme
nvme gen-hostnqn > /etc/nvme/hostnqn
cat /etc/nvme/hostnqn

# Install plugin
mkdir -p /usr/share/perl5/PVE/Storage/Custom
cp src/PVE/Storage/Custom/NVMeTCPPlugin.pm /usr/share/perl5/PVE/Storage/Custom/
chmod 644 /usr/share/perl5/PVE/Storage/Custom/NVMeTCPPlugin.pm

# Restart services
systemctl restart pvedaemon pveproxy pvestatd
```

### NVMe Discovery and Manual Connection

```bash
# Discover targets (before adding storage)
nvme discover -t tcp -a 10.21.140.60 -s 8009

# Manual connect (for testing)
nvme connect -t tcp \
    -a 10.21.140.60 \
    -s 8009 \
    -n nqn.2010-06.com.purestorage:flasharray.abc123 \
    --ctrl-loss-tmo=1800 \
    --reconnect-delay=10

# Manual disconnect
nvme disconnect -n nqn.2010-06.com.purestorage:flasharray.abc123

# List connected subsystems
nvme list-subsys

# List NVMe devices
nvme list
```

### Storage Management Commands

```bash
# Add NVMe-TCP connection (basic)
pvesm add nvmetcp <storage-id> \
    --nvme_portal <ip:port>[,<ip:port>...] \
    --nvme_subnqn <nqn> \
    --shared 1

# Add NVMe-TCP connection (full options)
pvesm add nvmetcp <storage-id> \
    --nvme_portal <ip>[,<ip>...] \
    --nvme_subnqn <nqn> \
    --nvme_multipath 1 \
    --nvme_iopolicy queue-depth \
    --nvme_host_iface <iface>[,<iface>...] \
    --nvme_host_traddr <ip>[,<ip>...] \
    --nvme_ctrl_loss_tmo 1800 \
    --nvme_reconnect_delay 10 \
    --shared 1

# Remove NVMe-TCP connection
pvesm remove <storage-id>

# Check storage status
pvesm status

# Scan storage
pvesm scan nvmetcp <portal> <nqn>
```

### LVM Commands

```bash
# Create physical volume on NVMe namespace
pvcreate /dev/nvme0n1

# Create volume group
vgcreate <vg-name> /dev/nvme0n1

# Create thin pool (optional)
lvcreate -L <size> -T <vg-name>/<pool-name>

# Add LVM storage to Proxmox (thick)
pvesm add lvm <storage-id> \
    --vgname <vg-name> \
    --content images,rootdir \
    --shared 1

# Add LVM-thin storage to Proxmox
pvesm add lvmthin <storage-id> \
    --vgname <vg-name> \
    --thinpool <pool-name> \
    --content images,rootdir \
    --shared 1

# Scan for VG on other nodes
pvscan --cache
vgscan
vgchange -ay <vg-name>
```

### Cluster Sync Commands

```bash
# Copy plugin to all nodes
for node in proxmox-02 proxmox-03; do
    scp /usr/share/perl5/PVE/Storage/Custom/NVMeTCPPlugin.pm \
        ${node}:/usr/share/perl5/PVE/Storage/Custom/
    ssh ${node} 'systemctl restart pvedaemon pveproxy pvestatd'
done

# Activate VG on all nodes
for node in proxmox-02 proxmox-03; do
    ssh ${node} 'pvscan --cache && vgchange -ay'
done
```

### Diagnostic Commands

```bash
# Check NVMe connection status
nvme list-subsys
nvme list

# Check multipath IO policy
cat /sys/class/nvme-subsystem/nvme-subsys*/iopolicy

# View multipath paths (JSON)
nvme list-subsys -o json

# Check controller status
cat /sys/class/nvme-subsystem/nvme-subsys*/nvme*/state

# View kernel messages
dmesg | grep -i nvme

# Check Proxmox logs
journalctl -u pvedaemon | grep -i nvme

# Test connectivity
ping <portal-ip>
nc -zv <portal-ip> 8009
```

---

## Configuration Options

| Option | Required | Default | Description |
|--------|----------|---------|-------------|
| `nvme_portal` | Yes | - | Target address(es), comma-separated for multipath |
| `nvme_subnqn` | Yes | - | NVMe subsystem NQN |
| `nvme_multipath` | No | 1 | Enable NVMe native multipathing |
| `nvme_iopolicy` | No | queue-depth | IO policy: round-robin, numa, queue-depth |
| `nvme_host_iface` | No | - | Host network interface(s), comma-separated |
| `nvme_host_traddr` | No | - | Host IP address(es), comma-separated |
| `nvme_ctrl_loss_tmo` | No | 1800 | Controller loss timeout (seconds) |
| `nvme_reconnect_delay` | No | 10 | Reconnect delay (seconds) |
| `shared` | No | 0 | Mark as shared storage for cluster |

### Example storage.cfg

```
nvmetcp: pure-nvme-connection
    nvme_portal 10.21.140.60,10.21.140.61,10.21.140.62,10.21.140.63
    nvme_subnqn nqn.2010-06.com.purestorage:flasharray.abc123
    nvme_multipath 1
    nvme_iopolicy queue-depth
    nvme_host_iface ens1f0np0,ens1f1np1
    shared 1

lvm: pure-lvm-ds01
    vgname pure-ds01-vg
    content images,rootdir
    shared 1
```

---

## GUI Installation (Optional)

This can be done as part of the install.sh script, but is shown here for reference.

```bash
# Install GUI components
./www/install-gui.sh

# Clear browser cache (Ctrl+Shift+R) after installation
# NVMe-TCP will appear in: Datacenter → Storage → Add

# Uninstall GUI
./www/uninstall-gui.sh
```

---

## Troubleshooting

### Check Connection Status

```bash
nvme list-subsys
nvme list
```

### Check IO Policy

```bash
cat /sys/class/nvme-subsystem/nvme-subsys*/iopolicy
```

### View Multipath Paths

```bash
nvme list-subsys -o json | jq '.Subsystems[] | {nqn: .NQN, paths: .Paths}'
```

### Check Logs

```bash
dmesg | grep nvme
journalctl -u pvedaemon | grep -i nvme
```

### Common Issues

**Storage shows as inactive:**
- Check if NVMe connection is established: `nvme list-subsys`
- Verify portal addresses are reachable: `ping <portal-ip>`
- Check firewall allows port 8009 (or your configured port)

**IO Policy not applied:**
- The plugin sets iopolicy on activation; restart pvedaemon to re-activate
- Verify: `cat /sys/class/nvme-subsystem/nvme-subsys*/iopolicy`

**Namespace not visible:**
- Wait a few seconds after connection for device discovery
- Check `dmesg` for NVMe errors

**VG not visible on other nodes:**
- Run `pvscan --cache` and `vgchange -ay` on each node
- Ensure plugin is installed on all nodes

---

## Comparison with iSCSI

| Feature | iSCSI | NVMe-TCP |
|---------|-------|----------|
| Protocol | SCSI over TCP | NVMe over TCP |
| Latency | Higher | Lower |
| CPU overhead | Higher | Lower |
| Multipath | dm-multipath | Native kernel |
| Queue depth | Limited | High (native NVMe) |

---

## License

MIT License - See LICENSE file for details.