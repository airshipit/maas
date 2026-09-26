#!/bin/bash

# Copyright 2026 The Airship Authors.
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

# Watchdog for maas-rackd running under systemd inside the rack container.
#
# rackd can end up in a state where it believes it is connected to every
# region event-loop, while the region has no RPC connection record for one
# of them (UI shows "rackd - 75% connected to region controllers"). The TFTP
# backend pins each booting node to a single RPC client, so nodes pinned to
# the broken connection fail to PXE boot until maas-rackd is restarted.
#
# This watchdog polls the region API for the rackd service status of this
# rack controller and restarts maas-rackd.service when it stays non-running
# for FAILURE_THRESHOLD consecutive checks.

set -u

INTERVAL=${WATCHDOG_INTERVAL:-60}
FAILURE_THRESHOLD=${WATCHDOG_FAILURE_THRESHOLD:-5}
COOLDOWN=${WATCHDOG_COOLDOWN:-600}
MAX_RESTARTS=${WATCHDOG_MAX_RESTARTS:-3}
STARTUP_GRACE=${WATCHDOG_STARTUP_GRACE:-600}
PROFILE=rackd-watchdog
STATUS_FILE=/run/maas-rackd-watchdog.status

log() {
  echo "maas-rackd-watchdog: $*"
}

write_status() {
  echo "$(date -u +%FT%TZ) $*" > "${STATUS_FILE}"
}

maas_login() {
  timeout 120 maas login "${PROFILE}" "${MAAS_ENDPOINT}" "${MAAS_API_KEY}" > /dev/null 2>&1
}

# Print "<status>|<status_info>" of the rackd service of this rack controller
# as seen by the region. Return non-zero if the region cannot be queried.
rackd_status() {
  local system_id json
  system_id=$(cat /var/lib/maas/maas_id 2> /dev/null)
  if [[ -z "${system_id}" ]]; then
    return 1
  fi
  if ! json=$(timeout 60 maas "${PROFILE}" rack-controller read "${system_id}" 2> /dev/null); then
    maas_login || true
    return 1
  fi
  jq -r '[.service_set[]? | select(.name == "rackd")][0] // {} | "\(.status // "unknown")|\(.status_info // "")"' <<< "${json}"
}

restart_rackd() {
  log "restarting maas-rackd.service ($*)"
  systemctl restart maas-rackd.service
}

if [[ -z "${MAAS_ENDPOINT:-}" ]] || [[ -z "${MAAS_API_KEY:-}" ]]; then
  log "MAAS_ENDPOINT and MAAS_API_KEY must be set, exiting"
  exit 1
fi

log "started: interval=${INTERVAL}s threshold=${FAILURE_THRESHOLD} cooldown=${COOLDOWN}s max_restarts=${MAX_RESTARTS} startup_grace=${STARTUP_GRACE}s"
write_status "starting"

# Give registration and the initial RPC connections time to settle.
sleep "${STARTUP_GRACE}"
maas_login || log "initial login to ${MAAS_ENDPOINT} failed, will retry"

failures=0
restarts=0
last_restart=0

while true; do
  sleep "${INTERVAL}"

  if ! systemctl is-active --quiet maas-rackd.service; then
    # systemd owns restarts of a crashed unit; only kick a unit left failed.
    if systemctl is-failed --quiet maas-rackd.service; then
      restart_rackd "unit is in failed state"
      last_restart=$(date +%s)
    fi
    write_status "rackd-inactive"
    continue
  fi

  if ! result=$(rackd_status); then
    # Region unreachable: restarting the rack would not help.
    log "unable to query rackd status from region at ${MAAS_ENDPOINT}, skipping check"
    write_status "region-unreachable"
    continue
  fi

  status=${result%%|*}
  info=${result#*|}

  if [[ "${status}" == "running" ]]; then
    if [[ ${failures} -gt 0 ]] || [[ ${restarts} -gt 0 ]]; then
      log "rackd is running again"
    fi
    failures=0
    restarts=0
    write_status "running"
    continue
  fi

  failures=$((failures + 1))
  log "rackd status is '${status}' (${info}), check ${failures}/${FAILURE_THRESHOLD}"
  write_status "${status} ${failures}/${FAILURE_THRESHOLD} ${info}"

  if [[ ${failures} -lt ${FAILURE_THRESHOLD} ]]; then
    continue
  fi

  now=$(date +%s)
  if [[ $((now - last_restart)) -lt ${COOLDOWN} ]]; then
    continue
  fi

  if [[ ${restarts} -ge ${MAX_RESTARTS} ]]; then
    # Do not flap forever if the cause is on the region side, e.g. a stale
    # region controller record that keeps every rack degraded.
    log "rackd still '${status}' after ${restarts} restarts, not restarting again until it recovers"
    write_status "gave-up ${status} ${info}"
    continue
  fi

  restart_rackd "status '${status}': ${info}"
  restarts=$((restarts + 1))
  failures=0
  last_restart=${now}
done
