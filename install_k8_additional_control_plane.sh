#!/bin/bash
# install_k8_additional_control_plane.sh
# This script installs and configures an additional Kubernetes control plane node.
# Usage: sudo bash ./install_k8_additional_control_plane.sh
# This script requires root privileges.
# Prerequisites: 
#   - Populate join_artifacts/control-plane-join.conf with values from primary control-plane
#   - Populate join_artifacts/node-ip.txt with this node's IP (or leave empty for auto-detection)

set -e
set -u

# Source shared configuration
source ./k8s-config.conf || { echo "Failed to load configuration"; exit 1; }

# Source join configuration
JOIN_ARTIFACTS_DIR="./join_artifacts"
JOIN_CONFIG_FILE="${JOIN_ARTIFACTS_DIR}/control-plane-join.conf"
NODE_IP_FILE="${JOIN_ARTIFACTS_DIR}/node-ip.txt"

# Additional control plane specific variables
CONTROL_PLANE_NODE_IP=""
CONTROL_PLANE_ENDPOINT=""
JOIN_TOKEN=""
CA_CERT_HASH=""
CERTIFICATE_KEY=""

# Ensure /usr/local/bin is in the PATH
export PATH="$PATH:/usr/local/bin"

# Logging function
log() {
  local msg="$1"
  # Ensure log directory exists
  local log_dir=$(dirname "$LOG_FILE")
  if [[ ! -d "$log_dir" ]]; then
    mkdir -p "$log_dir" || echo "WARNING: Could not create log directory $log_dir"
  fi
  echo "$(date +'%Y-%m-%d %H:%M:%S') : $msg" | tee -a "$LOG_FILE"
}

# Error handling function
error_exit() {
  local msg="$1"
  log "ERROR: $msg"
  exit 1
}

# Check for root
check_root() {
  if [[ $EUID -ne 0 ]]; then
    log "ERROR: This script must be run as root."
    exit 1
  fi
}

# Function to validate IP address format
validate_ip_address() {
  local ip="$1"
  local ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
  
  if [[ ! $ip =~ $ip_regex ]]; then
    return 1
  fi
  
  # Check each octet is between 0-255
  IFS='.' read -ra OCTETS <<< "$ip"
  for octet in "${OCTETS[@]}"; do
    if ((octet < 0 || octet > 255)); then
      return 1
    fi
  done
  
  return 0
}

# Function to load join configuration
load_join_config() {
  log "Loading join configuration from ${JOIN_CONFIG_FILE}"
  
  if [[ ! -f "$JOIN_CONFIG_FILE" ]]; then
    error_exit "Join configuration file not found: ${JOIN_CONFIG_FILE}. Please create it with values from the primary control-plane node."
  fi
  
  source "$JOIN_CONFIG_FILE" || error_exit "Failed to load join configuration from ${JOIN_CONFIG_FILE}"
  
  # Validate required variables
  if [[ -z "${CONTROL_PLANE_ENDPOINT}" || "${CONTROL_PLANE_ENDPOINT}" == *"<"* || "${CONTROL_PLANE_ENDPOINT}" == *"PRIMARY"* ]]; then
    error_exit "CONTROL_PLANE_ENDPOINT is not set or contains placeholder values. Please update ${JOIN_CONFIG_FILE}"
  fi
  
  if [[ -z "${JOIN_TOKEN}" || "${JOIN_TOKEN}" == *"<"* || "${JOIN_TOKEN}" == *"KUBEADM"* || "${JOIN_TOKEN}" == *"TOKEN"* ]]; then
    error_exit "JOIN_TOKEN is not set or contains placeholder values. Please update ${JOIN_CONFIG_FILE}"
  fi
  
  if [[ -z "${CA_CERT_HASH}" || "${CA_CERT_HASH}" == *"<"* || "${CA_CERT_HASH}" == *"HASH"* ]]; then
    error_exit "CA_CERT_HASH is not set or contains placeholder values. Please update ${JOIN_CONFIG_FILE}"
  fi
  
  if [[ -z "${CERTIFICATE_KEY}" || "${CERTIFICATE_KEY}" == *"<"* || "${CERTIFICATE_KEY}" == *"KEY"* ]]; then
    error_exit "CERTIFICATE_KEY is not set or contains placeholder values. Please update ${JOIN_CONFIG_FILE}"
  fi
  
  # Validate CONTROL_PLANE_ENDPOINT format (should be IP:PORT or HOSTNAME:PORT)
  if [[ ! "${CONTROL_PLANE_ENDPOINT}" =~ :[0-9]+$ ]]; then
    error_exit "CONTROL_PLANE_ENDPOINT must include port (e.g., 192.168.1.100:6443). Got: ${CONTROL_PLANE_ENDPOINT}"
  fi
  
  log "Join configuration loaded successfully."
  log "Control Plane Endpoint: ${CONTROL_PLANE_ENDPOINT}"
  log "Join Token: ${JOIN_TOKEN:0:6}***"
  log "CA Cert Hash: ${CA_CERT_HASH:0:8}***"
  log "Certificate Key: ${CERTIFICATE_KEY:0:8}***"
}

# Function to get the IP address based on the default route
# If multiple IPs exist on the same subnet as the default route, 
# select the one with the lowest last octet
get_primary_ip() {
  local default_interface default_gateway netmask ip_with_cidr ip_addresses selected_ip
  
  # Get the default route interface
  default_interface=$(ip route | grep '^default' | awk '{print $5}' | head -n 1)
  
  if [[ -z "$default_interface" ]]; then
    error_exit "Could not determine default route interface."
  fi
  
  log "Default route interface detected: ${default_interface}"
  
  # Get the default gateway IP
  default_gateway=$(ip route | grep '^default' | awk '{print $3}' | head -n 1)
  
  if [[ -z "$default_gateway" ]]; then
    error_exit "Could not determine default gateway IP."
  fi
  
  log "Default gateway IP: ${default_gateway}"
  
  # Get the IP address and CIDR from the default interface
  ip_with_cidr=$(ip -4 addr show dev "$default_interface" | grep -oP 'inet \K[\d.]+/\d+' | head -n 1)
  
  if [[ -z "$ip_with_cidr" ]]; then
    error_exit "Could not find IP address with CIDR on interface ${default_interface}"
  fi
  
  # Extract IP and netmask
  local ip_part="${ip_with_cidr%/*}"
  local cidr="${ip_with_cidr#*/}"
  
  log "Interface ${default_interface} has IP: ${ip_part}/${cidr}"
  
  # Calculate network address using the CIDR
  # For simplicity, we'll match IPs on the same interface that are in the same subnet as the gateway
  # Get all IPs on the default interface
  ip_addresses=$(ip -4 addr show dev "$default_interface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}(?=/)')
  
  if [[ -z "$ip_addresses" ]]; then
    error_exit "Could not find any IP addresses on interface ${default_interface}"
  fi
  
  # If multiple IPs, select the one with the lowest last octet
  selected_ip=$(echo "$ip_addresses" | sort -t. -k4 -n | head -n 1)
  
  # Validate the selected IP
  if ! validate_ip_address "$selected_ip"; then
    error_exit "Selected IP address ${selected_ip} is not valid"
  fi
  
  log "Selected IP address: ${selected_ip}"
  
  echo "$selected_ip"
}

# Function to set control plane node IP
set_control_plane_node_ip() {
  if [[ -f "$NODE_IP_FILE" ]] && [[ -s "$NODE_IP_FILE" ]]; then
    CONTROL_PLANE_NODE_IP=$(cat "$NODE_IP_FILE" | tr -d '[:space:]')
    
    # Check if it's a placeholder (common placeholder patterns)
    if [[ "$CONTROL_PLANE_NODE_IP" =~ ^192\.168\.1\.101$ ]] || \
       [[ "$CONTROL_PLANE_NODE_IP" =~ ^10\.0\.0\.1$ ]] || \
       [[ "$CONTROL_PLANE_NODE_IP" =~ ^(x\.x\.x\.x|X\.X\.X\.X)$ ]] || \
       [[ "$CONTROL_PLANE_NODE_IP" == *"<"* ]] || \
       [[ "$CONTROL_PLANE_NODE_IP" == *"PLACEHOLDER"* ]]; then
      log "Node IP file contains placeholder value (${CONTROL_PLANE_NODE_IP}). Auto-detecting IP based on default route..."
      CONTROL_PLANE_NODE_IP=$(get_primary_ip)
    elif validate_ip_address "$CONTROL_PLANE_NODE_IP"; then
      log "Using IP from ${NODE_IP_FILE}: ${CONTROL_PLANE_NODE_IP}"
    else
      error_exit "Invalid IP address format in ${NODE_IP_FILE}: ${CONTROL_PLANE_NODE_IP}"
    fi
  else
    log "Node IP file not found or empty. Auto-detecting IP based on default route..."
    CONTROL_PLANE_NODE_IP=$(get_primary_ip)
  fi
  
  log "Control plane node IP set to: ${CONTROL_PLANE_NODE_IP}"
}

# Function to perform upgrade
perform_upgrade() {
  log "Performing system upgrade."
  dnf -y upgrade || error_exit "System upgrade failed."
}

# Function to enable cockpit
enable_cockpit() {
  log "Enabling cockpit."
  if systemctl is-enabled cockpit.socket &>/dev/null; then
    log "Cockpit is already enabled."
  else
    systemctl enable --now cockpit.socket || error_exit "Failed to enable cockpit."
  fi
}

# Function to disable swap
disable_swap() {
  log "Disabling swap."
  swapoff -a || log "WARNING: swapoff failed or no swap enabled"
  
  # Backup fstab before modifying
  if [[ ! -f /etc/fstab.bak ]]; then
    cp /etc/fstab /etc/fstab.bak || log "WARNING: Could not backup fstab"
  fi
  
  sed -i.tmp '/swap/d' /etc/fstab
  sed -i.tmp 's/^\/dev\/mapper\/centos-swap/#\/dev\/mapper\/centos-swap/' /etc/fstab
  swapoff /dev/mapper/centos-swap 2>/dev/null || true
  
  # Verify swap is disabled
  if swapon --show | grep -q .; then
    log "WARNING: Swap may still be enabled"
  else
    log "Swap successfully disabled"
  fi
}

# Function to configure firewall (using control-plane rules)
configure_firewall() {
  log "Configuring firewall for control plane."
  
  # Check if firewalld is running
  if ! systemctl is-active --quiet firewalld; then
    log "WARNING: firewalld is not running. Skipping firewall configuration."
    return 0
  fi
  
  # Check if k8s-controlplane service already exists
  if firewall-cmd --get-services | grep -q "k8s-controlplane"; then
    log "Firewall service k8s-controlplane already exists. Skipping creation."
  else
    if [[ ! -f "$FIREWALLD_FILE" ]]; then
      error_exit "Firewall configuration file not found: ${FIREWALLD_FILE}"
    fi
    firewall-cmd --permanent --new-service-from-file="$FIREWALLD_FILE" --name=k8s-controlplane || error_exit "Failed to create new service."
    log "Created k8s-controlplane firewall service."
  fi
  
  firewall-cmd --reload || error_exit "Failed to reload firewall."
  
  # Add services if not already added
  if firewall-cmd --list-services | grep -q "k8s-controlplane"; then
    log "k8s-controlplane service already added to firewall."
  else
    firewall-cmd --permanent --add-service=k8s-controlplane || error_exit "Failed to add k8s-controlplane service to firewall."
  fi
  
  if firewall-cmd --list-services | grep -q "cockpit"; then
    log "cockpit service already added to firewall."
  else
    firewall-cmd --permanent --add-service=cockpit || error_exit "Failed to add cockpit service to firewall."
  fi
  
  firewall-cmd --reload || error_exit "Failed to reload firewall."
  log "Firewall configured successfully."
}

# Function to verify firewall ports
verify_firewall_ports() {
  log "Verifying firewall ports."
  
  # Check if firewalld is running
  if ! systemctl is-active --quiet firewalld; then
    log "WARNING: firewalld is not running. Skipping port verification."
    return 0
  fi
  
  local tcp_ports=(6443 2379 2380 10250 10251 10252 10255 10256 10257 10259 4240 4244 4245 9962 9963 9964)
  local udp_ports=(500 4500 8472 6081)
  local missing_ports=()
  
  for port in "${tcp_ports[@]}"; do
    if ! firewall-cmd --zone=public --query-port="${port}/tcp" &>/dev/null; then
      missing_ports+=("${port}/tcp")
    fi
  done
  
  for port in "${udp_ports[@]}"; do
    if ! firewall-cmd --zone=public --query-port="${port}/udp" &>/dev/null; then
      missing_ports+=("${port}/udp")
    fi
  done
  
  if [ ${#missing_ports[@]} -gt 0 ]; then
    log "WARNING: The following ports are not open: ${missing_ports[*]}"
  else
    log "All required firewall ports are open."
  fi
}

# Function to install containerd
install_containerd() {
  # Check if containerd is already installed
  if command -v containerd &>/dev/null; then
    local installed_version=$(containerd --version | awk '{print $3}' | sed 's/v//')
    log "containerd is already installed (version: ${installed_version})."
    if [[ "$installed_version" == "$CONTAINERD_VERSION" ]]; then
      log "containerd version matches required version. Skipping installation."
      return 0
    else
      log "Installed version differs from required version ${CONTAINERD_VERSION}. Proceeding with installation."
    fi
  fi
  
  log "Installing containerd version ${CONTAINERD_VERSION}."
  wget "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" -O /tmp/containerd.tar.gz || error_exit "Failed to download containerd."
  tar Cxzvf /usr/local /tmp/containerd.tar.gz || error_exit "Failed to extract containerd."
  rm -f /tmp/containerd.tar.gz
  log "containerd installed successfully."
}

# Function to create containerd service
create_containerd_service() {
  # Check if service already exists and is running
  if systemctl is-active --quiet containerd; then
    log "containerd service is already running."
    return 0
  fi
  
  log "Creating containerd service."
  cat <<EOF | tee /etc/systemd/system/containerd.service
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=$CONTAINERD_BIN

Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5

LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || error_exit "Failed to reload systemd."
  systemctl enable --now containerd || error_exit "Failed to enable containerd."
  
  # Verify containerd is running
  sleep 2
  if systemctl is-active --quiet containerd; then
    log "containerd service is running successfully."
  else
    error_exit "containerd service failed to start."
  fi
}

# Function to install runc
install_runc() {
  # Check if runc is already installed
  if command -v runc &>/dev/null; then
    local installed_version=$(runc --version | head -n1 | awk '{print $3}')
    log "runc is already installed (version: ${installed_version})."
    if [[ "$installed_version" == "$RUNC_VERSION" ]]; then
      log "runc version matches required version. Skipping installation."
      return 0
    else
      log "Installed version differs from required version ${RUNC_VERSION}. Proceeding with installation."
    fi
  fi
  
  log "Installing runc version ${RUNC_VERSION}."
  wget "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.amd64" -O /tmp/runc || error_exit "Failed to download runc."
  install -m 755 /tmp/runc /usr/local/sbin/runc || error_exit "Failed to install runc."
  rm -f /tmp/runc
  log "runc installed successfully."
}

# Function to install CNI plugins
install_cni_plugins() {
  # Check if CNI plugins are already installed
  if [[ -d /opt/cni/bin ]] && [[ -n "$(ls -A /opt/cni/bin)" ]]; then
    log "CNI plugins directory exists and is not empty. Checking version..."
    # CNI plugins don't have a simple version command, so we'll check if key binaries exist
    if [[ -f /opt/cni/bin/bridge ]] && [[ -f /opt/cni/bin/loopback ]]; then
      log "CNI plugins appear to be installed. Skipping installation."
      return 0
    fi
  fi
  
  log "Installing CNI plugins version ${CNI_PLUGINS_VERSION}."
  wget "https://github.com/containernetworking/plugins/releases/download/v${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-v${CNI_PLUGINS_VERSION}.tgz" -O /tmp/cni-plugins.tgz || error_exit "Failed to download CNI plugins."
  mkdir -p /opt/cni/bin || error_exit "Failed to create CNI plugins directory."
  tar Cxzvf /opt/cni/bin /tmp/cni-plugins.tgz || error_exit "Failed to extract CNI plugins."
  rm -f /tmp/cni-plugins.tgz
  log "CNI plugins installed successfully."
}

# Function to configure containerd
configure_containerd() {
  log "Configuring containerd."
  mkdir -p /etc/containerd || error_exit "Failed to create containerd config directory."
  
  # Check if config already exists and has SystemdCgroup enabled
  if [[ -f /etc/containerd/config.toml ]]; then
    if grep -q "SystemdCgroup = true" /etc/containerd/config.toml; then
      log "containerd config already exists with SystemdCgroup enabled. Skipping configuration."
      return 0
    else
      log "containerd config exists but needs update."
    fi
  fi
  
  "$CONTAINERD_BIN" config default | tee /etc/containerd/config.toml || error_exit "Failed to generate containerd config."
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml || error_exit "Failed to update containerd config."
  systemctl restart containerd || error_exit "Failed to restart containerd."
  
  # Verify containerd restarted successfully
  sleep 2
  if systemctl is-active --quiet containerd; then
    log "containerd restarted successfully."
  else
    error_exit "containerd failed to restart after configuration."
  fi
}

# Function to configure kernel modules and sysctl
configure_kernel() {
  log "Configuring kernel modules and sysctl."
  
  # Configure modules to load on boot
  cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

  # Load modules now
  modprobe overlay || error_exit "Failed to load overlay module."
  modprobe br_netfilter || error_exit "Failed to load br_netfilter module."
  
  # Verify modules are loaded
  if ! lsmod | grep -q overlay; then
    error_exit "overlay module not loaded"
  fi
  if ! lsmod | grep -q br_netfilter; then
    error_exit "br_netfilter module not loaded"
  fi
  log "Kernel modules loaded successfully."

  # Configure sysctl settings
  cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

  sysctl --system || error_exit "Failed to apply sysctl parameters."
  
  # Verify sysctl settings
  local ip_forward=$(sysctl -n net.ipv4.ip_forward)
  if [[ "$ip_forward" != "1" ]]; then
    error_exit "Failed to enable ip_forward"
  fi
  log "Kernel sysctl parameters configured successfully."
}

# Function to set SELinux to permissive mode
set_selinux_permissive() {
  log "Setting SELinux to ${SELINUX_MODE} mode."
  
  # Check current SELinux mode
  local current_mode=$(getenforce)
  log "Current SELinux mode: ${current_mode}"
  
  if [[ "$current_mode" == "Permissive" ]] || [[ "$current_mode" == "Disabled" ]]; then
    log "SELinux is already in ${current_mode} mode."
  else
    setenforce 0 || log "WARNING: Failed to set SELinux to permissive mode."
  fi
  
  # Update config file for persistence
  if grep -q "^SELINUX=enforcing" /etc/selinux/config; then
    sed -i "s/^SELINUX=enforcing/SELINUX=${SELINUX_MODE}/" /etc/selinux/config || error_exit "Failed to update SELinux config file."
    log "SELinux config file updated to ${SELINUX_MODE}."
  else
    log "SELinux config already set to ${SELINUX_MODE} or disabled."
  fi
}

# Function to install Kubernetes packages
install_kubernetes() {
  log "Installing Kubernetes packages."
  
  # Check if Kubernetes packages are already installed
  if command -v kubeadm &>/dev/null && command -v kubelet &>/dev/null && command -v kubectl &>/dev/null; then
    local kubeadm_version=$(kubeadm version -o short)
    log "Kubernetes tools are already installed (kubeadm version: ${kubeadm_version})."
    log "Skipping Kubernetes package installation."
    return 0
  fi
  
  dnf -y install ca-certificates curl gpg || error_exit "Failed to install prerequisites."
  
  # Create Kubernetes repo if it doesn't exist
  if [[ ! -f /etc/yum.repos.d/kubernetes.repo ]]; then
    cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_MINOR}/rpm/repodata/repomd.xml.key
EOF
    log "Kubernetes repository configured."
  else
    log "Kubernetes repository already exists."
  fi

  dnf -y install kubeadm kubelet kubectl || error_exit "Failed to install Kubernetes packages."
  log "Kubernetes packages installed successfully."
}

# Function to enable and start kubelet
enable_kubelet() {
  log "Enabling kubelet."
  if systemctl is-enabled kubelet &>/dev/null; then
    log "kubelet is already enabled."
  else
    systemctl enable kubelet || error_exit "Failed to enable kubelet."
  fi
  # Note: kubelet will fail to start until kubeadm join is run, this is expected
  log "kubelet enabled (will start after joining cluster)."
}

# Function to load IPVS modules and configure them to load on boot
configure_ipvs() {
  log "Loading IPVS modules..."
  modprobe ip_vs || error_exit "Failed to load ip_vs module."
  modprobe ip_vs_rr || error_exit "Failed to load ip_vs_rr module."
  modprobe ip_vs_wrr || error_exit "Failed to load ip_vs_wrr module."
  modprobe ip_vs_sh || error_exit "Failed to load ip_vs_sh module."
  modprobe nf_conntrack || error_exit "Failed to load nf_conntrack module."

  log "Ensuring IPVS modules load on boot..."
  echo -e "ip_vs\nip_vs_rr\nip_vs_wrr\nip_vs_sh\nnf_conntrack_ipv4" | tee /etc/modules-load.d/ipvs.conf

  log "Verifying loaded modules..."
  if ! lsmod | grep -q ip_vs; then
    error_exit "IPVS modules failed to load"
  fi
  log "IPVS modules are configured and loaded successfully."
}

# Function to increase nofile limits to 1048576
increase_nofile_limits() {
  log "Increasing nofile limits to ${NOFILE_LIMIT}..."
  
  # Update limits.conf
  grep -q "^\* soft nofile ${NOFILE_LIMIT}" /etc/security/limits.conf || echo "* soft nofile ${NOFILE_LIMIT}" | tee -a /etc/security/limits.conf
  grep -q "^\* hard nofile ${NOFILE_LIMIT}" /etc/security/limits.conf || echo "* hard nofile ${NOFILE_LIMIT}" | tee -a /etc/security/limits.conf
  
  # Update pam
  grep -q "^session required pam_limits.so" /etc/pam.d/system-auth || echo "session required pam_limits.so" | tee -a /etc/pam.d/system-auth
  
  # Update sysctl
  grep -q "^fs.file-max = ${NOFILE_LIMIT}" /etc/sysctl.conf || echo "fs.file-max = ${NOFILE_LIMIT}" | tee -a /etc/sysctl.conf
  sysctl -p /etc/sysctl.conf || log "WARNING: Failed to reload sysctl settings"
  
  log "Nofile limits configured successfully."
}

# Function to check and install required dependencies
install_dependencies() {
  local deps=(wget tar curl gpg jq iproute)
  local missing=()
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
      missing+=("$dep")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    log "Installing missing dependencies: ${missing[*]}"
    dnf -y install "${missing[@]}" || error_exit "Failed to install required dependencies: ${missing[*]}"
  else
    log "All required dependencies are already installed."
  fi
}

# Function to join the cluster as a control plane node
join_control_plane() {
  log "Joining Kubernetes cluster as control plane node."
  log "Control Plane Endpoint: ${CONTROL_PLANE_ENDPOINT}"
  log "Advertise Address: ${CONTROL_PLANE_NODE_IP}"
  
  # Check if node is already part of the cluster
  if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    log "WARNING: Node appears to already be part of a cluster (/etc/kubernetes/kubelet.conf exists)."
    log "If you need to rejoin, run 'kubeadm reset' first."
    return 0
  fi
  
  # Construct the join command
  JOIN_COMMAND="kubeadm join ${CONTROL_PLANE_ENDPOINT} \
    --token ${JOIN_TOKEN} \
    --discovery-token-ca-cert-hash sha256:${CA_CERT_HASH} \
    --control-plane \
    --certificate-key ${CERTIFICATE_KEY} \
    --apiserver-advertise-address ${CONTROL_PLANE_NODE_IP} \
    --v=5"
  
  log "Executing join command..."
  eval "$JOIN_COMMAND" || error_exit "Failed to join cluster as control plane node."
  
  # Verify join was successful
  if [[ -f /etc/kubernetes/kubelet.conf ]] && [[ -f /etc/kubernetes/admin.conf ]]; then
    log "Successfully joined cluster as control plane node."
  else
    error_exit "Join command completed but expected configuration files not found."
  fi
}

# Function to configure kubectl for all users with home directories
configure_kubectl_for_users() {
  log "Configuring kubectl for all users with home directories and for root."

  # Verify admin.conf exists
  if [[ ! -f "$KUBECONFIG" ]]; then
    log "WARNING: ${KUBECONFIG} not found. Skipping kubectl configuration."
    return 0
  fi

  local users
  users=$(ls /home 2>/dev/null || echo "")

  # Configure for each user
  for user in $users; do
    local user_home="/home/$user"
    if [[ -d "$user_home" ]]; then
      mkdir -p "$user_home/.kube" || log "WARNING: Failed to create .kube directory for user $user."
      if [[ -f "$user_home/.kube/config" ]]; then
        log "kubectl config already exists for user $user. Skipping."
      else
        cp "$KUBECONFIG" "$user_home/.kube/config" || log "WARNING: Failed to copy kubeconfig for user $user."
        chown "$user:$user" "$user_home/.kube/config" || log "WARNING: Failed to change ownership for user $user."
        log "Configured kubectl for user $user."
      fi
    fi
  done

  # Configure for root
  local root_home="/root"
  mkdir -p "$root_home/.kube" || log "WARNING: Failed to create .kube directory for root."
  if [[ -f "$root_home/.kube/config" ]]; then
    log "kubectl config already exists for root. Skipping."
  else
    cp "$KUBECONFIG" "$root_home/.kube/config" || log "WARNING: Failed to copy kubeconfig for root."
    chown root:root "$root_home/.kube/config" || log "WARNING: Failed to change ownership for root."
    log "Configured kubectl for root."
  fi
}

# Function to verify the node joined successfully
verify_node_status() {
  log "Verifying node status..."
  
  # Set kubeconfig for this verification
  export KUBECONFIG=/etc/kubernetes/admin.conf
  
  # Wait for node to register with retries
  local max_retries=12
  local retry_delay=5
  local retry_count=0
  
  while [ $retry_count -lt $max_retries ]; do
    log "Checking node registration (attempt $((retry_count + 1))/${max_retries})..."
    
    if kubectl get nodes 2>/dev/null | grep -q "$(hostname)"; then
      log "Node $(hostname) successfully registered with the cluster."
      kubectl get nodes || log "WARNING: Failed to display node list"
      return 0
    fi
    
    retry_count=$((retry_count + 1))
    if [ $retry_count -lt $max_retries ]; then
      log "Node not yet registered. Waiting ${retry_delay} seconds..."
      sleep $retry_delay
    fi
  done
  
  log "WARNING: Node $(hostname) may not have registered properly after ${max_retries} attempts."
  log "Please manually verify with: kubectl get nodes"
  return 1
}

# Main function
main() {
  check_root
  install_dependencies
  log "Starting additional Kubernetes control plane node setup."
  
  # Load join configuration and set node IP
  load_join_config
  set_control_plane_node_ip
  
  # System setup (same as worker node setup)
  perform_upgrade
  enable_cockpit
  disable_swap
  increase_nofile_limits
  configure_ipvs
  configure_firewall
  verify_firewall_ports
  install_containerd
  create_containerd_service
  install_runc
  install_cni_plugins
  configure_containerd
  configure_kernel
  set_selinux_permissive
  install_kubernetes
  enable_kubelet
  
  # Join as control plane (this is the key difference)
  join_control_plane
  
  # Post-join configuration
  configure_kubectl_for_users
  verify_node_status
  
  log "Additional Kubernetes control plane node setup completed successfully."
  log "This node has joined the cluster as a control plane node."
  log "You can verify the cluster status with: kubectl get nodes"
}

main "$@"
