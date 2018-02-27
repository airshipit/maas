FROM ubuntu:16.04

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
    apt-get -y install sudo software-properties-common

# TODO(alanmeadows)
# we need systemd 231 per https://github.com/systemd/systemd/commit/a1350640ba605cf5876b25abfee886488a33e50b
#RUN add-apt-repository ppa:pitti/systemd -y && add-apt-repository ppa:maas/stable -y && apt-get update
RUN apt-get install -y systemd

# install syslog and enable it
RUN apt-get install -y rsyslog
RUN systemctl enable rsyslog.service

ENV MAAS_VERSION 2.3.0-6434-gd354690-0ubuntu1~16.04.1

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
COPY 2.3_nat_fix.patch /tmp/2.3_nat_fix.patch
COPY 2.3_proxy_port.patch /tmp/2.3_proxy_port.patch
COPY 2.3_route.patch /tmp/2.3_route.patch
RUN cd /usr/lib/python3/dist-packages/maasserver/utils && patch __init__.py < /tmp/2.3_nat_fix.patch
RUN cd /usr/lib/python3/dist-packages/maasserver && patch compose_preseed.py < /tmp/2.3_proxy_port.patch
RUN cd /usr/lib/python3/dist-packages/maasserver && patch preseed_network.py < /tmp/2.3_route.patch

# initalize systemd
CMD ["/sbin/init"]
