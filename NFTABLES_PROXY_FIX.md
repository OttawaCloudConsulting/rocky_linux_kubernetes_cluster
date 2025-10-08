# nftables Fixes

## Overview

After the initial cluster creation, nodes where unable to communicate freely with each other.

## Testing

We created a dnsutils tool service `kubectl apply -f https://k8s.io/examples/admin/dns/dnsutils.yaml`

Performing a `kubectl exec -i -t dnsutils -- nslookup kubernetes.default` resulted in a timeout.

To verify if the issue is within the cluster or with dns, we tested with external facing dns using `kubectl exec -i -t dnsutils -- nslookup kubernetes.default` which also resulted in a timeout.

Logs can be checked during this process using `kubectl logs`:
```
    kubectl logs --namespace=kube-system -l k8s-app=calico-node
    kubectl logs --namespace=kube-system -l k8s-app=kube-dns
```

### Updates on Server

We update firewalld to use iptables:

```
sudo vi /etc/firewalld/firewalld.conf
```

```
# FirewallBackend
# Selects the firewall backend implementation.
# Choices are:
#       - nftables (default)
#       - iptables (iptables, ip6tables, ebtables and ipset)
# Note: The iptables backend is deprecated. It will be removed in a future
# release.
#FirewallBackend=nftables
FirewallBackend=iptables
```

We create a blacklist file:

```
sudo vi /etc/modprobe.d/10-blacklist-iptables.conf
```

```
    blacklist ip_tables
```

We then restart the firewalld service:

```
    sudo systemctl restart firewalld
```

### Updates in Kubectl

We need to update the kube-proxy service and the calico services

**Kube Proxy**

Edit the config map:
```
    kubectl edit configmap -n kube-system kube-proxy
```

The mode for nftables is not supported in production kubernetes, so we use the default with nftables masquerade:

```
    mode: ""
    nftables:
      masqueradeAll: true
      masqueradeBit: null
      minSyncPeriod: 0s
      syncPeriod: 0s
```

We saw log errors about MTU not being able to automaticalyl be set, so we update the calico configuration to specify interfaces. We add FELIX_IPTABLESBACKEND and FELIX_MTUIFACEPATTERN

```
    kubectl edit daemonset calico-node -n kube-system
```

```
    spec:
      containers:
      - env:
        - name: DATASTORE_TYPE
          value: kubernetes
        - name: WAIT_FOR_DATASTORE
          value: "true"
        - name: NODENAME
          valueFrom:
            fieldRef:
              apiVersion: v1
              fieldPath: spec.nodeName
        - name: CALICO_NETWORKING_BACKEND
          valueFrom:
            configMapKeyRef:
              key: calico_backend
              name: calico-config
        - name: CLUSTER_TYPE
          value: k8s,bgp
        - name: IP
          value: autodetect
        - name: CALICO_IPV4POOL_IPIP
          value: Always
        - name: CALICO_IPV4POOL_VXLAN
          value: Never
        - name: CALICO_IPV6POOL_VXLAN
          value: Never
        - name: FELIX_IPINIPMTU
          valueFrom:
            configMapKeyRef:
              key: veth_mtu
              name: calico-config
        - name: FELIX_VXLANMTU
          valueFrom:
            configMapKeyRef:
              key: veth_mtu
              name: calico-config
        - name: FELIX_WIREGUARDMTU
          valueFrom:
            configMapKeyRef:
              key: veth_mtu
              name: calico-config
        - name: CALICO_DISABLE_FILE_LOGGING
          value: "true"
        - name: FELIX_DEFAULTENDPOINTTOHOSTACTION
          value: ACCEPT
        - name: FELIX_IPV6SUPPORT
          value: "false"
        - name: FELIX_HEALTHENABLED
          value: "true"
        - name: FELIX_IPTABLESBACKEND
          value: NFT
        - name: FELIX_MTUIFACEPATTERN
          value: enX.*
```