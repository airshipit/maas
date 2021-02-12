#cloud-config
datasource:
  MAAS:
    timeout : 50
    max_wait : 120
    # there are no default values for metadata_url or oauth credentials
    # If no credentials are present, non-authed attempts will be made.
    metadata_url: {{ "{{" }}metadata_enlist_url{{ "}}" }}

output: {all: '| tee -a /var/log/cloud-init-output.log'}
{{- range $k, $v := .Values.conf.cloudconfig.sections }}
{{ dict $k $v | toYaml | trim }}
{{- end }}
