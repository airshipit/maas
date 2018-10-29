ARG FROM=ubuntu:16.04
FROM ${FROM}

LABEL org.opencontainers.image.authors='airship-discuss@lists.airshipit.org, irc://#airshipit@freenode'
LABEL org.opencontainers.image.url='https://airshipit.org'
LABEL org.opencontainers.image.documentation='https://github.com/openstack/airship-maas'
LABEL org.opencontainers.image.source='https://git.openstack.org/openstack/airship-maas'
LABEL org.opencontainers.image.vendor='The Airship Authors'
LABEL org.opencontainers.image.licenses='Apache-2.0'

ARG SSTREAM_IMAGE=https://images.maas.io/ephemeral-v3/daily/
ENV IMAGE_SRC ${SSTREAM_IMAGE}

RUN apt-get -qq update && \
    apt install -y simplestreams \
                   apache2 \
                   gpgv \
                   ubuntu-cloudimage-keyring \
                   python-certifi --no-install-recommends \
                   file

RUN sstream-mirror --keyring=/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg $IMAGE_SRC \
    /var/www/html/maas/images/ephemeral-v3/daily 'arch=amd64' 'release~xenial' --max=1 --progress

RUN sstream-mirror --keyring=/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg $IMAGE_SRC \
   /var/www/html/maas/images/ephemeral-v3/daily 'os~(grub*|pxelinux)' --max=1 --progress

RUN sh -c 'echo "" > /etc/apache2/ports.conf'

ENV APACHE_RUN_USER www-data
ENV APACHE_RUN_GROUP www-data
ENV APACHE_PID_FILE /var/run/apache2.pid
ENV APACHE_RUN_DIR /var/run/
ENV APACHE_LOCK_DIR /var/lock
ENV APACHE_LOG_DIR /var/log/
ENV LANG C

ENTRYPOINT ["/usr/sbin/apache2"]
CMD ["-E", "/dev/stderr","-c","ErrorLog /dev/stderr","-c","Listen 8888","-c","ServerRoot /etc/apache2","-c","DocumentRoot /var/www/html","-D","FOREGROUND"]
