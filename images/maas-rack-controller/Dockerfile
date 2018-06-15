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
    apt-get -y install \
    sudo \
    software-properties-common \
    libvirt-bin

# TODO(alanmeadows)
# we need systemd 231 per https://github.com/systemd/systemd/commit/a1350640ba605cf5876b25abfee886488a33e50b
#RUN add-apt-repository ppa:pitti/systemd -y && add-apt-repository ppa:maas/stable -y && apt-get update
RUN apt-get install -y systemd

# install syslog and enable it
RUN apt-get install -y rsyslog
RUN systemctl enable rsyslog.service

ENV MAAS_VERSION 2.3.0-6434-gd354690-0ubuntu1~16.04.1

# install maas
RUN rsyslogd; apt-get install -y maas-cli=$MAAS_VERSION maas-rack-controller=$MAAS_VERSION

COPY scripts/register-rack-controller.sh /usr/local/bin
RUN chmod +x /usr/local/bin/register-rack-controller.sh

# register ourselves with the region controller
COPY scripts/register-rack-controller.service /lib/systemd/system/register-rack-controller.service
RUN systemctl enable register-rack-controller.service

RUN mv /usr/sbin/tcpdump /usr/bin/tcpdump
RUN ln -s /usr/bin/tcpdump /usr/sbin/tcpdump

COPY scripts/journalctl-to-tty.service /etc/systemd/system/journalctl-to-tty.service
RUN mkdir -p /etc/systemd/system/basic.target.wants ;\
    ln -s /etc/systemd/system/journalctl-to-tty.service /etc/systemd/system/basic.target.wants/journalctl-to-tty.service

# initalize systemd
CMD ["/bin/bash", "-c", "exec /sbin/init --log-target=console 3>&1"]
