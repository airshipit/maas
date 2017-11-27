[![Docker Repository on Quay](https://quay.io/repository/attcomdev/maas-rack/status "Docker Repository on Quay")](https://quay.io/repository/attcomdev/maas-region) Ubuntu MaaS Region Controller <br>
[![Docker Repository on Quay](https://quay.io/repository/attcomdev/maas-rack/status "Docker Repository on Quay")](https://quay.io/repository/attcomdev/maas-rack) Ubuntu MaaS Rack Controller

Overview
==================

The MaaS project attempts to build highly decoupled metal as a service containers for use on the Kubernetes platform.  Today, we only break the MaaS service into the traditional region and rack controllers and breaking it down further is a work in progress.

Building Containers
===================

```
$ make build
```

Launching on Kubernetes
=======================

This will create the bridge necessary for MaaS provisioning (fixed with the name 'maas' rigt now) and launch the region controller 
and rack controller containers on kubernetes using kubectl by leveraging the YAML manifests in maas/deployments. 

```
$ make kuber_bridge
 ...
 
$ make kuber_deploy
 sudo kubectl create -f deployment/maas-service.yaml
 service "maas-region-ui" created
 sudo kubectl create -f deployment/maas-region-deployment.yaml
 deployment "maas-region" created
 sudo kubectl create -f deployment/maas-rack-deployment.yaml
 deployment "maas-rack" created

```

The provisioning network is fixed (and configured by kuber_bridge) as 10.7.200.0/24. To connect
external physical hardware to this network, simply place the network interface into the maas bridge, e.g:

```
brctl addif maas eth1
```

To destroy the kubernetes resources, you can run:

```
$ make kuber_clean
 sudo kubectl delete deployment maas-region
 deployment "maas-region" deleted
 sudo kubectl delete deployment maas-rack
 deployment "maas-rack" deleted
 sudo kubectl delete service maas-region-ui
 service "maas-region-ui" deleted

```

Once the region controller comes up, and you can login as admin/admin, you must configure a gateway within the UI on the
10.7.200.0 network, setting that to 10.7.200.1.  You must also enable DHCP and set the primary rack controller to the 
maas rack container booted (it will be a drop down choice).  This will eventually be automated.

Running Containers
==================

```
$ make run_region
 sudo docker run -d -p 7777:80 -v /sys/fs/cgroup:/sys/fs/cgroup:ro --privileged --name maas-region-controller maas-region:dockerfile
d7462aabf4d8982621c30d7df36adf6c3e0f634701c0a070f7214301829fa92e
```

```
$ make run_rack
 sudo docker run -d -v /sys/fs/cgroup:/sys/fs/cgroup:ro --privileged --name maas-rack-controller maas-rack:dockerfile	
fb36837cd68e56356cad2ad853ae517201ee3349fd1f80039185b71d052c5326
```

Region Bootstrap
================

The `scripts/create-provision-network.sh` script attempts to bootstrap both an admin user (with the password admin) but also creates a maas provisioning network matching the docker default, namely 172.16.86.0/24.  Turning this into a more configurable setting and also allowing for a dedicated provisioning network that can be plugged in via bridging to an actual physical network is a work in progress.  However, with the calls we do make you should be able to see the rack controller connected with an active dhcpd process running in the UI.

Retrieving Region Controller Details
====================================

Note that retrieving the API key may not be possible as MaaS region initialization is
delayed within the containers init startup.  It may take 60 seconds or so in order
to retrieve the API key, during which you may see the following message:

```
$ make get_region_api_key
 sudo docker exec maas-region-controller maas-region-admin apikey --username maas
WARNING: The maas-region-admin command is deprecated and will be removed in a future version. From now on please use 'maas-region' instead.
CommandError: User does not exist.
make: *** [get_region_api_key] Error 1
```

When the API is up and the admin user registered you will see the following:

```
$ make get_region_api_key
 sudo docker exec maas-region-controller maas-region apikey --username admin
ksKQbjtTzjZrZy2yP7:jVq2g4x5FYdxDqBQ7P:KGfnURCrYSKmGE6k2SXWk4QVHVSJHBfr
```

You can also retrieve the region secret and IP address, used to initialize the 
rack controller:

```
$ make get_region_secret
 sudo docker exec maas-region-controller cat /var/lib/maas/secret && echo
2036ba7575697b03d73353fc72a01686
```

```
$ make get_region_ip_address
 sudo docker inspect --format '{{ .NetworkSettings.Networks.bridge.IPAddress }}' maas-region-controller
172.16.86.4
```

Link Rack and Region
====================

Finally, with the output above we can link the region controller with the rack controller
by feeding the rack controller the endpoint and secret it requires.  Shortly after MaaS
will initiate an image sync with the rack.

```
$ make register_rack -e URL=http://172.16.84.4 SECRET=2036ba7575697b03d73353fc72a01686
sudo docker exec maas-rack-controller maas-rack register --url http://172.16.84.4 --secret 2036ba7575697b03d73353fc72a01686
alan@hpdesktop:~/Workbench/att/attcomdev/dockerfiles/maas$ 
```

Finally, to access your MaaS UI, visit http://172.0.0.1:7777/MAAS/ and login as admin/admin.

