# Enable the udp server for installation logging
$ModLoad imudp
$UDPServerRun {{ tuple "maas_region" "podport" "region_syslog" . | include "helm-toolkit.endpoints.endpoint_port_lookup" }}
#$ModLoad imtcp # load TCP listener

# Reduce message repetition
$RepeatedMsgReduction on
##$RepeatedMsgContainsOriginalMsg on

:fromhost-ip, !isequal, "127.0.0.1" {{ .Values.conf.syslog.logpath }}/{{ .Values.conf.syslog.logfile }}
& ~
