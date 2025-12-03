#!/bin/bash

# Copyright 2017 The Openstack-Helm Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.



# MAAS_ENDPOINT should be set to the MAAS API endpoint
# MAAS_API_KEY should be set to the MAAS API key

if [ -z "${MAAS_ENDPOINT}" ] || [ -z "${MAAS_API_KEY}" ]; then
  echo "MAAS_ENDPOINT and MAAS_API_KEY must be set"
  exit 1
fi
export MAAS_ENDPOINT
export MAAS_API_KEY

maas login admin "${MAAS_ENDPOINT}" "${MAAS_API_KEY}"

# Wait for this rack controller to be registered and running
echo "Waiting for local rack controller to be registered and running..."
MY_SYSTEM_ID=""
MAX_WAIT=300  # 5 minutes
ELAPSED=0
while [[ -z "${MY_SYSTEM_ID}" && ${ELAPSED} -lt ${MAX_WAIT} ]]; do
    # Get the system_id of this rack controller by matching hostname
    MY_HOSTNAME=$(hostname)
    MY_SYSTEM_ID=$(maas admin rack-controllers read 2>/dev/null | jq -r --arg hostname "${MY_HOSTNAME}" '.[] | select(.hostname == $hostname) | select(([.service_set[]? | select(.name=="rackd")] | .[]? .status) == "running") | .system_id // empty')

    if [[ -z "${MY_SYSTEM_ID}" ]]; then
        echo "Local rack controller not yet running (hostname=${MY_HOSTNAME}), waiting..."
        sleep 10
        ELAPSED=$((ELAPSED + 10))
    fi
done

if [[ -z "${MY_SYSTEM_ID}" ]]; then
    echo "ERROR: Local rack controller failed to register and become running within ${MAX_WAIT}s. Skipping cleanup."
    exit 0
fi

echo "Local rack controller registered with system_id: ${MY_SYSTEM_ID}"

# Get list of node names where maas-rack pods are currently scheduled via Kubernetes API
echo "Querying Kubernetes for active maas-rack pods..."
K8S_API="https://kubernetes.default.svc.cluster.local"
K8S_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
K8S_CACERT="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
NAMESPACE=${MAAS_RACK_NAMESPACE:-ucp}

# Get all maas-rack pods and extract their node names
ACTIVE_NODES=$(wget --quiet --ca-certificate="${K8S_CACERT}" \
    --header="Authorization: Bearer ${K8S_TOKEN}" \
    --output-document=- \
    "${K8S_API}/api/v1/namespaces/${NAMESPACE}/pods?labelSelector=application%3Dmaas%2Ccomponent%3Drack" 2>/dev/null | \
    jq -r '.items[]? | select(.status.phase == "Running") | .spec.nodeName // empty' | sort -u)

# Ensure MY_HOSTNAME is included in the active nodes list
if ! echo "${ACTIVE_NODES}" | grep -q "^${MY_HOSTNAME}$"; then
    ACTIVE_NODES=$(echo -e "${ACTIVE_NODES}\n${MY_HOSTNAME}" | grep -v '^$' | sort -u)
fi

echo "Active maas-rack pod nodes: ${ACTIVE_NODES}"

# Build jq filter to exclude nodes with active pods
ACTIVE_NODES_ARRAY=$(echo "${ACTIVE_NODES}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
echo "Nodes to protect from cleanup: ${ACTIVE_NODES_ARRAY}"

# Clean up orphaned racks entries that have not running status (excluding this controller and nodes with active pods)
MAAS_RACK_CONTROLLERS=$(maas admin rack-controllers read | jq -r --arg my_id "${MY_SYSTEM_ID}" --argjson active_nodes "${ACTIVE_NODES_ARRAY}" \
    'map({"system_id":.system_id,"hostname":.hostname,"service_set":(.service_set[] | select(.name=="rackd"))}) |
     map(select(.service_set.status != "running" and .system_id != $my_id and ([.hostname] | inside($active_nodes) | not))) |
     .[] | .system_id')

if [[ -z "${MAAS_RACK_CONTROLLERS}" ]]; then
    echo "No orphaned rack controllers to clean up."
else
    for sys_id in ${MAAS_RACK_CONTROLLERS}; do
        printf "Unregistering rack controller: %s" "${sys_id}"
        echo
        maas admin rack-controller delete ${sys_id} force=true
    done
    echo "Orphaned rack controllers cleanup complete."
fi

# Register racks as DHCP servers for the network with pxe name
# Enable DHCP
echo "[DHCP] Enabling / validating DHCP on PXE subnet..."

# 1. Locate PXE subnet ID
PXE_SUBNET_ID=$( maas admin subnets read | jq -r '.[] | select(.name=="pxe") | .id' | head -n1 )

if [[ -z "${PXE_SUBNET_ID}" || "${PXE_SUBNET_ID}" == "null" ]]; then
  echo "[DHCP] PXE subnet not found; skipping DHCP enable."
else
  # 2. Extract VLAN vid and fabric id for that subnet
  SUBNET_JSON=$(maas admin subnet read "${PXE_SUBNET_ID}" 2>/dev/null || true)
  VLAN_ID=$(echo "${SUBNET_JSON}" | jq -r '.vlan.vid // empty')
  FABRIC_ID=$(echo "${SUBNET_JSON}" | jq -r '.vlan.fabric_id // .vlan.fabric // empty')
  if [[ -z "${VLAN_ID}" || -z "${FABRIC_ID}" ]]; then
    echo "[DHCP] Missing VLAN vid or fabric id (vid=${VLAN_ID:-<none>} fabric=${FABRIC_ID:-<none>}); skipping."
  else
    # 3. Read current VLAN state (fabric + vid)
    CURRENT_VLAN_JSON=$(maas admin vlan read "${FABRIC_ID}" "${VLAN_ID}" 2>/dev/null || true)
    CURRENT_PRIMARY=$(echo "${CURRENT_VLAN_JSON}" | jq -r '.primary_rack // empty')
    CURRENT_SECONDARY=$(echo "${CURRENT_VLAN_JSON}" | jq -r '.secondary_rack // empty')
    CURRENT_DHCP=$(echo "${CURRENT_VLAN_JSON}" | jq -r '.dhcp_on // false')

    echo "[DHCP] Current VLAN state: fabric=${FABRIC_ID} vid=${VLAN_ID} current_primary=${CURRENT_PRIMARY:-<none>} current_secondary=${CURRENT_SECONDARY:-<none>} current_dhcp=${CURRENT_DHCP}"

    # 4. Get list of running rack controllers (including those starting up)
    # Accept both "running" and other non-dead states to avoid deregistering racks that are still initializing
    ALL_RACKS_JSON=$(maas admin rack-controllers read 2>/dev/null)

    # Get hostnames from rack controllers that have active pods in Kubernetes
    RACKS_WITH_ACTIVE_PODS=$(echo "${ALL_RACKS_JSON}" | jq -r --argjson active_nodes "${ACTIVE_NODES_ARRAY}" \
        '.[] | select([.hostname] | inside($active_nodes)) | .system_id')

    # Get racks with running rackd status
    RUNNING_RACKS=$(echo "${ALL_RACKS_JSON}" | jq -r \
        '[ .[] | {system_id, rackd_status: ([.service_set[]? | select(.name=="rackd")] | .[]? .status) } ] |
         map(select(.rackd_status=="running")) | .[].system_id')

    # Combine both lists and deduplicate
    ACTIVE_RACKS=$(echo -e "${RUNNING_RACKS}\n${RACKS_WITH_ACTIVE_PODS}" | grep -v '^$' | sort -u)
    RUNNING_RACKS_ARRAY=(${ACTIVE_RACKS})

    echo "[DHCP] Active rack controllers (running or with active pods): ${RUNNING_RACKS_ARRAY[@]}"

    # 5. Determine target primary and secondary
    # Strategy: Keep existing assignments if they're still running, otherwise assign from available running racks
    TARGET_PRIMARY=""
    TARGET_SECONDARY=""

    # Check if current primary is still running
    if [[ -n "${CURRENT_PRIMARY}" ]] && echo "${RUNNING_RACKS}" | grep -q "^${CURRENT_PRIMARY}$"; then
        TARGET_PRIMARY="${CURRENT_PRIMARY}"
        echo "[DHCP] Keeping existing primary: ${TARGET_PRIMARY}"
    fi

    # Check if current secondary is still running
    if [[ -n "${CURRENT_SECONDARY}" ]] && echo "${RUNNING_RACKS}" | grep -q "^${CURRENT_SECONDARY}$"; then
        TARGET_SECONDARY="${CURRENT_SECONDARY}"
        echo "[DHCP] Keeping existing secondary: ${TARGET_SECONDARY}"
    fi

    # Fill in missing primary from running racks
    if [[ -z "${TARGET_PRIMARY}" ]] && [[ ${#RUNNING_RACKS_ARRAY[@]} -ge 1 ]]; then
        for rack in "${RUNNING_RACKS_ARRAY[@]}"; do
            if [[ "${rack}" != "${TARGET_SECONDARY}" ]]; then
                TARGET_PRIMARY="${rack}"
                echo "[DHCP] Assigning new primary: ${TARGET_PRIMARY}"
                break
            fi
        done
    fi

    # Fill in missing secondary from running racks
    if [[ -z "${TARGET_SECONDARY}" ]] && [[ ${#RUNNING_RACKS_ARRAY[@]} -ge 2 ]]; then
        for rack in "${RUNNING_RACKS_ARRAY[@]}"; do
            if [[ "${rack}" != "${TARGET_PRIMARY}" ]]; then
                TARGET_SECONDARY="${rack}"
                echo "[DHCP] Assigning new secondary: ${TARGET_SECONDARY}"
                break
            fi
        done
    fi

    if [[ -z "${TARGET_PRIMARY}" ]]; then
      echo "[DHCP] No running rack controllers available to set as primary."
    elif [[ -z "${TARGET_SECONDARY}" ]]; then
      # Only one rack available - set it as primary only
      echo "[DHCP] Only one rack controller available. Setting primary='${TARGET_PRIMARY}' without secondary."
      echo "[DHCP] Target configuration: primary=${TARGET_PRIMARY} secondary=<none>"

      NEED_PRIMARY_CHANGE=false
      NEED_DHCP_ENABLE=false

      [[ "${CURRENT_PRIMARY}" != "${TARGET_PRIMARY}" ]] && NEED_PRIMARY_CHANGE=true
      [[ "${CURRENT_DHCP}" != "true" ]] && NEED_DHCP_ENABLE=true

      if ! $NEED_PRIMARY_CHANGE && ! $NEED_DHCP_ENABLE; then
        echo "[DHCP] VLAN already has correct primary & DHCP enabled."
      else
        # 6. Perform update(s) for single rack
        if $NEED_DHCP_ENABLE && $NEED_PRIMARY_CHANGE; then
          echo "[DHCP] Updating primary='${TARGET_PRIMARY}' and enabling DHCP..."
          maas admin vlan update "${FABRIC_ID}" "${VLAN_ID}" primary_rack="${TARGET_PRIMARY}" dhcp_on=true
        else
          if $NEED_PRIMARY_CHANGE; then
            echo "[DHCP] Updating primary rack: primary='${TARGET_PRIMARY}'..."
            maas admin vlan update "${FABRIC_ID}" "${VLAN_ID}" primary_rack="${TARGET_PRIMARY}"
          fi
          if $NEED_DHCP_ENABLE; then
            echo "[DHCP] Enabling DHCP..."
            maas admin vlan update "${FABRIC_ID}" "${VLAN_ID}" dhcp_on=true
          fi
        fi

        # 7. Verify post state
        POST_JSON=$(maas admin vlan read "${FABRIC_ID}" "${VLAN_ID}" 2>/dev/null || true)
        echo "[DHCP] Post-update state: $(echo "${POST_JSON}" | jq '{fabric: .fabric_id, vid: .vid, dhcp_on: .dhcp_on, primary_rack: .primary_rack, secondary_rack: .secondary_rack}')"
      fi
    else
      # Two or more racks available - set both primary and secondary
      echo "[DHCP] Target configuration: primary=${TARGET_PRIMARY} secondary=${TARGET_SECONDARY}"

      NEED_PRIMARY_CHANGE=false
      NEED_SECONDARY_CHANGE=false
      NEED_DHCP_ENABLE=false

      [[ "${CURRENT_PRIMARY}" != "${TARGET_PRIMARY}" ]] && NEED_PRIMARY_CHANGE=true
      [[ "${CURRENT_SECONDARY}" != "${TARGET_SECONDARY}" ]] && NEED_SECONDARY_CHANGE=true
      [[ "${CURRENT_DHCP}" != "true" ]] && NEED_DHCP_ENABLE=true

      if ! $NEED_PRIMARY_CHANGE && ! $NEED_SECONDARY_CHANGE && ! $NEED_DHCP_ENABLE; then
        echo "[DHCP] VLAN already matches desired primary/secondary & DHCP enabled."
      else
        # 6. Perform update(s)
        if $NEED_DHCP_ENABLE && ( $NEED_PRIMARY_CHANGE || $NEED_SECONDARY_CHANGE ); then
          echo "[DHCP] Updating primary='${TARGET_PRIMARY}' secondary='${TARGET_SECONDARY}' and enabling DHCP..."
          maas admin vlan update "${FABRIC_ID}" "${VLAN_ID}" primary_rack="${TARGET_PRIMARY}" secondary_rack="${TARGET_SECONDARY}" dhcp_on=true
        else
          if $NEED_PRIMARY_CHANGE || $NEED_SECONDARY_CHANGE; then
            echo "[DHCP] Updating racks: primary='${TARGET_PRIMARY}' secondary='${TARGET_SECONDARY}'..."
            maas admin vlan update "${FABRIC_ID}" "${VLAN_ID}" primary_rack="${TARGET_PRIMARY}" secondary_rack="${TARGET_SECONDARY}"
          fi
          if $NEED_DHCP_ENABLE; then
            echo "[DHCP] Enabling DHCP..."
            maas admin vlan update "${FABRIC_ID}" "${VLAN_ID}" dhcp_on=true
          fi
        fi

        # 7. Verify post state
        POST_JSON=$(maas admin vlan read "${FABRIC_ID}" "${VLAN_ID}" 2>/dev/null || true)
        echo "[DHCP] Post-update state: $(echo "${POST_JSON}" | jq '{fabric: .fabric_id, vid: .vid, dhcp_on: .dhcp_on, primary_rack: .primary_rack, secondary_rack: .secondary_rack}')"
      fi
    fi
  fi
fi