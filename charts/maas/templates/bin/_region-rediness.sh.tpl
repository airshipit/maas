#!/bin/bash

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



{{- if .Values.conf.maas.tls.enabled }}
LOCAL_MAAS_ENDPOINT="https://127.0.0.1:{{ tuple "maas_region" "podport" "region_api" . | include "helm-toolkit.endpoints.endpoint_port_lookup" }}/MAAS/api/2.0/"
{{- else }}
LOCAL_MAAS_ENDPOINT="http://127.0.0.1:{{ tuple "maas_region" "podport" "region_api" . | include "helm-toolkit.endpoints.endpoint_port_lookup" }}/MAAS/api/2.0/"
{{- end }}

function api_is_up {
	{{- if (and .Values.conf.maas.tls.enabled .Values.conf.maas.tls.insecure) }}
	python3 -c "
import urllib.request, ssl, sys
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
urllib.request.urlopen('${LOCAL_MAAS_ENDPOINT}version/', context=ctx, timeout=5)
"
	{{- else if .Values.conf.maas.tls.enabled }}
	python3 -c "
import urllib.request, ssl, sys
ctx = ssl.create_default_context(cafile='/usr/local/share/ca-certificates/maas-ca.crt')
urllib.request.urlopen('${LOCAL_MAAS_ENDPOINT}version/', context=ctx, timeout=5)
"
	{{- else }}
	python3 -c "
import urllib.request
urllib.request.urlopen('${LOCAL_MAAS_ENDPOINT}version/', timeout=5)
"
	{{- end }}
}


if ! api_is_up; then
    exit 1
fi
