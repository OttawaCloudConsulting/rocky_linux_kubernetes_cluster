# Kubernetes on Rocky Linux

- [Kubernetes on Rocky Linux](#kubernetes-on-rocky-linux)
  - [Overview](#overview)
    - [Purpose](#purpose)
  - [Features](#features)
  - [Requirements](#requirements)
    - [Software and Libraries](#software-and-libraries)
    - [System Requirements](#system-requirements)
  - [Installation](#installation)
  - [Script Descriptions and Functions](#script-descriptions-and-functions)
    - [install\_k8\_control\_plane.sh](#install_k8_control_planesh)
    - [install\_k8\_worker.sh](#install_k8_workersh)
  - [Configuration Management](#configuration-management)
    - [Centralized Configuration](#centralized-configuration)
    - [Firewall Configuration](#firewall-configuration)
  - [Known Issues and Troubleshooting](#known-issues-and-troubleshooting)
  - [References to External Documentation](#references-to-external-documentation)
    - [Operating System \& System Management](#operating-system--system-management)
    - [Container Runtime \& Standards](#container-runtime--standards)
    - [Container Network Interface (CNI)](#container-network-interface-cni)
    - [Kubernetes Core Documentation](#kubernetes-core-documentation)
    - [Kubernetes Advanced Topics](#kubernetes-advanced-topics)

## Overview

Setting up a Kubernetes cluster manually can be a complex and time-consuming process. This repository aims to simplify the setup by providing two automated scripts: `install_k8_control_plane.sh` for configuring the control plane node and `install_k8_worker.sh` for setting up worker nodes. These scripts are designed to run on Rocky Linux 8+, leveraging automated steps to ensure a consistent and repeatable installation process with Cilium CNI.

The `install_k8_control_plane.sh` script is responsible for preparing a node to act as the control plane in a Kubernetes cluster. This involves installing and configuring essential components such as containerd, kubelet, kubeadm, and kubectl, as well as setting up the necessary firewall rules, kernel parameters, and SELinux settings. Additionally, it initializes the Kubernetes cluster and prepares it for Cilium CNI installation (Cilium installation is performed post-bootstrap).

The `install_k8_worker.sh` script prepares worker nodes to join an existing Kubernetes cluster. Similar to the control plane node script, it installs and configures containerd, kubelet, and other necessary components, sets up firewall rules optimized for Cilium CNI and Hubble, kernel parameters, and adjusts SELinux settings. The script also ensures that each worker node can successfully communicate with the control plane node and join the cluster using the provided join command.

### Purpose

The primary purpose of these scripts is to streamline the deployment of a Kubernetes cluster on Rocky Linux 8 by automating the installation and configuration process. By using these scripts, administrators can reduce the potential for human error, ensure consistency across multiple nodes, and save time compared to manual setup methods.

These scripts are particularly useful for:

- **System Administrators**: Looking to quickly deploy and manage Kubernetes clusters.
- **DevOps Engineers**: Seeking to automate cluster setup as part of their CI/CD pipelines.
- **Developers**: Wanting to set up a local Kubernetes cluster for development and testing purposes.

## Features

- Automated installation and configuration of Kubernetes components with modern terminology (control plane vs master).
- Centralized configuration management through `k8s-config.conf` for version consistency.
- Service-based firewall configuration optimized for Cilium CNI and Hubble observability.
- Installation of container runtime (`containerd`), CNI plugins, and Kubernetes packages.
- Configuration of SELinux to permissive mode and system resource limits optimization.
- IPVS proxy mode configuration for improved performance.
- Automatic IP detection for control plane nodes.
- Comprehensive logging for troubleshooting and auditing purposes.
- Cockpit web console integration for system management.

## Requirements

### Software and Libraries

- Rocky Linux 8+
- Kubernetes 1.34+ (automatically detected latest stable version)
- containerd 2.1.4
- runc v1.3.1
- CNI plugins v1.8.0
- Cilium CNI (installed post-bootstrap)
- curl, wget, jq, and other basic command-line utilities

### System Requirements

- At least one control plane node and one worker node with Rocky Linux installed.
- Sufficient CPU and memory resources on each node (minimum 2 CPU and 4GB RAM recommended).
- Network connectivity between control plane and worker nodes.

## Installation

 1. Clone the repository to your control plane node:

    ```bash
    git clone https://github.com/OttawaCloudConsulting/rocky_linux_kubernetes_cluster.git
    cd rocky_linux_kubernetes_cluster
    ```

 2. Review and customize the configuration file if needed:

    ```bash
    # Optional: Edit k8s-config.conf to adjust versions or settings
    vi k8s-config.conf
    ```

 3. Run the `install_k8_control_plane.sh` script on the control plane node:

    ```bash
    # Auto-detect IP address
    sudo bash install_k8_control_plane.sh
    
    # Or specify control plane IP address
    sudo bash install_k8_control_plane.sh 192.168.1.10
    ```

 4. After the control plane node is set up, copy the configuration files to worker nodes and run the `install_k8_worker.sh` script:

    ```bash
    # On each worker node
    sudo bash install_k8_worker.sh
    ```

 5. Join each worker node to the cluster using the command provided by the control plane node setup process.

 6. Install Cilium CNI (post-bootstrap):

    ```bash
    # Install Cilium CLI
    CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    CLI_ARCH=amd64
    curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
    sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
    sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
    rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
    
    # Install Cilium with Hubble
    cilium install --version 1.15.6
    cilium hubble enable --ui
    
    # Verify installation
    cilium status --wait
    ```

## Script Descriptions and Functions

### install_k8_control_plane.sh

This script sets up the control plane node of the Kubernetes cluster with automatic IP detection and Cilium-ready configuration.

- **check_root**: Ensures the script is run with root privileges.
- **install_dependencies**: Installs required dependencies (wget, tar, curl, gpg).
- **set_control_plane_node_ip**: Auto-detects or accepts a manually specified control plane IP address.
- **perform_upgrade**: Upgrades all installed packages to the latest version and installs jq.
- **increase_nofile_limits**: Increases file descriptor limits for improved performance.
- **enable_cockpit**: Enables Cockpit web console for remote management.
- **disable_swap**: Disables swap to ensure Kubernetes runs correctly.
- **configure_ipvs**: Loads IPVS kernel modules for high-performance kube-proxy mode.
- **configure_firewall**: Configures service-based firewall rules optimized for Kubernetes and Cilium.
- **verify_firewall_ports**: Verifies that all required ports are properly opened.
- **install_containerd**: Installs the latest containerd container runtime.
- **create_containerd_service**: Creates and enables systemd service for containerd.
- **get_latest_kubeadm_version**: Automatically detects and uses the latest stable Kubernetes version.
- **install_runc**: Installs runc, the CLI tool for running containers.
- **install_cni_plugins**: Installs CNI plugins required for networking.
- **configure_containerd**: Configures containerd with systemd cgroup driver.
- **configure_kernel**: Configures kernel modules (overlay, br_netfilter) and sysctl parameters.
- **set_selinux_permissive**: Sets SELinux to permissive mode.
- **install_kubernetes**: Installs Kubernetes packages (kubeadm, kubelet, kubectl).
- **enable_kubelet**: Enables and starts the kubelet service.
- **update_kubeadm_config**: Updates kubeadm configuration with detected values.
- **initialize_cluster**: Initializes the Kubernetes cluster using kubeadm with IPVS proxy mode.
- **configure_kubectl_for_users**: Configures kubectl for all users with home directories and root.
- **create_kubeadm_token**: Creates a new kubeadm token and displays the join command for worker nodes.

### install_k8_worker.sh

This script sets up a worker node with Cilium and Hubble-optimized firewall rules and joins it to the Kubernetes cluster.

- **check_root**: Ensures the script is run with root privileges.
- **install_dependencies**: Installs required dependencies (wget, tar, curl, gpg).
- **perform_upgrade**: Upgrades all installed packages to the latest version and installs jq.
- **enable_cockpit**: Enables Cockpit web console for remote management.
- **disable_swap**: Disables swap to ensure Kubernetes runs correctly.
- **increase_nofile_limits**: Increases file descriptor limits for improved performance.
- **configure_ipvs**: Loads IPVS kernel modules for high-performance kube-proxy mode.
- **configure_firewall**: Configures service-based firewall rules optimized for worker nodes with Cilium and Hubble support.
- **verify_firewall_ports**: Verifies that all required ports are properly opened.
- **install_containerd**: Installs the containerd container runtime.
- **create_containerd_service**: Creates and enables systemd service for containerd.
- **install_runc**: Installs runc, the CLI tool for running containers.
- **install_cni_plugins**: Installs CNI plugins required for networking.
- **configure_containerd**: Configures containerd with systemd cgroup driver.
- **configure_kernel**: Configures kernel modules (overlay, br_netfilter) and sysctl parameters.
- **set_selinux_permissive**: Sets SELinux to permissive mode.
- **install_kubernetes**: Installs Kubernetes packages (kubeadm, kubelet, kubectl).
- **enable_kubelet**: Enables and starts the kubelet service.

## Configuration Management

### Centralized Configuration

All shared variables are managed through the `k8s-config.conf` file, including:

- Container runtime versions (containerd, runc, CNI plugins)
- Kubernetes version settings
- File paths and limits
- Network configuration

### Firewall Configuration

Firewall rules are managed through service definition files:

- `firewalld/k8s-controlplane.xml` - Control plane firewall service
- `firewalld/k8s-worker.xml` - Worker node firewall service

Both configurations include optimized port sets for:

- Kubernetes core services
- Cilium CNI and agent
- Hubble observability (UI, relay, metrics)
- VXLAN/Geneve overlay networking

## Known Issues and Troubleshooting

- **Cilium Installation**: This script prepares the cluster for Cilium but does not install it. Install Cilium post-bootstrap using the Cilium CLI or Helm.
- **Port Conflicts**: Ensure no other processes are using the required Kubernetes ports before running the scripts.
- **Firewall Rules**: The scripts use service-based firewall configuration. Verify services are properly loaded with `firewall-cmd --list-services`.
- **Network Configuration**: Verify network configuration if worker nodes cannot join the control plane node.
- **IPVS Requirements**: Ensure IPVS kernel modules are available if using IPVS proxy mode.
- **File Descriptor Limits**: The scripts increase nofile limits to 1048576 - verify system resources support this.
- **Logs**: Check log files (`/var/log/k8s_install.log`) for detailed error messages and troubleshooting information.

## References to External Documentation

### Operating System & System Management

- **[Rocky Linux](https://rockylinux.org)** - Enterprise-class Linux distribution used as the base OS
- **[Firewalld Documentation](https://firewalld.org/documentation/concepts.html)** - Dynamic firewall management tool
- **[Cockpit Project](https://cockpit-project.org)** - Web-based server management interface

### Container Runtime & Standards

- **[Containerd](https://containerd.io)** - Industry-standard container runtime
- **[Containerd Repository](https://github.com/containerd/containerd)** - Source code and releases
- **[Runc Repository](https://github.com/opencontainers/runc)** - CLI tool for spawning and running containers
- **[Open Container Initiative](https://opencontainers.org)** - Container format and runtime specifications
- **[CNI Plugins Repository](https://github.com/containernetworking/plugins)** - Standard networking plugins for containers

### Container Network Interface (CNI)

- **[Cilium Documentation](https://docs.cilium.io/)** - eBPF-based networking, observability, and security
- **[Cilium Quick Installation](https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/)** - Installation guide for Kubernetes
- **[Hubble Network Observability](https://docs.cilium.io/en/stable/observability/hubble/)** - Network visibility and monitoring

### Kubernetes Core Documentation

- **[Kubernetes Documentation](https://kubernetes.io/docs/home/#)** - Main documentation hub
- **[Kubeadm Installation](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)** - Installation instructions
- **[Kubeadm Cluster Bootstrapping](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/)** - Cluster setup guide
- **[Kubelet Reference](https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/)** - Node agent documentation
- **[Kubectl Reference](https://kubernetes.io/docs/reference/kubectl/)** - Command-line tool documentation

### Kubernetes Advanced Topics

- **[Kubernetes Networking](https://kubernetes.io/docs/concepts/cluster-administration/networking/)** - Cluster networking concepts
- **[Managing Resources](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)** - Resource management and limits
- **[Role-Based Access Control](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)** - Security and permissions
- **[Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)** - Storage management
