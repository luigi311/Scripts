#!/bin/bash

# Retrieve the list of node names in the cluster
NODES_LIST=$(pvecm nodes | awk 'NR>4 {print $3}')

# Convert the node names into an array
NODES=($NODES_LIST)

# Get the current host's name
CURRENT_HOST=$(hostname)

# Remove the current host from the NODES array so it can be handled last
REMOTE_NODES=()
for NODE in "${NODES[@]}"; do
  if [ "$NODE" != "$CURRENT_HOST" ]; then
    REMOTE_NODES+=("$NODE")
  fi
done

# For debugging (optional)
echo "All Nodes: ${NODES[@]}"
echo "Current Host: ${CURRENT_HOST}"
echo "Remote Nodes: ${REMOTE_NODES[@]}"

# Set HA resources to maintenance mode on all nodes
for NODE in "${NODES[@]}"; do
  ssh root@$NODE 'for resource in $(ha-manager status | awk "/enabled/{print \$1}"); do
    ha-manager set $resource --maintenance 1
  done'
done

# Shutdown all VMs and LXCs on all nodes
for NODE in "${NODES[@]}"; do
  ssh root@$NODE 'for vmid in $(qm list | awk "NR>1 {print \$1}"); do
    qm shutdown $vmid
  done'
  ssh root@$NODE 'for ct_id in $(pct list | awk "NR>1 {print \$1}"); do
    pct shutdown $ct_id
  done'
done

# Wait for all VMs and LXCs to stop
ALL_STOPPED=0
while [ $ALL_STOPPED -eq 0 ]; do
  ALL_STOPPED=1
  for NODE in "${NODES[@]}"; do
    RUNNING_VMS=$(ssh root@$NODE 'qm list | grep running | wc -l')
    RUNNING_CTS=$(ssh root@$NODE 'pct list | grep running | wc -l')
    if [ $RUNNING_VMS -gt 0 ] || [ $RUNNING_CTS -gt 0 ]; then
      ALL_STOPPED=0
      break
    fi
  done
  if [ $ALL_STOPPED -eq 0 ]; then
    echo "Waiting for VMs and LXCs to shut down..."
    sleep 5
  fi
done

# Stop HA services on all nodes
for NODE in "${NODES[@]}"; do
  ssh root@$NODE 'systemctl stop pve-ha-lrm'
  ssh root@$NODE 'systemctl stop pve-ha-crm'
done

# Set ceph flags for maintanence
ceph osd set noout
ceph osd set nodown

# Stop Ceph services and shutdown remote nodes
for NODE in "${REMOTE_NODES[@]}"; do
  ssh root@"$NODE" 'shutdown -h now'
done

# Finally, stop Ceph services and shutdown the current host last
shutdown -h now
