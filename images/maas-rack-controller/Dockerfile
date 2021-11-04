ARG FROM=ubuntu:18.04
FROM ${FROM}

LABEL org.opencontainers.image.authors='airship-discuss@lists.airshipit.org, irc://#airshipit@freenode'
LABEL org.opencontainers.image.url='https://airshipit.org'
LABEL org.opencontainers.image.documentation='https://github.com/openstack/airship-maas'
LABEL org.opencontainers.image.source='https://git.openstack.org/openstack/airship-maas'
LABEL org.opencontainers.image.vendor='The Airship Authors'
LABEL org.opencontainers.image.licenses='Apache-2.0'

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

ENV DEBIAN_FRONTEND noninteractive
ENV container docker

ENV MAAS_VERSION 2.8.7-8611-g.f2514168f-0ubuntu1~18.04.1

RUN apt-get -qq update \
 && apt-get install -y \
        avahi-daemon \
        isc-dhcp-server \
        jq \
        libvirt-bin \
        patch \
        software-properties-common \
        sudo \
        systemd \
        ca-certificates \
# Don't start any optional services except for the few we need.
# (specifically, don't start avahi-daemon, isc-dhcp-server, or libvirtd)
 && find /etc/systemd/system \
         /lib/systemd/system \
         -path '*.wants/*' \
         -not -name '*journald*' \
         -not -name '*systemd-tmpfiles*' \
         -not -name '*systemd-user-sessions*' \
         -exec rm \{} \; \
 && systemctl set-default multi-user.target \
# Install maas from the ppa
 && add-apt-repository -yu ppa:maas/2.8 \
 && apt-get install -y \
        maas-rack-controller=$MAAS_VERSION \
 && rm -rf /var/lib/apt/lists/*

# Preserve the directory structure, permissions, and contents of /var/lib/maas
RUN mkdir -p /opt/maas/ && tar -cvzf /opt/maas/var-lib-maas.tgz /var/lib/maas

# register ourselves with the region controller
COPY scripts/register-rack-controller.service /lib/systemd/system/register-rack-controller.service
RUN systemctl enable register-rack-controller.service

# Patch so that Calico interfaces are ignored
COPY 2.8_nic_filter.patch /tmp/2.8_nic_filter.patch
COPY 2.8_secure_headers.patch /tmp/2.8_secure_headers.patch
# Patch so maas knows that "BMC error" is retriable
COPY 2.8_ipmi_error.patch /tmp/2.8_ipmi_error.patch
# Patch to space redfish request retries apart a bit, to avoid overwhelming the BMC
COPY 2.8_redfish_retries.patch /tmp/2.8_redfish_retries.patch

RUN cd /usr/lib/python3/dist-packages/provisioningserver/utils && patch network.py < /tmp/2.8_nic_filter.patch
RUN cd /usr/lib/python3/dist-packages/twisted/web && patch server.py < /tmp/2.8_secure_headers.patch
RUN cd /usr/lib/python3/dist-packages/provisioningserver/drivers/power && patch ipmi.py < /tmp/2.8_ipmi_error.patch
RUN cd /usr/lib/python3/dist-packages/provisioningserver/drivers/power && patch redfish.py < /tmp/2.8_redfish_retries.patch

# echo journalctl logs to the container's stdout
COPY scripts/journalctl-to-tty.service /etc/systemd/system/journalctl-to-tty.service
RUN systemctl enable journalctl-to-tty.service

# quiet sudo for the maas user
RUN umask 0337; echo 'Defaults:maas !pam_session, !syslog' > /etc/sudoers.d/99-maas-no-log

# avoid triggering bind9 high cpu utilization bug
RUN sed -i -e '$a\include "/etc/bind/bind.keys";' /etc/bind/named.conf

# initalize systemd
CMD ["/bin/bash", "-c", "exec /sbin/init --log-target=console 3>&1"]
