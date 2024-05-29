 # Kubernetes on Rocky Linux
 
 ## Overview
 
Setting up a Kubernetes cluster manually can be a complex and time-consuming process. This repository aims to simplify the setup by providing two automated scripts: `install_k8_master.sh` for configuring the master node and `install_k8_worker.sh` for setting up worker nodes. These scripts are designed to run on Rocky Linux 8, leveraging automated steps to ensure a consistent and repeatable installation process.

The `install_k8_master.sh` script is responsible for preparing a node to act as the master in a Kubernetes cluster. This involves installing and configuring essential components such as containerd, kubelet, kubeadm, and kubectl, as well as setting up the necessary firewall rules, kernel parameters, and SELinux settings. Additionally, it initializes the Kubernetes cluster and installs a pod network add-on (Calico) to enable communication between pods across the cluster.

The `install_k8_worker.sh` script prepares worker nodes to join an existing Kubernetes cluster. Similar to the master node script, it installs and configures containerd, kubelet, and other necessary components, sets up firewall rules, kernel parameters, and adjusts SELinux settings. The script also ensures that each worker node can successfully communicate with the master node and join the cluster using the provided join command.
 
 ### Purpose
 
The primary purpose of these scripts is to streamline the deployment of a Kubernetes cluster on Rocky Linux 8 by automating the installation and configuration process. By using these scripts, administrators can reduce the potential for human error, ensure consistency across multiple nodes, and save time compared to manual setup methods.

These scripts are particularly useful for:

- **System Administrators**: Looking to quickly deploy and manage Kubernetes clusters.
- **DevOps Engineers**: Seeking to automate cluster setup as part of their CI/CD pipelines.
- **Developers**: Wanting to set up a local Kubernetes cluster for development and testing purposes.
 
 ## Features
 
 - Automated installation and configuration of Kubernetes components.
 - Setup of necessary firewall rules and kernel parameters.
 - Installation of container runtime (`containerd`), CNI plugins, and Kubernetes packages.
 - Configuration of SELinux to permissive mode.
 - Ability to detect and join worker nodes to the master node.
 - Logging for troubleshooting and auditing purposes.
 
 ## Requirements
 
 ### Software and Libraries
 
 - Rocky Linux 8+
 - Kubernetes 1.30
 - containerd 1.7.9
 - runc v1.1.10
 - CNI plugins v1.3.0
 - curl, wget, and other basic command-line utilities
 
 ### System Requirements
 
 - At least one master node and one worker node with Rocky Linux installed.
 - Sufficient CPU and memory resources on each node (minimum 2 CPU and 4GB RAM recommended).
 - Network connectivity between master and worker nodes.
 
 ## Installation
 
 1. Clone the repository to your master node:
    ```bash
    git clone https://github.com/OttawaCloudConsulting/rocky_linux_kubernetes_cluster.git
    cd rocky_linux_kubernetes_cluster
    ```
 
 2. Run the `install_k8_master.sh` script on the master node:
    ```bash
    sudo bash install_k8_master.sh
    ```
 
 3. After the master node is set up, run the `install_k8_worker.sh` script on each worker node:
    ```bash
    sudo bash install_k8_worker.sh
    ```
 
 4. Join each worker node to the cluster using the command provided by the master node setup process.
 
 ## Script Descriptions and Functions
 
 ### install_k8_master.sh
 
 This script sets up the master node of the Kubernetes cluster.
 
 - **perform_upgrade**: Upgrades all installed packages to the latest version.
 - **enable_cockpit**: Enables Cockpit for remote management.
 - **disable_swap**: Disables swap to ensure Kubernetes runs correctly.
 - **configure_firewall**: Configures firewall rules required for the master node.
 - **install_containerd**: Installs the containerd container runtime.
 - **create_containerd_service**: Creates a systemd service for containerd.
 - **install_runc**: Installs runc, the CLI tool for running containers.
 - **install_cni_plugins**: Installs CNI plugins required for networking.
 - **configure_containerd**: Configures containerd with the necessary settings.
 - **configure_kernel**: Configures kernel modules and sysctl parameters.
 - **set_selinux_permissive**: Sets SELinux to permissive mode.
 - **install_kubernetes**: Installs Kubernetes packages (kubeadm, kubelet, kubectl).
 - **enable_kubelet**: Enables and starts the kubelet service.
 - **initialize_cluster**: Initializes the Kubernetes cluster using kubeadm.
 - **configure_kubectl_for_users**: Configures kubectl for all users with home directories.
 - **install_pod_network**: Installs the Calico pod network add-on.
 - **display_cluster_info**: Displays cluster information and checks the status of the Calico pod.
 - **create_kubeadm_token**: Creates a new kubeadm token and displays the join command.
 
 ### install_k8_worker.sh
 
 This script sets up a worker node and joins it to the Kubernetes cluster.
 
 - **perform_upgrade**: Upgrades all installed packages to the latest version.
 - **disable_swap**: Disables swap to ensure Kubernetes runs correctly.
 - **configure_firewall**: Configures firewall rules required for the worker node.
 - **install_containerd**: Installs the containerd container runtime.
 - **create_containerd_service**: Creates a systemd service for containerd.
 - **install_runc**: Installs runc, the CLI tool for running containers.
 - **install_cni_plugins**: Installs CNI plugins required for networking.
 - **configure_containerd**: Configures containerd with the necessary settings.
 - **configure_kernel**: Configures kernel modules and sysctl parameters.
 - **set_selinux_permissive**: Sets SELinux to permissive mode.
 - **install_kubernetes**: Installs Kubernetes packages (kubeadm, kubelet, kubectl).
 - **enable_kubelet**: Enables and starts the kubelet service.
 
 ## Known Issues and Troubleshooting
 
 - **Timeouts**: nftables is the successor to iptables, and may need additional configuration for [Proxy Modes](https://kubernetes.io/docs/reference/networking/virtual-ips/)
 - **Port Conflicts**: Ensure no other processes are using the required Kubernetes ports (e.g., 10250) before running the scripts.
 - **Firewall Rules**: Double-check firewall rules if nodes cannot communicate.
 - **Network Configuration**: Verify network configuration if the worker nodes cannot join the master node.
 - **Logs**: Check log files (`/var/log/k8s_install.log` on master, `/var/log/k8s_worker_install.log` on workers) for detailed error messages.
 
 ## References to External Documentation

[Rocky Linux - Main](https://rockylinux.org)

[Firewalld - Documentation](https://firewalld.org/documentation/concepts.html)

[Cockpit Project](https://cockpit-project.org)

[Containerd - main](https://containerd.io)

[Containerd - Repository](https://github.com/containerd/containerd)

[Runc - Repository](https://github.com/opencontainers/runc)

[Open Container Initiative](https://opencontainers.org)

[Container Networking Plugins - Repository](https://github.com/containernetworking/plugins)

[Project Calico](https://docs.tigera.io)
 
[Kubernetes Documentation - Main](https://kubernetes.io/docs/home/#)

[Kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)

[Kubeadm - Kubernetes Cluster Bootstrapping Tool](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/)

[Kubelet](https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/)

[Kubetctl](https://kubernetes.io/docs/reference/kubectl/)

[Kubernetes Networking Guide](https://kubernetes.io/docs/concepts/cluster-administration/networking/)

[Kubernetes - Managing Resources](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)

[Kubernetes - Role-Based Access Control (RBAC)](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)

[Kubernetes - Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)

