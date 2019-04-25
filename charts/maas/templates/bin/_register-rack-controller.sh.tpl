#!/bin/bash

set -x

unregister_maas_rack() {
  # In oder to avoid the issue with race condition in maas,
  # do not de-register the dead maas-controller from mass-region
  # just delete the local state of the maas-controller's.
  echo "Deregistering this pod's local state in /var/lib/maas directory."
  rm -f /var/lib/maas/secret
  rm -f /var/lib/maas/maas_id
}

register_maas_rack() {
  echo "register-rack-controller URL: ${MAAS_ENDPOINT}"

  # register forever until success
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

unregister_maas_rack
register_maas_rack
