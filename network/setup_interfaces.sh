#!/usr/bin/env bash
# setup_interfaces.sh
# Enhanced Kubernetes node network setup script
# Supports both worker and control-plane nodes with configurable parameters
# - Computes IP addresses based on hostname and node type
# - Configures both primary and secondary interfaces with VLANs
# - All settings externalized to network/interfaces.conf

set -euo pipefail

# Script directory and configuration file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/interfaces.conf"

# Load configuration
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE" >&2
    exit 1
fi

# Source the configuration file
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
command -v ip >/dev/null || die "ip command not found."

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

# Function to calculate IP addresses based on node type and number
calculate_ip_addresses() {
    local node_type="$1"
    local last_digit="$2"
    local primary_octet secondary_octet
    
    case "$node_type" in
        "worker")
            primary_octet=$((WORKER_PRIMARY_BASE + last_digit))
            secondary_octet=$((WORKER_SECONDARY_BASE + last_digit))
            ;;
        "control-plane")
            primary_octet=$((CONTROL_PLANE_PRIMARY_BASE + last_digit))
            secondary_octet=$((CONTROL_PLANE_SECONDARY_BASE + last_digit))
            ;;
        *)
            die "Unknown node type: $node_type"
            ;;
    esac
    
    # Validate octet ranges
    for octet in "$primary_octet" "$secondary_octet"; do
        if [[ $octet -lt 1 || $octet -gt 254 ]]; then
            die "Calculated IP octet $octet is out of valid range (1-254)"
        fi
    done
    
    # Create IP addresses by substituting {} in MANAGEMENT_CIDR template
    local primary_ip="${MANAGEMENT_CIDR//\{\}/$primary_octet}"
    local secondary_ip="${MANAGEMENT_CIDR//\{\}/$secondary_octet}"
    
    log "Calculated IPs - Primary: $primary_ip, Secondary: $secondary_ip"
    echo "$primary_ip:$secondary_ip"
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

# Function to configure a VLAN interface
configure_vlan_interface() {
    local parent_if="$1"
    local vlan_id="$2"
    local ip_address="$3"  # Can be empty for no IP
    local interface_name="$4"  # "primary" or "secondary"
    
    local vlan_dev="${parent_if}.${vlan_id}"
    local vlan_con="vlan${vlan_id}-${parent_if}-${interface_name}"
    
    if [[ -n "$ip_address" ]]; then
        log "Configuring $interface_name interface: $vlan_con ($vlan_dev) with IP $ip_address"
    else
        log "Configuring $interface_name interface: $vlan_con ($vlan_dev) without IP"
    fi
    
    # Clean existing configurations
    nm_del_by_name "$vlan_con"
    nm_del_by_device "$vlan_dev"
    
    # Create VLAN interface
    if [[ -n "$ip_address" ]]; then
        # With static IP
        sudo nmcli con add type vlan ifname "$vlan_dev" dev "$parent_if" id "$vlan_id" \
            con-name "$vlan_con" ip4 "$ip_address" gw4 "$GATEWAY_IP"
        sudo nmcli con mod "$vlan_con" \
            ipv4.method manual ipv6.method ignore \
            ipv4.dns "$DNS_SERVERS" connection.autoconnect yes
    else
        # Without IP (for MetalLB presence)
        sudo nmcli con add type vlan ifname "$vlan_dev" dev "$parent_if" id "$vlan_id" \
            con-name "$vlan_con"
        sudo nmcli con mod "$vlan_con" \
            ipv4.method disabled ipv6.method ignore connection.autoconnect yes
    fi
    
    # Bring up the interface
    if ! sudo nmcli con up "$vlan_con"; then
        if [[ -n "$ip_address" ]]; then
            die "Failed to bring up $vlan_con with IP $ip_address. Check for IP conflicts."
        else
            log "Warning: Failed to bring up $vlan_con (no IP configured)"
        fi
    fi
    
    verbose_log "Successfully configured $vlan_con"
}

# Function to remove DHCP configuration from an interface
remove_dhcp_config() {
    local interface="$1"
    
    verbose_log "Checking for DHCP connections on $interface"
    local dhcp_connections
    dhcp_connections="$(nmcli -g NAME,DEVICE con show | awk -F: -v dev="$interface" '$2==dev{print $1}' | grep -v "vlan" || true)"
    
    if [[ -n "$dhcp_connections" ]]; then
        while IFS= read -r conn; do
            [[ -z "$conn" ]] && continue
            log "Removing DHCP connection: $conn"
            sudo nmcli con down "$conn" 2>/dev/null || true
            sudo nmcli con del "$conn" 2>/dev/null || true
        done <<< "$dhcp_connections"
    fi
}

# Main execution
main() {
    log "Starting Kubernetes node network configuration"
    log "Using configuration file: $CONFIG_FILE"
    
    # Get hostname and parse node information
    local hostname
    hostname="$(hostname -s)"
    log "Current hostname: $hostname"
    
    local node_info
    node_info="$(parse_hostname "$hostname")"
    IFS=':' read -r node_type node_number last_digit <<< "$node_info"
    
    # Calculate IP addresses
    local ip_info
    ip_info="$(calculate_ip_addresses "$node_type" "$last_digit")"
    IFS=':' read -r primary_ip secondary_ip <<< "$ip_info"
    
    log "Node configuration: Type=$node_type, Number=$node_number"
    log "IP assignment: Primary=$primary_ip, Secondary=$secondary_ip"
    
    # Ensure VLAN kernel support
    verbose_log "Loading 8021q kernel module"
    sudo modprobe 8021q || log "Warning: Could not load 8021q module (may already be loaded)"
    
    # Remove DHCP from secondary interface if requested
    if [[ "${REMOVE_DHCP_ON_SECOND:-no}" == "yes" ]]; then
        log "Removing DHCP configuration from $SECOND_IF"
        remove_dhcp_config "$SECOND_IF"
    fi
    
    # Configure management VLAN on both interfaces
    log "Configuring management VLAN $MGMT_VLAN_ID on both interfaces"
    configure_vlan_interface "$PARENT_IF" "$MGMT_VLAN_ID" "$primary_ip" "primary"
    configure_vlan_interface "$SECOND_IF" "$MGMT_VLAN_ID" "$secondary_ip" "secondary"
    
    # Configure extra VLANs (no IP) on both interfaces for MetalLB
    log "Configuring additional VLANs for MetalLB: ${EXTRA_VLANS[*]}"
    for vlan_id in "${EXTRA_VLANS[@]}"; do
        configure_vlan_interface "$PARENT_IF" "$vlan_id" "" "primary"
        configure_vlan_interface "$SECOND_IF" "$vlan_id" "" "secondary"
    done
    
    # Display results
    echo
    echo "========================================="
    echo "Network Configuration Complete"
    echo "========================================="
    echo
    echo "Primary Interface ($PARENT_IF) Results:"
    ip -4 addr show "${PARENT_IF}.${MGMT_VLAN_ID}" 2>/dev/null | sed 's/^/  /' || echo "  Interface not found"
    echo
    echo "Secondary Interface ($SECOND_IF) Results:"
    ip -4 addr show "${SECOND_IF}.${MGMT_VLAN_ID}" 2>/dev/null | sed 's/^/  /' || echo "  Interface not found"
    echo
    echo "Default Route:"
    ip route show default | head -n 1 | sed 's/^/  /' || echo "  No default route found"
    echo
    echo "Active VLAN Interfaces:"
    for interface in "$PARENT_IF" "$SECOND_IF"; do
        echo "  $interface VLANs:"
        for vlan_id in "$MGMT_VLAN_ID" "${EXTRA_VLANS[@]}"; do
            local vlan_dev="${interface}.${vlan_id}"
            if ip link show "$vlan_dev" &>/dev/null; then
                echo "    ✓ $vlan_dev"
            else
                echo "    ✗ $vlan_dev (not found)"
            fi
        done
    done
    
    echo
    echo "========================================="
    echo "Configuration Notes:"
    echo "========================================="
    echo "• Primary management IP: $primary_ip"
    echo "• Secondary management IP: $secondary_ip"  
    echo "• SSH access available on both IPs"
    echo "• Node type: $node_type"
    echo "• Additional VLANs configured for MetalLB: ${EXTRA_VLANS[*]}"
    if [[ "${REMOVE_DHCP_ON_SECOND:-no}" == "yes" ]]; then
        echo "• DHCP removed from $SECOND_IF as requested"
    else
        echo "• DHCP preserved on $SECOND_IF"
    fi
    echo "• Gateway: $GATEWAY_IP"
    echo "• DNS servers: $DNS_SERVERS"
    echo
    
    log "Network configuration completed successfully"
}

# Verify we're running as root or with sudo
if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
    die "This script requires root privileges. Please run with sudo."
fi

# Execute main function
main "$@"
