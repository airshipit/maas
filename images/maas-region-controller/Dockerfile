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

# Don't start any optional services except for the few we need.
RUN find /etc/systemd/system \
         /lib/systemd/system \
         -path '*.wants/*' \
         -not -name '*journald*' \
         -not -name '*systemd-tmpfiles*' \
         -not -name '*systemd-user-sessions*' \
         -exec rm \{} \;
RUN systemctl set-default multi-user.target

# everything else below is to setup maas into the systemd initialized
# container based on ubuntu 16.04
RUN apt-get -qq update && \
    apt-get -y install sudo \
                       software-properties-common \
                       jq

# TODO(alanmeadows)
# we need systemd 231 per https://github.com/systemd/systemd/commit/a1350640ba605cf5876b25abfee886488a33e50b
#RUN add-apt-repository ppa:pitti/systemd -y && add-apt-repository ppa:maas/stable -y && apt-get update
RUN apt-get install -y systemd

# install syslog and enable it
RUN apt-get install -y rsyslog
RUN systemctl enable rsyslog.service

ENV MAAS_VERSION 2.3.5-6511-gf466fdb-0ubuntu1

# install maas
RUN rsyslogd; apt-get install -y maas-cli=$MAAS_VERSION \
    maas-dns=$MAAS_VERSION \
    maas-region-api=$MAAS_VERSION \
    avahi-utils \
    dbconfig-pgsql=2.0.4ubuntu1 \
    iputils-ping \
    postgresql \
    tcpdump \
    python3-pip


RUN apt-get download maas-region-controller=$MAAS_VERSION && \
# remove postinstall script in order to avoid db_sync
    dpkg-deb --extract maas-region-controller*.deb maas-region-controller && \
    dpkg-deb --control maas-region-controller*.deb maas-region-controller/DEBIAN && \
    rm maas-region-controller/DEBIAN/postinst && \
    dpkg-deb --build maas-region-controller && \
    dpkg -i maas-region-controller.deb && \
    pg_dropcluster --stop 9.5 main

# 2.3 workarounds
COPY 2.3_route.patch /tmp/2.3_route.patch
COPY 2.3_kernel_package.patch /tmp/2.3_kernel_package.patch
COPY 2.3_bios_grub_partition.patch /tmp/2.3_bios_grub_partition.patch
COPY 2.3_bios_grub_preseed.patch /tmp/2.3_bios_grub_preseed.patch
# sh8121att: patch so that maas-enlist works with domains that contain '-'
COPY 2.3_maas_enlist.patch /tmp/2.3_maas_enlist.patch
# sh8121att: patch so that interfaces with MAC 00:00:00:00:00:00 omit the MAC address
COPY 2.3_mac_address.patch /tmp/2.3_mac_address.patch
# sh8121att: allow all requests via the proxy to allow it to work
# behind ingress
COPY 2.3_proxy_acl.patch /tmp/2.3_proxy_acl.patch
RUN cd /usr/lib/python3/dist-packages/maasserver && patch preseed_network.py < /tmp/2.3_route.patch
RUN cd /usr/lib/python3/dist-packages/maasserver && patch preseed.py < /tmp/2.3_kernel_package.patch
RUN cd /usr/lib/python3/dist-packages/maasserver/models && patch partition.py < /tmp/2.3_bios_grub_partition.patch
RUN cd /usr/lib/python3/dist-packages/maasserver && patch preseed_storage.py < /tmp/2.3_bios_grub_preseed.patch
RUN cd /usr/lib/python3/dist-packages/metadataserver/user_data/templates/snippets && patch maas_enlist.sh < /tmp/2.3_maas_enlist.patch
RUN cd /usr/lib/python3/dist-packages/provisioningserver/utils && patch ipaddr.py < /tmp/2.3_mac_address.patch
RUN cd /usr/lib/python3/dist-packages/provisioningserver/utils && patch ipaddr.py < /tmp/2.3_mac_address.patch
RUN cd /usr/lib/python3/dist-packages/provisioningserver/templates/proxy && patch maas-proxy.conf.template < /tmp/2.3_proxy_acl.patch

COPY journalctl-to-tty.service /etc/systemd/system/journalctl-to-tty.service
RUN mkdir -p /etc/systemd/system/basic.target.wants ;\
    ln -s /etc/systemd/system/journalctl-to-tty.service /etc/systemd/system/basic.target.wants/journalctl-to-tty.service

# initalize systemd
CMD ["/bin/bash", "-c", "exec /sbin/init --log-target=console 3>&1"]
