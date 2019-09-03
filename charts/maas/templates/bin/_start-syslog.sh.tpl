#!/bin/bash
{{/*
 Copyright 2019 AT&T Intellectual Property. All rights reserved.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.*/}}
set -x

RSYSLOG_BIN=${RSYSLOG_BIN:-"/usr/sbin/rsyslogd"}
RSYSLOG_CONFFILE=${RSYSLOG_CONFFILE:-"/etc/rsyslog.conf"}
LOGFILE=${LOGFILE:-"/var/log/maas/nodeboot.log"}

$RSYSLOG_BIN -f "$RSYSLOG_CONFFILE"

# Handle race waiting for rsyslogd to start logging
while true
do
  tail -f "$LOGFILE"
  echo "Waiting for log file to exist."
  sleep 10
done

