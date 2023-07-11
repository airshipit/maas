{{/* file location: /etc/default/named */}}
{{- $cpus := index .Values.conf.bind "cpus" -}}
#
# run resolvconf?
RESOLVCONF=no

# startup options for the server
OPTIONS="-4 -u bind {{- if $cpus }} -n {{ $cpus }}{{ end }}"
