# Enable the udp server for installation logging
$ModLoad imudp
$UDPServerRun {{ tuple "maas_region" "podport" "region_syslog" . | include "helm-toolkit.endpoints.endpoint_port_lookup" }}
#$ModLoad imtcp # load TCP listener

# Discard messages from localhost
:fromhost-ip, isequal, "127.0.0.1" ~

# Log remote messages, based on the configured log level
*.{{ .Values.conf.syslog.log_level | default "*" }} {{ .Values.conf.syslog.logpath }}/{{ .Values.conf.syslog.logfile }}
& ~
