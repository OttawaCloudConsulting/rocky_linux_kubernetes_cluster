#!/bin/bash

set -e

# Function to get the IP address of the first non-loopback network interface
get_first_non_loopback_ip() {
    local ip_address
    ip_address=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    
    if [[ -z "$ip_address" ]]; then
        echo "Error: Could not find a valid IP address for a non-loopback interface."
        exit 1
    fi

    echo "$ip_address"
}

# Function to log messages
log_message() {
    local message="$1"
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $message"
}

# Main script logic
if [[ $# -eq 1 ]]; then
    # Parse the argument
    if [[ $1 =~ ^IP_ADDRESS=([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IP_ADDRESS="${1#*=}"
        log_message "Using specified IP address: $IP_ADDRESS"
    else
        log_message "Error: Invalid argument format. Expected format is IP_ADDRESS=x.x.x.x"
        exit 1
    fi
elif [[ $# -eq 0 ]]; then
    # Get the IP address of the first non-loopback network interface
    IP_ADDRESS=$(get_first_non_loopback_ip)
    log_message "Detected IP address: $IP_ADDRESS"
else
    log_message "Error: Invalid number of arguments."
    exit 1
fi

# Print the IP address
echo "IP address is $IP_ADDRESS"
log_message "Script completed successfully."
