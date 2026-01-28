package PVE::Storage::Custom::NVMeTCPPlugin;

use strict;
use warnings;

use File::stat;
use IO::Dir;
use IO::File;
use File::Path qw(make_path);

use PVE::JSONSchema qw(get_standard_option);
use PVE::Storage::Plugin;
use PVE::Tools qw(run_command file_read_firstline trim dir_glob_regex dir_glob_foreach);

use base qw(PVE::Storage::Plugin);

# Command paths
my $NVME_CLI = '/usr/sbin/nvme';

# API Version for plugin compatibility
# See https://git.proxmox.com/?p=pve-storage.git;a=blob;f=ApiChangeLog
use constant APIVER => 13;
use constant APIAGE => 0;

sub api {
    return APIVER;
}

sub apiage {
    return APIAGE;
}

my $found_nvme_cli;
sub assert_nvme_support {
    my ($noerr) = @_;
    return $found_nvme_cli if $found_nvme_cli;

    $found_nvme_cli = -x $NVME_CLI;

    if (!$found_nvme_cli) {
        die "error: no nvme support - please install nvme-cli\n" if !$noerr;
        warn "warning: no nvme support - please install nvme-cli\n";
    }
    return $found_nvme_cli;
}

# Get hostnqn from system
sub get_hostnqn {
    my $hostnqn = file_read_firstline('/etc/nvme/hostnqn');
    if (!$hostnqn || $hostnqn eq '') {
        # Try to generate one
        eval {
            run_command([$NVME_CLI, 'gen-hostnqn'], outfunc => sub { $hostnqn = shift; });
        };
    }
    return $hostnqn;
}

# Discover NVMe-TCP targets (returns list of discovered subsystems)
sub nvme_discover {
    my ($portal, $port) = @_;

    assert_nvme_support();
    $port //= 8009;  # Default NVMe-TCP port

    my $targets = {};
    my $cmd = [$NVME_CLI, 'discover', '-t', 'tcp', '-a', $portal, '-s', $port];

    eval {
        my @output_lines;
        run_command(
            $cmd,
            outfunc => sub { push @output_lines, shift; },
            errfunc => sub { },  # Suppress stderr
        );

        # Parse text output (more reliable than JSON across nvme-cli versions)
        my $current_rec = {};
        for my $line (@output_lines) {
            if ($line =~ /subnqn:\s*(\S+)/) {
                $current_rec->{subnqn} = $1;
            } elsif ($line =~ /traddr:\s*(\S+)/) {
                $current_rec->{traddr} = $1;
            } elsif ($line =~ /trsvcid:\s*(\S+)/) {
                $current_rec->{trsvcid} = $1;
            } elsif ($line =~ /trtype:\s*(\S+)/) {
                $current_rec->{transport} = $1;
            }

            # When we have a complete record, save it
            if ($current_rec->{subnqn} && $current_rec->{traddr}) {
                $targets->{$current_rec->{subnqn}} = { %$current_rec };
                $current_rec = {};
            }
        }
    };
    warn $@ if $@;

    return $targets;
}

# Get IPv4 address assigned to a network interface
sub get_iface_ip {
    my ($iface) = @_;

    return undef if !$iface;

    # Try reading from /sys/class/net/<iface>/...
    # Use 'ip' command to get the address
    my $ip = undef;
    eval {
        my $output = '';
        run_command(
            ['ip', '-4', '-o', 'addr', 'show', $iface],
            outfunc => sub { $output .= shift; },
            errfunc => sub { },
            noerr => 1,
        );
        # Parse: "2: eth0    inet 192.168.1.10/24 brd ..."
        if ($output =~ /inet\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/) {
            $ip = $1;
        }
    };

    return $ip;
}

# Connect to NVMe-TCP subsystem with options
sub nvme_connect {
    my ($subnqn, $portals, $options) = @_;

    assert_nvme_support();

    my $multipath = $options->{multipath} // 1;
    my $iopolicy = $options->{iopolicy} // 'queue-depth';
    my $ctrl_loss_tmo = $options->{ctrl_loss_tmo} // 1800;
    my $reconnect_delay = $options->{reconnect_delay} // 10;
    my $host_ifaces = $options->{host_iface} ? [ split(/,/, $options->{host_iface}) ] : [];
    my $host_traddrs = $options->{host_traddr} ? [ split(/,/, $options->{host_traddr}) ] : [];

    # Enable native multipath if requested
    if ($multipath) {
        my $mp_file = '/sys/module/nvme_core/parameters/multipath';
        if (-e $mp_file && -w $mp_file) {
            my $current = file_read_firstline($mp_file);
            if ($current ne 'Y') {
                eval {
                    my $fh = IO::File->new($mp_file, 'w');
                    if ($fh) {
                        print $fh "Y\n";
                        $fh->close();
                    }
                };
                warn "Could not enable NVMe multipath: $@" if $@;
            }
        }
    }

    # Build connection matrix: each portal with each interface/address combination
    # This creates full mesh for proper multipath
    for my $portal (@$portals) {
        my ($addr, $port) = split(/:/, $portal);
        $port //= 8009;

        # If host interfaces/addresses are specified, connect from each one
        # Otherwise, connect once without specifying host interface
        my @iface_pairs;
        if (@$host_ifaces) {
            # For each interface, get the IP if not explicitly provided
            for (my $i = 0; $i < scalar(@$host_ifaces); $i++) {
                my $iface = $host_ifaces->[$i];
                my $traddr;

                # Use explicit traddr if provided, otherwise auto-detect from interface
                if (@$host_traddrs && $i < scalar(@$host_traddrs)) {
                    $traddr = $host_traddrs->[$i];
                } else {
                    $traddr = get_iface_ip($iface);
                    if (!$traddr) {
                        warn "Could not get IP address for interface $iface, skipping\n";
                        next;
                    }
                }
                push @iface_pairs, { iface => $iface, traddr => $traddr };
            }
        } elsif (@$host_traddrs) {
            # Only traddrs specified (no interfaces)
            for my $traddr (@$host_traddrs) {
                push @iface_pairs, { iface => undef, traddr => $traddr };
            }
        } else {
            # No host interfaces specified, connect without them
            push @iface_pairs, { iface => undef, traddr => undef };
        }

        # Connect from each host interface to this portal
        for my $pair (@iface_pairs) {
            my @cmd = (
                $NVME_CLI, 'connect',
                '-t', 'tcp',
                '-n', $subnqn,
                '-a', $addr,
                '-s', $port,
                '--ctrl-loss-tmo=' . $ctrl_loss_tmo,
                '--reconnect-delay=' . $reconnect_delay,
            );

            # Add host interface if specified
            if ($pair->{iface}) {
                push @cmd, '--host-iface=' . $pair->{iface};
            }

            # Add host transport address if specified
            if ($pair->{traddr}) {
                push @cmd, '--host-traddr=' . $pair->{traddr};
            }

            eval { run_command(\@cmd); };
            if ($@) {
                my $path_desc = $pair->{iface} ? " via $pair->{iface}" : "";
                $path_desc .= $pair->{traddr} ? " ($pair->{traddr})" : "";
                warn "NVMe connect to $portal$path_desc failed: $@";
            }
        }
    }

    # Set IO policy if multipath is enabled
    if ($multipath) {
        set_iopolicy($subnqn, $iopolicy);
    }
}

# Disconnect from NVMe subsystem
sub nvme_disconnect {
    my ($subnqn) = @_;

    assert_nvme_support();
    run_command([$NVME_CLI, 'disconnect', '-n', $subnqn]);
}

# Rescan NVMe subsystem for new namespaces
# Call this after adding new namespaces on the storage target
sub nvme_rescan {
    my ($subnqn) = @_;

    assert_nvme_support();

    # Find all controllers for this subsystem and rescan them
    my $subsys_path = "/sys/class/nvme-subsystem";
    my @controllers;

    dir_glob_foreach($subsys_path, 'nvme-subsys(\d+)', sub {
        my ($dir, $num) = @_;
        my $nqn = file_read_firstline("$subsys_path/$dir/subsysnqn");
        if ($nqn && $nqn eq $subnqn) {
            # Find all controller devices under this subsystem
            dir_glob_foreach("$subsys_path/$dir", 'nvme\d+$', sub {
                my ($ctrl) = @_;
                push @controllers, $ctrl;
            });
        }
    });

    # Rescan each controller
    for my $ctrl (@controllers) {
        my $rescan_path = "/sys/class/nvme/$ctrl/rescan_controller";
        if (-w $rescan_path) {
            eval {
                my $fh = IO::File->new($rescan_path, 'w');
                if ($fh) {
                    print $fh "1\n";
                    $fh->close();
                }
            };
            warn "Failed to rescan controller $ctrl: $@" if $@;
        }
    }

    # Wait for new devices to settle
    sleep(2);

    return scalar(@controllers);
}

# Count how many storages in the config use a given NVMe subsystem NQN
# This is used to determine if we should disconnect when removing a storage
sub count_storages_using_subsystem {
    my ($subnqn, $exclude_storeid) = @_;

    my $count = 0;

    # Read storage config
    my $cfg_file = '/etc/pve/storage.cfg';
    return 0 unless -f $cfg_file;

    my $raw = PVE::Tools::file_get_contents($cfg_file);
    my @lines = split(/\n/, $raw);

    my $current_storeid;
    my $current_type;

    for my $line (@lines) {
        # Match section headers like "nvmetcp: storagename"
        if ($line =~ m/^(\S+):\s*(\S+)\s*$/) {
            $current_type = $1;
            $current_storeid = $2;
        }
        # Match nvme_subnqn property
        elsif ($line =~ m/^\s+nvme_subnqn\s+(\S+)/) {
            my $nqn = $1;
            if ($current_type eq 'nvmetcp' &&
                $nqn eq $subnqn &&
                (!$exclude_storeid || $current_storeid ne $exclude_storeid)) {
                $count++;
            }
        }
    }

    return $count;
}

# Set IO policy for NVMe multipath
sub set_iopolicy {
    my ($subnqn, $policy) = @_;

    # Valid policies: round-robin, numa, queue-depth
    my $valid_policies = { 'round-robin' => 1, 'numa' => 1, 'queue-depth' => 1 };
    $policy = 'queue-depth' unless $valid_policies->{$policy};

    my $subsys_path = "/sys/class/nvme-subsystem";
    dir_glob_foreach($subsys_path, 'nvme-subsys(\d+)', sub {
        my ($dir, $num) = @_;
        my $nqn = file_read_firstline("$subsys_path/$dir/subsysnqn");
        if ($nqn && $nqn eq $subnqn) {
            my $policy_file = "$subsys_path/$dir/iopolicy";
            if (-w $policy_file) {
                eval {
                    my $fh = IO::File->new($policy_file, 'w');
                    if ($fh) {
                        print $fh "$policy\n";
                        $fh->close();
                    }
                };
                warn "Could not set IO policy: $@" if $@;
            }
        }
    });
}

# Get NVMe device path(s) for subsystem
# Returns first device in scalar context, all devices in list context
sub get_nvme_device {
    my ($subnqn) = @_;

    my @devices;
    my $subsys_path = "/sys/class/nvme-subsystem";

    dir_glob_foreach($subsys_path, 'nvme-subsys(\d+)', sub {
        my ($dir, $num) = @_;
        my $nqn = file_read_firstline("$subsys_path/$dir/subsysnqn");
        if ($nqn && $nqn eq $subnqn) {
            # Look for nvme namespace devices (nvmeXnY)
            # Note: A subsystem can have multiple namespaces (LUNs)
            dir_glob_foreach("$subsys_path/$dir", 'nvme\d+n\d+', sub {
                my ($dev) = @_;
                push @devices, "/dev/$dev";
            });
        }
    });

    # Return first device in scalar context for backward compatibility
    return wantarray ? @devices : $devices[0];
}

# Get all NVMe namespaces for a subsystem (returns list of device paths)
sub get_nvme_namespaces {
    my ($subnqn) = @_;
    return get_nvme_device($subnqn);  # list context
}

# Check if subsystem is connected with at least one controller path
sub is_connected {
    my ($subnqn) = @_;

    my $connected = 0;
    my $subsys_path = "/sys/class/nvme-subsystem";

    dir_glob_foreach($subsys_path, 'nvme-subsys(\d+)', sub {
        my ($dir, $num) = @_;
        my $nqn = file_read_firstline("$subsys_path/$dir/subsysnqn");
        if ($nqn && $nqn eq $subnqn) {
            # Check if there are actual controller paths connected
            # Look for nvmeX directories under the subsystem
            my $has_controllers = 0;
            dir_glob_foreach("$subsys_path/$dir", 'nvme\d+$', sub {
                my ($ctrl) = @_;
                # Check if controller is in 'live' state
                my $state = file_read_firstline("$subsys_path/$dir/$ctrl/state");
                $has_controllers = 1 if ($state && $state eq 'live');
            });
            $connected = 1 if $has_controllers;
        }
    });

    return $connected;
}

# Plugin type
sub type {
    return 'nvmetcp';
}

# Plugin properties - expose namespaces as images like iSCSI does with LUNs
sub plugindata {
    return {
        content => [ { images => 1, none => 1 }, { images => 1 } ],
    };
}

# Plugin configuration properties (use nvme_ prefix to avoid conflicts with other plugins)
sub properties {
    return {
        nvme_portal => {
            description => "NVMe-TCP portal address(es), comma-separated for multipath",
            type => 'string',
        },
        nvme_subnqn => {
            description => "NVMe subsystem NQN",
            type => 'string',
        },
        nvme_host_iface => {
            description => "Host network interface(s) for NVMe-TCP connections, comma-separated (e.g., 'eth0,eth1')",
            type => 'string',
        },
        nvme_host_traddr => {
            description => "Host transport address(es)/IP(s) for NVMe-TCP connections, comma-separated. Optional - if nvme_host_iface is set, IPs are auto-detected from the interfaces.",
            type => 'string',
        },
        nvme_multipath => {
            description => "Enable NVMe native multipathing",
            type => 'boolean',
            default => 1,
        },
        nvme_iopolicy => {
            description => "NVMe multipath IO policy",
            type => 'string',
            enum => ['round-robin', 'numa', 'queue-depth'],
            default => 'queue-depth',
        },
        nvme_ctrl_loss_tmo => {
            description => "Controller loss timeout in seconds",
            type => 'integer',
            minimum => 0,
            maximum => 86400,
            default => 1800,
        },
        nvme_reconnect_delay => {
            description => "Reconnect delay in seconds",
            type => 'integer',
            minimum => 1,
            maximum => 600,
            default => 10,
        },
    };
}

# Plugin options - connection management only
sub options {
    return {
        nvme_portal => { fixed => 1 },
        nvme_subnqn => { fixed => 1 },
        nodes => { optional => 1 },
        disable => { optional => 1 },
        content => { optional => 1 },
        nvme_multipath => { optional => 1 },
        nvme_iopolicy => { optional => 1 },
        nvme_host_iface => { optional => 1 },
        nvme_host_traddr => { optional => 1 },
        nvme_ctrl_loss_tmo => { optional => 1 },
        nvme_reconnect_delay => { optional => 1 },
        shared => { optional => 1 },
    };
}

# Called when storage is added - just validate NVMe connection parameters
sub on_add_hook {
    my ($class, $storeid, $scfg, %param) = @_;

    # Validate required parameters exist
    my $subnqn = $scfg->{nvme_subnqn}
        or die "nvme_subnqn is required\n";
    my $portal = $scfg->{nvme_portal}
        or die "nvme_portal is required\n";

    return;
}

# Called when storage is deleted - disconnect NVMe if no other storages use the subsystem
sub on_delete_hook {
    my ($class, $storeid, $scfg) = @_;

    my $subnqn = $scfg->{nvme_subnqn};

    # Check if other storages still use this subsystem
    my $other_users = count_storages_using_subsystem($subnqn, $storeid);

    if ($other_users > 0) {
        # Other storages still use this subsystem, don't disconnect
        return;
    }

    # Disconnect the NVMe subsystem if this was the last user
    if (is_connected($subnqn)) {
        eval { nvme_disconnect($subnqn); };
        warn "Failed to disconnect NVMe subsystem $subnqn: $@" if $@;
    }

    return;
}

# Parse portal string into array
sub parse_portals {
    my ($portal_str) = @_;
    return [ split(/,/, $portal_str) ];
}

# Activate storage - connect to NVMe target
sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    assert_nvme_support();

    my $subnqn = $scfg->{nvme_subnqn};
    my $portals = parse_portals($scfg->{nvme_portal});
    my $iopolicy = $scfg->{nvme_iopolicy} // 'queue-depth';

    # Connect if not already connected
    if (!is_connected($subnqn)) {
        nvme_connect($subnqn, $portals, {
            multipath => $scfg->{nvme_multipath} // 1,
            iopolicy => $iopolicy,
            ctrl_loss_tmo => $scfg->{nvme_ctrl_loss_tmo} // 1800,
            reconnect_delay => $scfg->{nvme_reconnect_delay} // 10,
            host_iface => $scfg->{nvme_host_iface},
            host_traddr => $scfg->{nvme_host_traddr},
        });

        # Wait for NVMe device to appear and settle
        my $waited = 0;
        my $max_wait = 10;
        while ($waited < $max_wait) {
            # Check if any NVMe namespace appeared
            my @nvme_devs = glob("/dev/nvme*n*");
            last if @nvme_devs;
            sleep(1);
            $waited++;
        }

        # Additional settle time for device mapper / multipath
        sleep(1);
    } else {
        # Already connected - ensure iopolicy is set correctly
        if ($scfg->{nvme_multipath} // 1) {
            set_iopolicy($subnqn, $iopolicy);
        }
    }

    return 1;
}

# Deactivate storage - connection stays up, managed by on_delete_hook
sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # We don't disconnect NVMe as other storages might use it
    # Disconnection is handled by on_delete_hook or systemd service
    return 1;
}

# Get storage status - just report connection status
sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $subnqn = $scfg->{nvme_subnqn};

    # Check if connected
    if (!is_connected($subnqn)) {
        return (0, 0, 0, 0);  # Not active
    }

    # Connection-only storage - report active but no capacity info
    return (0, 0, 0, 1);
}

# Get list of NVMe namespaces for a subsystem (like iSCSI LUNs)
sub nvme_namespace_list {
    my ($subnqn) = @_;

    my $res = {};

    # Find subsystems matching our NQN
    for my $subsys_path (glob("/sys/class/nvme-subsystem/nvme-subsys*")) {
        my $subsys_nqn = file_read_firstline("$subsys_path/subsysnqn") // '';
        next if $subsys_nqn ne $subnqn;

        # Find all namespaces in this subsystem
        for my $ns_link (glob("$subsys_path/nvme*n*")) {
            next if !-l $ns_link;
            my $ns_name = $ns_link;
            $ns_name =~ s|.*/||;

            # Skip controller entries (nvmeX), only want namespaces (nvmeXnY)
            next if $ns_name !~ /^nvme\d+n\d+$/;

            # Get size from sysfs
            my $size_file = "/sys/class/block/$ns_name/size";
            my $size_sectors = file_read_firstline($size_file) // 0;
            my $size = $size_sectors * 512;  # Convert sectors to bytes

            # Use wwid or nguid for stable identification if available
            my $wwid = file_read_firstline("/sys/class/block/$ns_name/wwid") // '';
            my $nguid = file_read_firstline("/sys/class/block/$ns_name/nguid") // '';

            my $volname = $ns_name;
            if ($wwid) {
                $wwid =~ s/\s+//g;
                $volname = "wwid-$wwid" if $wwid;
            } elsif ($nguid && $nguid !~ /^0+$/) {
                $nguid =~ s/\s+//g;
                $volname = "nguid-$nguid";
            }

            $res->{$volname} = {
                format => 'raw',
                size => $size,
                vmid => 0,  # Not assigned to any VM
                devname => $ns_name,
            };
        }
    }

    return $res;
}

# Parse volume name (namespace identifier)
sub parse_volname {
    my ($class, $volname) = @_;

    # Format: nvmeXnY or wwid-xxx or nguid-xxx
    if ($volname =~ m/^(nvme\d+n\d+|wwid-\S+|nguid-\S+)$/) {
        return ('images', $volname, undef, undef, undef, undef, 'raw');
    }

    die "unable to parse nvme volume name '$volname'\n";
}

# Get filesystem path for volume (namespace)
sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    die "snapshots not supported on nvme-tcp storage\n" if defined($snapname);

    my $path;
    if ($volname =~ /^nvme\d+n\d+$/) {
        $path = "/dev/$volname";
    } elsif ($volname =~ /^wwid-(.+)$/) {
        $path = "/dev/disk/by-id/nvme-$1";
    } elsif ($volname =~ /^nguid-(.+)$/) {
        $path = "/dev/disk/by-id/nvme-$1";
    } else {
        die "cannot determine path for volume '$volname'\n";
    }

    return wantarray ? ($path, undef, 'images') : $path;
}

# List all namespaces as images (like iSCSI lists LUNs)
sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $res = [];
    my $subnqn = $scfg->{nvme_subnqn};

    return $res if !is_connected($subnqn);

    my $namespaces = nvme_namespace_list($subnqn);

    for my $volname (keys %$namespaces) {
        my $info = $namespaces->{$volname};
        my $volid = "$storeid:$volname";

        if ($vollist) {
            my $found = grep { $_ eq $volid } @$vollist;
            next if !$found;
        } else {
            # We have no owner for raw namespaces
            next if defined($vmid);
        }

        push @$res, {
            volid => $volid,
            format => 'raw',
            size => $info->{size},
            vmid => 0,
            content => 'images',
        };
    }

    return $res;
}

# Override list_volumes to always return namespaces regardless of content type
sub list_volumes {
    my ($class, $storeid, $scfg, $vmid, $content_types) = @_;

    my $res = $class->list_images($storeid, $scfg, $vmid);

    for my $item (@$res) {
        $item->{content} = 'images';
    }

    return $res;
}

# Cannot allocate - namespaces are managed by the storage target
sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;
    die "cannot allocate space on nvme-tcp storage - namespaces are managed by the storage target\n";
}

# Cannot free - namespaces are managed by the storage target
sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;
    die "cannot free space on nvme-tcp storage - namespaces are managed by the storage target\n";
}

# Volume features
sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    my $features = {
        copy => { current => 1 },
    };

    my $key = 'current';
    return 1 if $features->{$feature}->{$key};

    return undef;
}

1;

