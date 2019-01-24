ARG FROM=ubuntu:16.04
FROM ${FROM}

LABEL org.opencontainers.image.authors='airship-discuss@lists.airshipit.org, irc://#airshipit@freenode'
LABEL org.opencontainers.image.url='https://airshipit.org'
LABEL org.opencontainers.image.documentation='https://github.com/openstack/airship-maas'
LABEL org.opencontainers.image.source='https://git.openstack.org/openstack/airship-maas'
LABEL org.opencontainers.image.vendor='The Airship Authors'
LABEL org.opencontainers.image.licenses='Apache-2.0'

ENV DEBIAN_FRONTEND noninteractive
ENV container docker

# everything else below is to setup maas into the systemd initialized
# container based on ubuntu 16.04
RUN apt-get -qq update && \
    apt-get -y install \
    sudo \
    software-properties-common \
    libvirt-bin \
    systemd \
    patch \
    jq
# Don't start any optional services except for the few we need.

RUN find /etc/systemd/system \
         /lib/systemd/system \
         -path '*.wants/*' \
         -not -name '*journald*' \
         -not -name '*systemd-tmpfiles*' \
         -not -name '*systemd-user-sessions*' \
         -exec rm \{} \;
RUN systemctl set-default multi-user.target

# install syslog and enable it
RUN apt-get install -y rsyslog
RUN systemctl enable rsyslog.service

ENV MAAS_VERSION 2.3.5-6511-gf466fdb-0ubuntu1

# install maas
RUN rsyslogd; apt-get install -y maas-cli=$MAAS_VERSION maas-rack-controller=$MAAS_VERSION

RUN mv /usr/sbin/tcpdump /usr/bin/tcpdump
RUN ln -s /usr/bin/tcpdump /usr/sbin/tcpdump

# register ourselves with the region controller
COPY scripts/register-rack-controller.service /lib/systemd/system/register-rack-controller.service
RUN systemctl enable register-rack-controller.service

# Patch so that Calico interfaces are ignored
# dc6350: this appears to be fixed in maas master as of 10/4/2018, but that change is not in 2.3.5
COPY 2.3_nic_filter.patch /tmp/2.3_nic_filter.patch
# sh8121att: patch so that interfaces with MAC 00:00:00:00:00:00 omit the MAC address
COPY 2.3_mac_address.patch /tmp/2.3_mac_address.patch
# sh8121att: patch so query for RPC info contains proper Host header
copy 2.3_hostheader.patch /tmp/2.3_hostheader.patch

RUN cd /usr/lib/python3/dist-packages/provisioningserver/utils && patch network.py < /tmp/2.3_nic_filter.patch
RUN cd /usr/lib/python3/dist-packages/provisioningserver/utils && patch ipaddr.py < /tmp/2.3_mac_address.patch
RUN cd /usr/lib/python3/dist-packages/provisioningserver/rpc && patch clusterservice.py < /tmp/2.3_hostheader.patch

# echo journalctl logs to the container's stdout
COPY scripts/journalctl-to-tty.service /etc/systemd/system/journalctl-to-tty.service
RUN mkdir -p /etc/systemd/system/basic.target.wants ;\
    ln -s /etc/systemd/system/journalctl-to-tty.service /etc/systemd/system/basic.target.wants/journalctl-to-tty.service

# initalize systemd
CMD ["/bin/bash", "-c", "exec /sbin/init --log-target=console 3>&1"]
