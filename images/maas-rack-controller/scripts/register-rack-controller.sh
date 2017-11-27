#!/bin/bash

# show env
env > /tmp/env

echo "register-rack-controller URL: ${MAAS_ENDPOINT}"

# note the secret must be a valid hex value

# register forever
while [ 1 ];
do
    if maas-rack register --url=http://${MAAS_ENDPOINT}/MAAS --secret="${MAAS_REGION_SECRET}";
    then
        echo "Successfully registered with MaaS Region Controller"
        break
    else
        echo "Unable to register with http://${MAAS_ENDPOINT}/MAAS... will try again"
        sleep 10
    fi;

done;
