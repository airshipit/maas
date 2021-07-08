{{ "{{" }}preseed_data{{ "}}" }}
{{- range $k, $v := .Values.conf.cloudconfig.sections }}
{{ dict $k $v | toYaml | trim }}
{{- end }}
