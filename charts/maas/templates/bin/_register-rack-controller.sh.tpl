#!/bin/bash

set -x

# Path where the host's cloud-init data is mounted
# to source the maas system_id
HOST_MOUNT_PATH=${HOST_MOUNT_PATH:-"/host_cloud-init/"}

unregister_maas_rack() {
  sys_id="$1"
  echo "Deregister this pod as MAAS rack controller ${sys_id}."
  maas login local "$MAAS_ENDPOINT" "$MAAS_API_KEY"
  maas local rack-controller delete "$sys_id"
  rm -f ~maas/maas_id
  rm -f ~maas/secret
}

register_maas_rack() {
  sys_id=${1:-""}
  echo "register-rack-controller URL: ${MAAS_ENDPOINT}"

  if [[ ! -z "$sys_id" ]]
  then
    echo "Using provided system id ${sys_id}."
    echo "$sys_id" > ~maas/maas_id
  fi

  # register forever
  while [ 1 ];
  do
    if maas-rack register --url=${MAAS_ENDPOINT} --secret="${MAAS_REGION_SECRET}";
    then
        echo "Successfully registered with MaaS Region Controller"
        break
    else
        echo "Unable to register with ${MAAS_ENDPOINT}... will try again"
        sleep 30
    fi;
  done;
}

get_host_identity() {
  # Check if the underlying host was deployed by MAAS
  if [[ -r "${HOST_MOUNT_PATH}/instance-data.json" ]]
  then
    grep -E 'instance-id' "${HOST_MOUNT_PATH}/instance-data.json" | head -1 | tr -d ' ",' | cut -d: -f 2
  else
    echo ""
  fi
}

get_pod_identity() {
  if [[ -r ~maas/maas_id ]]
  then
    cat ~maas/maas_id
  else
    echo ""
  fi
}

HOST_SYSTEM_ID=$(get_host_identity)
POD_SYSTEM_ID=$(get_pod_identity)

# This Pod state already has a MAAS identity
if [[ ! -z "$POD_SYSTEM_ID" ]]
then
  # If the pod maas identity doesn't match the
  # host maas identity, unregister the pod identity
  # as a rack controller
  if [[ "$HOST_SYSTEM_ID" != "$POD_SYSTEM_ID" ]]
  then
    unregister_maas_rack "$POD_SYSTEM_ID"
    register_maas_rack "$HOST_SYTEM_ID"
  else
    echo "Found existing maas_id, assuming already registered."
  fi

  exit 0
else
  register_maas_rack
fi
