# Join Artifacts Directory

This directory contains the configuration files required to join additional control-plane nodes to your Kubernetes cluster.

## Overview

When adding additional control-plane nodes to your cluster, you need specific credentials and configuration data from the primary (first) control-plane node. This directory stores those artifacts.

## Files in This Directory

### 1. `control-plane-join.conf`
Consolidated configuration file containing all the join parameters needed from the primary control-plane node:
- Control plane endpoint (IP:PORT)
- Join token
- CA certificate hash
- Certificate key

### 2. `node-ip.txt`
The IP address of the new control-plane node being added. This is the IP that will be advertised by this control-plane node's API server.

## Prerequisites

Before running the `install_k8_additional_control_plane.sh` script, you must:

1. Have a running Kubernetes cluster with at least one control-plane node
2. Have SSH access to the primary control-plane node
3. Generate fresh join credentials (tokens and certificate keys expire)

## How to Generate Join Artifacts

### On the Primary Control-Plane Node

Run the following commands on your **primary (first) control-plane node** to generate the required values:

#### Step 1: Upload Cluster Certificates
```bash
sudo kubeadm init phase upload-certs --upload-certs
```

This command will output a **certificate key** (valid for 2 hours). Copy this value.

Example output:
```
[upload-certs] Storing the certificates in Secret "kubeadm-certs" in the "kube-system" Namespace
[upload-certs] Using certificate key:
a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2
```

#### Step 2: Create a Join Token
```bash
sudo kubeadm token create
```

This will output a **join token** (valid for 24 hours). Copy this value.

Example output:
```
abcdef.0123456789abcdef
```

#### Step 3: Get the CA Certificate Hash
```bash
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \
  openssl rsa -pubin -outform der 2>/dev/null | \
  openssl dgst -sha256 -hex | sed 's/^.* //'
```

This will output the **CA certificate hash**. Copy this value.

Example output:
```
1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
```

#### Step 4 (Alternative): Get Complete Join Command
Alternatively, you can generate everything at once:
```bash
sudo kubeadm token create --print-join-command --certificate-key \
  $(sudo kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1)
```

This outputs the complete join command with all required values.

### On the New Control-Plane Node

#### Step 5: Update Configuration Files

1. Edit `control-plane-join.conf` and replace the placeholder values:
   ```bash
   CONTROL_PLANE_ENDPOINT="<primary-cp-ip>:6443"  # Replace with actual IP
   JOIN_TOKEN="<token-from-step-2>"                # Replace with actual token
   CA_CERT_HASH="<hash-from-step-3>"              # Replace with actual hash
   CERTIFICATE_KEY="<key-from-step-1>"            # Replace with actual key
   ```

2. Edit `node-ip.txt` and replace with the IP address of this new control-plane node:
   ```bash
   echo "192.168.1.101" > node-ip.txt  # Replace with actual IP
   ```

   Or let the script auto-detect it by leaving the file empty or removing it.

## Important Notes

### Token and Key Expiration
- **Join tokens** expire after 24 hours by default
- **Certificate keys** expire after 2 hours by default
- If you encounter errors, regenerate fresh tokens and keys from the primary control-plane

### Network Requirements
Ensure the new control-plane node can reach:
- Primary control-plane API server (port 6443)
- etcd cluster (ports 2379-2380)
- All other control-plane nodes

### Version Compatibility
The new control-plane node must run the same Kubernetes version as the existing control-plane nodes.

## Usage

Once you have populated the configuration files:

```bash
sudo bash ./install_k8_additional_control_plane.sh
```

The script will:
1. Read the configuration from `join_artifacts/control-plane-join.conf`
2. Read the node IP from `join_artifacts/node-ip.txt` (or auto-detect)
3. Perform system setup (containerd, kernel modules, firewall, etc.)
4. Join the cluster as an additional control-plane node
5. Configure kubectl for local use

## Troubleshooting

### "Token expired" Error
Generate a new token on the primary control-plane:
```bash
sudo kubeadm token create
```

### "Certificate key expired" Error
Upload certificates again on the primary control-plane:
```bash
sudo kubeadm init phase upload-certs --upload-certs
```

### "Connection refused" Error
Verify:
- Network connectivity to the primary control-plane
- Firewall rules allow traffic on required ports
- The control-plane endpoint IP/hostname is correct

### Node IP Detection Issues
Explicitly set the IP in `node-ip.txt` rather than relying on auto-detection.

## Security Considerations

⚠️ **IMPORTANT**: The files in this directory contain sensitive cluster credentials.

- Do not commit populated versions to version control
- Protect these files with appropriate permissions (chmod 600)
- Delete or rotate credentials after use
- Use secure channels (SSH, SCP) to transfer these files between nodes

## Load Balancer Setup (Out of Scope)

For true high-availability, you should configure a load balancer in front of your control-plane nodes. When doing so:
- Set `CONTROL_PLANE_ENDPOINT` to the load balancer's IP:PORT
- Ensure the load balancer is configured before adding additional control-plane nodes
- Refer to Kubernetes HA documentation for load balancer configuration

---

For more information, see:
- [Kubernetes HA Clusters](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/)
- [kubeadm join Documentation](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-join/)
