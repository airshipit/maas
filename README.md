# MaaS Helm Artifacts

This repository holds artifacts supporting the deployment of [Canonical MaaS](https://maas.io)
in a Kubernetes cluster.

## Images

The MaaS install is made up of two required imags and one optional image. The Dockerfiles
in this repo can be used to build all three. These images are intended to be deployed
via a Kubernetes Helm chart.

### MaaS Region Controller

The regiond [Dockerfile](images/maas-region-controller/Dockerfile) builds a systemD-based
Docker image to run the MaaS Region API server and metadata server.

### MaaS Rack Controller

The rackd [Dockerfile](images/maas-rack-controller/Dockerfile) builds a systemD-based
Docker image to run the MaaS Rack controller and dependent services (DHCPd, TFTPd, etc...).
This image needs to be run in privileged host networking mode to function.

### MaaS Image Cache

The cache image [Dockerfile](images/sstream-cache/Dockerfile) simply provides a point-in-time
mirror of the maas.io image repository so that if you are deploying MaaS somewhere
without network connectivity, you have a local copy of Ubuntu. Currently this only
mirrors Ubuntu 16.04 Xenial and does not update the mirror after image creation.

## Charts

Also provided is a Kubernetes [Helm chart](charts/maas) to deploy the MaaS pieces and
integrates them. This chart depends on a previous deployment of Postgres. The recommended
avenue for this is the [Openstack Helm Postgres chart](https://github.com/openstack/openstack-helm/tree/master/postgresql)
but any Postgres instance should work.

### Overrides

Chart overrides are likely required to deploy MaaS into your environment

* values.labels.rack.node_selector_key - This is the Kubernetes label key for selecting nodes to deploy the rack controller
* values.labels.rack.node_selector_value - This is the Kubernetges label value for selecting nodes to deploy the rack controller
* values.labels.region.node_selector_key - this is the Kubernetes label key for selecting nodes to deploy the region controller
* values.labels.region.node_selector_value - This is the Kubernetes label value for selecting nodes to deploy the region controller
* values.conf.cache.enabled - Boolean on whether to use the repo cache image in the deployment
* values.conf.maas.url.maas_url - The URL rack controllers and nodes should use for accessing the region API (e.g. http://10.10.10.10:8080/MAAS)

### Deployment Flow

During deployment, the chart executes the below steps:

1. Initializes the Postgres DB for MaaS
1. Starts a Pod with the region controller and optionally the image cache sidecar container
1. Once the region controller is running, deploy a Pod with the rack controller and join it to the region controller.
1. Initialize the configuration of MaaS and start the image sync
1. Export an API key into a Kubernetes secret so other Pods can access the API if needed
