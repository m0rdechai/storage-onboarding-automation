#!/usr/bin/env bash
#
# setup-storage-lta.sh — Storage LTA onboarding utility
#
# Automates the end-to-end process of connecting a ScaleLab cloud allocation
# to the Storage LTA (cloud99).  Stages:
#   collect    — query QUADS API, extract host/interface/MAC data
#   verify     — check that target interfaces aren't already in use
#   jira-draft — generate a VLAN-change Jira request (SCALELAB project)
#   host-setup — create VLAN sub-interfaces, configure iSCSI + multipath
#   check      — verify connectivity to storage portal IPs
#
# Design principles:
#   - Minimal required input: CLOUD_ID + STORAGE_ARRAYS in an env file
#   - Everything else auto-discovered from the QUADS API
#   - Alternating NIC-to-path mapping for multipath resilience
#   - Dry-run mode for safe previewing
#
# VLAN/subnet formulas from storage-lta-subnet-calc.sh:
#   VLAN   = storage_digit × 100 + cloud_id
#   Subnet = 172.(15 + storage_digit).(100 + cloud_id).0/24

set -euo pipefail

PROG="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESULTS_DIR="${REPO_DIR}/results"

# =============================================================================
# Defaults (overridable via env file)
# =============================================================================
CLOUD_ID=""
STORAGE_ARRAYS=""
NETWORKS="3 4"
EXCLUDE_HOSTS=""
TARGET_TYPE="ocp"
SSH_USER=""
QUADS_API="https://quads2.rdu2.scalelab.redhat.com/api/v3"
CLOUD99_OUTER_VLAN="2080"

# Script options
DRY_RUN=false
VERBOSE=false
SINGLE_WORKER=""
ENV_FILE=""
LOG_DIR="${REPO_DIR}/logs"
LOG_FILE=""

# =============================================================================
# Platform digit table (from storage-lta-subnet-calc.sh)
# name|pathA_digit — path B is always pathA_digit + 1
# =============================================================================
declare -A PLATFORM_DIGITS
PLATFORM_DIGITS=(
    [ibm]=1
    [netapp-asa]=3
    [pure]=5
    [netapp-a300]=7
)

declare -A PLATFORM_NAMES
PLATFORM_NAMES=(
    [ibm]="IBM FlashSystem 7300"
    [netapp-asa]="NetApp ASA A70"
    [pure]="Pure FlashArray X70R5"
    [netapp-a300]="NetApp AFF A300"
)

# =============================================================================
# Model-to-OS interface name mapping (from ScaleLabTipsAndTricks)
# Key: MODEL:emN  Value: OS-level name on EL9
# =============================================================================
declare -A IFACE_OS_MAP
IFACE_OS_MAP=(
    [R630:em1]="eno1"        [R630:em2]="eno2"        [R630:em3]="eno3"        [R630:em4]="eno4"
    [R640:em1]="ens1f0"      [R640:em2]="ens1f1"      [R640:em3]="ens2f0np0"   [R640:em4]="ens2f1np1"   [R640:em5]="eno2np1"
    [R650:em1]="ens1f0"      [R650:em2]="ens1f1"      [R650:em3]="ens2f0np0"   [R650:em4]="ens2f1np1"   [R650:em5]="eno12409np1"
    [R660:em1]="ens1f0"      [R660:em2]="ens1f1"      [R660:em3]="ens2f0np0"   [R660:em4]="ens2f1np1"   [R660:em5]="eno12409np1"
    [R750:em1]="ens3f0"      [R750:em2]="ens3f1"      [R750:em3]="ens6f0np0"   [R750:em4]="ens6f1np1"   [R750:em5]="eno12409np1"
    [R6625:em1]="ens2f0"     [R6625:em2]="ens2f1"     [R6625:em3]="ens1f0np0"  [R6625:em4]="ens1f1np1"  [R6625:em5]="eno12409np1"
)

# =============================================================================
# Multipath device configs per vendor
# =============================================================================
MULTIPATH_IBM='devices {
        device {
                vendor                  "IBM"
                product                 "2145"
                path_grouping_policy    "group_by_prio"
                prio                    "alua"
                path_checker            "tur"
                path_selector           "service-time 0"
                failback                "immediate"
                no_path_retry           "queue"
                rr_weight               "uniform"
                rr_min_io_rq            1
                fast_io_fail_tmo        5
                dev_loss_tmo            infinity
        }
}'

MULTIPATH_PURE='devices {
        device {
                vendor                  "PURE"
                product                 "FlashArray"
                path_grouping_policy    "group_by_prio"
                prio                    "alua"
                path_checker            "tur"
                path_selector           "service-time 0"
                failback                "immediate"
                no_path_retry           1
                rr_weight               "uniform"
                rr_min_io_rq            1
                fast_io_fail_tmo        10
                dev_loss_tmo            60
        }
}'

MULTIPATH_NETAPP='devices {
        device {
                vendor                  "NETAPP"
                product                 "LUN"
                path_grouping_policy    "group_by_prio"
                prio                    "ontap"
                path_checker            "tur"
                path_selector           "service-time 0"
                failback                "immediate"
                no_path_retry           "queue"
                rr_weight               "uniform"
                rr_min_io_rq            128
                fast_io_fail_tmo        5
                dev_loss_tmo            infinity
                features                "3 queue_if_no_path pg_init_retries 50"
        }
}'

# =============================================================================
# Logging
# =============================================================================
log()         { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
log_verbose() { [[ "$VERBOSE" == "true" ]] && log "[VERBOSE] $*"; }
log_error()   { log "[ERROR] $*"; }
log_success() { log "[OK] $*"; }
log_warn()    { log "[WARN] $*"; }

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
Usage: ${PROG} -e <env-file> [STAGE] [OPTIONS]

Stages (run one at a time, or 'all'):
  collect      Query QUADS API, output MAC CSV to results/
  verify       Check interfaces aren't already in cloud99 / active use
  jira-draft   Generate Jira VLAN change request text
  host-setup   Create VLAN sub-interfaces + iSCSI/multipath config
  check        Verify connectivity to storage portal IPs
  all          Run all stages in order

Options:
  -e FILE      Environment file (required)
  -n           Dry-run mode — show what would be done, change nothing
  -v           Verbose output
  -w HOST      Single-worker mode — run only on this host
  -h           Show this help

The env file must set at minimum:
  CLOUD_ID=6
  STORAGE_ARRAYS="ibm pure"

See env/cloud06.env for a full example.
EOF
    exit 0
}

# =============================================================================
# VLAN / Subnet helpers (from storage-lta-subnet-calc.sh formulas)
# =============================================================================
calc_vlan()        { echo $(( $1 * 100 + CLOUD_ID )); }
calc_subnet_base() { echo "172.$(( 15 + $1 )).$(( 100 + CLOUD_ID ))"; }

get_platform_digit_a() {
    local vendor="$1"
    local digit="${PLATFORM_DIGITS[$vendor]:-}"
    if [[ -z "$digit" ]]; then
        log_error "Unknown storage vendor '${vendor}'. Known: ${!PLATFORM_DIGITS[*]}"
        return 1
    fi
    echo "$digit"
}

# =============================================================================
# NIC-to-path mapping — alternating convention
#
# Vendors at odd positions (1st, 3rd) in STORAGE_ARRAYS:
#   path A → first network NIC, path B → second network NIC
# Vendors at even positions (2nd, 4th):
#   path B → first network NIC, path A → second network NIC
#
# Result: each physical NIC carries exactly one path per vendor.
# =============================================================================

# Prints lines: <emN> <vlan_id> <subnet_base> <vendor> <path>
# for every (vendor, path, NIC) combination.
compute_vlan_layout() {
    local -a networks_arr
    read -r -a networks_arr <<< "$NETWORKS"
    if (( ${#networks_arr[@]} < 2 )); then
        log_error "NETWORKS must list at least 2 network numbers (got: ${NETWORKS})"
        return 1
    fi
    local nic_first="em${networks_arr[0]}"
    local nic_second="em${networks_arr[1]}"

    local -a vendors_arr
    read -r -a vendors_arr <<< "$STORAGE_ARRAYS"

    local idx=0
    for vendor in "${vendors_arr[@]}"; do
        local digitA
        digitA=$(get_platform_digit_a "$vendor") || return 1
        local digitB=$(( digitA + 1 ))

        local vlanA vlanB subA subB
        vlanA=$(calc_vlan "$digitA")
        vlanB=$(calc_vlan "$digitB")
        subA=$(calc_subnet_base "$digitA")
        subB=$(calc_subnet_base "$digitB")

        if (( idx % 2 == 0 )); then
            # Odd-position vendor (0-indexed even): path A → first NIC
            echo "${nic_first}  ${vlanA}  ${subA}  ${vendor}  A"
            echo "${nic_second} ${vlanB}  ${subB}  ${vendor}  B"
        else
            # Even-position vendor (0-indexed odd): flipped
            echo "${nic_first}  ${vlanB}  ${subB}  ${vendor}  B"
            echo "${nic_second} ${vlanA}  ${subA}  ${vendor}  A"
        fi
        (( idx++ )) || true
    done
}

# =============================================================================
# QUADS API helpers
# =============================================================================
quads_query_hosts() {
    local cloud_name="cloud$(printf '%02d' "$CLOUD_ID")"
    local cache_file="${RESULTS_DIR}/${cloud_name}.json"

    # Check results dir first, then repo root (legacy location)
    if [[ -f "$cache_file" ]]; then
        log "Using cached QUADS data: ${cache_file}"
        cat "$cache_file"
        return
    fi
    if [[ -f "${REPO_DIR}/${cloud_name}.json" ]]; then
        log "Using cached QUADS data: ${REPO_DIR}/${cloud_name}.json"
        cat "${REPO_DIR}/${cloud_name}.json"
        return
    fi

    local url="${QUADS_API}/hosts?cloud=${cloud_name}"
    log "Querying QUADS API: ${url}"
    local response
    response=$(curl -sf "$url") || {
        # Try without zero-padding
        url="${QUADS_API}/hosts?cloud=cloud${CLOUD_ID}"
        log "Retrying: ${url}"
        response=$(curl -sf "$url") || {
            log_error "Failed to query QUADS API for cloud ${CLOUD_ID}"
            return 1
        }
    }

    mkdir -p "$RESULTS_DIR"
    echo "$response" | python3 -m json.tool > "$cache_file" 2>/dev/null || echo "$response" > "$cache_file"
    log "Cached QUADS response to ${cache_file}"
    cat "$cache_file"
}

# Extract hosts JSON → lines of: hostname model
parse_hosts() {
    local json="$1"
    echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for h in data:
    print(h['name'], h.get('model', 'UNKNOWN'))
"
}

# Extract interfaces for a given host and network numbers
# Output: hostname interface_name mac_address
parse_interfaces() {
    local json="$1"
    local -a net_nums
    read -r -a net_nums <<< "$NETWORKS"

    local iface_filter=""
    for n in "${net_nums[@]}"; do
        iface_filter+="\"em${n}\","
    done
    iface_filter="${iface_filter%,}"

    echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
wanted = {${iface_filter}}
exclude = set('''${EXCLUDE_HOSTS}'''.split())
for h in data:
    if h['name'] in exclude:
        continue
    for iface in h.get('interfaces', []):
        if iface['name'] in wanted:
            print(h['name'], iface['name'], iface['mac_address'])
"
}

# Get model for a specific host
get_host_model() {
    local json="$1"
    local hostname="$2"
    echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for h in data:
    if h['name'] == '${hostname}':
        print(h.get('model', 'UNKNOWN'))
        break
"
}

# Resolve BIOS interface name (emN) to OS-level name for a model
resolve_os_iface() {
    local model="$1"
    local bios_name="$2"
    local key="${model}:${bios_name}"
    local os_name="${IFACE_OS_MAP[$key]:-}"
    if [[ -z "$os_name" ]]; then
        log_warn "No OS interface mapping for ${key}; using BIOS name '${bios_name}'"
        echo "$bios_name"
    else
        echo "$os_name"
    fi
}

# =============================================================================
# Remote execution helpers — OCP vs bare-metal
#
# OCP CoreOS workers cannot be configured via SSH + nmcli.
#   - VLAN interfaces → NNCP (NodeNetworkConfigurationPolicy) CRDs via oc apply
#   - Host commands   → oc debug node/<name> -- chroot /host <cmd>
#
# Bare-metal / VMware hosts use direct SSH + nmcli.
# =============================================================================
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

# run_on_host — execute a command on a host, dispatching by TARGET_TYPE.
#   For OCP:        oc debug node/<node> -- chroot /host bash -c '<cmd>'
#   For bare-metal: ssh <user>@<host> '<cmd>'
run_on_host() {
    local host="$1"
    shift
    local cmd="$*"

    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ "$TARGET_TYPE" == "ocp" ]]; then
            log "[DRY-RUN] Would run on node ${host} via oc debug: ${cmd}"
        else
            log "[DRY-RUN] Would execute on ${host} via SSH: ${cmd}"
        fi
        return 0
    fi

    if [[ "$TARGET_TYPE" == "ocp" ]]; then
        log_verbose "oc debug node/${host}: ${cmd}"
        oc debug "node/${host}" -- chroot /host bash -c "$cmd" 2>&1
    else
        log_verbose "SSH ${host}: ${cmd}"
        ssh $SSH_OPTS "${SSH_USER}@${host}" "$cmd" 2>&1
    fi
}

# Resolve a QUADS FQDN to the identifier used for remote execution.
#   OCP:        the short node name known to oc (e.g. "f01-h23-000-r640")
#   bare-metal: the FQDN or InternalIP
get_worker_id() {
    local hostname="$1"
    if [[ "$TARGET_TYPE" == "ocp" ]]; then
        # OCP node names are typically the short hostname
        local short="${hostname%%.*}"
        # Verify it exists in oc get nodes
        if command -v oc &>/dev/null; then
            if oc get node "$short" &>/dev/null 2>&1; then
                echo "$short"
                return
            fi
            # Try the FQDN
            if oc get node "$hostname" &>/dev/null 2>&1; then
                echo "$hostname"
                return
            fi
        fi
        # Fallback: return the short name and let oc debug fail with a clear message
        echo "$short"
    else
        echo "$hostname"
    fi
}

# Test that we can reach a host (SSH or oc debug)
test_host_reachable() {
    local worker_id="$1"
    if [[ "$TARGET_TYPE" == "ocp" ]]; then
        oc debug "node/${worker_id}" -- echo ok &>/dev/null 2>&1
    else
        ssh $SSH_OPTS "${SSH_USER}@${worker_id}" "echo ok" &>/dev/null 2>&1
    fi
}

# =============================================================================
# STAGE: collect
# =============================================================================
do_collect() {
    log "=== STAGE: collect ==="
    log "Cloud ID: ${CLOUD_ID}, Networks: ${NETWORKS}"

    local json
    json=$(quads_query_hosts) || return 1

    local cloud_name="cloud$(printf '%02d' "$CLOUD_ID")"
    local csv_file="${RESULTS_DIR}/${cloud_name}.csv"

    log "Extracting interfaces for networks: ${NETWORKS}"

    {
        echo "hostname,interface,mac_address"
        parse_interfaces "$json" | while read -r hostname iface mac; do
            echo "${hostname},${iface},${mac}"
        done
    } > "$csv_file"

    local count
    count=$(( $(wc -l < "$csv_file") - 1 ))
    log_success "Collected ${count} interface(s) → ${csv_file}"

    if [[ "$VERBOSE" == "true" ]]; then
        log_verbose "Contents:"
        cat "$csv_file" >&2
    fi
}

# =============================================================================
# STAGE: verify
# =============================================================================
do_verify() {
    log "=== STAGE: verify ==="

    local cloud_name="cloud$(printf '%02d' "$CLOUD_ID")"
    local csv_file="${RESULTS_DIR}/${cloud_name}.csv"
    if [[ ! -f "$csv_file" ]]; then
        log_error "No CSV found at ${csv_file}. Run 'collect' stage first."
        return 1
    fi

    local issues=0
    local checked=0

    # Read all MACs and verify against the full QUADS host list
    log "Verifying MAC addresses against QUADS host inventory..."
    local all_hosts_response
    all_hosts_response=$(curl -sf "${QUADS_API}/hosts?retired=false&broken=false" 2>/dev/null) || {
        log_warn "Could not query full QUADS inventory for verification. Skipping MAC cross-check."
        all_hosts_response=""
    }

    tail -n +2 "$csv_file" | while IFS=',' read -r hostname iface mac; do
        (( checked++ )) || true

        if [[ -n "$all_hosts_response" ]]; then
            local match
            match=$(echo "$all_hosts_response" | python3 -c "
import json, sys
data = json.load(sys.stdin)
mac = '${mac}'
for h in data:
    for i in h.get('interfaces', []):
        if i['mac_address'] == mac:
            print(f\"{h['name']}:{i['name']}\")
            sys.exit(0)
print('NOT_FOUND')
" 2>/dev/null) || match="ERROR"

            if [[ "$match" == "NOT_FOUND" ]]; then
                log_warn "  MAC ${mac} (${hostname}/${iface}) not found in QUADS inventory"
                (( issues++ )) || true
            elif [[ "$match" != "${hostname}:${iface}" && "$match" != "ERROR" ]]; then
                log_warn "  MAC ${mac} mapped to ${match} in QUADS, but CSV says ${hostname}:${iface}"
                (( issues++ )) || true
            else
                log_verbose "  OK: ${mac} → ${hostname}:${iface}"
            fi
        fi
    done

    if (( issues > 0 )); then
        log_warn "Verification found ${issues} issue(s). Review before proceeding."
    else
        log_success "All MAC addresses verified (${checked} checked, 0 issues)"
    fi
}

# =============================================================================
# STAGE: jira-draft
# =============================================================================
do_jira_draft() {
    log "=== STAGE: jira-draft ==="

    local cloud_name="cloud$(printf '%02d' "$CLOUD_ID")"
    local csv_file="${RESULTS_DIR}/${cloud_name}.csv"
    if [[ ! -f "$csv_file" ]]; then
        log_error "No CSV found at ${csv_file}. Run 'collect' stage first."
        return 1
    fi

    local draft_file="${RESULTS_DIR}/${cloud_name}-jira-draft.txt"
    local -a networks_arr
    read -r -a networks_arr <<< "$NETWORKS"

    {
        cat <<HEADER
The request is for requesting vlan membership change for ${#networks_arr[@]} interfaces on specific ${cloud_name} hosts.

Please re-assign vlan membership for the following hosts and interfaces currently in ${cloud_name} to cloud99

hostname,interface,mac_address
HEADER

        tail -n +2 "$csv_file" | while IFS=',' read -r hostname iface mac; do
            echo "${hostname},${iface},${mac}"
        done

        echo ""
        echo "--- quads commands ---"
        echo ""

        # Collect unique hostnames, then emit quads commands per host per network
        local prev_host=""
        tail -n +2 "$csv_file" | sort | while IFS=',' read -r hostname iface mac; do
            local nic_num="${iface#em}"
            echo "quads --modify-switch-conf --host ${hostname} --nic${nic_num} ${CLOUD99_OUTER_VLAN} --change # reassign vlan membership from ${cloud_name} for ${mac} to cloud99"
        done

        echo ""
        echo "Note that while these hosts are part of ${cloud_name} some of these interfaces shared above may show cloud outer-vlan membership in another cloud. The desired result is for them to be in cloud99."
    } > "$draft_file"

    log_success "Jira draft written to: ${draft_file}"

    if [[ "$VERBOSE" == "true" ]]; then
        echo "--- begin jira draft ---" >&2
        cat "$draft_file" >&2
        echo "--- end jira draft ---" >&2
    fi
}

# =============================================================================
# STAGE: host-setup
#
# Two paths depending on TARGET_TYPE:
#   ocp  → generate NNCP YAMLs for VLAN interfaces, apply via oc apply;
#          iSCSI/multipath via oc debug
#   bare/vmware → SSH + nmcli for VLANs, SSH for iSCSI/multipath
# =============================================================================

# ---- OCP: Generate NNCP YAML for a single VLAN interface --------------------
# Generates a NodeNetworkConfigurationPolicy that creates a VLAN sub-interface
# with DHCP on all matching nodes.
generate_nncp_yaml() {
    local os_nic="$1"
    local vlan_id="$2"
    local vendor="$3"
    local path="$4"
    local node_selector_key="$5"
    local node_selector_value="$6"

    local cloud_name="cloud$(printf '%02d' "$CLOUD_ID")"
    local profile="vlan${vlan_id}"
    local vendor_name="${PLATFORM_NAMES[$vendor]:-$vendor}"

    cat <<EOF
---
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ${cloud_name}-${profile}-storage-lta
  labels:
    storage-lta/cloud: "${cloud_name}"
    storage-lta/vendor: "${vendor}"
    storage-lta/path: "${path}"
spec:
  nodeSelector:
    ${node_selector_key}: "${node_selector_value}"
  desiredState:
    interfaces:
      - name: ${os_nic}
        type: ethernet
        state: up
        mtu: 9000
      - name: ${os_nic}.${vlan_id}
        type: vlan
        state: up
        ipv4:
          dhcp: true
          enabled: true
        ipv6:
          enabled: false
        vlan:
          base-iface: ${os_nic}
          id: ${vlan_id}
        mtu: 9000
EOF
}

# ---- OCP: Generate all NNCP YAMLs and apply them ----------------------------
setup_vlan_interfaces_ocp() {
    local json="$1"
    local cloud_name="cloud$(printf '%02d' "$CLOUD_ID")"
    local nncp_dir="${RESULTS_DIR}/${cloud_name}-nncp"
    mkdir -p "$nncp_dir"
    # Clear old NNCPs from previous runs
    rm -f "${nncp_dir}"/*.yaml 2>/dev/null || true

    # Determine if all nodes share the same model (from QUADS data)
    local -a models=()
    mapfile -t models < <(echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
exclude = set('''${EXCLUDE_HOSTS}'''.split())
models = set()
for h in data:
    if h['name'] not in exclude:
        models.add(h.get('model', 'UNKNOWN'))
for m in sorted(models):
    print(m)
")

    log "  Node models in cloud: ${models[*]}"

    # Get actual OCP worker node names from the cluster
    local -a ocp_workers=()
    if command -v oc &>/dev/null && [[ "$DRY_RUN" != "true" ]]; then
        mapfile -t ocp_workers < <(oc get nodes -l node-role.kubernetes.io/worker --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
        log "  OCP worker nodes: ${ocp_workers[*]}"
    fi

    if (( ${#models[@]} == 1 )); then
        # All same model — one set of NNCPs with worker nodeSelector
        local model="${models[0]}"
        log "  All nodes are ${model} — generating NNCPs with worker nodeSelector"

        compute_vlan_layout | while read -r bios_nic vlan_id subnet_base vendor path; do
            local os_nic
            os_nic=$(resolve_os_iface "$model" "$bios_nic")
            local vendor_name="${PLATFORM_NAMES[$vendor]:-$vendor}"
            local nncp_file="${nncp_dir}/nncp-vlan${vlan_id}.yaml"

            log "    ${bios_nic} (${os_nic}): vlan${vlan_id} → ${vendor_name} path ${path} (DHCP)"

            generate_nncp_yaml "$os_nic" "$vlan_id" "$vendor" "$path" \
                "node-role.kubernetes.io/worker" "" \
                > "$nncp_file"
        done
    else
        # Mixed models — need per-node NNCPs using actual OCP node names.
        # Build a MAC → OCP node name map by probing each OCP worker.
        log "  Mixed models detected — generating per-node NNCPs"
        log "  Building MAC → OCP node mapping..."

        declare -A mac_to_ocp_node=()
        declare -A ocp_node_model=()
        for ocp_node in "${ocp_workers[@]}"; do
            # Discover MACs on this OCP node to match against QUADS data
            local node_macs
            node_macs=$(oc debug "node/${ocp_node}" -- chroot /host bash -c \
                'for d in /sys/class/net/*/address; do iface=$(echo $d | cut -d/ -f5); mac=$(cat $d); echo "$iface $mac"; done' 2>/dev/null | grep -v "^lo " || true)
            while read -r iface mac; do
                mac_to_ocp_node["$mac"]="$ocp_node"
            done <<< "$node_macs"
        done

        # Now match QUADS hosts to OCP nodes via em3 MAC
        parse_hosts "$json" | while read -r hostname model; do
            if [[ -n "$EXCLUDE_HOSTS" ]]; then
                local skip=false
                for excl in $EXCLUDE_HOSTS; do
                    [[ "$hostname" == *"$excl"* ]] && skip=true
                done
                [[ "$skip" == "true" ]] && continue
            fi
            if [[ -n "$SINGLE_WORKER" && "$hostname" != *"$SINGLE_WORKER"* ]]; then
                continue
            fi

            # Find this host's em3 MAC to identify the OCP node
            local em3_mac
            em3_mac=$(echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for h in data:
    if h['name'] == '${hostname}':
        for i in h.get('interfaces', []):
            if i['name'] == 'em3':
                print(i['mac_address'])
                break
        break
" 2>/dev/null)

            local ocp_node="${mac_to_ocp_node[$em3_mac]:-}"
            if [[ -z "$ocp_node" ]]; then
                log_warn "    Could not find OCP node for ${hostname} (em3 MAC: ${em3_mac}). Skipping."
                continue
            fi

            log "    ${hostname} (${model}) → OCP node: ${ocp_node}"

            compute_vlan_layout | while read -r bios_nic vlan_id subnet_base vendor path; do
                local os_nic
                os_nic=$(resolve_os_iface "$model" "$bios_nic")
                local vendor_name="${PLATFORM_NAMES[$vendor]:-$vendor}"
                local nncp_file="${nncp_dir}/nncp-${ocp_node}-vlan${vlan_id}.yaml"

                log "      ${bios_nic} (${os_nic}): vlan${vlan_id} → ${vendor_name} path ${path}"

                generate_nncp_yaml "$os_nic" "$vlan_id" "$vendor" "$path" \
                    "kubernetes.io/hostname" "$ocp_node" \
                    > "$nncp_file"
            done
        done
    fi

    log ""
    log "  NNCP manifests written to: ${nncp_dir}/"
    local nncp_count
    nncp_count=$(find "$nncp_dir" -name '*.yaml' | wc -l)
    log "  Total NNCPs: ${nncp_count}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would apply: oc apply -f ${nncp_dir}/"
        return 0
    fi

    if ! command -v oc &>/dev/null; then
        log_error "  'oc' command not found. NNCPs generated but not applied."
        log "  Apply manually: oc apply -f ${nncp_dir}/"
        return 1
    fi

    log "  Applying NNCPs..."
    if oc apply -f "$nncp_dir/" 2>&1; then
        log_success "  NNCPs applied. Waiting for rollout..."
        # Give nmstate time to reconcile
        local timeout=120
        local elapsed=0
        local all_available=false
        while (( elapsed < timeout )); do
            local not_ready
            not_ready=$(oc get nncp -l "storage-lta/cloud=${cloud_name}" \
                -o jsonpath='{.items[?(@.status.conditions[?(@.type=="Available")].status!="True")].metadata.name}' 2>/dev/null || true)
            if [[ -z "$not_ready" ]]; then
                all_available=true
                break
            fi
            log_verbose "  Waiting for NNCPs: ${not_ready} (${elapsed}s/${timeout}s)"
            sleep 10
            (( elapsed += 10 ))
        done

        if [[ "$all_available" == "true" ]]; then
            log_success "  All NNCPs available"
        else
            log_warn "  Some NNCPs not yet available after ${timeout}s. Check: oc get nncp -l storage-lta/cloud=${cloud_name}"
        fi
    else
        log_error "  oc apply failed. Review the NNCP YAMLs in ${nncp_dir}/"
        return 1
    fi
}

# ---- OCP: iSCSI + multipath via oc debug ------------------------------------
setup_iscsi_initiator_ocp() {
    local node="$1"
    log "  Configuring iSCSI initiator on node ${node} via oc debug..."

    run_on_host "$node" "systemctl enable --now iscsid 2>/dev/null; \
        test -s /etc/iscsi/initiatorname.iscsi || echo \"InitiatorName=\$(iscsi-iname)\" > /etc/iscsi/initiatorname.iscsi; \
        echo OK" || {
        log_warn "  Could not configure iSCSI on ${node}"
        return 0
    }
    log_success "  iSCSI initiator ready on ${node}"
}

setup_multipath_vendor_ocp() {
    local node="$1"
    local vendor="$2"

    local vendor_pattern=""
    local config_block=""
    case "$vendor" in
        ibm)
            config_block="$MULTIPATH_IBM"
            vendor_pattern='vendor.*"IBM"'
            ;;
        pure)
            config_block="$MULTIPATH_PURE"
            vendor_pattern='vendor.*"PURE"'
            ;;
        netapp-asa|netapp-a300)
            config_block="$MULTIPATH_NETAPP"
            vendor_pattern='vendor.*"NETAPP"'
            ;;
        *)
            log_warn "  No multipath config known for vendor '${vendor}'; skipping"
            return 0
            ;;
    esac

    local check
    check=$(run_on_host "$node" "grep -q '${vendor_pattern}' /etc/multipath.conf 2>/dev/null && echo EXISTS || echo NOT_FOUND")
    if [[ "$DRY_RUN" == "true" ]]; then return 0; fi

    if [[ "$check" == "EXISTS" ]]; then
        log_verbose "  Multipath config for ${vendor} already present on ${node}"
        return 0
    fi

    log "  Adding multipath config for ${vendor} on ${node} via oc debug..."
    run_on_host "$node" "cp /etc/multipath.conf /etc/multipath.conf.bak.\$(date +%s); \
        cat >> /etc/multipath.conf <<'EOFMP'
${config_block}
EOFMP
echo ADDED" || {
        log_error "  Failed to update multipath.conf on ${node}"
        return 1
    }
    log_success "  Multipath config for ${vendor} added on ${node}"
}

# ---- Bare-metal / VMware: VLAN interfaces via SSH + nmcli --------------------
setup_vlan_interfaces_ssh() {
    local worker="$1"
    local model="$2"

    log "  Setting up VLAN sub-interfaces on ${worker} via nmcli (model: ${model})..."

    compute_vlan_layout | while read -r bios_nic vlan_id subnet_base vendor path; do
        local os_nic
        os_nic=$(resolve_os_iface "$model" "$bios_nic")
        local profile="vlan${vlan_id}"
        local vendor_name="${PLATFORM_NAMES[$vendor]:-$vendor}"

        log "    ${bios_nic} (${os_nic}): ${profile} → ${vendor_name} path ${path} (${subnet_base}.0/24, DHCP)"

        if [[ "$DRY_RUN" == "true" ]]; then continue; fi

        # Set parent MTU to 9000 if needed
        run_on_host "$worker" "
            current_mtu=\$(ip link show ${os_nic} 2>/dev/null | grep -oP 'mtu \K[0-9]+' || echo 0)
            if [ \"\$current_mtu\" -lt 9000 ] 2>/dev/null; then
                parent_profile=\$(nmcli -g NAME device show ${os_nic} 2>/dev/null || true)
                if [ -n \"\$parent_profile\" ]; then
                    nmcli connection modify \"\$parent_profile\" 802-3-ethernet.mtu 9000 2>/dev/null || true
                    nmcli connection up \"\$parent_profile\" 2>/dev/null || true
                fi
            fi
        " || true

        # Create VLAN sub-interface with DHCP
        run_on_host "$worker" "
            if nmcli -g NAME connection show 2>/dev/null | grep -qx '${profile}'; then
                nmcli connection down '${profile}' 2>/dev/null || true
                nmcli connection modify '${profile}' \
                    ipv4.method auto \
                    ipv6.method disabled \
                    ipv4.dns '' \
                    ipv4.gateway '' \
                    mtu 9000 \
                    connection.autoconnect yes
            else
                nmcli connection add \
                    type vlan \
                    con-name '${profile}' \
                    ifname '${profile}' \
                    dev '${os_nic}' \
                    id '${vlan_id}' \
                    ipv4.method auto \
                    ipv6.method disabled \
                    ipv4.dns '' \
                    ipv4.gateway '' \
                    mtu 9000 \
                    connection.autoconnect yes
            fi
            nmcli connection up '${profile}'
        " || {
            log_error "    Failed to create/activate ${profile} on ${worker}"
            continue
        }
        log_success "    ${profile} active on ${worker}"
    done
}

# ---- Bare-metal: iSCSI + multipath via SSH -----------------------------------
setup_iscsi_initiator_ssh() {
    local worker="$1"
    log "  Configuring iSCSI initiator on ${worker} via SSH..."

    local check
    check=$(run_on_host "$worker" "systemctl is-active iscsid 2>/dev/null || echo inactive")
    if [[ "$DRY_RUN" == "true" ]]; then return 0; fi

    if [[ "$check" != "active" ]]; then
        run_on_host "$worker" "systemctl enable --now iscsid" || log_warn "  Could not start iscsid on ${worker}"
    fi

    run_on_host "$worker" "test -s /etc/iscsi/initiatorname.iscsi || echo 'InitiatorName=\$(iscsi-iname)' | tee /etc/iscsi/initiatorname.iscsi" || true
    log_success "  iSCSI initiator ready on ${worker}"
}

setup_multipath_vendor_ssh() {
    local worker="$1"
    local vendor="$2"

    local config_block=""
    local vendor_pattern=""
    case "$vendor" in
        ibm)
            config_block="$MULTIPATH_IBM"
            vendor_pattern='vendor.*"IBM"'
            ;;
        pure)
            config_block="$MULTIPATH_PURE"
            vendor_pattern='vendor.*"PURE"'
            ;;
        netapp-asa|netapp-a300)
            config_block="$MULTIPATH_NETAPP"
            vendor_pattern='vendor.*"NETAPP"'
            ;;
        *)
            log_warn "  No multipath config known for vendor '${vendor}'; skipping"
            return 0
            ;;
    esac

    local check
    check=$(run_on_host "$worker" "grep -q '${vendor_pattern}' /etc/multipath.conf 2>/dev/null && echo EXISTS || echo NOT_FOUND")
    if [[ "$DRY_RUN" == "true" ]]; then return 0; fi

    if [[ "$check" == "EXISTS" ]]; then
        log_verbose "  Multipath config for ${vendor} already present on ${worker}"
        return 0
    fi

    log "  Adding multipath config for ${vendor} on ${worker}..."
    run_on_host "$worker" "cp /etc/multipath.conf /etc/multipath.conf.bak.\$(date +%s); \
        cat >> /etc/multipath.conf <<'EOFMP'
${config_block}
EOFMP
echo ADDED" || {
        log_error "  Failed to update multipath.conf on ${worker}"
        return 1
    }
    log_success "  Multipath config for ${vendor} added on ${worker}"
}

# ---- Main host-setup dispatcher ----------------------------------------------
do_host_setup() {
    log "=== STAGE: host-setup ==="

    if [[ -z "$STORAGE_ARRAYS" ]]; then
        log_error "STORAGE_ARRAYS not set. Cannot determine which VLANs to create."
        return 1
    fi

    log "Target type: ${TARGET_TYPE}"
    log "VLAN layout plan (alternating NIC-to-path mapping):"
    compute_vlan_layout | while read -r bios_nic vlan_id subnet_base vendor path; do
        local vendor_name="${PLATFORM_NAMES[$vendor]:-$vendor}"
        log "  ${bios_nic}: vlan${vlan_id} → ${vendor_name} path ${path} (${subnet_base}.0/24)"
    done

    local json
    json=$(quads_query_hosts) || return 1

    local -a vendors_arr
    read -r -a vendors_arr <<< "$STORAGE_ARRAYS"

    # ---- OCP path: NNCP for VLANs, oc debug for iSCSI/multipath ----
    if [[ "$TARGET_TYPE" == "ocp" ]]; then
        log ""
        log "--- OCP mode: VLAN interfaces via NNCP ---"
        setup_vlan_interfaces_ocp "$json"

        log ""
        log "--- OCP mode: iSCSI + multipath via oc debug ---"

        # Get actual OCP worker node names
        local -a ocp_worker_list=()
        if command -v oc &>/dev/null; then
            mapfile -t ocp_worker_list < <(oc get nodes -l node-role.kubernetes.io/worker --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
        fi

        if (( ${#ocp_worker_list[@]} == 0 )); then
            log_warn "  No OCP worker nodes found. Skipping iSCSI/multipath setup."
        else
            for node in "${ocp_worker_list[@]}"; do
                if [[ -n "$SINGLE_WORKER" && "$node" != *"$SINGLE_WORKER"* ]]; then
                    continue
                fi

                log ""
                log "=== Processing OCP node: ${node} ==="

                if [[ "$DRY_RUN" != "true" ]]; then
                    if ! test_host_reachable "$node"; then
                        log_error "  Cannot reach node ${node} via oc debug. Skipping."
                        continue
                    fi
                fi

                setup_iscsi_initiator_ocp "$node"

                for vendor in "${vendors_arr[@]}"; do
                    setup_multipath_vendor_ocp "$node" "$vendor"
                done

                if [[ "$DRY_RUN" != "true" ]]; then
                    log "  Restarting multipathd and iscsi services..."
                    run_on_host "$node" "systemctl restart multipathd iscsi 2>/dev/null; systemctl enable multipathd iscsid 2>/dev/null" || true
                    log_success "  Services restarted on ${node}"
                fi
            done
        fi

    # ---- Bare-metal / VMware path: SSH + nmcli ----
    else
        log ""
        log "--- Bare-metal/VMware mode: SSH + nmcli ---"
        parse_hosts "$json" | while read -r hostname model; do
            if [[ -n "$EXCLUDE_HOSTS" ]]; then
                local skip=false
                for excl in $EXCLUDE_HOSTS; do
                    [[ "$hostname" == *"$excl"* ]] && skip=true
                done
                [[ "$skip" == "true" ]] && { log "Skipping excluded host: ${hostname}"; continue; }
            fi
            if [[ -n "$SINGLE_WORKER" && "$hostname" != *"$SINGLE_WORKER"* ]]; then
                continue
            fi

            local worker
            worker=$(get_worker_id "$hostname")
            log ""
            log "=== Processing: ${hostname} (${model}) ==="

            if [[ "$DRY_RUN" != "true" ]]; then
                if ! test_host_reachable "$worker"; then
                    log_error "  Cannot SSH to ${worker}. Skipping."
                    continue
                fi
            fi

            setup_vlan_interfaces_ssh "$worker" "$model"
            setup_iscsi_initiator_ssh "$worker"

            for vendor in "${vendors_arr[@]}"; do
                setup_multipath_vendor_ssh "$worker" "$vendor"
            done

            if [[ "$DRY_RUN" != "true" ]]; then
                log "  Restarting multipathd and iscsi services..."
                run_on_host "$worker" "systemctl restart multipathd iscsi 2>/dev/null; systemctl enable multipathd iscsid 2>/dev/null" || true
                log_success "  Services restarted on ${worker}"
            fi
        done
    fi
}

# =============================================================================
# STAGE: check
# =============================================================================
do_check() {
    log "=== STAGE: check ==="

    if [[ -z "$STORAGE_ARRAYS" ]]; then
        log_error "STORAGE_ARRAYS not set. Cannot determine portal IPs to check."
        return 1
    fi

    local json
    json=$(quads_query_hosts) || return 1

    # Build list of portal IPs to check (first portal IP per path: .2)
    local -a portal_ips=()
    compute_vlan_layout | while read -r bios_nic vlan_id subnet_base vendor path; do
        echo "${subnet_base}.2"
    done | sort -u > /tmp/_portal_ips_$$
    mapfile -t portal_ips < /tmp/_portal_ips_$$
    rm -f /tmp/_portal_ips_$$

    log "Portal IPs to check: ${portal_ips[*]}"

    # For OCP, iterate over actual OCP worker node names
    # For bare-metal, iterate over QUADS hosts
    if [[ "$TARGET_TYPE" == "ocp" ]]; then
        local -a check_nodes=()
        if command -v oc &>/dev/null; then
            mapfile -t check_nodes < <(oc get nodes -l node-role.kubernetes.io/worker --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
        fi

        # Determine model for interface name resolution (use first model from QUADS)
        local check_model
        check_model=$(echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for h in data:
    m = h.get('model', 'UNKNOWN')
    if m != 'UNKNOWN':
        print(m)
        break
" 2>/dev/null) || check_model="UNKNOWN"

        for node in "${check_nodes[@]}"; do
            if [[ -n "$SINGLE_WORKER" && "$node" != *"$SINGLE_WORKER"* ]]; then
                continue
            fi
            log "  Checking OCP node: ${node}..."

            for portal_ip in "${portal_ips[@]}"; do
                local result
                result=$(run_on_host "$node" "ping -c 2 -W 3 ${portal_ip} &>/dev/null && echo PASS || echo FAIL" 2>/dev/null) || result="UNREACHABLE"

                if [[ "$DRY_RUN" == "true" ]]; then
                    log "    [DRY-RUN] Would ping ${portal_ip}"
                elif [[ "$result" == "PASS" ]]; then
                    log_success "    ${portal_ip}: reachable"
                else
                    log_warn "    ${portal_ip}: ${result} (may not be configured on storage side yet)"
                fi
            done

            if [[ "$DRY_RUN" != "true" ]]; then
                log "  VLAN interface status:"
                compute_vlan_layout | while read -r bios_nic vlan_id subnet_base vendor path; do
                    local os_nic
                    os_nic=$(resolve_os_iface "$check_model" "$bios_nic")
                    local iface_name="${os_nic}.${vlan_id}"
                    local ip
                    ip=$(run_on_host "$node" "ip -4 addr show ${iface_name} 2>/dev/null | grep -oP 'inet \K[0-9.]+'" 2>/dev/null) || ip="no-ip"
                    if [[ "$ip" != "no-ip" && -n "$ip" ]]; then
                        log_success "    ${iface_name}: ${ip}"
                    else
                        log_warn "    ${iface_name}: no IPv4 address (DHCP may not be serving this VLAN yet)"
                    fi
                done
            fi
        done
    else
        parse_hosts "$json" | while read -r hostname model; do
            if [[ -n "$EXCLUDE_HOSTS" ]]; then
                local skip=false
                for excl in $EXCLUDE_HOSTS; do
                    [[ "$hostname" == *"$excl"* ]] && skip=true
                done
                [[ "$skip" == "true" ]] && continue
            fi

            if [[ -n "$SINGLE_WORKER" && "$hostname" != *"$SINGLE_WORKER"* ]]; then
                continue
            fi

            local worker_id
            worker_id=$(get_worker_id "$hostname")
            log "  Checking ${hostname} (${worker_id})..."

            for portal_ip in "${portal_ips[@]}"; do
                local result
                result=$(run_on_host "$worker_id" "ping -c 2 -W 3 ${portal_ip} &>/dev/null && echo PASS || echo FAIL" 2>/dev/null) || result="UNREACHABLE"

                if [[ "$DRY_RUN" == "true" ]]; then
                    log "    [DRY-RUN] Would ping ${portal_ip}"
                elif [[ "$result" == "PASS" ]]; then
                    log_success "    ${portal_ip}: reachable"
                else
                    log_warn "    ${portal_ip}: ${result} (may not be configured on storage side yet)"
                fi
            done

            if [[ "$DRY_RUN" != "true" ]]; then
                log "  VLAN interface status:"
                compute_vlan_layout | while read -r bios_nic vlan_id subnet_base vendor path; do
                    local os_nic
                    os_nic=$(resolve_os_iface "$model" "$bios_nic")
                    local iface_name="vlan${vlan_id}"
                    local ip
                    ip=$(run_on_host "$worker_id" "ip -4 addr show ${iface_name} 2>/dev/null | grep -oP 'inet \K[0-9.]+'" 2>/dev/null) || ip="no-ip"
                    if [[ "$ip" != "no-ip" && -n "$ip" ]]; then
                        log_success "    ${iface_name}: ${ip}"
                    else
                        log_warn "    ${iface_name}: no IPv4 address (DHCP may not be serving this VLAN yet)"
                    fi
                done
            fi
        done
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    local stage=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -e) ENV_FILE="$2"; shift 2 ;;
            -n) DRY_RUN=true; shift ;;
            -v) VERBOSE=true; shift ;;
            -w) SINGLE_WORKER="$2"; shift 2 ;;
            -h|--help) usage ;;
            collect|verify|jira-draft|host-setup|check|all)
                stage="$1"; shift ;;
            *)
                echo "Unknown option: $1" >&2
                usage
                ;;
        esac
    done

    if [[ -z "$ENV_FILE" ]]; then
        echo "Error: -e <env-file> is required." >&2
        usage
    fi

    if [[ ! -f "$ENV_FILE" ]]; then
        echo "Error: env file not found: ${ENV_FILE}" >&2
        exit 1
    fi

    if [[ -z "$stage" ]]; then
        echo "Error: no stage specified." >&2
        usage
    fi

    # Source the env file
    # shellcheck disable=SC1090
    source "$ENV_FILE"

    # Validate required vars
    if [[ -z "$CLOUD_ID" ]]; then
        echo "Error: CLOUD_ID not set in ${ENV_FILE}" >&2
        exit 1
    fi

    CLOUD_ID=$((10#${CLOUD_ID}))
    if (( CLOUD_ID < 1 || CLOUD_ID > 99 )); then
        echo "Error: CLOUD_ID must be 1-99 (got ${CLOUD_ID})" >&2
        exit 1
    fi

    # Auto-set SSH_USER from TARGET_TYPE if not explicitly set
    if [[ -z "$SSH_USER" ]]; then
        case "$TARGET_TYPE" in
            ocp)     SSH_USER="core" ;;
            vmware)  SSH_USER="root" ;;
            *)       SSH_USER="root" ;;
        esac
    fi

    # Setup logging
    mkdir -p "$LOG_DIR" "$RESULTS_DIR" 2>/dev/null || true
    local cloud_name="cloud$(printf '%02d' "$CLOUD_ID")"
    LOG_FILE="${LOG_DIR}/${cloud_name}-$(date '+%Y%m%d_%H%M%S').log"

    log "============================================================================="
    log "  Storage LTA Setup — ${cloud_name} — $(date)"
    log "============================================================================="
    log "  Env file:       ${ENV_FILE}"
    log "  Cloud ID:       ${CLOUD_ID}"
    log "  Storage arrays: ${STORAGE_ARRAYS:-<not set>}"
    log "  Networks:       ${NETWORKS}"
    log "  Target type:    ${TARGET_TYPE}"
    log "  SSH user:       ${SSH_USER}"
    [[ "$DRY_RUN" == "true" ]] && log "  *** DRY-RUN MODE ***"
    log ""

    case "$stage" in
        collect)    do_collect ;;
        verify)     do_verify ;;
        jira-draft) do_jira_draft ;;
        host-setup) do_host_setup ;;
        check)      do_check ;;
        all)
            do_collect
            do_verify
            do_jira_draft
            log ""
            log "===================================================================="
            log "  Stages collect, verify, jira-draft complete."
            log "  Review the Jira draft at: ${RESULTS_DIR}/${cloud_name}-jira-draft.txt"
            log "  After the VLAN change is applied by ScaleLab ops, run:"
            log "    ${PROG} -e ${ENV_FILE} host-setup"
            log "    ${PROG} -e ${ENV_FILE} check"
            log "===================================================================="
            ;;
    esac

    log ""
    log "Log saved to: ${LOG_FILE}"
}

main "$@"
