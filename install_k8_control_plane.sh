#!/bin/bash
# install_k8_control_plane.sh
# This script installs and configures a Kubernetes control plane node.
# Usage: sudo bash ./install_k8_control_plane.sh
# Usage: sudo bash ./install_k8_control_plane.sh CONTROL_PLANE_ADDRESS=x.x.x.x
# This script requires root privileges.


set -e
set -u

# Source shared configuration
source ./k8s-config.conf || { echo "Failed to load configuration"; exit 1; }

# Control plane specific variables
CONTROL_PLANE_NODE_IP=""

# Ensure /usr/local/bin is in the PATH
export PATH="$PATH:/usr/local/bin"

# Logging function
log() {
  local msg="$1"
  echo "$(date +'%Y-%m-%d %H:%M:%S') : $msg" | sudo tee -a "$LOG_FILE"
}

# Error handling function
error_exit() {
  local msg="$1"
  log "ERROR: $msg"
  exit 1
}

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

# Function to set control plane node IP
set_control_plane_node_ip() {
    if [[ -n "${1:-}" ]]; then
        CONTROL_PLANE_NODE_IP="$1"
        log "Using provided control plane IP: $CONTROL_PLANE_NODE_IP"
    else
        CONTROL_PLANE_NODE_IP=$(get_first_non_loopback_ip)
        log "Auto-detected control plane IP: $CONTROL_PLANE_NODE_IP"
    fi
}

# Function to perform upgrade
perform_upgrade() {
  log "Performing system upgrade."
  sudo dnf -y upgrade || error_exit "System upgrade failed."
}

# Function to enable cockpit
enable_cockpit() {
  log "Enabling cockpit."
  sudo systemctl enable --now cockpit.socket || error_exit "Failed to enable cockpit."
}

# Function to disable swap
disable_swap() {
  log "Disabling swap."
  sudo swapoff -a
  sudo sed -i '/swap/d' /etc/fstab
  sudo sed -i 's/^\/dev\/mapper\/centos-swap/#\/dev\/mapper\/centos-swap/' /etc/fstab
  sudo swapoff /dev/mapper/centos-swap || true
}

# Function to configure firewall
configure_firewall() {
  log "Configuring firewall."
  # local ports=(6443 2379 2380 10250-10252 10255)
  # for port in "${ports[@]}"; do
  #   sudo firewall-cmd --zone=public --add-port="${port}/tcp" --permanent || error_exit "Failed to add port $port to firewall."
  # done
  sudo firewall-cmd --permanent --new-service-from-file=$FIREWALLD_FILE --name=k8s-controlplane || error_exit "Failed to create new service."
  sudo firewall-cmd --reload || error_exit "Failed to reload firewall."
  sudo firewall-cmd --permanent --add-service=k8s-controlplane || error_exit "Failed to add service to firewall."
  sudo firewall-cmd --permanent --add-service=cockpit || error_exit "Failed to add service to firewall."
  sudo firewall-cmd --reload || error_exit "Failed to reload firewall."
}

# Function to verify firewall ports
verify_firewall_ports() {
  log "Verifying firewall ports."
  local tcp_ports=(6443 2379 2380 10250 10251 10252 10255 10256 10257 10259 4240 4244 4245 9962 9963 9964)
  local udp_ports=(500 4500 8472 6081)
  for port in "${tcp_ports[@]}"; do
    sudo firewall-cmd --zone=public --query-port="${port}/tcp" || echo "TCP Port $port is not open."
  done
  for port in "${udp_ports[@]}"; do
    sudo firewall-cmd --zone=public --query-port="${port}/udp" || echo "UDP Port $port is not open."
  done
}

# Function to install containerd
install_containerd() {
  log "Installing containerd."
  wget "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" -O /tmp/containerd.tar.gz || error_exit "Failed to download containerd."
  sudo tar Cxzvf /usr/local /tmp/containerd.tar.gz || error_exit "Failed to extract containerd."
}

# Function to create containerd service
create_containerd_service() {
  log "Creating containerd service."
  cat <<EOF | sudo tee /etc/systemd/system/containerd.service
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
  sudo systemctl daemon-reload || error_exit "Failed to reload systemd."
  sudo systemctl enable --now containerd || error_exit "Failed to enable containerd."
}

# Function to find the latest version of kubernetes from github releases
get_latest_kubeadm_version() {
    echo "Finding the latest version of kubeadm..."
    TAGS=$(curl -s https://api.github.com/repos/kubernetes/kubernetes/tags | jq -r '.[].name')
    latest_version=$(echo "$TAGS" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1)
    if [[ -z "$latest_version" ]]; then
        echo "Unable to find the latest kubeadm version."
        exit 1
    fi
    echo "Latest kubeadm version found: $latest_version"
    LATEST_VERSION_NO_PREFIX=${latest_version#v}
    echo $LATEST_VERSION_NO_PREFIX

    # Extract the patch version (e.g., 1.30.1) from the full version string
    K8S_VERSION_PATCH=$(echo $LATEST_VERSION_NO_PREFIX | grep -oP '^\d+\.\d+\.\d+')
    # Extract the minor version (e.g., 1.30) from the patch version
    K8S_VERSION_MINOR=$(echo $LATEST_VERSION_NO_PREFIX | grep -oP '^\d+\.\d+')
}

# Function to install runc
install_runc() {
  log "Installing runc."
  wget "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.amd64" -O /tmp/runc || error_exit "Failed to download runc."
  sudo install -m 755 /tmp/runc /usr/local/sbin/runc || error_exit "Failed to install runc."
}

# Function to install CNI plugins
install_cni_plugins() {
  log "Installing CNI plugins."
  wget "https://github.com/containernetworking/plugins/releases/download/v${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-v${CNI_PLUGINS_VERSION}.tgz" -O /tmp/cni-plugins.tgz || error_exit "Failed to download CNI plugins."
  sudo mkdir -p /opt/cni/bin || error_exit "Failed to create CNI plugins directory."
  sudo tar Cxzvf /opt/cni/bin /tmp/cni-plugins.tgz || error_exit "Failed to extract CNI plugins."
}

# Function to configure containerd
configure_containerd() {
  log "Configuring containerd."
  sudo mkdir -p /etc/containerd || error_exit "Failed to create containerd config directory."
  sudo "$CONTAINERD_BIN" config default | sudo tee /etc/containerd/config.toml || error_exit "Failed to generate containerd config."
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml || error_exit "Failed to update containerd config."
  sudo systemctl restart containerd || error_exit "Failed to restart containerd."
}

# Function to configure kernel modules and sysctl
configure_kernel() {
  log "Configuring kernel modules and sysctl."
  cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

  sudo modprobe overlay || error_exit "Failed to load overlay module."
  sudo modprobe br_netfilter || error_exit "Failed to load br_netfilter module."

  cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

  sudo sysctl --system || error_exit "Failed to apply sysctl parameters."
}

# Function to set SELinux to permissive mode
set_selinux_permissive() {
  log "Setting SELinux to permissive mode."
  sudo setenforce 0 || error_exit "Failed to set SELinux to ${SELINUX_MODE} mode."
  sudo sed -i "s/^SELINUX=enforcing/SELINUX=${SELINUX_MODE}/" /etc/selinux/config || error_exit "Failed to update SELinux config file."
}

# Function to install Kubernetes packages
install_kubernetes() {
  log "Installing Kubernetes packages."
  sudo dnf -y install ca-certificates curl gpg || error_exit "Failed to install prerequisites."
  
  cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION_MINOR}/rpm/repodata/repomd.xml.key
EOF

  sudo dnf -y install kubeadm kubelet kubectl || error_exit "Failed to install Kubernetes packages."
}

# Function to enable and start kubelet
enable_kubelet() {
  log "Enabling and starting kubelet."
  sudo systemctl enable --now kubelet || error_exit "Failed to enable kubelet."
}

update_kubeadm_config() {
    echo "Updating kubeadm config file with actual values..."
    if [[ ! -f "$K8_INIT_FILE" ]]; then
        echo "Config file $K8_INIT_FILE does not exist."
        exit 1
    fi

    sed -i "s/{YOUR_CONTROL_PLANE_NODE_IP}/$CONTROL_PLANE_NODE_IP/g" "$K8_INIT_FILE"
    sed -i "s/{CONTROL_PLANE_ENDPOINT}/$CONTROL_PLANE_NODE_IP:6443/g" "$K8_INIT_FILE"
    sed -i "s/{YOUR_KUBERNETES_VERSION}/$K8S_VERSION_PATCH/g" "$K8_INIT_FILE"

    echo "kubeadm config file updated successfully."
}

# Function to initialize Kubernetes cluster
initialize_cluster() {
  log "Initializing Kubernetes cluster."
  sudo sudo kubeadm init --config=kubeadm-config.yaml --v=5 || error_exit "Failed to initialize Kubernetes cluster."
}

# Function to configure kubectl for all users with home directories
configure_kubectl_for_users() {
  log "Configuring kubectl for all users with home directories and for root."

  local users
  users=$(ls /home)

  # Configure for each user
  for user in $users; do
    local user_home="/home/$user"
    if [[ -d "$user_home" ]]; then
      sudo mkdir -p "$user_home/.kube" || error_exit "Failed to create .kube directory for user $user."
      sudo cp -i "$KUBECONFIG" "$user_home/.kube/config" || error_exit "Failed to copy kubeconfig for user $user."
      sudo chown "$user:$user" "$user_home/.kube/config" || error_exit "Failed to change ownership of kubeconfig for user $user."
      log "Configured kubectl for user $user."
    fi
  done

  # Configure for root
  local root_home="/root"
  sudo mkdir -p "$root_home/.kube" || error_exit "Failed to create .kube directory for root."
  sudo cp -i "$KUBECONFIG" "$root_home/.kube/config" || error_exit "Failed to copy kubeconfig for root."
  sudo chown root:root "$root_home/.kube/config" || error_exit "Failed to change ownership of kubeconfig for root."
  log "Configured kubectl for root."
}


# Function to create a new kubeadm token and display the join command
create_kubeadm_token() {
  log "Creating a new kubeadm token."
  NEW_TOKEN=$(kubeadm token create) || error_exit "Failed to create kubeadm token."
  log "New kubeadm token created: $NEW_TOKEN"

  CA_CERT_HASH=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //')
  log "CA certificate hash: $CA_CERT_HASH"

  JOIN_COMMAND="sudo kubeadm join $CONTROL_PLANE_NODE_IP:6443 --token $NEW_TOKEN --discovery-token-ca-cert-hash sha256:$CA_CERT_HASH"
  log "Worker node join command: $JOIN_COMMAND"
  echo "On the worker node, run the following command to join the cluster:"
  echo "$JOIN_COMMAND"
}

# Function to load IPVS modules and configure them to load on boot
configure_ipvs() {
    log "Loading IPVS modules..."
    sudo modprobe ip_vs || error_exit "Failed to load ip_vs module."
    sudo modprobe ip_vs_rr || error_exit "Failed to load ip_vs_rr module."
    sudo modprobe ip_vs_wrr || error_exit "Failed to load ip_vs_wrr module."
    sudo modprobe ip_vs_sh || error_exit "Failed to load ip_vs_sh module."
    sudo modprobe nf_conntrack || error_exit "Failed to load nf_conntrack module."

    log "Ensuring IPVS modules load on boot..."
    echo -e "ip_vs\nip_vs_rr\nip_vs_wrr\nip_vs_sh\nnf_conntrack_ipv4" | sudo tee /etc/modules-load.d/ipvs.conf

    log "Verifying loaded modules..."
    lsmod | grep -e ip_vs -e nf_conntrack_ipv4

    log "IPVS modules are configured and loaded successfully."
}

# Function to increase nofile limits to 1048576
increase_nofile_limits() {
    log "Increasing nofile limits..."
    grep -q "* soft nofile ${NOFILE_LIMIT}" /etc/security/limits.conf || echo "* soft nofile ${NOFILE_LIMIT}" | sudo tee -a /etc/security/limits.conf
    grep -q "* hard nofile ${NOFILE_LIMIT}" /etc/security/limits.conf || echo "* hard nofile ${NOFILE_LIMIT}" | sudo tee -a /etc/security/limits.conf
    grep -q "session required pam_limits.so" /etc/pam.d/system-auth || echo "session required pam_limits.so" | sudo tee -a /etc/pam.d/system-auth
    grep -q "fs.file-max = ${NOFILE_LIMIT}" /etc/sysctl.conf || echo "fs.file-max = ${NOFILE_LIMIT}" | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p
    log "Nofile limits increased successfully."
}

# Function to check and install required dependencies
install_dependencies() {
  local deps=(wget tar curl gpg)
  local missing=()
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
      missing+=("$dep")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    log "Installing missing dependencies: ${missing[*]}"
    sudo dnf -y install "${missing[@]}" || error_exit "Failed to install required dependencies: ${missing[*]}"
  else
    log "All required dependencies are already installed."
  fi
}

# Check for root
check_root() {
  if [[ $EUID -ne 0 ]]; then
    log "ERROR: This script must be run as root."
    exit 1
  fi
}

# Main function
main() {
  check_root
  install_dependencies
  log "Starting Kubernetes control plane node setup."
  set_control_plane_node_ip "$@"
  perform_upgrade
  increase_nofile_limits
  enable_cockpit
  disable_swap
  configure_ipvs
  configure_firewall
  verify_firewall_ports
  install_containerd
  create_containerd_service
  get_latest_kubeadm_version
  install_runc
  install_cni_plugins
  configure_containerd
  configure_kernel
  set_selinux_permissive
  install_kubernetes
  enable_kubelet
  update_kubeadm_config
  initialize_cluster
  configure_kubectl_for_users
  # install_pod_network (removed for Cilium)
  # display_cluster_info (removed for Cilium)
  create_kubeadm_token
  log "Kubernetes control plane node setup completed."
}

main "$@"
