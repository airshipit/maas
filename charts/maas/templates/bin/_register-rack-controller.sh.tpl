#!/bin/bash

set -x

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
