{{/* file location: /etc/default/bind9 */}}
{{- $cpus := index .Values.conf.bind "cpus" -}}
#
# run resolvconf?
RESOLVCONF=no

# startup options for the server
OPTIONS="-u bind {{- if $cpus }} -n {{ $cpus }}{{ end }}"
