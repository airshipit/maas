#!/bin/bash

{{/*
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
# limitations under the License. */}}

set -ex

function check_boot_images {
	local is_importing=$(maas local boot-resources is-importing 2>/dev/null || echo "false")
	local synced_imgs=$(maas local boot-resources read 2>/dev/null | tr -d '\n' | grep -oE '{[^}]+}' | grep ubuntu | grep -c Synced || echo "0")

	if echo "$is_importing" | grep -q 'true'; then
		echo "Boot resources currently importing... (synced: $synced_imgs)"
		return 1
	else
		if [[ $synced_imgs -gt 0 ]]; then
			echo "Boot resources have completed importing ($synced_imgs images synced)"
			return 0
		else
			echo "No synced boot images found yet (import status: not importing)"
			return 1
		fi
	fi
}

function check_rack_controllers {
	rack_cnt=$(maas local rack-controllers read | grep -c hostname)
	if [[ $rack_cnt -gt 0 ]]; then
		echo "Found $rack_cnt rack controllers."
		return 0
	else
		return 1
	fi
}

function check_admin_api {
	if maas local version read; then
		echo 'Admin API is responding'
		return 0
	else
		return 1
	fi
}

function establish_session {
	echo "Attempting to establish MAAS session at ${MAAS_URL}..."
	retry_count=0
	max_retries=10
	until maas login local ${MAAS_URL} ${MAAS_API_KEY}; do
		retry_count=$((retry_count + 1))
		if [[ $retry_count -ge $max_retries ]]; then
			echo "Failed to establish MAAS session after $max_retries attempts"
			return 1
		fi
		echo "Session login failed, retrying... (attempt $retry_count/$max_retries)"
		sleep 5
	done
	echo "MAAS session established successfully"
	return 0
}

# Import CA Certificate
{{- if (and .Values.conf.maas.tls.enabled .Values.conf.maas.tls.insecure) }}
update-ca-certificates
{{- end }}

establish_session

if [[ $? -ne 0 ]]; then
	echo "MAAS API login FAILED!"
	exit 1
fi

# Wait for rack controllers to register first (max 10 minutes)
echo "Waiting for rack controllers to register..."
retry_count=0
max_retries=60  # 60 * 10 seconds = 10 minutes
until check_rack_controllers; do
	retry_count=$((retry_count + 1))
	if [[ $retry_count -ge $max_retries ]]; then
		echo "Rack controller query FAILED! Timeout after 10 minutes."
		echo "This usually means the rack controller pods are not running or cannot connect to the region."
		exit 1
	fi
	if [[ $((retry_count % 6)) -eq 0 ]]; then
		echo "Rack controllers not ready yet, waiting... (attempt $retry_count/$max_retries, elapsed: $((retry_count * 10 / 60)) minutes)"
	fi
	sleep 10
done

# Wait for boot images to complete importing (max 20 minutes)
# The import job should handle any stalls, we just verify the result
echo "Waiting for boot images to complete importing..."
retry_count=0
max_retries=120  # 120 * 10 seconds = 20 minutes

until check_boot_images; do
	retry_count=$((retry_count + 1))

	if [[ $retry_count -ge $max_retries ]]; then
		echo "Image import test FAILED! Timeout after 20 minutes."
		echo "The import job may have failed or is still running."
		echo "Check the 'maas-import-resources' job logs for details."
		exit 1
	fi

	if [[ $((retry_count % 6)) -eq 0 ]]; then
		echo "Boot images not ready yet, waiting... (attempt $retry_count/$max_retries, elapsed: $((retry_count * 10 / 60)) minutes)"
	fi

	sleep 10
done

# Verify admin API is still responding
if ! check_admin_api; then
	echo "Admin API response FAILED!"
	exit 1
fi

echo "MAAS Validation SUCCESS!"
exit 0
