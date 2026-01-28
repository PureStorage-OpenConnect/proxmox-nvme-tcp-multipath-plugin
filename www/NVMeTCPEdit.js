/*
 * NVMe-TCP Storage Plugin GUI for Proxmox VE
 * This file is appended to pvemanagerlib.js by install-gui.sh
 */

// Register NVMe-TCP in the storage schema (for Add menu and type display)
PVE.Utils.storageSchema.nvmetcp = {
    name: 'NVMe-TCP',
    ipanel: 'NVMeTCPInputPanel',
    faIcon: 'building',
    backups: false,
};

// Input panel for NVMe-TCP storage configuration
Ext.define('PVE.storage.NVMeTCPInputPanel', {
    extend: 'PVE.panel.StorageBase',
    mixins: ['Proxmox.Mixin.CBind'],

    onGetValues: function(values) {
        let me = this;

        // Remove empty optional fields so they don't get sent to the API
        if (!values.nvme_host_iface || values.nvme_host_iface === '') {
            delete values.nvme_host_iface;
        }
        if (!values.nvme_host_traddr || values.nvme_host_traddr === '') {
            delete values.nvme_host_traddr;
        }
        if (!values.nvme_iopolicy || values.nvme_iopolicy === '') {
            delete values.nvme_iopolicy;
        }

        return me.callParent([values]);
    },

    column1: [
        {
            xtype: 'pmxDisplayEditField',
            cbind: {
                editable: '{isCreate}',
            },
            name: 'nvme_portal',
            fieldLabel: gettext('Portal(s)'),
            emptyText: '192.168.1.100:8009',
            allowBlank: false,
        },
        {
            xtype: 'pmxDisplayEditField',
            cbind: {
                editable: '{isCreate}',
            },
            name: 'nvme_subnqn',
            fieldLabel: gettext('Subsystem NQN'),
            emptyText: 'nqn.2024-01.com.example:storage',
            allowBlank: false,
        },
    ],

    column2: [
        {
            xtype: 'proxmoxcheckbox',
            name: 'shared',
            checked: true,
            uncheckedValue: 0,
            fieldLabel: gettext('Shared'),
        },
        {
            xtype: 'proxmoxcheckbox',
            name: 'nvme_multipath',
            checked: true,
            uncheckedValue: 0,
            fieldLabel: gettext('Multipath'),
        },
        {
            xtype: 'proxmoxKVComboBox',
            name: 'nvme_iopolicy',
            fieldLabel: gettext('IO Policy'),
            value: 'queue-depth',
            comboItems: [
                ['round-robin', 'Round Robin'],
                ['numa', 'NUMA'],
                ['queue-depth', 'Queue Depth'],
            ],
            allowBlank: true,
        },
        {
            xtype: 'textfield',
            name: 'nvme_host_iface',
            fieldLabel: gettext('Host Interface(s)'),
            emptyText: 'eth0,eth1',
            allowBlank: true,
            submitEmptyText: false,
        },
        {
            xtype: 'textfield',
            name: 'nvme_host_traddr',
            fieldLabel: gettext('Host Address(es)'),
            emptyText: '192.168.1.10,192.168.1.11',
            allowBlank: true,
            submitEmptyText: false,
        },
    ],
});

