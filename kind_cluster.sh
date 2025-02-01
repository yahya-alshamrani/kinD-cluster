#!/bin/bash

create() {

  podman system reset -f

  podman network create kind -d bridge --subnet 10.90.0.0/24

  #jq '.ipv6_enabled = false' /etc/containers/networks/kind.json > /tmp/kind.json && mv /tmp/kind.json /etc/containers/networks/kind.json

  cat <<EOF | kind create cluster --config -
  kind: Cluster
  apiVersion: kind.x-k8s.io/v1alpha4
  name: istio-lab
  nodes:
    - role: control-plane
    - role: worker
      extraPortMappings:
        - containerPort: 80
          hostPort: 80
          protocol: TCP
        - containerPort: 443
          hostPort: 443
          protocol: TCP
  networking:
    ipFamily: ipv4
    podSubnet: "10.244.0.0/16"
    serviceSubnet: "10.96.0.0/12"
EOF

  # Create another host network
  INTERFACE=$(ip r | grep default | cut -d' ' -f 5)
  
  OS=$(grep -E "^ID=" /etc/os-release | cut -d'=' -f2 | tr -d '"')
  
  if [[ $OS == 'rhel' ]]; then
    if ! yum module list --installed | grep -q "^container-tools"; then
      yum module install -y container-tools
      systemctl enable --now netavark-dhcp-proxy.service
    fi
  else
    echo "Use RHEL!" && exit 169
  fi
  
  PODMAN_NETWORK_DRIVER=$(podman system info | grep backend | cut -d':' -f2 | tr -d ' ')
  if [[ $PODMAN_NETWORK_DRIVER != 'netavark' ]]; then
    if [[ -f /etc/containers/containers.conf ]]; then
      sed -i 's@network_backend.*@network_backend = "netavark@" /etc/containers/containers.conf
      systemctl restart -q podman.service &>/dev/null || echo "Error in restarting podman"
    else
      cp /usr/share/containers/containers.conf /etc/containers/
      sed -i 's@network_backend.*@network_backend = "netavark@" /etc/containers/containers.conf 

    fi
  fi 
  
  podman network create --driver macvlan --opt parent=$INTERFACE --ipam-driver dhcp macvlan

  podman network connect macvlan istio-lab-control-plane
  podman network connect macvlan istio-lab-worker

 
  kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/refs/heads/main/config/manifests/metallb-native.yaml || exit 169

  kubectl wait --for=condition=Ready pod -l component=controller --timeout=120s -n metallb-system

  cat <<EOF | kubectl apply -f -
    apiVersion: metallb.io/v1beta1
    kind: IPAddressPool
    metadata:
      name: lan
      namespace: metallb-system
    spec:
      addresses:
      - 192.168.0.240-192.168.0.250
EOF

  cat <<EOF | kubectl apply -f -
    apiVersion: metallb.io/v1beta1
    kind: L2Advertisement
    metadata:
      name: lan
      namespace: metallb-system
    spec:
      ipAddressPools:
      - lan
      interfaces:
      - eth1
EOF
}

destroy() {
  kind delete cluster --name istio-lab 
  podman system reset -f
}

up() {
  podman network disconnect macvlan istio-lab-control-plane
  podman network disconnect macvlan istio-lab-worker 
  podman start istio-lab-control-plane  
  podman start istio-lab-worker
  podman network connect macvlan istio-lab-control-plane
  podman network connect macvlan istio-lab-worker 
}

down() {
  podman stop istio-lab-control-plane  
  podman stop istio-lab-worker
}

# Check if an argument is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 {create|destroy|up|down}"
    exit 1
fi

# Handle the argument
case "$1" in
    create)
        create
        ;;
    destroy)
        destroy
        ;;
    up)
        up
        ;;
    down)
        down
        ;;
    *)
        echo "Invalid argument. Usage: $0 {create|destroy}"
        exit 1
        ;;
esac
