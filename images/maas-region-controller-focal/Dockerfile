ARG FROM=ubuntu:20.04
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

ENV MAAS_VERSION 1:3.0.0-10029-g.986ea3e45-0ubuntu1~20.04.1

RUN apt-get -qq update \
 && apt-get install -y \
        avahi-daemon \
        jq \
        patch \
        software-properties-common \
        sudo \
        systemd \
        cron \
        ca-certificates \
# Don't start any optional services except for the few we need.
# (specifically, don't start avahi-daemon)
 && find /etc/systemd/system \
         /lib/systemd/system \
         -path '*.wants/*' \
         -not -name '*journald*' \
         -not -name '*systemd-tmpfiles*' \
         -not -name '*systemd-user-sessions*' \
         -exec rm \{} \; \
 && systemctl set-default multi-user.target \
# Install maas from the ppa
 && add-apt-repository -yu ppa:maas/3.0 \
 && apt-get install -y \
        maas-region-api=$MAAS_VERSION \
        # tcpdump is required by /usr/lib/maas/beacon-monitor
        tcpdump \
 && rm -rf /var/lib/apt/lists/*

# Preserve the directory structure, permissions, and contents of /var/lib/maas
RUN mkdir -p /opt/maas/ && tar -cvzf /opt/maas/var-lib-maas.tgz /var/lib/maas

# MAAS workarounds
COPY 3.0_route.patch /tmp/3.0_route.patch
COPY 3.0_kernel_package.patch /tmp/3.0_kernel_package.patch
COPY 3.0_bios_grub_partition.patch /tmp/3.0_bios_grub_partition.patch
# sh8121att: allow all requests via the proxy to allow it to work
# behind ingress
COPY 3.0_proxy_acl.patch /tmp/3.0_proxy_acl.patch
# Patch to add retrying to MaaS BMC user setup, and improve exception handling
COPY 3.0_configure_ipmi_user.patch /tmp/3.0_configure_ipmi_user.patch
COPY 3.0_secure_headers.patch /tmp/3.0_secure_headers.patch
COPY 3.0_region_secret_rotate.patch /tmp/3.0_region_secret_rotate.patch
COPY 3.0_partitiontable_does_not_exist.patch /tmp/3.0_partitiontable_does_not_exist.patch
# Allow tags with '/' symbols
COPY 3.0_regex_tags.patch /tmp/3.0_regex_tags.patch

RUN cd /usr/lib/python3/dist-packages/maasserver && patch preseed_network.py < /tmp/3.0_route.patch
RUN cd /usr/lib/python3/dist-packages/maasserver && patch preseed.py < /tmp/3.0_kernel_package.patch
RUN cd /usr/lib/python3/dist-packages/maasserver/models && patch partition.py < /tmp/3.0_bios_grub_partition.patch
RUN cd /usr/lib/python3/dist-packages/maasserver && patch security.py < /tmp/3.0_region_secret_rotate.patch
RUN cd /usr/lib/python3/dist-packages/metadataserver/builtin_scripts/commissioning_scripts && patch bmc_config.py < /tmp/3.0_configure_ipmi_user.patch
RUN cd /usr/lib/python3/dist-packages/provisioningserver/templates/proxy && patch maas-proxy.conf.template < /tmp/3.0_proxy_acl.patch
RUN cd /usr/lib/python3/dist-packages/twisted/web && patch server.py < /tmp/3.0_secure_headers.patch
RUN cd /usr/lib/python3/dist-packages/maasserver/api && patch partitions.py < /tmp/3.0_partitiontable_does_not_exist.patch
RUN cd /usr/lib/python3/dist-packages/maasserver/models && patch ownerdata.py < /tmp/3.0_regex_tags.patch

# echo journalctl logs to the container's stdout
COPY journalctl-to-tty.service /etc/systemd/system/journalctl-to-tty.service
RUN systemctl enable journalctl-to-tty.service

# quiet sudo for the maas user
RUN umask 0337; echo 'Defaults:maas !pam_session, !syslog' > /etc/sudoers.d/99-maas-no-log

# avoid triggering bind9 high cpu utilization bug
RUN sed -i -e '$a\include "/etc/bind/bind.keys";' /etc/bind/named.conf

# initalize systemd
CMD ["/bin/bash", "-c", "exec /sbin/init --log-target=console 3>&1"]
