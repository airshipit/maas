#!/bin/bash

set -x

# Path where the host's cloud-init data is mounted
# to source the maas system_id
HOST_MOUNT_PATH=${HOST_MOUNT_PATH:-"/host_cloud-init/"}

get_impacted_nets() {
  system_id="$1"
  maas local fabrics read | jq -cr 'map(.vlans) | map(.[]) | map(select(.primary_rack == "'"$system_id"'" or .secondary_rack == "'"$system_id"'")) | .[] | {vid, fabric_id}'
}

detach_rack_controller() {
  system_id="$1"
  for net in $(get_impacted_nets "$system_id");
  do
    vid=$(echo "$net" | jq -r .vid)
    fid=$(echo "$net" | jq -r .fabric_id)
    maas local vlan update "$fid" "$vid" primary_rack='' secondary_rack=''
  done
}

unregister_maas_rack() {
  sys_id="$1"
  echo "Deregister this pod as MAAS rack controller ${sys_id}."

  maas login local "$MAAS_ENDPOINT" "$MAAS_API_KEY"

  if [[ $? -ne 0 ]];
  then
    echo "Could not login to MAAS API."
    exit $?
  fi

  detach_rack_controller "$sys_id"

  while [ 1 ];
  do
    maas local rack-controller delete "$sys_id"

    if [[ $? -ne 0 ]];
    then
      echo "Could not delete rack controller."
      sleep 10
    else
      break
    fi
  done

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
    if maas-rack register --url="${MAAS_ENDPOINT}" --secret="${MAAS_REGION_SECRET}";
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
    if $?;
    then
      echo "Unregister of $POD_SYSTEM_ID failed, exitting."
      exit 1
    fi
    register_maas_rack "$HOST_SYSTEM_ID"
  else
    echo "Found existing maas_id, assuming already registered."
  fi

  exit 0
else
  register_maas_rack
fi
