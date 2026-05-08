#!/usr/bin/env bash
# setup_interfaces.sh
# Kubernetes node network setup — bonded layout (campaign: host-network-bonding F-9).
#
# Builds:
#   1. A single active-backup `bond0` NM bond connection enslaving PARENT_IF
#      (primary) and SECOND_IF (backup).
#   2. One VLAN sub-interface per entry in ALL_VLANS, stacked on bond0
#      (e.g. bond0.43), each with the per-node IP computed from the hostname.
#   3. Per-iface rp_filter override for bond0/41 + bond0/43 via the manifest
#      in network/rp_filter_per_iface.conf (delegated to
#      setup_rp_filter_per_iface.sh).
#   4. NM dispatcher that re-applies sysctl on bond0.<vlan> `up` events
#      (Component #5 / Decision D-6 in the host-network-bonding architecture
#      doc; required for reboot persistence of per-iface rp_filter).
#   5. Kubelet --node-ip pinned to the management-VLAN address on
#      bond0.<MGMT_VLAN_ID>.
#
# Configuration (all knobs) lives in network/interfaces.conf.

set -euo pipefail

# Script directory and configuration file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/interfaces.conf"

# Load configuration
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Logging functions
log() {
    printf "[$(date '+%Y-%m-%d %H:%M:%S')] %s\n" "$*" >&2
    [[ "${VERBOSE_LOGGING:-no}" == "yes" ]] && logger -t "k8s-net-setup" "$*"
}

die() {
    printf "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: %s\n" "$*" >&2
    exit 1
}

verbose_log() {
    [[ "${VERBOSE_LOGGING:-no}" == "yes" ]] && log "[VERBOSE] $*"
}

# Validate required commands
command -v nmcli >/dev/null || die "nmcli not found. Please install NetworkManager."
command -v ip >/dev/null    || die "ip command not found."

# Function to extract node information from hostname
parse_hostname() {
    local hostname="$1"
    local node_type=""
    local node_number=""

    verbose_log "Parsing hostname: $hostname"

    # Match patterns: PREFIX{worker|control-plane}[-]{##}
    if [[ "$hostname" =~ ^${HOSTNAME_PREFIX}(worker|control-plane)-?([0-9]{1,2})$ ]]; then
        node_type="${BASH_REMATCH[1]}"
        node_number="${BASH_REMATCH[2]}"

        # Extract last digit for IP calculation
        local last_digit="${node_number: -1}"

        log "Detected node type: $node_type, number: $node_number, last digit: $last_digit"

        echo "$node_type:$node_number:$last_digit"
        return 0
    else
        die "Hostname '$hostname' does not match expected pattern '${HOSTNAME_PREFIX}{worker|control-plane}[-]{##}'"
    fi
}

# Resolve the per-node primary octet for a given node type + last hostname digit.
node_primary_octet() {
    local node_type="$1"
    local last_digit="$2"
    local octet
    case "$node_type" in
        worker)        octet=$((WORKER_PRIMARY_BASE + last_digit)) ;;
        control-plane) octet=$((CONTROL_PLANE_PRIMARY_BASE + last_digit)) ;;
        *)             die "Unknown node type: $node_type" ;;
    esac
    if [[ $octet -lt 1 || $octet -gt 254 ]]; then
        die "Calculated IP octet $octet is out of valid range (1-254)"
    fi
    echo "$octet"
}

# Resolve the bond0.<vlan_id> IP/gateway/dns triple for a node.
calculate_vlan_ip_address() {
    local vlan_id="$1"
    local node_type="$2"
    local last_digit="$3"
    local octet network_cidr gateway_ip dns_ip ip

    octet="$(node_primary_octet "$node_type" "$last_digit")"

    if [[ "$vlan_id" == "$MGMT_VLAN_ID" ]]; then
        network_cidr="$MANAGEMENT_CIDR"
        gateway_ip="$GATEWAY_IP"
        dns_ip="${DNS_SERVERS%% *}"
    else
        local vlan_config="${VLAN_CONFIGS[$vlan_id]:-}"
        [[ -z "$vlan_config" ]] && die "VLAN $vlan_id not found in VLAN_CONFIGS"
        IFS=':' read -r network_cidr gateway_ip dns_ip <<< "$vlan_config"
    fi

    ip="${network_cidr//\{\}/$octet}"
    verbose_log "VLAN $vlan_id IP: $ip (gw $gateway_ip, dns $dns_ip)"
    echo "$ip:$gateway_ip:$dns_ip"
}

# NetworkManager helper functions
nm_named_devs() {
    nmcli -g NAME,DEVICE con show 2>/dev/null || true
}

nm_del_by_name() {
    local name="$1"
    if nmcli -g NAME con show 2>/dev/null | grep -qx "$name"; then
        verbose_log "Removing connection: $name"
        sudo nmcli con down "$name" 2>/dev/null || true
        sudo nmcli con del "$name" 2>/dev/null || true
        log "Removed existing connection: $name"
    fi
}

nm_del_by_device() {
    local device="$1"
    local names
    names="$(nm_named_devs | awk -F: -v dev="$device" '$2==dev{print $1}')"
    [[ -z "$names" ]] && return 0

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        verbose_log "Removing connection for device $device: $name"
        sudo nmcli con down "$name" 2>/dev/null || true
        sudo nmcli con del "$name" 2>/dev/null || true
    done <<< "$names"

    [[ -n "$names" ]] && log "Removed existing connections for device: $device"
}

# Remove any non-VLAN/non-bond NM connection bound to a physical NIC. Used to
# clear DHCP/legacy auto-connections from bond members before enslavement.
remove_non_bond_connections_on() {
    local device="$1"
    local names
    names="$(nmcli -g NAME,DEVICE,TYPE con show 2>/dev/null | \
             awk -F: -v dev="$device" '$2==dev && $3!="vlan" && $3!="bond-slave"{print $1}')"
    [[ -z "$names" ]] && return 0

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        log "Removing pre-bond connection on $device: $name"
        sudo nmcli con down "$name" 2>/dev/null || true
        sudo nmcli con del "$name" 2>/dev/null || true
    done <<< "$names"
}

# Create the bond + 2 slave connections. Idempotent: removes any existing
# connection bound to BOND_IF / PARENT_IF / SECOND_IF first, then creates fresh.
configure_bond() {
    local bond_con="bond-${BOND_IF}"
    local parent_slave_con="bond-slave-${PARENT_IF}"
    local second_slave_con="bond-slave-${SECOND_IF}"

    log "Configuring bond ${BOND_IF}: primary=${PARENT_IF}, backup=${SECOND_IF}"

    # Tear down any prior bond / VLAN / DHCP connections on the three devices.
    nm_del_by_device "$BOND_IF"
    for vlan_id in "${ALL_VLANS[@]}"; do
        nm_del_by_device "${BOND_IF}.${vlan_id}"
        nm_del_by_device "${PARENT_IF}.${vlan_id}"
        nm_del_by_device "${SECOND_IF}.${vlan_id}"
    done
    nm_del_by_name "$bond_con"
    nm_del_by_name "$parent_slave_con"
    nm_del_by_name "$second_slave_con"
    remove_non_bond_connections_on "$PARENT_IF"
    remove_non_bond_connections_on "$SECOND_IF"

    local bond_options="mode=${BOND_MODE},miimon=${BOND_MIIMON},primary=${PARENT_IF},fail_over_mac=${BOND_FAIL_OVER_MAC},num_grat_arp=${BOND_NUM_GRAT_ARP},primary_reselect=${BOND_PRIMARY_RESELECT}"

    sudo nmcli con add type bond ifname "$BOND_IF" con-name "$bond_con" \
        bond.options "$bond_options" \
        ipv4.method disabled ipv6.method ignore connection.autoconnect yes

    sudo nmcli con add type ethernet ifname "$PARENT_IF" \
        con-name "$parent_slave_con" master "$BOND_IF" slave-type bond \
        connection.autoconnect yes

    sudo nmcli con add type ethernet ifname "$SECOND_IF" \
        con-name "$second_slave_con" master "$BOND_IF" slave-type bond \
        connection.autoconnect yes

    sudo nmcli con up "$parent_slave_con" || die "Failed to bring up $parent_slave_con"
    sudo nmcli con up "$second_slave_con" || die "Failed to bring up $second_slave_con"
    sudo nmcli con up "$bond_con"         || die "Failed to bring up $bond_con"

    log "Bond ${BOND_IF} active: primary=${PARENT_IF}, backup=${SECOND_IF}"
}

# Create one VLAN sub-interface on bond0 with a single static IP.
configure_bond_vlan() {
    local vlan_id="$1"
    local ip_address="$2"
    local gateway_ip="$3"
    local dns_ip="$4"
    local is_mgmt_vlan="$5"

    local vlan_dev="${BOND_IF}.${vlan_id}"
    local vlan_con="vlan${vlan_id}-${BOND_IF}"

    log "Configuring VLAN $vlan_id on $BOND_IF: $vlan_dev = $ip_address"

    nm_del_by_name "$vlan_con"
    nm_del_by_device "$vlan_dev"

    sudo nmcli con add type vlan ifname "$vlan_dev" dev "$BOND_IF" id "$vlan_id" \
        con-name "$vlan_con" ip4 "$ip_address"

    sudo nmcli con mod "$vlan_con" \
        ipv4.method manual ipv6.method ignore \
        ipv4.dns "$dns_ip" connection.autoconnect yes

    if [[ "$is_mgmt_vlan" == "yes" ]]; then
        sudo nmcli con mod "$vlan_con" gw4 "$gateway_ip"
        verbose_log "Set gateway $gateway_ip for management VLAN $vlan_id"
    else
        verbose_log "Skipping gateway for non-management VLAN $vlan_id"
    fi

    if ! sudo nmcli con up "$vlan_con"; then
        die "Failed to bring up $vlan_con with IP $ip_address. Check for IP conflicts."
    fi

    verbose_log "Successfully configured $vlan_con"
}

# Install the NM dispatcher that re-applies per-iface sysctl on bond0.<vlan> up.
# Component #5 / Decision D-6 in docs/host-network-bonding/ARCHITECTURE_AND_DESIGN.md:
# NM creates bond0.<vlan> children after the systemd sysctl pass at boot, so
# per-iface keys would otherwise miss those interfaces. Idempotent.
install_nm_dispatcher() {
    local target="/etc/NetworkManager/dispatcher.d/99-occ-vlan-rp_filter"

    log "Installing NM dispatcher: $target"
    sudo tee "$target" >/dev/null << 'EOF'
#!/bin/bash
# OCC bonding campaign — re-apply per-iface rp_filter on bond0.* up events
# Component #5 (Architecture doc §Component Inventory)
# Decision D-6 (Architecture doc §Design Decisions)
# Why: per-iface sysctl keys apply only when the named iface exists at
# sysctl-read time. NM creates bond0.<vlan> children during boot/connection
# bounce, after the systemd sysctl pass. Re-apply on every bond0.* `up` event.
[[ "$2" != "up" ]] && exit 0
[[ "$1" =~ ^bond0\.[0-9]+$ ]] || exit 0
sysctl -p /etc/sysctl.d/99-occ-vlan-rp_filter.conf >/dev/null 2>&1 || true
exit 0
EOF
    sudo chown root:root "$target"
    sudo chmod 0755 "$target"

    log "✓ NM dispatcher installed at $target"
}

# Remove any pre-bonding rp_filter sysctl drop-in. Architecture doc forbids
# all.* / default.* rp_filter flips; only per-iface keys (managed by
# setup_rp_filter_per_iface.sh) are valid sustainment.
purge_legacy_rp_filter_dropin() {
    local legacy="/etc/sysctl.d/99-vlan-routing-rp_filter.conf"
    if [[ -f "$legacy" ]]; then
        log "Removing legacy rp_filter drop-in (forbids all/default flips): $legacy"
        sudo rm -f "$legacy"
    fi
}

# Main execution
main() {
    log "Starting Kubernetes node network configuration (bonded layout)"
    log "Using configuration file: $CONFIG_FILE"

    # Get hostname and parse node information
    local hostname
    hostname="$(hostname -s)"
    log "Current hostname: $hostname"

    local node_info
    node_info="$(parse_hostname "$hostname")"
    IFS=':' read -r node_type node_number last_digit <<< "$node_info"

    log "Node configuration: Type=$node_type, Number=$node_number"

    # Ensure VLAN + bonding kernel support
    verbose_log "Loading 8021q kernel module"
    sudo modprobe 8021q || log "Warning: Could not load 8021q module (may already be loaded)"
    verbose_log "Loading bonding kernel module"
    sudo modprobe bonding || log "Warning: Could not load bonding module (may already be loaded)"

    # Stage 1: bond + slaves
    configure_bond

    # Stage 2: 6 VLAN sub-interfaces on bond0
    log "Configuring VLANs on $BOND_IF: ${ALL_VLANS[*]}"

    declare -A configured_vlans
    for vlan_id in "${ALL_VLANS[@]}"; do
        local vlan_info
        vlan_info="$(calculate_vlan_ip_address "$vlan_id" "$node_type" "$last_digit")"
        IFS=':' read -r ip_address gateway_ip dns_ip <<< "$vlan_info"

        local is_mgmt_vlan="no"
        [[ "$vlan_id" == "$MGMT_VLAN_ID" ]] && is_mgmt_vlan="yes"

        if [[ "$is_mgmt_vlan" == "yes" ]]; then
            log "Configuring MANAGEMENT VLAN $vlan_id - $BOND_IF.$vlan_id = $ip_address (kubelet --node-ip)"
        else
            log "Configuring VLAN $vlan_id - $BOND_IF.$vlan_id = $ip_address"
        fi

        configure_bond_vlan "$vlan_id" "$ip_address" "$gateway_ip" "$dns_ip" "$is_mgmt_vlan"
        configured_vlans[$vlan_id]="$ip_address"
    done

    # Stage 3: rp_filter sustainment
    purge_legacy_rp_filter_dropin

    # Stage 4: NM dispatcher (rp_filter persistence on bond0.<vlan> up)
    install_nm_dispatcher

    # Stage 5: per-iface rp_filter manifest application
    if [[ -f "${SCRIPT_DIR}/setup_rp_filter_per_iface.sh" ]]; then
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/setup_rp_filter_per_iface.sh"
        setup_rp_filter_per_iface_main
    else
        die "setup_rp_filter_per_iface.sh missing — per-iface rp_filter override cannot be applied"
    fi

    # Stage 6: result display
    echo
    echo "========================================="
    echo "Network Configuration Complete"
    echo "========================================="
    echo
    echo "Bond device ($BOND_IF):"
    if ip link show "$BOND_IF" &>/dev/null; then
        ip -d link show "$BOND_IF" | sed 's/^/  /'
    else
        echo "  (not found)"
    fi
    echo
    echo "VLAN sub-interfaces on $BOND_IF:"
    for vlan_id in "${ALL_VLANS[@]}"; do
        local vlan_dev="${BOND_IF}.${vlan_id}"
        if ip -4 addr show "$vlan_dev" &>/dev/null; then
            echo "  VLAN $vlan_id (${configured_vlans[$vlan_id]}):"
            ip -4 addr show "$vlan_dev" | grep inet | sed 's/^/    /'
        else
            echo "  VLAN $vlan_id: Interface not found"
        fi
    done
    echo
    echo "Default Route:"
    ip route show default | head -n 1 | sed 's/^/  /' || echo "  No default route found"
    echo
    echo "========================================="
    echo "Configuration Summary:"
    echo "========================================="
    echo "• Node type: $node_type"
    echo "• Bond: $BOND_IF (mode=$BOND_MODE primary=$PARENT_IF backup=$SECOND_IF)"
    echo "• Management VLAN: $MGMT_VLAN_ID (${MANAGEMENT_CIDR})"
    echo "• Management IP (for K8s): ${configured_vlans[$MGMT_VLAN_ID]} on $BOND_IF.$MGMT_VLAN_ID"
    echo "• Management gateway: $GATEWAY_IP"
    echo "• Kubernetes NODE IP: ${configured_vlans[$MGMT_VLAN_ID]%/*} (kubelet --node-ip)"
    echo "• Kubelet auto-config: ${KUBELET_AUTO_CONFIG:-yes} (via /etc/sysconfig/kubelet)"
    echo "• All VLANs configured on $BOND_IF: ${ALL_VLANS[*]}"
    echo "• rp_filter: per-iface override on bond0/41 + bond0/43 (no all.*/default.* flips)"
    echo
    echo "VLAN IP Assignments:"
    for vlan_id in "${ALL_VLANS[@]}"; do
        echo "  VLAN $vlan_id: ${configured_vlans[$vlan_id]}"
    done
    echo

    # Stage 7: kubelet --node-ip
    if [[ "${KUBELET_AUTO_CONFIG:-yes}" == "yes" ]]; then
        configure_kubelet_node_ip "$node_type" "$last_digit"
    else
        verbose_log "Kubelet auto-configuration disabled (KUBELET_AUTO_CONFIG=no)"
    fi

    log "Network configuration completed successfully"
}

# Function to configure kubelet with the management VLAN IP using sysconfig method
configure_kubelet_node_ip() {
    local node_type="$1"
    local last_digit="$2"

    if ! command -v kubelet >/dev/null 2>&1; then
        verbose_log "Kubelet not found, skipping kubelet configuration"
        return 0
    fi

    local octet management_ip node_ip
    octet="$(node_primary_octet "$node_type" "$last_digit")"
    management_ip="${MANAGEMENT_CIDR//\{\}/$octet}"
    node_ip="${management_ip%/*}"

    log "Configuring kubelet --node-ip = $node_ip (bond0.$MGMT_VLAN_ID)"

    local sysconfig_file="/etc/sysconfig/kubelet"

    if [[ -f "$sysconfig_file" ]]; then
        local backup_file="${sysconfig_file}.backup-$(date +%Y%m%d-%H%M%S)"
        sudo cp "$sysconfig_file" "$backup_file"
        verbose_log "Backed up existing $sysconfig_file to $backup_file"
    fi

    cat << EOF | sudo tee "$sysconfig_file" >/dev/null
# Kubernetes kubelet configuration
# This file is sourced by systemd kubelet service via kubeadm
KUBELET_EXTRA_ARGS="--node-ip=$node_ip"
EOF

    log "✓ Updated $sysconfig_file with node-ip: $node_ip"

    local systemd_node_ip_file="/etc/systemd/system/kubelet.service.d/11-node-ip.conf"
    if [[ -f "$systemd_node_ip_file" ]]; then
        sudo rm "$systemd_node_ip_file"
        log "Removed conflicting systemd environment file: $systemd_node_ip_file"
    fi

    sudo systemctl daemon-reload
    verbose_log "Reloaded systemd configuration"

    if sudo systemctl is-active kubelet >/dev/null 2>&1; then
        log "Restarting kubelet service with new node-ip"
        sudo systemctl restart kubelet

        sleep 5
        if sudo systemctl is-active kubelet >/dev/null 2>&1; then
            log "✓ Kubelet successfully restarted with node-ip: $node_ip"

            sleep 2
            if ps aux | grep kubelet | grep -v grep | grep -q -- "--node-ip=$node_ip"; then
                log "✓ VERIFIED: kubelet process is using --node-ip=$node_ip"
            else
                log "⚠ Warning: --node-ip may not be visible yet in process, check in 1-2 minutes"
            fi
        else
            log "❌ Warning: Kubelet may have failed to restart. Check: systemctl status kubelet"
        fi
    else
        log "Kubelet not currently running, configuration will apply on next start"
    fi

    echo
    echo "Kubelet Configuration (SYSCONFIG METHOD):"
    echo "• Node IP: $node_ip (on bond0.$MGMT_VLAN_ID)"
    echo "• Configuration method: /etc/sysconfig/kubelet (kubeadm standard)"
    echo "• To verify: kubectl get nodes -o wide (from control plane)"
    echo
}

# Verify we're running as root or with sudo
if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
    die "This script requires root privileges. Please run with sudo."
fi

# Execute main function
main "$@"
