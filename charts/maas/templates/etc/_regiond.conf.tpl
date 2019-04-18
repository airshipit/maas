{{/*
# Copyright 2017 The Openstack-Helm Authors.
# Copyright (c) 2017 AT&T Intellectual Property. All rights reserved.
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
*/}}
database_host: {{ tuple "maas_db" "internal" . | include "helm-toolkit.endpoints.hostname_fqdn_endpoint_lookup" }}
database_name: {{ .Values.endpoints.maas_db.auth.user.database }}
database_pass: {{ .Values.endpoints.maas_db.auth.user.password }}
database_user: {{ .Values.endpoints.maas_db.auth.user.username }}

{{- if empty .Values.conf.maas.url.maas_url }}
maas_url: {{ tuple "maas_region" "public" "region_api" . | include "helm-toolkit.endpoints.keystone_endpoint_uri_lookup" | quote }}
{{- else }}
maas_url: {{ .Values.conf.maas.url.maas_url }}
{{- end }}
