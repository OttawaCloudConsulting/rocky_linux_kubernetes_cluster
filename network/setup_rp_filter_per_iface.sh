#!/usr/bin/env bash
# setup_rp_filter_per_iface.sh
# Templates /etc/sysctl.d/99-occ-vlan-rp_filter.conf from the per-host iface
# manifest in rp_filter_per_iface.conf and applies the override.
#
# Idempotent: re-running on an already-converted node yields no change. The
# script writes the new content to a tmpfile, compares against the live file,
# and only replaces (and re-runs sysctl --system) if the bytes differ.
#
# Standalone: bash setup_rp_filter_per_iface.sh
# Sourced:    setup_rp_filter_per_iface_main "$@"   # called from setup_interfaces.sh

set -euo pipefail

RPF_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
RPF_MANIFEST="${RPF_SCRIPT_DIR}/rp_filter_per_iface.conf"
RPF_INTERFACES_CONF="${RPF_SCRIPT_DIR}/interfaces.conf"

rpf_log()  { printf "[$(date '+%Y-%m-%d %H:%M:%S')] %s\n" "$*" >&2; }
rpf_die()  { printf "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: %s\n" "$*" >&2; exit 1; }

# Parse hostname into node_type using the same pattern as setup_interfaces.sh.
# Reads HOSTNAME_PREFIX from interfaces.conf so the two stay in lockstep.
rpf_parse_node_type() {
    local hostname="$1"
    local prefix="${HOSTNAME_PREFIX:-}"
    [[ -z "$prefix" ]] && rpf_die "HOSTNAME_PREFIX not set; source interfaces.conf first"

    if [[ "$hostname" =~ ^${prefix}(worker|control-plane)-?([0-9]{1,2})$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    rpf_die "Hostname '$hostname' does not match '${prefix}{worker|control-plane}[-]{##}'"
}

# Resolve the iface + VLAN list for a host.
# Per-host overrides win over node_type defaults.
rpf_resolve_keys() {
    local hostname="$1"
    local node_type="$2"
    local ifaces vlans

    if [[ -n "${RPF_HOST_IFACES[$hostname]:-}" ]]; then
        ifaces="${RPF_HOST_IFACES[$hostname]}"
    else
        ifaces="${RPF_NODE_TYPE_IFACES[$node_type]:-}"
    fi
    [[ -z "$ifaces" ]] && rpf_die "No ifaces resolved for host=$hostname type=$node_type"

    if [[ -n "${RPF_HOST_VLANS[$hostname]:-}" ]]; then
        vlans="${RPF_HOST_VLANS[$hostname]}"
    else
        vlans="${RPF_NODE_TYPE_VLANS[$node_type]:-}"
    fi
    [[ -z "$vlans" ]] && rpf_die "No vlans resolved for host=$hostname type=$node_type"

    printf '%s\n%s\n' "$ifaces" "$vlans"
}

# Emit the canonical file body for a node_type.
# Body is byte-stable: identical inputs produce identical bytes.
# Header prose is intentionally specialised per node_type so the file matches
# the apply-campaign artifacts already on disk; key ordering is VLAN-outer,
# iface-inner per PRD §Configuration list ordering.
rpf_emit_body() {
    local node_type="$1"
    local ifaces_str="$2"
    local vlans_str="$3"

    case "$node_type" in
        control-plane)
            cat <<'EOF'
# OCC apply campaign — VLAN43 RPF remediation (per-interface rp_filter=2)
# Source: docs/problems/vlan43-error/apply/prd.md §Configuration (k8control row)
# Architecture: docs/problems/vlan43-error/apply/architecture.md Decision #1, #2
# Sustainment: RECOMMENDATION.md §4 — file name sorts AFTER /usr/lib/sysctl.d/50-redhat.conf
#              (the wildcard *.rp_filter=1 writer identified by predecessor D-1).
# Note: per-iface keys are independent of net.ipv4.conf.all.rp_filter (Linux kernel
#       uses max(all, iface) for RPF; the Cilium override all.rp_filter=0 does NOT
#       mask the values below on these interfaces).
EOF
            ;;
        worker)
            cat <<'EOF'
# OCC apply campaign — VLAN43 RPF remediation (per-interface rp_filter=2)
# Source: docs/problems/vlan43-error/apply/prd.md §Configuration (worker rows)
# Architecture: docs/problems/vlan43-error/apply/architecture.md Decision #1, #2
# Sustainment: RECOMMENDATION.md §4 — file name sorts AFTER /usr/lib/sysctl.d/50-redhat.conf
#              (the wildcard *.rp_filter=1 writer identified by predecessor D-1).
# Note: per-iface keys are independent of net.ipv4.conf.all.rp_filter.
# Workers: include /41 keys to close VLAN41 structural risk per RECOMMENDATION.md §4 row 2.
EOF
            ;;
        *)
            rpf_die "Unsupported node_type: $node_type"
            ;;
    esac

    local vlan iface
    for vlan in $vlans_str; do
        for iface in $ifaces_str; do
            echo "net.ipv4.conf.${iface}/${vlan}.rp_filter = 2"
        done
    done
}

# Public: print the canonical file body for a given hostname.
# Used by both the on-node setup path and the operator-side drift checker.
rpf_render_for_host() {
    local hostname="$1"
    local node_type ifaces vlans
    node_type="$(rpf_parse_node_type "$hostname")"

    local resolved
    resolved="$(rpf_resolve_keys "$hostname" "$node_type")"
    ifaces="$(printf '%s' "$resolved" | sed -n '1p')"
    vlans="$(printf '%s' "$resolved" | sed -n '2p')"

    rpf_emit_body "$node_type" "$ifaces" "$vlans"
}

# Idempotent install: write tmpfile, diff, replace only on change.
# Returns 0 (no change), 0 (changed + applied), or non-zero (failure).
# Echos one of: "no-change", "applied" on stdout for caller capture.
rpf_install() {
    local target="${RPF_PERSISTENCE_FILE:?manifest not loaded}"
    local owner="${RPF_FILE_OWNER:?}"
    local mode="${RPF_FILE_MODE:?}"
    local context="${RPF_FILE_SELINUX_CONTEXT:?}"
    local hostname; hostname="$(hostname -s)"

    local tmpfile
    tmpfile="$(mktemp /tmp/99-occ-vlan-rp_filter.XXXXXX.conf)"
    # Expand $tmpfile NOW so the trap body has the value baked in — `local`
    # tmpfile goes out of scope before the RETURN trap body evaluates under
    # `set -u`, which would otherwise raise "unbound variable".
    # shellcheck disable=SC2064
    trap "rm -f '$tmpfile'" RETURN

    rpf_render_for_host "$hostname" > "$tmpfile"

    # Normalise expected mode to match `stat -c %a` output (no leading 0).
    local mode_norm="${mode#0}"

    if [[ -f "$target" ]] && cmp -s "$tmpfile" "$target"; then
        # Content identical. Verify metadata too; reapply metadata if drifted.
        local cur_owner cur_mode cur_ctx
        cur_owner="$(stat -c '%U:%G' "$target")"
        cur_mode="$(stat -c '%a' "$target")"
        cur_ctx="$(stat -c '%C' "$target" 2>/dev/null || echo '')"

        if [[ "$cur_owner" == "$owner" && "$cur_mode" == "$mode_norm" && \
              ( -z "$cur_ctx" || "$cur_ctx" == "$context" ) ]]; then
            rpf_log "rp_filter override: no change ($target)"
            echo "no-change"
            return 0
        fi
        rpf_log "rp_filter override: content unchanged but metadata drifted; re-applying perms/context"
        sudo chown "$owner" "$target"
        sudo chmod "$mode" "$target"
        command -v chcon >/dev/null && sudo chcon "$context" "$target" || true
        echo "applied"
        return 0
    fi

    rpf_log "rp_filter override: installing $target"
    sudo install -o "${owner%:*}" -g "${owner#*:}" -m "$mode" "$tmpfile" "$target"
    if command -v chcon >/dev/null; then
        sudo chcon "$context" "$target" 2>/dev/null || \
            rpf_log "WARN: chcon failed; SELinux context may differ"
    fi

    rpf_log "rp_filter override: applying via sysctl --system"
    sudo sysctl --system >/dev/null

    # POST verify: every key generated must read back as 2 from the kernel.
    local node_type ifaces vlans iface vlan key val ok=1
    node_type="$(rpf_parse_node_type "$hostname")"
    local resolved; resolved="$(rpf_resolve_keys "$hostname" "$node_type")"
    ifaces="$(printf '%s' "$resolved" | sed -n '1p')"
    vlans="$(printf '%s' "$resolved" | sed -n '2p')"
    for vlan in $vlans; do
        for iface in $ifaces; do
            key="net.ipv4.conf.${iface}/${vlan}.rp_filter"
            val="$(sudo sysctl -n "$key" 2>/dev/null || echo MISSING)"
            if [[ "$val" != "2" ]]; then
                rpf_log "POST verify FAIL: $key=$val (expected 2)"
                ok=0
            fi
        done
    done
    [[ "$ok" == "1" ]] || rpf_die "POST verify failed for one or more keys"

    rpf_log "rp_filter override: applied"
    echo "applied"
}

setup_rp_filter_per_iface_main() {
    [[ -f "$RPF_INTERFACES_CONF" ]] || rpf_die "Missing $RPF_INTERFACES_CONF"
    [[ -f "$RPF_MANIFEST" ]]        || rpf_die "Missing $RPF_MANIFEST"
    # shellcheck disable=SC1090
    source "$RPF_INTERFACES_CONF"
    # shellcheck disable=SC1090
    source "$RPF_MANIFEST"

    rpf_install
}

# When executed directly (not sourced), run main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_rp_filter_per_iface_main "$@"
fi
