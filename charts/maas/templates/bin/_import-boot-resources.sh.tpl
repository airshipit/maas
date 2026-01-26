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

set -x

JOB_TIMEOUT=${JOB_TIMEOUT:-900}
RETRY_TIMER=${RETRY_TIMER:-10}

function timer {
	retry_wait=$1
	shift

	# Use local timeout to avoid polluting global JOB_TIMEOUT
	local timeout=$JOB_TIMEOUT

	while [[ ${timeout} -gt 0 ]]; do
		"$@"
		rc=$?
		if [ $rc -eq 0 ]; then
			return $rc
		else
			timeout=$((timeout - retry_wait))
			sleep $retry_wait
		fi
	done

	return 124
}

function start_import {
	local import_start_time=$(date +%s)
	local last_log_time=$import_start_time
	local last_status_change_time=$import_start_time
	local last_is_importing="unknown"
	local import_issued=false
	local restart_done=false
	local stall_threshold=$((RETRY_TIMER * 3))
	# Use local timeout to avoid polluting global JOB_TIMEOUT
	local timeout=$JOB_TIMEOUT

	echo "Starting import at $(date) (timeout: ${timeout}s, stall threshold: ${stall_threshold}s)"

	while [[ ${timeout} -gt 0 ]]; do
		# Issue import command once at the start
		if [[ $import_issued == false ]]; then
			echo "Issuing boot-resources import command..."
			maas ${ADMIN_USERNAME} boot-resources import
			import_issued=true
			sleep 30
		fi

		local current_time=$(date +%s)
		local elapsed=$((current_time - import_start_time))
		local is_importing=$(maas ${ADMIN_USERNAME} boot-resources is-importing 2>/dev/null || echo "unknown")

		# Check if import is complete
		if [[ "$is_importing" == "false" ]]; then
			echo "Import completed successfully after ${elapsed}s!"
			return 0
		fi

		# Track status changes
		if [[ "$is_importing" != "$last_is_importing" ]]; then
			echo "Status changed: ${last_is_importing} → ${is_importing}"
			last_is_importing="$is_importing"
			last_status_change_time=$current_time
			# Reset restart flag on status change - allows restart if stalls again
			restart_done=false
		fi

		# Detect stall: no status change for stall_threshold seconds
		local time_since_change=$((current_time - last_status_change_time))
		if [[ $restart_done == false ]] && [[ $time_since_change -ge $stall_threshold ]] && [[ "$is_importing" != "false" ]]; then
			echo "========================================"
			echo "WARNING: Import stalled - no status change for ${time_since_change}s (threshold: ${stall_threshold}s)"
			echo "Current status: is_importing=${is_importing}"
			echo "Attempting recovery via region restart..."
			echo "========================================"

			if restart_stalled_import; then
				echo "Recovery successful, continuing import monitoring..."
				# Reset state after successful restart
				import_start_time=$(date +%s)
				last_log_time=$import_start_time
				last_status_change_time=$(date +%s)
				last_is_importing="unknown"
				restart_done=true
				import_issued=false
				sleep 15
			else
				echo "========================================"
				echo "ERROR: Failed to recover from stalled import"
				echo "Region restart or re-login failed"
				echo "Cannot continue - aborting import"
				echo "========================================"
				return 1
			fi
		fi

		# Progress log every 2 iterations
		if [[ $((current_time - last_log_time)) -ge $((RETRY_TIMER * 2)) ]]; then
			echo "Import in progress... (elapsed: ${elapsed}s, is_importing: ${is_importing}, stalled: ${time_since_change}s/${stall_threshold}s, timeout: ${timeout}s)"
			last_log_time=$current_time
		fi

		timeout=$((timeout - RETRY_TIMER))
		sleep $RETRY_TIMER
	done

	echo "========================================"
	echo "ERROR: Import timed out after ${elapsed}s"
	echo "Final state: is_importing=${is_importing}"
	echo "========================================"
	echo "Increase 'jobs.import_boot_resources.timeout' in values.yaml"
	return 124
}

function restart_region_statefulset {
	# Disable debug output to avoid cluttering logs with large JSON responses
	set +x

	echo "Triggering rollout restart of maas-region statefulset via Kubernetes API..."

	PATCH_DATA='{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}}}}}'

	local patch_response=$(wget -qO- \
		--ca-certificate=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
		--header='Content-Type: application/strategic-merge-patch+json' \
		--header="Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
		--method=PATCH \
		--body-data="$PATCH_DATA" \
		https://kubernetes.default.svc.cluster.local/apis/apps/v1/namespaces/{{ .Release.Namespace }}/statefulsets/maas-region \
		2>&1)

	# Check if patch was successful by looking for error in response
	if echo "$patch_response" | grep -qi "error"; then
		echo "ERROR: Failed to patch statefulset:"
		echo "$patch_response" | jq -r '.message // .' 2>/dev/null || echo "$patch_response"
		return 1
	else
		echo "Restart command sent successfully"
	fi

	echo "Waiting for statefulset rollout to complete..."

	# Wait for statefulset to be ready (equivalent to kubectl rollout status)
	local max_wait=300  # 5 minutes timeout
	local waited=0

	while [[ $waited -lt $max_wait ]]; do
		# Get statefulset status via K8s API
		local sts_status=$(wget -qO- \
			--ca-certificate=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
			--header="Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
			https://kubernetes.default.svc.cluster.local/apis/apps/v1/namespaces/{{ .Release.Namespace }}/statefulsets/maas-region 2>/dev/null)

		local replicas=$(echo "$sts_status" | jq -r '.spec.replicas // 0')
		local ready_replicas=$(echo "$sts_status" | jq -r '.status.readyReplicas // 0')
		local current_replicas=$(echo "$sts_status" | jq -r '.status.currentReplicas // 0')
		local updated_replicas=$(echo "$sts_status" | jq -r '.status.updatedReplicas // 0')

		echo "Statefulset status: replicas=${replicas}, ready=${ready_replicas}, current=${current_replicas}, updated=${updated_replicas}"

		# Check if rollout is complete
		if [[ "$ready_replicas" == "$replicas" ]] && [[ "$updated_replicas" == "$replicas" ]] && [[ "$current_replicas" == "$replicas" ]] && [[ "$replicas" != "0" ]]; then
			echo "Statefulset rollout completed successfully!"
			return 0
		fi

		sleep 5
		waited=$((waited + 5))

		if [[ $((waited % 30)) -eq 0 ]]; then
			echo "Still waiting for rollout... (${waited}s elapsed)"
		fi
	done

	echo "WARNING: Timeout waiting for statefulset rollout after ${max_wait}s"
	set -x
	return 1
}

function restart_stalled_import {
	# Disable debug output to avoid cluttering logs
	set +x

	echo "Attempting to restart stalled import..."
	echo "Stopping current import..."
	maas ${ADMIN_USERNAME} boot-resources stop-import || true
	sleep 15

	# Restart the region statefulset to clear stuck state
	if ! restart_region_statefulset; then
		echo "ERROR: Failed to restart region statefulset"
		return 1
	fi

	echo "Waiting for region to be ready after restart..."
	max_wait=90
	waited=0
	until wget --spider -q ${MAAS_ENDPOINT} 2>/dev/null; do
		sleep 3
		waited=$((waited + 3))
		if [[ $waited -gt $max_wait ]]; then
			echo "WARNING: Region may not be fully ready yet, proceeding anyway"
			break
		fi
		if [[ $((waited % 15)) -eq 0 ]]; then
			echo "Still waiting for region API... (${waited}s elapsed)"
		fi
	done

	echo "Re-establishing MAAS session after restart..."
	if ! maas_login; then
		echo "ERROR: Failed to re-establish MAAS session"
		return 1
	fi

	echo "Restarting import after region restart and cleanup..."
	maas ${ADMIN_USERNAME} boot-resources import
	sleep 10

	echo "Import restarted at $(date)"
	set -x
}

function check_then_set_single {
	option="$1"
	value="$2"

	cur_val=$(maas ${ADMIN_USERNAME} maas get-config name=${option} | tail -1 | tr -d '"')
	desired_val=$(echo ${value} | tr -d '"')

	if [[ $cur_val != $desired_val ]]; then
		echo "Setting MAAS option ${option} to ${desired_val}"
		maas ${ADMIN_USERNAME} maas set-config name=${option} value=${desired_val}
		return $?
	else
		echo "MAAS option ${option} already set to ${cur_val}"
		return 0
	fi
}

function check_then_set {
	option=$1
	value=$2

	timer "$RETRY_TIMER" check_then_set_single "$option" "$value"
}

function configure_proxy {
	check_then_set enable_http_proxy ${MAAS_PROXY_ENABLED}
	check_then_set use_peer_proxy ${MAAS_PEER_PROXY_ENABLED}
	check_then_set http_proxy ${MAAS_PROXY_SERVER}
	check_then_set maas_proxy_port ${MAAS_INTERNAL_PROXY_PORT}
}

function configure_ntp {
	check_then_set ntp_servers ${MAAS_NTP_SERVERS}
	check_then_set ntp_external_only ${MAAS_NTP_EXTERNAL_ONLY}
}

function configure_dns {
	check_then_set dnssec_validation ${MAAS_DNS_DNSSEC_REQUIRED}
	check_then_set upstream_dns ${MAAS_DNS_SERVERS}
}

function configure_syslog {
	check_then_set remote_syslog ${MAAS_REMOTE_SYSLOG}
}

function configure_images {
	check_then_set default_osystem ${MAAS_DEFAULT_OS}
	check_then_set commissioning_distro_series ${MAAS_DEFAULT_DISTRO}
	check_then_set default_distro_series ${MAAS_DEFAULT_DISTRO}
	check_then_set default_min_hwe_kernel ${MAAS_DEFAULT_KERNEL}
}

function configure_boot_sources {
	# Set the boot source URL if using local image cache
	if [[ $USE_IMAGE_CACHE == 'true' ]]; then
		maas ${ADMIN_USERNAME} boot-source update 1 url=http://localhost:8888/maas/images/ephemeral-v3/daily/
	fi

	# Read all selections for boot_source_id 1
	maas ${ADMIN_USERNAME} boot-source-selections read 1

	# Need to start an import to get the availability data
	maas "$ADMIN_USERNAME" boot-resources import
	sleep 10
	maas "$ADMIN_USERNAME" boot-resources stop-import

	# Create a selection for the desired distro
	maas ${ADMIN_USERNAME} boot-source-selections create 1 os="${MAAS_DEFAULT_OS}" \
		release="${MAAS_DEFAULT_DISTRO}" arches="amd64" subarches='*' labels='*'

	# Need to start an import to get the availability data
	maas "$ADMIN_USERNAME" boot-resources import
	sleep 10

	# Set as default
	maas ${ADMIN_USERNAME} maas set-config name=default_distro_series value="${MAAS_DEFAULT_DISTRO}"
	maas ${ADMIN_USERNAME} maas set-config name=commissioning_distro_series value="${MAAS_DEFAULT_DISTRO}"

	# Wait for MAAS to process the new selection
	sleep 10

	# Delete any selections that do not match the desired distro
	selections_output=$(maas ${ADMIN_USERNAME} boot-source-selections read 1 2>&1 || echo "[]")

	# Check if output is valid JSON before parsing
	if echo "$selections_output" | jq -e . >/dev/null 2>&1; then
		for row in $(echo "$selections_output" | jq -r \
			--arg distro "$MAAS_DEFAULT_DISTRO" \
			'.[] | select(.release != $distro) | "\(.id):\(.boot_source_id)"'); do
			id="${row%%:*}"
			boot_source_id="${row##*:}"
			echo "Deleting selection id $id from boot_source_id $boot_source_id"
			maas ${ADMIN_USERNAME} boot-source-selection delete "$boot_source_id" "$id"
		done
	else
		echo "Warning: Unable to parse boot-source-selections output, skipping cleanup of old selections"
		echo "Output was: $selections_output"
	fi

	# Need to re-start an import to get the availability data
	sleep 10
	maas "$ADMIN_USERNAME" boot-resources stop-import
	sleep 10
	maas "$ADMIN_USERNAME" boot-resources import

}

function create_extra_commissioning_script {
  cat > /tmp/script.sh << 'EOF'
#!/bin/bash
set -e

output=""
for net_iface in /sys/class/net/ens*
do
  if [ -z "$output" ]; then output="{"; else output+=","; fi
  output+=" \"$(basename "$net_iface")\": \"$(udevadm test-builtin net_id "$net_iface" 2>/dev/null | grep ID_NET_NAME_PATH | awk -F '=' '{print $2}')\""
done
if [ -z "$output" ]; then output="{}"; else output+=" }"; fi

echo $output

EOF

  maas "${ADMIN_USERNAME}" commissioning-scripts create name='99-netiface-names.sh' content@=/tmp/script.sh

  rm /tmp/script.sh
}

function configure_extra_settings {
	{{- range $k, $v := .Values.conf.maas.extra_settings }}
	check_then_set {{$k}} {{$v}}
	{{- else }}
	: No additional MAAS config
	{{- end }}
}

function maas_login {
	KEY=$(maas-region apikey --username=${ADMIN_USERNAME})
	if [ -z "$KEY" ]; then
		return 1
	fi
	{{- if (and .Values.conf.maas.tls.enabled .Values.conf.maas.tls.insecure) }}
	maas login --insecure ${ADMIN_USERNAME} ${MAAS_ENDPOINT} $KEY
  {{- else if .Values.conf.maas.tls.enabled }}
	maas login --cacerts /usr/local/share/ca-certificates/maas-ca.crt ${ADMIN_USERNAME} ${MAAS_ENDPOINT} $KEY
	{{- else }}
	maas login ${ADMIN_USERNAME} ${MAAS_ENDPOINT} $KEY
	{{- end }}
	return $?
}

timer "$RETRY_TIMER" maas_login

configure_proxy
configure_ntp
configure_dns
configure_syslog
configure_extra_settings
create_extra_commissioning_script

# make call to import images
timer "$RETRY_TIMER" configure_boot_sources
start_import

if [[ $? -eq 0 ]]; then
	configure_images
else
	echo "Image import FAILED!"
	exit 1
fi
