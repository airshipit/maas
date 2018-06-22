#!/bin/bash

set -x

if [[ -r ~maas/maas_id && -r ~maas/secret ]]
then
  echo "Found existing maas_id and secret, assuming already registered."
  exit 0
fi

echo "register-rack-controller URL: ${MAAS_ENDPOINT}"

# register forever
while [ 1 ];
do
    if maas-rack register --url=${MAAS_ENDPOINT} --secret="${MAAS_REGION_SECRET}";
    then
        echo "Successfully registered with MaaS Region Controller"
        break
    else
        echo "Unable to register with ${MAAS_ENDPOINT}... will try again"
        sleep 10
    fi;
done;
