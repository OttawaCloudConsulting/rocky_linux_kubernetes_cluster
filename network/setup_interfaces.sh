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

# Function to calculate IP addresses for a specific VLAN based on node type and number
calculate_vlan_ip_addresses() {
    local vlan_id="$1"
    local node_type="$2"
    local last_digit="$3"
    local primary_octet secondary_octet
    
    # Get VLAN network configuration
    local vlan_config="${VLAN_CONFIGS[$vlan_id]:-}"
    if [[ -z "$vlan_config" ]]; then
        die "VLAN $vlan_id not found in VLAN_CONFIGS"
    fi
    
    IFS=':' read -r network_cidr gateway_ip dns_ip <<< "$vlan_config"
    
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
            die "Calculated IP octet $octet is out of valid range (1-254) for VLAN $vlan_id"
        fi
    done
    
    # Create IP addresses by substituting {} in network CIDR template
    local primary_ip="${network_cidr//\{\}/$primary_octet}"
    local secondary_ip="${network_cidr//\{\}/$secondary_octet}"
    
    verbose_log "VLAN $vlan_id IPs - Primary: $primary_ip, Secondary: $secondary_ip, Gateway: $gateway_ip, DNS: $dns_ip"
    echo "$primary_ip:$secondary_ip:$gateway_ip:$dns_ip"
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
    local ip_address="$3"
    local gateway_ip="$4"
    local dns_ip="$5"
    local interface_name="$6"  # "primary" or "secondary"
    local is_mgmt_vlan="$7"    # "yes" or "no"
    
    local vlan_dev="${parent_if}.${vlan_id}"
    local vlan_con="vlan${vlan_id}-${parent_if}-${interface_name}"
    
    log "Configuring $interface_name interface: $vlan_con ($vlan_dev) with IP $ip_address"
    
    # Clean existing configurations
    nm_del_by_name "$vlan_con"
    nm_del_by_device "$vlan_dev"
    
    # Create VLAN interface with static IP
    sudo nmcli con add type vlan ifname "$vlan_dev" dev "$parent_if" id "$vlan_id" \
        con-name "$vlan_con" ip4 "$ip_address"
    
    # Configure connection properties
    sudo nmcli con mod "$vlan_con" \
        ipv4.method manual ipv6.method ignore \
        ipv4.dns "$dns_ip" connection.autoconnect yes
    
    # Only set gateway for management VLAN to avoid routing conflicts
    if [[ "$is_mgmt_vlan" == "yes" ]]; then
        sudo nmcli con mod "$vlan_con" gw4 "$gateway_ip"
        verbose_log "Set gateway $gateway_ip for management VLAN $vlan_id"
    else
        verbose_log "Skipping gateway for non-management VLAN $vlan_id"
    fi
    
    # Bring up the interface
    if ! sudo nmcli con up "$vlan_con"; then
        die "Failed to bring up $vlan_con with IP $ip_address. Check for IP conflicts."
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
    
    log "Node configuration: Type=$node_type, Number=$node_number"
    
    # Ensure VLAN kernel support
    verbose_log "Loading 8021q kernel module"
    sudo modprobe 8021q || log "Warning: Could not load 8021q module (may already be loaded)"
    
    # Remove DHCP from secondary interface if requested
    if [[ "${REMOVE_DHCP_ON_SECOND:-no}" == "yes" ]]; then
        log "Removing DHCP configuration from $SECOND_IF"
        remove_dhcp_config "$SECOND_IF"
    fi
    
    # Configure all VLANs on both interfaces
    log "Configuring VLANs: ${ALL_VLANS[*]}"
    
    declare -A configured_vlans_primary
    declare -A configured_vlans_secondary
    
    for vlan_id in "${ALL_VLANS[@]}"; do
        # Calculate IP addresses for this VLAN
        local vlan_info
        vlan_info="$(calculate_vlan_ip_addresses "$vlan_id" "$node_type" "$last_digit")"
        IFS=':' read -r primary_ip secondary_ip gateway_ip dns_ip <<< "$vlan_info"
        
        # Determine if this is the management VLAN
        local is_mgmt_vlan="no"
        [[ "$vlan_id" == "$MGMT_VLAN_ID" ]] && is_mgmt_vlan="yes"
        
        log "Configuring VLAN $vlan_id - Primary: $primary_ip, Secondary: $secondary_ip"
        
        # Configure on both interfaces
        configure_vlan_interface "$PARENT_IF" "$vlan_id" "$primary_ip" "$gateway_ip" "$dns_ip" "primary" "$is_mgmt_vlan"
        configure_vlan_interface "$SECOND_IF" "$vlan_id" "$secondary_ip" "$gateway_ip" "$dns_ip" "secondary" "$is_mgmt_vlan"
        
        configured_vlans_primary[$vlan_id]="$primary_ip"
        configured_vlans_secondary[$vlan_id]="$secondary_ip"
    done
    
    # Display results
    echo
    echo "========================================="
    echo "Network Configuration Complete"
    echo "========================================="
    echo
    echo "Primary Interface ($PARENT_IF) Results:"
    for vlan_id in "${ALL_VLANS[@]}"; do
        local vlan_dev="${PARENT_IF}.${vlan_id}"
        if ip -4 addr show "$vlan_dev" &>/dev/null; then
            echo "  VLAN $vlan_id (${configured_vlans_primary[$vlan_id]}):"
            ip -4 addr show "$vlan_dev" | grep inet | sed 's/^/    /'
        else
            echo "  VLAN $vlan_id: Interface not found"
        fi
    done
    echo
    echo "Secondary Interface ($SECOND_IF) Results:"
    for vlan_id in "${ALL_VLANS[@]}"; do
        local vlan_dev="${SECOND_IF}.${vlan_id}"
        if ip -4 addr show "$vlan_dev" &>/dev/null; then
            echo "  VLAN $vlan_id (${configured_vlans_secondary[$vlan_id]}):"
            ip -4 addr show "$vlan_dev" | grep inet | sed 's/^/    /'
        else
            echo "  VLAN $vlan_id: Interface not found"
        fi
    done
    echo
    echo "Default Route:"
    ip route show default | head -n 1 | sed 's/^/  /' || echo "  No default route found"
    echo
    echo "Active VLAN Interfaces:"
    for interface in "$PARENT_IF" "$SECOND_IF"; do
        echo "  $interface VLANs:"
        for vlan_id in "${ALL_VLANS[@]}"; do
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
    echo "Configuration Summary:"
    echo "========================================="
    echo "• Node type: $node_type"
    echo "• Management VLAN: $MGMT_VLAN_ID"
    echo "• Primary management IP: ${configured_vlans_primary[$MGMT_VLAN_ID]}"
    echo "• Secondary management IP: ${configured_vlans_secondary[$MGMT_VLAN_ID]}"
    echo "• SSH access available on both management IPs"
    echo "• All VLANs configured: ${ALL_VLANS[*]}"
    if [[ "${REMOVE_DHCP_ON_SECOND:-no}" == "yes" ]]; then
        echo "• DHCP removed from $SECOND_IF as requested"
    else
        echo "• DHCP preserved on $SECOND_IF"
    fi
    echo
    echo "VLAN IP Assignments:"
    for vlan_id in "${ALL_VLANS[@]}"; do
        echo "  VLAN $vlan_id: Primary=${configured_vlans_primary[$vlan_id]}, Secondary=${configured_vlans_secondary[$vlan_id]}"
    done
    echo
    
    log "Network configuration completed successfully"
}

# Verify we're running as root or with sudo
if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
    die "This script requires root privileges. Please run with sudo."
fi

# Execute main function
main "$@"
