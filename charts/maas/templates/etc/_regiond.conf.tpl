# Copyright 2017 The Openstack-Helm Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

{{ include "maas.conf.maas_values_skeleton" .Values.conf.maas | trunc 0 }}
{{ include "maas.conf.maas" .Values.conf.maas }}

{{- define "maas.conf.maas_values_skeleton" -}}
{{- if not .database -}}{{- set . "database" dict -}}{{- end -}}
{{- if not .url -}}{{- set . "url" dict -}}{{- end -}}
{{- end -}}

{{- if empty .Values.conf.maas.url.maas_url -}}
{{- tuple "maas_region_ui" "default" "region_ui" . | include "helm-toolkit.endpoints.keystone_endpoint_uri_lookup" | set .Values.conf.maas.url "maas_url" | quote | trunc 0 -}}
{{- end -}}


{{- define "maas.conf.maas" -}}

database_host: {{ .database.database_host }}
database_name: {{ .database.database_name }}
database_pass: {{ .database.database_password }}
database_user: {{ .database.database_user }}
maas_url: {{ .url.maas_url }}

{{- end -}}
