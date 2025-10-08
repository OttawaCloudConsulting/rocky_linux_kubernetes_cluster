#!/bin/bash
#
# install_k8_worker.sh
# This script installs and configures a Kubernetes worker node.
# Usage: sudo bash ./install_k8_worker.sh
# This script requires root privileges.


set -eux

# Source shared configuration
source ./k8s-config.conf || { echo "Failed to load configuration"; exit 1; }

# Ensure /usr/local/bin is in the PATH
export PATH="$PATH:/usr/local/bin"

# Logging function
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

# Check for root
check_root() {
  if [[ $EUID -ne 0 ]]; then
    log "ERROR: This script must be run as root."
    exit 1
  fi
}

# Function to perform upgrade
perform_upgrade() {
  log "Performing system upgrade."
  sudo dnf -y upgrade || error_exit "System upgrade failed."
  log "Installing jq dependency."
  sudo dnf -y install jq || error_exit "Failed to install jq."
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
  sudo firewall-cmd --permanent --new-service-from-file=$FIREWALLD_WORKER_FILE --name=k8s-worker || error_exit "Failed to create new service."
  sudo firewall-cmd --reload || error_exit "Failed to reload firewall."
  sudo firewall-cmd --permanent --add-service=k8s-worker || error_exit "Failed to add service to firewall."
  sudo firewall-cmd --permanent --add-service=cockpit || error_exit "Failed to add service to firewall."
  sudo firewall-cmd --reload || error_exit "Failed to reload firewall."
}

# Function to verify firewall ports
verify_firewall_ports() {
  log "Verifying firewall ports."
  local tcp_ports=(10250 10256 4240 4244 4245 9962 9963 9964)
  local udp_ports=(8472 6081 4789)
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

main() {
  check_root
  install_dependencies
  log "Starting Kubernetes worker node setup."
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
  log "Kubernetes worker node setup completed."
}

main "$@"
