#!/bin/bash
#
# install_k8_master.sh
#
# This script installs and configures a Kubernetes master node.
#
# Usage: sudo bash ./install_k8_master.sh
#
# This script requires root privileges.
#

set -e
set -u

# Constants
LOG_FILE="/var/log/k8s_install.log"
CONTAINERD_VERSION="1.7.9"
RUNC_VERSION="v1.1.10"
CNI_PLUGINS_VERSION="1.3.0"
K8S_VERSION="1.30"
KUBECONFIG="/etc/kubernetes/admin.conf"
CONTAINERD_BIN="/usr/local/bin/containerd"

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

# Performs a system upgrade to ensure all packages are up to date.
#
# This function runs the dnf package manager to upgrade all installed
# packages on the system.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes log messages indicating progress and any errors encountered.
perform_upgrade() {
  log "Performing system upgrade."
  sudo dnf -y upgrade || error_exit "System upgrade failed."
}

# Enables the Cockpit web-based interface for system management.
#
# This function enables and starts the Cockpit service to allow for
# remote management of the system.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes log messages indicating progress and any errors encountered.
enable_cockpit() {
  log "Enabling cockpit."
  sudo systemctl enable --now cockpit.socket || error_exit "Failed to enable cockpit."
}

# Disables swap to ensure Kubernetes runs correctly.
#
# This function disables swap, both immediately and by removing any
# swap entries from /etc/fstab.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes log messages indicating progress and any errors encountered.
disable_swap() {
  log "Disabling swap."
  sudo swapoff -a
  sudo sed -i '/swap/d' /etc/fstab
  sudo sed -i 's/^\/dev\/mapper\/centos-swap/#\/dev\/mapper\/centos-swap/' /etc/fstab
  sudo swapoff /dev/mapper/centos-swap || true
}

# Configures the firewall for Kubernetes.
#
# This function opens the necessary ports for Kubernetes in the firewall.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes log messages indicating progress and any errors encountered.
configure_firewall() {
  log "Configuring firewall."
  local ports=(6443 2379 2380 10250-10252 10255)
  for port in "${ports[@]}"; do
    sudo firewall-cmd --zone=public --add-port="${port}/tcp" --permanent || error_exit "Failed to add port $port to firewall."
  done
  sudo firewall-cmd --reload || error_exit "Failed to reload firewall."
}

# Verifies that the necessary firewall ports are open.
#
# This function checks that the required ports for Kubernetes are open
# in the firewall.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes log messages indicating progress and any errors encountered.
verify_firewall_ports() {
  log "Verifying firewall ports."
  local ports=(6443 2379 2380 10250 10251 10252 10255)
  for port in "${ports[@]}"; do
    sudo firewall-cmd --zone=public --query-port="${port}/tcp" || error_exit "Port $port is not open."
  done
}

# Installs containerd from the specified version.
#
# This function downloads and installs the specified version of containerd.
#
# Globals:
#   CONTAINERD_VERSION (read-only): The version of containerd to install.
#   CONTAINERD_BIN (read-only): The path to the containerd binary.
# Arguments:
#   None
# Outputs:
#   Writes log messages indicating progress and any errors encountered.
install_containerd() {
  log "Installing containerd."
  wget "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" -O /tmp/containerd.tar.gz || error_exit "Failed to download containerd."
  sudo tar Cxzvf /usr/local /tmp/containerd.tar.gz || error_exit "Failed to extract containerd."
}

# Creates a systemd service for containerd.
#
# This function creates and enables a systemd service for containerd.
#
# Globals:
#   CONTAINERD_BIN (read-only): The path to the containerd binary.
# Arguments:
#   None
# Outputs:
#   Writes log messages indicating progress and any errors encountered.
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

# Installs runc from the specified version.
#
# This function downloads and installs the specified version of runc.
#
# Globals:
#   RUNC_VERSION (read-only): The version of runc to install.
# Arguments:
#   None
# Outputs:
#   Writes log messages indicating progress and any errors encountered.
install_runc() {
  log "Installing runc."
  wget "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.amd64" -O /tmp/runc || error_exit "Failed to download runc."
  sudo install -m 755 /tmp/runc /usr/local/sbin/runc || error_exit "Failed to install runc."
}

# Installs CNI plugins from the specified version.
#
# This function downloads and installs the specified version of CNI plugins.
#
# Globals:
#   CNI_PLUGINS_VERSION (read-only): The version of CNI plugins to install.
# Arguments:
#   None
# Outputs:
#   Writes log messages indicating progress and any errors encountered.
install_cni_plugins() {
  log "Installing CNI plugins."
  wget "https://github.com/containernetworking/plugins/releases/download/v${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-v${CNI_PLUGINS_VERSION}.tgz" -O /tmp/cni-plugins.tgz || error_exit "Failed to download CNI plugins."
  sudo mkdir -p /opt/cni/bin || error_exit "Failed to create CNI plugins directory."
  sudo tar Cxzvf /opt/cni/bin /tmp/cni-plugins.tgz || error_exit "Failed to extract CNI plugins."
}

# Configures containerd with the default settings.
#
# This function generates the default containerd configuration and
# updates the SystemdCgroup setting to true.
#
# Globals:
#   CONTAINERD_BIN (read-only): The path to the containerd binary.
# Arguments:
#   None
# Outputs:
#   Writes log messages indicating progress and any errors encountered.
configure_containerd() {
  log "Configuring containerd."
  sudo mkdir -p /etc/containerd || error_exit "Failed to create containerd config directory."
  sudo "$CONTAINERD_BIN" config default | sudo tee /etc/containerd/config.toml || error_exit "Failed to generate containerd config."
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml || error_exit "Failed to update containerd config."
  sudo systemctl restart containerd || error_exit "Failed to restart containerd."
}

# Configures kernel modules and sysctl settings for Kubernetes.
#
# This function loads necessary kernel modules and configures sysctl
# parameters required by Kubernetes.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes log messages indicating progress and any errors encountered.
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

# Sets SELinux to permissive mode.
#
# This function sets SELinux to permissive mode to avoid any potential
# issues with Kubernetes installation and operation.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes log messages indicating progress and any errors encountered.
set_selinux_permissive() {
  log "Setting SELinux to permissive mode."
  sudo setenforce 0 || error_exit "Failed to set SELinux to permissive mode."
  sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config || error_exit "Failed to update SELinux config file."
}

# Installs Kubernetes packages.
#
# This function installs the required Kubernetes packages including
# kubeadm, kubelet, and kubectl.
#
# Globals:
#   K8S_VERSION (read-only): The version of Kubernetes to install.
# Arguments:
#   None
# Outputs:
#   Writes log messages indicating progress and any errors encountered.
install_kubernetes() {
  log "Installing Kubernetes packages."
  sudo dnf -y install ca-certificates curl gpg || error_exit "Failed to install prerequisites."
  
  cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key
EOF

  sudo dnf -y install kubeadm kubelet kubectl || error_exit "Failed to install Kubernetes packages."
}

# Enables and starts the kubelet service.
#
# This function enables and starts the kubelet service to ensure
# it runs on system startup.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes log messages indicating progress and any errors encountered.
enable_kubelet() {
  log "Enabling and starting kubelet."
  sudo systemctl enable --now kubelet || error_exit "Failed to enable kubelet."
}

# Initializes the Kubernetes cluster.
#
# This function initializes the Kubernetes cluster using kubeadm.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes log messages indicating progress and any errors encountered.
initialize_cluster() {
  log "Initializing Kubernetes cluster."
  sudo kubeadm init --v=5 || error_exit "Failed to initialize Kubernetes cluster."
}

# Configures kubectl for all users with home directories and for root.
#
# This function iterates over all users with home directories in /home, and
# sets up the kubeconfig file in each user's ~/.kube directory. It also
# sets up the kubeconfig for the root user.
#
# Globals:
#   KUBECONFIG (read-only): Path to the Kubernetes configuration file.
# Arguments:
#   None
# Outputs:
#   Writes log messages indicating progress and any errors encountered.
#   Copies the kubeconfig file to each user's ~/.kube directory.
#   Changes ownership of the kubeconfig file to the respective user.
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

# Displays Kubernetes cluster information.
#
# This function outputs the Kubernetes cluster information using kubectl.
#
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Displays cluster information on the screen and writes to log file.
display_cluster_info() {
  log "Displaying Kubernetes cluster information."
  kubectl cluster-info | tee -a "$LOG_FILE"
}

main() {
  log "Starting Kubernetes master node setup."
  perform_upgrade
  enable_cockpit
  disable_swap
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
  initialize_cluster
  configure_kubectl_for_users
  display_cluster_info
  log "Kubernetes master node setup completed."
}

main "$@"
