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

function log {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

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

# Resilient wrapper for maas CLI commands.
# Retries on transient failures (502/503, HTML error pages, non-zero exit)
# with exponential backoff: 10 -> 20 -> 40 -> 80 -> 160 -> 320.
# Fails hard (return 1) when backoff exceeds 300s so the pod restarts.
function maas_cli {
	local delay=10
	local max_delay=300

	while true; do
		local output
		# Disable xtrace so debug lines don't get captured into output via 2>&1
		{ local xtrace_was_set=$-; set +x; } 2>/dev/null
		output=$(command maas "$@" 2>&1)
		local rc=$?
		[[ "$xtrace_was_set" == *x* ]] && set -x

		# Only retry on transient HTTP errors (502/503/HTML error pages)
		# Non-zero exit with valid API response (JSON error) is NOT retried
		if echo "$output" | grep -qiE '<html|502 Bad Gateway|503 Service|Bad Gateway|Internal Server Error'; then
			log "WARNING: maas $* got transient HTTP error (rc=$rc, delay=${delay}s)" >&2
			log "Output: $(echo "$output" | head -5)" >&2

			if [[ $delay -gt $max_delay ]]; then
				log "ERROR: maas $* still failing after exponential backoff exceeded ${max_delay}s - giving up" >&2
				return 1
			fi

			log "Retrying in ${delay}s..." >&2
			sleep $delay
			delay=$((delay * 2))
		else
			# Valid API response (no HTML errors) - always succeed
			# Non-zero rc with valid JSON/text is a legitimate API answer, not a failure
			echo "$output"
			return 0
		fi
	done
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

	log "Starting import (timeout: ${timeout}s, stall threshold: ${stall_threshold}s)"

	while [[ ${timeout} -gt 0 ]]; do
		# Issue import command once at the start
		if [[ $import_issued == false ]]; then
			log "Issuing boot-resources import command..."
			maas_cli ${ADMIN_USERNAME} boot-resources import || exit 1
			import_issued=true
			sleep 30
		fi

		local current_time=$(date +%s)
		local elapsed=$((current_time - import_start_time))
		local is_importing
		is_importing=$(maas_cli ${ADMIN_USERNAME} boot-resources is-importing) || is_importing="unknown"

		# Check if import is complete
		if [[ "$is_importing" == "false" ]]; then
			log "Import completed successfully after ${elapsed}s!"
			return 0
		fi

		# Track status changes
		if [[ "$is_importing" != "$last_is_importing" ]]; then
			log "Status changed: ${last_is_importing} → ${is_importing}"
			last_is_importing="$is_importing"
			last_status_change_time=$current_time
			# Reset restart flag on status change - allows restart if stalls again
			restart_done=false
		fi

		# Detect stall: no status change for stall_threshold seconds
		local time_since_change=$((current_time - last_status_change_time))
		if [[ $restart_done == false ]] && [[ $time_since_change -ge $stall_threshold ]] && [[ "$is_importing" != "false" ]]; then
			log "========================================"
			log "WARNING: Import stalled - no status change for ${time_since_change}s (threshold: ${stall_threshold}s)"
			log "Current status: is_importing=${is_importing}"
			log "Attempting recovery via region restart..."
			log "========================================"

			if restart_stalled_import; then
				log "Recovery successful, continuing import monitoring..."
				# Reset state after successful restart
				import_start_time=$(date +%s)
				last_log_time=$import_start_time
				last_status_change_time=$(date +%s)
				last_is_importing="unknown"
				restart_done=true
				import_issued=false
				sleep 15
			else
				log "========================================"
				log "ERROR: Failed to recover from stalled import"
				log "Region restart or re-login failed"
				log "Cannot continue - aborting import"
				log "========================================"
				return 1
			fi
		fi

		# Progress log every 2 iterations
		if [[ $((current_time - last_log_time)) -ge $((RETRY_TIMER * 2)) ]]; then
			log "Import in progress... (elapsed: ${elapsed}s, is_importing: ${is_importing}, stalled: ${time_since_change}s/${stall_threshold}s, timeout: ${timeout}s)"
			last_log_time=$current_time
		fi

		timeout=$((timeout - RETRY_TIMER))
		sleep $RETRY_TIMER
	done

	log "========================================"
	log "ERROR: Import timed out after ${elapsed}s"
	log "Final state: is_importing=${is_importing}"
	log "========================================"
	log "Increase 'jobs.import_boot_resources.timeout' in values.yaml"
	return 124
}

function restart_region_statefulset {
	# Disable debug output to avoid cluttering logs with large JSON responses
	set +x

	log "Triggering rollout restart of maas-region statefulset via Kubernetes API..."

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
		log "ERROR: Failed to patch statefulset:"
		echo "$patch_response" | jq -r '.message // .' 2>/dev/null || echo "$patch_response"
		return 1
	else
		log "Restart command sent successfully"
	fi

	log "Waiting for statefulset rollout to complete..."

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

		log "Statefulset status: replicas=${replicas}, ready=${ready_replicas}, current=${current_replicas}, updated=${updated_replicas}"

		# Check if rollout is complete
		if [[ "$ready_replicas" == "$replicas" ]] && [[ "$updated_replicas" == "$replicas" ]] && [[ "$current_replicas" == "$replicas" ]] && [[ "$replicas" != "0" ]]; then
			log "Statefulset rollout completed successfully!"
			return 0
		fi

		sleep 5
		waited=$((waited + 5))

		if [[ $((waited % 30)) -eq 0 ]]; then
			log "Still waiting for rollout... (${waited}s elapsed)"
		fi
	done

	log "WARNING: Timeout waiting for statefulset rollout after ${max_wait}s"
	set -x
	return 1
}

function restart_stalled_import {
	# Disable debug output to avoid cluttering logs
	set +x

	log "Attempting to restart stalled import..."
	log "Stopping current import..."
	maas_cli ${ADMIN_USERNAME} boot-resources stop-import || true
	sleep 15

	# Restart the region statefulset to clear stuck state
	if ! restart_region_statefulset; then
		log "ERROR: Failed to restart region statefulset"
		return 1
	fi

	log "Waiting for region to be ready after restart..."
	max_wait=90
	waited=0
	until wget -q -O /dev/null --timeout=5 ${MAAS_ENDPOINT}/api/2.0/version/ 2>/dev/null; do
		sleep 3
		waited=$((waited + 3))
		if [[ $waited -gt $max_wait ]]; then
			log "WARNING: Region may not be fully ready yet, proceeding anyway"
			break
		fi
		if [[ $((waited % 15)) -eq 0 ]]; then
			log "Still waiting for region API... (${waited}s elapsed)"
		fi
	done

	log "Re-establishing MAAS session after restart..."
	if ! maas_login; then
		log "ERROR: Failed to re-establish MAAS session"
		return 1
	fi

	log "Restarting import after region restart and cleanup..."
	maas_cli ${ADMIN_USERNAME} boot-resources import || return 1
	sleep 10

	log "Import restarted successfully"
	set -x
}

function check_then_set_single {
	option="$1"
	value="$2"

	local raw_val
	raw_val=$(maas_cli ${ADMIN_USERNAME} maas get-config name=${option}) || return 1
	cur_val=$(echo "$raw_val" | tail -1 | tr -d '"' | tr ' ' ',')
	desired_val=$(echo ${value} | tr -d '"')

	if [[ $cur_val != $desired_val ]]; then
		log "Setting MAAS option ${option} to ${desired_val}"
		local result
		result=$(maas_cli ${ADMIN_USERNAME} maas set-config name=${option} value=${desired_val}) || return 1
		# Check if MAAS rejected the value (e.g. kernel not yet available after import)
		if echo "$result" | grep -q 'is not a valid'; then
			log "WARNING: MAAS rejected value '${desired_val}' for ${option} (images may still be syncing), will retry"
			return 1
		fi
		return 0
	else
		log "MAAS option ${option} already set to ${cur_val}"
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
	# Single-attempt per setting — no internal retry timer.
	# If MAAS rejects a value (images not yet in DB), the caller retries the
	# entire import+configure cycle via the outer timer, re-triggering start_import
	# rather than spinning on set-config alone.
	local rc=0
	check_then_set_single default_osystem ${MAAS_DEFAULT_OS} || rc=1
	check_then_set_single commissioning_distro_series ${MAAS_DEFAULT_DISTRO} || rc=1
	check_then_set_single default_distro_series ${MAAS_DEFAULT_DISTRO} || rc=1
	check_then_set_single default_min_hwe_kernel ${MAAS_DEFAULT_KERNEL} || true
	return $rc
}

function configure_boot_sources {
	# Set the boot source URL if using local image cache
	if [[ $USE_IMAGE_CACHE == 'true' ]]; then
		maas_cli ${ADMIN_USERNAME} boot-source update 1 \
			url=http://localhost:8888/maas/images/ephemeral-v3/daily/ || exit 1
	fi

	local selections
	selections=$(maas_cli ${ADMIN_USERNAME} boot-source-selections read 1) || exit 1

	local desired_id
	desired_id=$(echo "$selections" | jq -r \
		--arg os "${MAAS_DEFAULT_OS}" \
		--arg distro "${MAAS_DEFAULT_DISTRO}" \
		'.[] | select(.os == $os and .release == $distro) | .id' 2>/dev/null)

	if [[ -z "$desired_id" ]]; then
		# The desired distro is not yet in selections. UPDATE the first existing
		# selection in-place rather than deleting it and creating a new one.
		# Deletion is blocked by MAAS when the selection is the current
		# commissioning OS ("Unable to delete... used in ephemeral environments").
		# An in-place update changes the release without triggering that check,
		# ensuring the sstream import will only see the desired distro and won't
		# hang waiting for a distro the local sstream container doesn't carry.
		local first_id
		first_id=$(echo "$selections" | jq -r 'first | .id // empty' 2>/dev/null)

		if [[ -n "$first_id" ]]; then
			log "Updating selection id=${first_id} in-place to ${MAAS_DEFAULT_OS}/${MAAS_DEFAULT_DISTRO}"
			maas_cli ${ADMIN_USERNAME} boot-source-selection update 1 "${first_id}" \
				os="${MAAS_DEFAULT_OS}" release="${MAAS_DEFAULT_DISTRO}" \
				arches="amd64" subarches='*' labels='*' || exit 1
		else
			log "No existing selections — creating ${MAAS_DEFAULT_OS}/${MAAS_DEFAULT_DISTRO}"
			maas_cli ${ADMIN_USERNAME} boot-source-selections create 1 \
				os="${MAAS_DEFAULT_OS}" release="${MAAS_DEFAULT_DISTRO}" \
				arches="amd64" subarches='*' labels='*' || exit 1
		fi

		# Re-read after update/create so the stale-cleanup below sees fresh state
		selections=$(maas_cli ${ADMIN_USERNAME} boot-source-selections read 1) || exit 1
	else
		log "Selection for ${MAAS_DEFAULT_OS}/${MAAS_DEFAULT_DISTRO} already exists (id=${desired_id})"
	fi

	# Remove all remaining selections not pointing to the desired distro.
	# MUST be done before start_import — if any stale selection remains,
	# the local sstream (which only carries the desired distro) will never
	# satisfy it and is-importing will never return false.
	#
	# If MAAS refuses to delete a selection because it is the current
	# commissioning OS, update it in-place to the desired distro instead.
	# After import completes, configure_images will switch commissioning to
	# the new distro and cleanup_old_boot_source_selections removes duplicates.
	local stale_ids
	stale_ids=$(echo "$selections" | jq -r \
		--arg distro "${MAAS_DEFAULT_DISTRO}" \
		'.[] | select(.release != $distro) | .id' 2>/dev/null)

	for id in $stale_ids; do
		log "Deleting stale selection id=${id}"
		local result
		result=$(maas_cli ${ADMIN_USERNAME} boot-source-selection delete 1 "${id}") || true
		if echo "$result" | grep -qi "Unable to delete\|ephemeral"; then
			log "Delete blocked (commissioning OS restriction) — updating selection id=${id} to ${MAAS_DEFAULT_OS}/${MAAS_DEFAULT_DISTRO} in-place"
			local update_result
			update_result=$(maas_cli ${ADMIN_USERNAME} boot-source-selection update 1 "${id}" \
				os="${MAAS_DEFAULT_OS}" release="${MAAS_DEFAULT_DISTRO}" \
				arches="amd64" subarches='*' labels='*') || exit 1
			# maas_cli returns 0 even for API-level errors; inspect the response
			if echo "$update_result" | grep -qi "error\|not found\|does not exist"; then
				log "ERROR: in-place update of selection id=${id} failed: ${update_result}"
				exit 1
			fi
		fi
	done

	# Final safety check: assert no stale selections remain before start_import.
	# Any stale entry would cause the import to hang waiting for a distro the
	# local sstream doesn't carry.
	local remaining_stale
	remaining_stale=$(maas_cli ${ADMIN_USERNAME} boot-source-selections read 1 | jq -r \
		--arg distro "${MAAS_DEFAULT_DISTRO}" \
		'.[] | select(.release != $distro) | .id' 2>/dev/null)
	if [[ -n "$remaining_stale" ]]; then
		log "ERROR: stale boot-source selections still present after cleanup (ids: ${remaining_stale}). Aborting to prevent import hang."
		exit 1
	fi
}

function cleanup_old_boot_source_selections {
	# After configure_images has switched commissioning_distro_series to the new
	# distro, remove any duplicate selections that were updated in-place from the
	# old distro. Keep only the first one found for the desired distro.
	local selections
	selections=$(maas_cli ${ADMIN_USERNAME} boot-source-selections read 1) || return 1

	if ! echo "$selections" | jq -e . >/dev/null 2>&1; then
		log "Warning: Unable to parse boot-source-selections output, skipping cleanup"
		return 0
	fi

	local keep_id
	keep_id=$(echo "$selections" | jq -r \
		--arg distro "$MAAS_DEFAULT_DISTRO" \
		'[.[] | select(.release == $distro)] | first | .id // empty' 2>/dev/null)

	if [[ -z "$keep_id" ]]; then
		log "Warning: no ${MAAS_DEFAULT_DISTRO} selection found in cleanup — nothing to do"
		return 0
	fi

	for row in $(echo "$selections" | jq -r \
		--argjson keep "${keep_id}" \
		'.[] | select(.id != $keep) | "\(.id):\(.boot_source_id)"'); do
		local id="${row%%:*}"
		local boot_source_id="${row##*:}"
		log "Deleting duplicate selection id=${id} from boot_source_id=${boot_source_id}"
		local result
		result=$(maas_cli ${ADMIN_USERNAME} boot-source-selection delete "$boot_source_id" "$id") || true
		if echo "$result" | grep -qi "Unable to delete\|ephemeral"; then
			log "WARNING: Cannot delete selection ${id}: ${result} — skipping"
		fi
	done
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

  maas_cli "${ADMIN_USERNAME}" commissioning-scripts create name='99-netiface-names.sh' content@=/tmp/script.sh || exit 1

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
	local rc=$?
	if [[ $rc -eq 0 ]]; then
		log "Refreshing local API description cache..."
		command maas refresh 2>/dev/null || true
	fi
	return $rc
}

timer "$RETRY_TIMER" maas_login

configure_proxy
configure_ntp
configure_dns
configure_syslog
configure_extra_settings
create_extra_commissioning_script

# Add desired distro selection, then import, then apply configs, then clean up old selections.
# Order matters:
#   1. configure_boot_sources    — ensure only the desired distro is in selections
#   2. import_and_configure loop — retry start_import + configure_images as a unit:
#        if configure_images fails (images not yet accepted by MAAS), the outer
#        timer re-runs start_import on the next attempt rather than spinning on
#        set-config alone, which would loop forever against an empty boot-resource DB.
#   3. cleanup_old_boot_source_selections — remove duplicates left by in-place updates

function import_and_configure {
	start_import || return 1
	configure_images || return 1
}

timer "$RETRY_TIMER" configure_boot_sources
timer "$RETRY_TIMER" import_and_configure || { log "Import and configure FAILED!"; exit 1; }
cleanup_old_boot_source_selections
