#!/bin/sh

# This is a stub ntpd process that will do barely enough to satisfy
# /etc/init.d/ntp stop/start/restart/status
tail -f /dev/null & echo $! > /var/run/ntpd.pid
