ARG FROM=quay.io/airshipit/ubuntu:jammy
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

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

ENV MAAS_VERSION=1:3.5.8-16381-g.d7e999261-0ubuntu1~22.04.1
ENV MAAS_PPA=ppa:maas/3.5

RUN apt-get -qq update \
 && apt upgrade -y \
 && apt-get install -y \
        avahi-daemon \
        jq \
        patch \
        software-properties-common \
        sudo \
        systemd \
        cron \
        ca-certificates \
        bind9-dnsutils \
        chrony \
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
 && add-apt-repository -yu $MAAS_PPA \
 && apt-get install -y \
        maas-region-api=$MAAS_VERSION \
        # tcpdump is required by /usr/lib/maas/beacon-monitor
        tcpdump \
 && rm -rf /var/lib/apt/lists/*\
 && rm -f /etc/ssl/private/snakeoil.*

# Preserve the directory structure, permissions, and contents of /var/lib/maas
RUN mkdir -p /opt/maas/ && tar -cvzf /opt/maas/var-lib-maas.tgz /var/lib/maas

# MAAS workarounds
COPY 3.5_route.patch /tmp/3.5_route.patch
COPY 3.5_kernel_package.patch /tmp/3.5_kernel_package.patch
# sh8121att: allow all requests via the proxy to allow it to work
# behind ingress
COPY 3.5_proxy_acl.patch /tmp/3.5_proxy_acl.patch
# Patch to add retrying to MaaS BMC user setup, and improve exception handling
COPY 3.5_configure_ipmi_user.patch /tmp/3.5_configure_ipmi_user.patch
COPY 3.5_secure_headers.patch /tmp/3.5_secure_headers.patch
COPY 3.5_partitiontable_does_not_exist.patch /tmp/3.5_partitiontable_does_not_exist.patch
# Allow tags with '/' symbols
COPY 3.5_regex_tags.patch /tmp/3.5_regex_tags.patch
# Patch to restrict access to zone transfers
COPY 3.5_transfer_trusted_only.patch /tmp/3.5_transfer_trusted_only.patch

RUN cd /usr/lib/python3/dist-packages/maasserver && patch preseed_network.py < /tmp/3.5_route.patch
RUN cd /usr/lib/python3/dist-packages/maasserver && patch preseed.py < /tmp/3.5_kernel_package.patch
RUN cd /usr/lib/python3/dist-packages/metadataserver/builtin_scripts/commissioning_scripts && patch bmc_config.py < /tmp/3.5_configure_ipmi_user.patch
RUN cd /usr/lib/python3/dist-packages/provisioningserver/templates/proxy && patch maas-proxy.conf.template < /tmp/3.5_proxy_acl.patch
RUN cd /usr/lib/python3/dist-packages/twisted/web && patch server.py < /tmp/3.5_secure_headers.patch
RUN cd /usr/lib/python3/dist-packages/maasserver/api && patch partitions.py < /tmp/3.5_partitiontable_does_not_exist.patch
RUN cd /usr/lib/python3/dist-packages/maasserver/models && patch ownerdata.py < /tmp/3.5_regex_tags.patch
RUN cd /usr/lib/python3/dist-packages/provisioningserver/templates/dns && patch named.conf.options.inside.maas.template < /tmp/3.5_transfer_trusted_only.patch

# echo journalctl logs to the container's stdout
COPY journalctl-to-tty.service /etc/systemd/system/journalctl-to-tty.service
RUN systemctl enable journalctl-to-tty.service

# quiet sudo for the maas user
RUN umask 0337; echo 'Defaults:maas !pam_session, !syslog' > /etc/sudoers.d/99-maas-no-log

# avoid triggering bind9 high cpu utilization bug
RUN sed -i -e '$a\include "/etc/bind/bind.keys";' /etc/bind/named.conf && /usr/lib/maas/maas-common setup-dns

# fix chronyd.pid location
RUN grep -i "^pidfile " /etc/chrony/chrony.conf && \
    sed -i 's|^pidfile .*|pidfile /run/chronyd.pid|' /etc/chrony/chrony.conf || \
    echo 'pidfile /run/chronyd.pid' >> /etc/chrony/chrony.conf
COPY override.chrony.conf /etc/systemd/system/chrony.service.d/override.conf

# initalize systemd
CMD ["/bin/bash", "-c", "exec /sbin/init --log-target=console 3>&1"]
