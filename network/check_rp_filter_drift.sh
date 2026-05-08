#!/usr/bin/env bash
# check_rp_filter_drift.sh
# Operator-side SSH-fanout drift check for /etc/sysctl.d/99-occ-vlan-rp_filter.conf.
# Renders the canonical content per host from rp_filter_per_iface.conf, fetches
# the on-disk file from each node via SSH, diffs, and reports per-host status.
#
# Run from the operator Mac (or any host with SSH access to the cluster nodes).
# Exits 0 if every host reports clean; non-zero if any host drifted, missing,
# or unreachable.
#
# Usage:  bash check_rp_filter_drift.sh [-h host1[,host2,...]]
# Default host list:  k8control k8w00 k8w01 k8w02

set -euo pipefail

DRIFT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
DRIFT_MANIFEST="${DRIFT_SCRIPT_DIR}/rp_filter_per_iface.conf"
DRIFT_INTERFACES_CONF="${DRIFT_SCRIPT_DIR}/interfaces.conf"
DRIFT_RENDERER="${DRIFT_SCRIPT_DIR}/setup_rp_filter_per_iface.sh"

DEFAULT_HOSTS=("k8control" "k8w00" "k8w01" "k8w02")

usage() {
    cat <<EOF
Usage: bash $(basename "$0") [-h host1,host2,...]

Checks /etc/sysctl.d/99-occ-vlan-rp_filter.conf on each host against the
canonical content rendered from rp_filter_per_iface.conf.

Options:
  -h HOSTS   Comma-separated SSH host aliases. Default: ${DEFAULT_HOSTS[*]}

Exit codes:
  0  every host clean
  1  one or more hosts drifted, missing the file, or unreachable
EOF
}

HOSTS=("${DEFAULT_HOSTS[@]}")
while getopts ":h:?" opt; do
    case "$opt" in
        h) IFS=',' read -r -a HOSTS <<< "$OPTARG" ;;
        ?|*) usage; exit 0 ;;
    esac
done

[[ -f "$DRIFT_MANIFEST" ]]      || { echo "missing $DRIFT_MANIFEST" >&2; exit 2; }
[[ -f "$DRIFT_INTERFACES_CONF" ]] || { echo "missing $DRIFT_INTERFACES_CONF" >&2; exit 2; }
[[ -f "$DRIFT_RENDERER" ]]      || { echo "missing $DRIFT_RENDERER" >&2; exit 2; }

# Source manifest + renderer into THIS shell so we can call rpf_render_for_host.
# shellcheck disable=SC1090
source "$DRIFT_INTERFACES_CONF"
# shellcheck disable=SC1090
source "$DRIFT_MANIFEST"
# shellcheck disable=SC1090
source "$DRIFT_RENDERER"

# Translate SSH alias -> remote hostname -s. We render against the remote
# hostname (parse_node_type expects HOSTNAME_PREFIX-matching strings), not the
# local SSH alias.
remote_hostname() {
    ssh -o ConnectTimeout=5 -o BatchMode=yes "$1" 'hostname -s' 2>/dev/null
}

target="${RPF_PERSISTENCE_FILE:?manifest did not load}"

overall_rc=0
printf '%-12s  %-32s  %s\n' "host" "remote-hostname" "status"
printf '%-12s  %-32s  %s\n' "----" "---------------" "------"
for host in "${HOSTS[@]}"; do
    rh="$(remote_hostname "$host")" || rh=""
    if [[ -z "$rh" ]]; then
        printf '%-12s  %-32s  %s\n' "$host" "(unreachable)" "FAIL"
        overall_rc=1
        continue
    fi

    expected="$(rpf_render_for_host "$rh" 2>/dev/null)" || {
        printf '%-12s  %-32s  %s\n' "$host" "$rh" "FAIL (cannot render: hostname does not match manifest)"
        overall_rc=1
        continue
    }

    actual="$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" "cat $target 2>/dev/null" || true)"
    if [[ -z "$actual" ]]; then
        printf '%-12s  %-32s  %s\n' "$host" "$rh" "FAIL (file missing)"
        overall_rc=1
        continue
    fi

    if [[ "$expected" == "$actual" ]]; then
        printf '%-12s  %-32s  %s\n' "$host" "$rh" "OK"
    else
        printf '%-12s  %-32s  %s\n' "$host" "$rh" "DRIFT"
        echo "    --- expected vs $host:$target ---"
        diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/    /'
        overall_rc=1
    fi
done

exit "$overall_rc"
