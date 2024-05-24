#!/bin/bash
# install_k8_master.sh
# This script installs and configures a Kubernetes master node.
# Usage: sudo bash ./install_k8_master.sh
# This script requires root privileges.


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
MASTER_NODE_IP="<master-node-ip>"  # Replace with your master node IP address

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
  local ports=(6443 2379 2380 10250-10252 10255)
  for port in "${ports[@]}"; do
    sudo firewall-cmd --zone=public --add-port="${port}/tcp" --permanent || error_exit "Failed to add port $port to firewall."
  done
  sudo firewall-cmd --reload || error_exit "Failed to reload firewall."
}

# Function to verify firewall ports
verify_firewall_ports() {
  log "Verifying firewall ports."
  local ports=(6443 2379 2380 10250 10251 10252 10255)
  for port in "${ports[@]}"; do
    sudo firewall-cmd --zone=public --query-port="${port}/tcp" || error_exit "Port $port is not open."
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
  sudo setenforce 0 || error_exit "Failed to set SELinux to permissive mode."
  sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config || error_exit "Failed to update SELinux config file."
}

# Function to install Kubernetes packages
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

# Function to enable and start kubelet
enable_kubelet() {
  log "Enabling and starting kubelet."
  sudo systemctl enable --now kubelet || error_exit "Failed to enable kubelet."
}

# Function to initialize Kubernetes cluster
initialize_cluster() {
  log "Initializing Kubernetes cluster."
  sudo kubeadm init --v=5 || error_exit "Failed to initialize Kubernetes cluster."
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

# Function to install the Calico pod network add-on
install_pod_network() {
  log "Installing Calico pod network add-on."
  kubectl apply -f "https://docs.projectcalico.org/manifests/calico.yaml" || error_exit "Failed to install Calico pod network add-on."
}

# Function to display Kubernetes cluster information and check Calico pod status
display_cluster_info() {
  log "Displaying Kubernetes cluster information."
  kubectl cluster-info | tee -a "$LOG_FILE"
  sleep 5
  log "Checking the status of the Calico pod network."
  while true; do
    calico_status=$(kubectl get pods -n kube-system -l k8s-app=calico-node -o jsonpath='{.items[0].status.phase}')
    echo "Calico pod status: $calico_status"
    if [[ "$calico_status" == "Running" ]]; then
      log "Calico pod is running."
      kubectl get pods -n kube-system -l k8s-app=calico-node | tee -a "$LOG_FILE"
      break
    fi
    sleep 5
  done
}

# Function to create a new kubeadm token and display the join command
create_kubeadm_token() {
  log "Creating a new kubeadm token."
  NEW_TOKEN=$(kubeadm token create) || error_exit "Failed to create kubeadm token."
  log "New kubeadm token created: $NEW_TOKEN"

  CA_CERT_HASH=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //')
  log "CA certificate hash: $CA_CERT_HASH"

  JOIN_COMMAND="sudo kubeadm join $MASTER_NODE_IP:6443 --token $NEW_TOKEN --discovery-token-ca-cert-hash sha256:$CA_CERT_HASH"
  log "Worker node join command: $JOIN_COMMAND"
  echo "On the worker node, run the following command to join the cluster:"
  echo $JOIN_COMMAND
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
  install_pod_network
  display_cluster_info
  create_kubeadm_token
  log "Kubernetes master node setup completed."
}

main "$@"
