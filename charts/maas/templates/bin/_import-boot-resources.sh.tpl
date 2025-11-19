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

import_tries=0

TRY_LIMIT=${TRY_LIMIT:-1}
JOB_TIMEOUT=${JOB_TIMEOUT:-900}
RETRY_TIMER=${RETRY_TIMER:-30}

function timer {
	retry_wait=$1
	shift

	while [[ ${JOB_TIMEOUT} -gt 0 ]]; do
		"$@"
		rc=$?
		if [ $rc -eq 0 ]; then
			return $rc
		else
			JOB_TIMEOUT=$((JOB_TIMEOUT - retry_wait))
			sleep $retry_wait
		fi
	done

	return 124
}

function import_resources {
	check_for_download
	rc=$?

	if [ $rc -ne 0 ]; then
		echo "Starting image import try ${import_tries}..."
		maas ${ADMIN_USERNAME} boot-resources import
		sleep 30
		check_for_download
		rc=$?
	fi

	return $rc
}

function start_import {
	local import_start_time=$(date +%s)
	local stall_check_time=$import_start_time
	local last_progress_time=$import_start_time
	local stall_restart_done=false
	local last_synced_count=$(get_synced_count)
	local stall_check_interval=300  # Check for stalls every 5 minutes

	echo "Starting import at $(date) (timeout: ${JOB_TIMEOUT}s)"
	echo "Initial synced count: ${last_synced_count}"

	# Custom loop with stall detection based on progress
	while [[ ${JOB_TIMEOUT} -gt 0 ]]; do
		import_resources
		rc=$?

		if [ $rc -eq 0 ]; then
			echo "Import completed successfully!"
			return 0
		fi

		local current_time=$(date +%s)
		local elapsed=$((current_time - import_start_time))
		local current_synced_count=$(get_synced_count)

		# Track progress - if synced count increased, update progress time
		if [[ $current_synced_count -gt $last_synced_count ]]; then
			echo "Progress detected: synced count increased from ${last_synced_count} to ${current_synced_count}"
			last_synced_count=$current_synced_count
			last_progress_time=$current_time
		fi

		# Check if import appears stalled (no progress for 5 minutes)
		if [[ $stall_restart_done == false ]]; then
			if check_import_stalled "$last_synced_count" "$current_synced_count" "$stall_check_interval" "$last_progress_time"; then
				echo "Stalled import detected - attempting restart..."
				restart_stalled_import
				import_start_time=$(date +%s)
				last_progress_time=$import_start_time
				stall_restart_done=true
				stall_check_time=$import_start_time
				# Don't update last_synced_count - we want to see if restart helps
			fi
		fi

		# Progress update every 2 minutes
		if [[ $((current_time - stall_check_time)) -gt 120 ]]; then
			echo "Import still in progress... (elapsed: ${elapsed}s, synced: ${current_synced_count}, timeout remaining: ${JOB_TIMEOUT}s)"
			stall_check_time=$current_time
		fi

		JOB_TIMEOUT=$((JOB_TIMEOUT - RETRY_TIMER))
		sleep $RETRY_TIMER
	done

	echo "ERROR: Import timed out after reaching JOB_TIMEOUT"
	echo "Last known state before timeout:"
	check_for_download || true
	return 124
}

function check_for_download {
	local is_importing=$(maas ${ADMIN_USERNAME} boot-resources is-importing 2>/dev/null || echo "false")
	local synced_imgs=$(maas ${ADMIN_USERNAME} boot-resources read 2>/dev/null | tail -n +1 | jq '.[] | select( .type | contains("Synced")) | .name ' 2>/dev/null | grep -c $MAAS_DEFAULT_DISTRO || echo "0")

	if echo "$is_importing" | grep -q 'true'; then
		echo -e "\nBoot resources currently importing (synced: ${synced_imgs})\n"
		return 1
	else
		if [[ $synced_imgs -gt 0 ]]; then
			echo "Boot resources have completed importing (synced: ${synced_imgs})"
			return 0
		else
			echo 'Import failed - no synced images found!'
			return 1
		fi
	fi
}

function get_synced_count {
	maas ${ADMIN_USERNAME} boot-resources read 2>/dev/null | tail -n +1 | jq '.[] | select( .type | contains("Synced")) | .name ' 2>/dev/null | grep -c $MAAS_DEFAULT_DISTRO || echo "0"
}

function check_import_stalled {
	# Check if import has been running without making progress
	# This detects both stuck downloads and queued-but-never-starting imports
	local last_synced_count=${1:-0}
	local current_synced_count=${2:-0}
	local check_interval=${3:-300}  # How long to wait for progress (5 minutes)
	local last_progress_time=${4:-0}

	local current_time=$(date +%s)

	# If synced count increased, we're making progress
	if [[ $current_synced_count -gt $last_synced_count ]]; then
		return 1  # Not stalled, making progress
	fi

	# No progress detected, check how long it's been
	if [[ $last_progress_time -eq 0 ]]; then
		return 1  # First check, can't determine stall yet
	fi

	local stall_duration=$((current_time - last_progress_time))

	if [[ $stall_duration -gt $check_interval ]]; then
		echo "WARNING: No import progress for ${stall_duration}s (synced count stuck at ${current_synced_count})"
		echo "Checking import status details..."

		# Show what's in the queue
		maas ${ADMIN_USERNAME} boot-resources read 2>/dev/null | jq -r '.[] | "\(.name): \(.type)"' | head -20 || true

		return 0  # Import appears stalled
	fi

	return 1  # Not stalled yet
}

function clean_boot_resources {
	echo "Cleaning boot resource metadata from database..."

	# Use maas-region command to access the database
	maas-region shell << 'PYTHON_EOF'
from maasserver.models import BootResource, BootResourceFile, BootResourceSet
from django.db import transaction

print("Checking for boot resources in database...")
resources = BootResource.objects.all()
print(f"Found {resources.count()} boot resources in database")

if resources.count() > 0:
    print("Deleting all boot resource metadata to force fresh download...")
    with transaction.atomic():
        deleted_files = BootResourceFile.objects.all().delete()
        deleted_sets = BootResourceSet.objects.all().delete()
        deleted_resources = BootResource.objects.all().delete()
        print(f"Deleted: {deleted_resources[0]} resources, {deleted_sets[0]} sets, {deleted_files[0]} files")
    print("Database cleaned successfully")
else:
    print("No boot resources found")
PYTHON_EOF

	echo "Boot resource cleanup completed"
}

function restart_region_statefulset {
	echo "Triggering rollout restart of maas-region statefulset via Kubernetes API..."

	PATCH_DATA='{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'"}}}}}'

	wget \
		--server-response \
		--ca-certificate=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
		--header='Content-Type: application/strategic-merge-patch+json' \
		--header="Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
		--method=PATCH \
		--body-data="$PATCH_DATA" \
		https://kubernetes.default.svc.cluster.local/apis/apps/v1/namespaces/{{ .Release.Namespace }}/statefulsets/maas-region \
		2>&1 | grep -E '200 OK|error|Error' || true

	echo "Restart command sent, waiting for statefulset rollout to complete..."

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
	return 1
}

function restart_stalled_import {
	echo "Attempting to restart stalled import..."
	echo "Stopping current import..."
	maas ${ADMIN_USERNAME} boot-resources stop-import || true
	sleep 15

	# Clean boot resource metadata that may be causing issues
	clean_boot_resources

	# Restart the region statefulset to clear stuck state
	restart_region_statefulset

	echo "Waiting for region to be ready after restart..."
	max_wait=90
	waited=0
	until curl -sf ${MAAS_ENDPOINT}/MAAS/ > /dev/null 2>&1; do
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
	maas_login

	echo "Restarting import after region restart and cleanup..."
	maas ${ADMIN_USERNAME} boot-resources import
	sleep 10

	echo "Import restarted at $(date)"
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

# Get rack controllers reporting a healthy rackd
function get_active_rack_controllers {
	maas ${ADMIN_USERNAME} rack-controllers read | jq -r 'map({"system_id":.system_id,"service_set":(.service_set[] | select(.name=="rackd"))}) | map(select(.service_set.status == "running")) | .[] | .system_id'
}

function check_for_rack_sync_single {
	sync_list=""

	rack_list=$(get_active_rack_controllers)
	for rack_id in ${rack_list}; do
		selected_imgs=$(maas ${ADMIN_USERNAME} rack-controller list-boot-images ${rack_id} | tail -n +1 | jq ".images[] | select( .name | contains(\"${MAAS_DEFAULT_DISTRO}\")) | .name")
		synced_ctlr=$(maas ${ADMIN_USERNAME} rack-controller list-boot-images ${rack_id} | tail -n +1 | jq '.status == "synced"')
		if [[ $synced_ctlr == "true" && -n ${selected_imgs} ]]; then
			sync_list=$(echo -e "${sync_list}\n${rack_id}" | sort | uniq)
		else
			maas ${ADMIN_USERNAME} rack-controller import-boot-images ${rack_id}
		fi
		if [[ $(echo -e "${rack_list}" | sort | uniq | grep -v '^$') == $(echo -e "${sync_list}" | sort | uniq | grep -v '^$') ]]; then
			return 0
		fi
	done

	return 1
}

function check_for_rack_sync {
	timer "$RETRY_TIMER" check_for_rack_sync_single
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
	check_for_rack_sync

	if [[ $? -eq 124 ]]; then
		echo "Timed out waiting for rack controller sync."
		return 1
	fi

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
	maas "$ADMIN_USERNAME" boot-resources is-importing
	sleep 10
	maas "$ADMIN_USERNAME" boot-resources stop-import

	# Create a selection for the desired distro
	maas ${ADMIN_USERNAME} boot-source-selections create 1 os="${MAAS_DEFAULT_OS}" \
		release="${MAAS_DEFAULT_DISTRO}" arches="amd64" subarches='*' labels='*'

	# Need to start an import to get the availability data
	maas "$ADMIN_USERNAME" boot-resources import
	sleep 10
	maas "$ADMIN_USERNAME" boot-resources is-importing
	sleep 10

	# Set as default
	maas ${ADMIN_USERNAME} maas set-config name=default_distro_series value="${MAAS_DEFAULT_DISTRO}"
	maas ${ADMIN_USERNAME} maas set-config name=commissioning_distro_series value="${MAAS_DEFAULT_DISTRO}"


	# Delete any selections that do not match the desired distro
	for row in $(maas ${ADMIN_USERNAME} boot-source-selections read 1 | jq -r \
		--arg distro "$MAAS_DEFAULT_DISTRO" \
		'.[] | select(.release != $distro) | "\(.id):\(.boot_source_id)"'); do
		id="${row%%:*}"
		boot_source_id="${row##*:}"
		echo "Deleting selection id $id from boot_source_id $boot_source_id"
		maas ${ADMIN_USERNAME} boot-source-selection delete "$boot_source_id" "$id"
	done

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
