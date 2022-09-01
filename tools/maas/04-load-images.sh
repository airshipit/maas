#!/bin/sh

set -ex

# import region controller
sudo -E docker image import \
  ${MAAS_REGION_CONTROLLER} \
  quay.io/airshipit/maas-region-controller:latest

# import rack controller
sudo -E docker image import \
  ${MAAS_RACK_CONTROLLER} \
  quay.io/airshipit/maas-rack-controller:latest

# import sstream cache
sudo -E docker image import \
  ${MAAS_SSTREAM_CACHE} \
  quay.io/airshipit/sstream-cache:latest
