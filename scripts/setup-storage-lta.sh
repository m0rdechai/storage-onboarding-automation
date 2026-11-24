#!/usr/bin/env bash
#
# setup-storage-lta.sh — Storage LTA onboarding utility
#
# Automates the end-to-end process of connecting a ScaleLab cloud allocation
# to the Storage LTA (cloud99).  Stages:
#   collect    — query QUADS API, extract host/interface/MAC data
#   verify     — check that target interfaces aren't already in use
#   jira-draft — generate a VLAN-change Jira request (SCALELAB project)
#   host-setup — VLAN sub-interfaces, iSCSI, and multipath (MachineConfig on OCP)
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

# ESXi host-setup (TARGET_TYPE=vmware). The host list is
# `govc find -type h` of VMWARE_HOST_FOLDER. GOVC_* stays in the shell.
# VMWARE_HOST_DOMAIN and VMWARE_HOST_ALIAS are not used to select hosts.
VMWARE_HOST_FOLDER="/Perf/host/MTV"
VMWARE_HOST_DOMAIN=".rdu2.scalelab.redhat.com"
VMWARE_HOST_ALIAS=""
VMWARE_HOST_MAP=""
VMWARE_ANCHOR_VSWITCH="vSwitch2"
VMWARE_VM_PORTGROUP="VM Network"
VMWARE_ISCSI_ADAPTER="vmhba64"
# storage-setup iSCSI govc bounds. host-setup does not use these.
VMWARE_ADAPTER_GET_TIMEOUT=60
VMWARE_SENDTARGET_LIST_TIMEOUT=60
VMWARE_SENDTARGET_ADD_TIMEOUT=120
VMWARE_SESSION_LIST_TIMEOUT=60
VMWARE_REDISCOVER_TIMEOUT=900
VMWARE_ADAPTER_POLL_INTERVAL=30
VMWARE_ADAPTER_POLL_WINDOW=300
VMWARE_JOB_PARALLEL=4

# Volume / LUN configuration for storage-setup stage
LUN_SIZE="1TB"
LUN_COUNT=1

# Seconds to wait for mcp/worker after applying the multipath MachineConfig.
MCP_WAIT_TIMEOUT=3600

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
    [netapp-aff]=7
)

declare -A PLATFORM_NAMES
PLATFORM_NAMES=(
    [ibm]="IBM FlashSystem 7300"
    [netapp-asa]="NetApp ASA A70"
    [pure]="Pure FlashArray X70R5"
    [netapp-aff]="NetApp AFF A300"
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
# Multipath configuration
# One file for every vendor (files/multipath.conf): IBM and Pure device
# blocks, NetApp on the built-in ONTAP profile. OpenShift installs it with a
# worker MachineConfig. Bare metal writes the same file over SSH.
# VMware does not: ESXi has no /etc/multipath.conf.
# =============================================================================
MULTIPATH_CONF_FILE="${REPO_DIR}/files/multipath.conf"

# =============================================================================
# Logging
# =============================================================================
log()         { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; if [[ -n "${LOG_FILE:-}" ]]; then echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; fi; }
log_verbose() { if [[ "$VERBOSE" == "true" ]]; then log "[VERBOSE] $*"; fi; }
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
  collect        Query QUADS API, output MAC CSV to results/
  verify         Check interfaces aren't already in cloud99 / active use
  jira-draft     Generate Jira VLAN change request text
  host-setup     Create VLAN sub-interfaces + iSCSI; multipath via MachineConfig on OCP
  storage-setup  Configure storage arrays (portals, volumes, hosts, mappings)
  check          Verify connectivity to storage portal IPs
  all            Run all stages in order

Options:
  -e FILE      Environment file (required)
  -n           Dry-run mode — show what would be done, change nothing
  -v           Verbose output
  -w HOST      Single-worker mode — run only on this host
               (host-setup MachineConfig still applies to the whole worker pool)
  -h           Show this help

The env file must set at minimum:
  CLOUD_ID=6
  STORAGE_ARRAYS="ibm pure"

See env/example.env for a full example.
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
#   - multipath.conf  → MachineConfig on the worker MachineConfigPool
#   - Host commands   → oc debug node/<name> -- chroot /host <cmd>
#
# Bare-metal hosts use direct SSH + nmcli.
# VMware hosts use govc host.esxcli. Do not SSH to ESXi.
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
        oc debug "node/${host}" --quiet -- chroot /host bash -c "$cmd" 2>&1
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
            echo "quads --mod-switch-conf --host ${hostname} --nic${nic_num} ${CLOUD99_OUTER_VLAN} --change # reassign vlan membership from ${cloud_name} for ${mac} to cloud99"
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
# Three paths depending on TARGET_TYPE:
#   ocp    → NNCP YAMLs for VLAN interfaces, applied via oc apply;
#            /etc/multipath.conf via one worker MachineConfig, then wait for
#            mcp/worker; iSCSI initiator via oc debug after the pool rolls
#   vmware → hosts from `govc find -type h` of VMWARE_HOST_FOLDER, then
#            host.esxcli portgroups, vmkernel DHCP, iSCSI portal bind.
#            ESXi has no /etc/multipath.conf and is not reached over SSH.
#   bare   → SSH + nmcli for VLANs, SSH for iSCSI and multipath.conf
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

    # Per-node NNCPs need unique names; include hostname when targeting a specific node
    local nncp_name="${cloud_name}-${profile}-storage-lta"
    if [[ "$node_selector_key" == "kubernetes.io/hostname" ]]; then
        nncp_name="${cloud_name}-${node_selector_value}-${profile}-storage-lta"
    fi

    cat <<EOF
---
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ${nncp_name}
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

# ---- OCP: iSCSI initiator via oc debug ---------------------------------------
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

# ---- OCP: multipath.conf via a worker MachineConfig --------------------------
# files/multipath.conf is one file with a single devices section. The worker
# MachineConfigPool is what makes that file survive a reboot. Label values
# are limited to 63 characters, so the sha256 label keeps the first 63 hex
# digits of the file hash.
generate_multipath_mc_yaml() {
    local cloud_name="$1"
    local sha_label="$2"
    local b64="$3"
    local mc_name="99-${cloud_name}-storage-lta-multipath"

    cat <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: ${mc_name}
  labels:
    machineconfiguration.openshift.io/role: worker
    storage-lta/cloud: "${cloud_name}"
    storage-lta/multipath-sha256: "${sha_label}"
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - path: /etc/multipath.conf
          mode: 0644
          overwrite: true
          filesystem: root
          contents:
            source: data:text/plain;charset=utf-8;base64,${b64}
    systemd:
      units:
        - name: multipathd.service
          enabled: true
EOF
}

# Poll mcp/worker until the rendered config includes this MachineConfig and
# the pool is Updated. A label-only change does not move the rendered name,
# so an already-current pool returns on the first poll.
wait_for_worker_mcp() {
    local mc_name="$1"
    local pool="$2"
    local timeout="${MCP_WAIT_TIMEOUT:-3600}"
    local interval=15
    local elapsed=0

    if [[ ! "$timeout" =~ ^[0-9]+$ ]]; then
        log_error "  MCP_WAIT_TIMEOUT must be a number of seconds (got '${timeout}')"
        return 1
    fi

    if ! oc get "mcp/${pool}" >/dev/null 2>&1; then
        log_error "  MachineConfigPool ${pool} not found"
        return 1
    fi

    log "  Waiting up to ${timeout}s for mcp/${pool} to roll out ${mc_name}..."

    while (( elapsed < timeout )); do
        local line
        line=$(oc get "mcp/${pool}" -o jsonpath='{.spec.configuration.name}{"|"}{.status.configuration.name}{"|"}{.status.conditions[?(@.type=="Updated")].status}{"|"}{.status.conditions[?(@.type=="Updating")].status}{"|"}{.status.conditions[?(@.type=="Degraded")].status}{"|"}{.status.updatedMachineCount}{"|"}{.status.machineCount}{"|"}{.spec.configuration.source[*].name}' 2>/dev/null || true)

        local spec_name status_name updated updating degraded updated_count machine_count sources
        IFS='|' read -r spec_name status_name updated updating degraded updated_count machine_count sources <<< "$line"

        local has_mc=false
        if [[ " ${sources} " == *" ${mc_name} "* ]]; then
            has_mc=true
        fi

        log "  mcp/${pool}: Updated=${updated:-unknown} Updating=${updating:-unknown} Degraded=${degraded:-unknown} (${updated_count:-?}/${machine_count:-?})"

        if [[ "$has_mc" == "true" && "$degraded" == "True" ]]; then
            log_error "  mcp/${pool} is Degraded while rolling out ${mc_name}. Check: oc describe mcp ${pool}"
            return 1
        fi

        if [[ "$has_mc" == "true" && -n "$spec_name" && "$spec_name" == "$status_name" \
            && "$updated" == "True" && "$updating" != "True" && "$degraded" != "True" ]]; then
            log_success "  mcp/${pool} is updated (${updated_count}/${machine_count})"
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_error "  mcp/${pool} did not reach Updated=True within ${timeout}s. Check: oc get mcp ${pool}"
    return 1
}

setup_multipath_ocp() {
    local cloud_name="cloud$(printf '%02d' "$CLOUD_ID")"
    local mc_name="99-${cloud_name}-storage-lta-multipath"
    local pool="worker"
    local mc_dir="${RESULTS_DIR}/${cloud_name}-machineconfig"
    local mc_file="${mc_dir}/${mc_name}.yaml"
    local conf="${MULTIPATH_CONF_FILE}"

    if [[ ! -f "$conf" ]]; then
        log_error "  Multipath config not found: ${conf}"
        return 1
    fi

    local sha sha_label b64
    sha=$(sha256sum "$conf" | awk '{print $1}')
    # Label values max out at 63 characters; sha256 hex is 64.
    sha_label="${sha:0:63}"
    b64=$(base64 -w0 "$conf")

    mkdir -p "$mc_dir"
    generate_multipath_mc_yaml "$cloud_name" "$sha_label" "$b64" > "$mc_file"
    log "  MachineConfig written to: ${mc_file}"

    if [[ -n "$SINGLE_WORKER" ]]; then
        log_warn "  -w limits per-node iSCSI only. MachineConfig ${mc_name} applies to every node in the worker pool."
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would apply: oc apply -f ${mc_file}"
        log "[DRY-RUN] A new or changed MachineConfig reboots every worker in mcp/${pool}."
        return 0
    fi

    if ! command -v oc &>/dev/null; then
        log_error "  'oc' command not found. MachineConfig generated but not applied."
        log "  Apply manually: oc apply -f ${mc_file}"
        return 1
    fi

    local live_sha updated updating degraded
    live_sha=$(oc get "mc/${mc_name}" -o "jsonpath={.metadata.labels['storage-lta/multipath-sha256']}" 2>/dev/null || true)
    updated=$(oc get "mcp/${pool}" -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' 2>/dev/null || true)
    updating=$(oc get "mcp/${pool}" -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null || true)
    degraded=$(oc get "mcp/${pool}" -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || true)

    if [[ "$live_sha" == "$sha_label" && "$updated" == "True" && "$updating" != "True" && "$degraded" != "True" ]]; then
        log_success "  MachineConfig ${mc_name} already applied and mcp/${pool} is updated"
        return 0
    fi

    log "  Applying MachineConfig ${mc_name} to mcp/${pool}..."
    log "  A new or changed MachineConfig reboots every worker in the pool."
    if ! oc apply -f "$mc_file" 2>&1; then
        log_error "  oc apply failed. Review ${mc_file}"
        return 1
    fi

    wait_for_worker_mcp "$mc_name" "$pool"
}

# ---- Bare-metal: VLAN interfaces via SSH + nmcli -----------------------------
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

setup_multipath_ssh() {
    local worker="$1"
    local conf="${MULTIPATH_CONF_FILE}"

    if [[ ! -f "$conf" ]]; then
        log_error "  Multipath config not found: ${conf}"
        return 1
    fi

    log "  Installing multipath.conf on ${worker}..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would install ${conf} as /etc/multipath.conf on ${worker} and restart multipathd if it differs"
        return 0
    fi

    local b64 remote result
    b64=$(base64 -w0 "$conf")
    remote="set -euo pipefail
echo '${b64}' | base64 -d > /tmp/multipath.conf.storage-lta
if [ -f /etc/multipath.conf ] && cmp -s /tmp/multipath.conf.storage-lta /etc/multipath.conf; then
    rm -f /tmp/multipath.conf.storage-lta
    echo SAME
    exit 0
fi
if [ -f /etc/multipath.conf ]; then
    cp -a /etc/multipath.conf /etc/multipath.conf.bak.\$(date +%s)
fi
cp /tmp/multipath.conf.storage-lta /etc/multipath.conf
chmod 644 /etc/multipath.conf
if command -v restorecon >/dev/null 2>&1; then
    restorecon /etc/multipath.conf || true
fi
rm -f /tmp/multipath.conf.storage-lta
systemctl enable --now multipathd
systemctl restart multipathd
echo UPDATED"
    result=$(run_on_host "$worker" "$remote") || {
        log_error "  Failed to install multipath.conf on ${worker}"
        return 1
    }

    if [[ "$result" == *UPDATED* ]]; then
        log_success "  multipath.conf installed and multipathd restarted on ${worker}"
    elif [[ "$result" == *SAME* ]]; then
        log_verbose "  multipath.conf already matches on ${worker}"
    else
        log_error "  Unexpected result installing multipath.conf on ${worker}: ${result}"
        return 1
    fi
}

# ---- VMware: govc host.esxcli ------------------------------------------------
# On this esxcli, -u means --use-vswitch. Pin with -active-uplinks and an
# empty -standby-uplinks. Do not pass -u.

vmware_redact() { sed -E 's#://[^[:space:]/@]*@#://#g'; }

vmware_preflight() {
    if ! command -v govc >/dev/null 2>&1; then
        log_error "govc not found on PATH"
        return 1
    fi
    local about
    if ! about=$(govc about 2>&1); then
        log_error "govc about failed: $(printf '%s\n' "$about" | vmware_redact)"
        return 1
    fi
    if [[ -z "$about" ]]; then
        log_error "govc about returned an empty result"
        return 1
    fi
    local full
    full=$(printf '%s\n' "$about" | awk -F: '/^FullName:/ {sub(/^[ \t]+/, "", $2); print $2; exit}')
    log "govc about ok: ${full:-reachable}"
}

# One sorted inventory path per HostSystem under VMWARE_HOST_FOLDER.
vmware_list_hosts() {
    local out paths
    if ! out=$(govc find -type h "${VMWARE_HOST_FOLDER}" 2>&1); then
        log_error "govc find failed for ${VMWARE_HOST_FOLDER}: $(printf '%s\n' "$out" | vmware_redact)"
        return 1
    fi
    paths=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*//; s/[[:space:]]*$//; /^\/.*\/[^/]/p' | sort)
    if [[ -z "$paths" ]]; then
        log_error "No ESXi hosts under ${VMWARE_HOST_FOLDER}"
        return 1
    fi
    printf '%s\n' "$paths"
}

# Selected ESXi inventory paths, one per line. Same -w and EXCLUDE_HOSTS
# filter as host-setup. An empty result returns 1.
vmware_selected_hosts() {
    local hosts
    if ! hosts=$(vmware_list_hosts); then
        return 1
    fi

    local -a selected=()
    local ipath skip excl
    while IFS= read -r ipath; do
        [[ -z "$ipath" ]] && continue
        skip=false
        if [[ -n "$EXCLUDE_HOSTS" ]]; then
            for excl in $EXCLUDE_HOSTS; do
                if [[ "$ipath" == *"$excl"* ]]; then
                    skip=true
                fi
            done
        fi
        if [[ "$skip" == "true" ]]; then
            log "Skipping excluded host: ${ipath}"
            continue
        fi
        if [[ -n "$SINGLE_WORKER" && "$ipath" != *"$SINGLE_WORKER"* ]]; then
            continue
        fi
        selected+=("$ipath")
    done <<< "$hosts"

    if (( ${#selected[@]} == 0 )); then
        if [[ -n "$SINGLE_WORKER" ]]; then
            log_error "No ESXi hosts under ${VMWARE_HOST_FOLDER} match '${SINGLE_WORKER}'"
        else
            log_error "No ESXi hosts selected under ${VMWARE_HOST_FOLDER}"
        fi
        return 1
    fi
    printf '%s\n' "${selected[@]}"
}

# First DNS label of a vCenter inventory path, for VMWARE_HOST_MAP.
vmware_short_name() {
    local base="${1##*/}"
    printf '%s\n' "${base%%.*}"
}

vmware_pg_name() {
    local vendor="$1" path="$2"
    case "${vendor}:${path}" in
        ibm:A) echo ibm ;;
        ibm:B) echo ibm2 ;;
        netapp-asa:A) echo netapp-asa ;;
        netapp-asa:B) echo netapp-asa2 ;;
        pure:A) echo pure ;;
        pure:B) echo pure2 ;;
        netapp-aff:A) echo netapp-aff ;;
        netapp-aff:B) echo netapp-aff2 ;;
        *)
            log_error "No ESXi portgroup name for vendor '${vendor}'"
            return 1
            ;;
    esac
}

vmware_esxcli() {
    local mode="$1" ipath="$2"
    shift 2
    if [[ "$mode" == "write" && "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would run: govc host.esxcli -host.ipath ${ipath} $*"
        return 0
    fi
    log_verbose "govc host.esxcli -host.ipath ${ipath} $*"
    govc host.esxcli -host.ipath "$ipath" "$@"
}

# Same as a write through vmware_esxcli, but the govc client is killed if it
# does not return within the given seconds. Exit 124 is that timeout.
vmware_esxcli_bounded() {
    local seconds="$1" ipath="$2"
    shift 2
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would run: govc host.esxcli -host.ipath ${ipath} $*"
        return 0
    fi
    log_verbose "govc host.esxcli -host.ipath ${ipath} $*"
    timeout "$seconds" govc host.esxcli -host.ipath "$ipath" "$@"
}

# A read through govc. Dry-run still runs it. Exit 124 means the client
# was killed after `seconds`.
vmware_iscsi_timeout() {
    local seconds="$1" ipath="$2"
    shift 2
    log_verbose "govc host.esxcli -host.ipath ${ipath} $*"
    timeout "$seconds" govc host.esxcli -host.ipath "$ipath" "$@"
}

# Wait for background jobs started in this shell. Sets VMW_WAIT_FAILED
# to the number of non-zero exits. Must not be called from $().
vmware_wait_pids() {
    local pid rc
    VMW_WAIT_FAILED=0
    for pid in "$@"; do
        rc=0
        wait "$pid" || rc=$?
        if [[ "$rc" -ne 0 ]]; then
            VMW_WAIT_FAILED=$((VMW_WAIT_FAILED + 1))
        fi
    done
}

# Name: value from `iscsi adapter get` that starts with iqn.
vmware_adapter_iqn() {
    local ipath="$1"
    local out status=0 name
    out=$(vmware_iscsi_timeout "$VMWARE_ADAPTER_GET_TIMEOUT" "$ipath" iscsi adapter get -A "$VMWARE_ISCSI_ADAPTER" 2>&1) || status=$?
    if [[ "$status" -eq 124 ]]; then
        log_error "  ${ipath}: iscsi adapter get did not return within ${VMWARE_ADAPTER_GET_TIMEOUT}s"
        return 1
    fi
    if [[ "$status" -ne 0 ]]; then
        log_error "  ${ipath}: iscsi adapter get failed: $(printf '%s\n' "$out" | vmware_redact)"
        return 1
    fi
    name=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*Name:[[:space:]]*//p' | tr -d '\r' | sed -n '/^iqn\./{p;q}')
    if [[ -z "$name" || "$name" != iqn.* ]]; then
        log_error "  ${ipath}: adapter ${VMWARE_ISCSI_ADAPTER} did not return an IQN"
        return 1
    fi
    printf '%s\n' "$name"
}

vmware_reset_caches() {
    declare -gA VMW_PG_VS=()
    declare -gA VMW_PG_VLAN=()
    declare -gA VMW_VMK_PG=()
    declare -gA VMW_VMK_MTU=()
    declare -gA VMW_VMK_IP=()
    declare -gA VMW_PORTAL=()
}

vmware_load_portgroups() {
    local ipath="$1" out
    if ! out=$(vmware_esxcli read "$ipath" network vswitch standard portgroup list 2>&1); then
        log_error "  portgroup list failed for ${ipath}: $(printf '%s\n' "$out" | vmware_redact)"
        return 1
    fi
    local name vs vlan
    while IFS=$'\t' read -r name vs vlan; do
        [[ -z "$name" ]] && continue
        VMW_PG_VS["$name"]="$vs"
        VMW_PG_VLAN["$name"]="$vlan"
    done < <(printf '%s\n' "$out" | python3 -c '
import sys
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line.strip() or line.startswith("Name"):
        continue
    if set(line.strip()) <= set("- "):
        continue
    parts = line.rsplit(None, 3)
    if len(parts) != 4 or not parts[3].isdigit():
        continue
    print("%s\t%s\t%s" % (parts[0], parts[1], parts[3]))
')
}

vmware_load_vmks() {
    local ipath="$1" out name pg mtu
    if ! out=$(vmware_esxcli read "$ipath" network ip interface list 2>&1); then
        log_error "  interface list failed for ${ipath}: $(printf '%s\n' "$out" | vmware_redact)"
        return 1
    fi
    VMW_VMK_PG=()
    VMW_VMK_MTU=()
    while IFS=$'\t' read -r name pg mtu; do
        [[ -z "$name" ]] && continue
        VMW_VMK_PG["$name"]="$pg"
        VMW_VMK_MTU["$name"]="$mtu"
    done < <(printf '%s\n' "$out" | python3 -c '
import sys
for block in sys.stdin.read().split("\n\n"):
    name = pg = mtu = None
    for line in block.splitlines():
        if ":" not in line:
            continue
        key, val = line.split(":", 1)
        key, val = key.strip(), val.strip()
        if key == "Name":
            name = val
        elif key == "Portgroup":
            pg = val
        elif key == "MTU":
            mtu = val
    if name and name.startswith("vmk"):
        print("%s\t%s\t%s" % (name, pg or "", mtu or ""))
')
    vmware_load_ips "$ipath"
}

vmware_load_ips() {
    local ipath="$1" out name ip
    if ! out=$(vmware_esxcli read "$ipath" network ip interface ipv4 get 2>&1); then
        log_error "  ipv4 get failed for ${ipath}: $(printf '%s\n' "$out" | vmware_redact)"
        return 1
    fi
    VMW_VMK_IP=()
    while read -r name ip _; do
        [[ "$name" == vmk* ]] || continue
        VMW_VMK_IP["$name"]="$ip"
    done <<< "$out"
}

vmware_load_portals() {
    local ipath="$1" out name status
    if ! out=$(vmware_esxcli read "$ipath" iscsi networkportal list 2>&1); then
        log_error "  iscsi networkportal list failed: $(printf '%s\n' "$out" | vmware_redact)"
        return 1
    fi
    VMW_PORTAL=()
    while IFS=$'\t' read -r name status; do
        [[ -z "$name" ]] && continue
        VMW_PORTAL["$name"]="$status"
    done < <(printf '%s\n' "$out" | python3 -c '
import sys
for block in sys.stdin.read().split("\n\n"):
    vmknic = status = None
    for line in block.splitlines():
        if ":" not in line:
            continue
        key, val = line.split(":", 1)
        key, val = key.strip(), val.strip()
        if key == "Vmknic":
            vmknic = val
        elif key == "CompliantStatus":
            status = val
    if vmknic:
        print("%s\t%s" % (vmknic, status or ""))
')
}

vmware_vswitch_uplinks() {
    local ipath="$1" want="$2" out
    if ! out=$(vmware_esxcli read "$ipath" network vswitch standard list 2>&1); then
        log_error "  vswitch list failed for ${ipath}: $(printf '%s\n' "$out" | vmware_redact)"
        return 1
    fi
    local found
    found=$(printf '%s\n' "$out" | awk -v want="$want" '
        /^Name:/ { name=$2 }
        /^Uplinks:/ && name==want {
            sub(/^Uplinks:[[:space:]]*/, "")
            print
            hit=1
        }
        END { exit hit ? 0 : 1 }
    ') || {
        log_error "  vSwitch ${want} not found on ${ipath}"
        return 1
    }
    printf '%s\n' "$found"
}

# Echo "vswitch uplinkA uplinkB". $3 is a VMWARE_HOST_MAP value, or empty.
vmware_parse_anchor() {
    local anchor="$1" csv="$2" mapval="$3"
    local -a ups=()
    local part f1 f2 f3
    if [[ -z "$mapval" ]]; then
        IFS=',' read -r -a ups <<< "$csv"
        local clean=()
        for part in "${ups[@]}"; do
            part="${part#"${part%%[![:space:]]*}"}"
            part="${part%"${part##*[![:space:]]}"}"
            [[ -n "$part" ]] && clean+=("$part")
        done
        if [[ ${#clean[@]} -ne 2 ]]; then
            log_error "  ${anchor} has ${#clean[@]} uplinks (${csv}); set VMWARE_HOST_MAP"
            return 1
        fi
        echo "${anchor} ${clean[0]} ${clean[1]}"
        return 0
    fi
    IFS=':' read -r f1 f2 f3 <<< "$mapval"
    if [[ -n "$f3" ]]; then
        echo "${f1} ${f2} ${f3}"
        return 0
    fi
    if [[ "$f1" == vmnic* && "$f2" == vmnic* ]]; then
        echo "${anchor} ${f1} ${f2}"
        return 0
    fi
    log_error "  VMWARE_HOST_MAP value '${mapval}' must be uplinkA:uplinkB or vSwitch:uplinkA:uplinkB"
    return 1
}

vmware_uplink_in_csv() {
    local csv="$1" want="$2" part
    local -a ups=()
    IFS=',' read -r -a ups <<< "$csv"
    for part in "${ups[@]}"; do
        part="${part#"${part%%[![:space:]]*}"}"
        part="${part%"${part##*[![:space:]]}"}"
        [[ "$part" == "$want" ]] && return 0
    done
    return 1
}

vmware_one_active_uplink() {
    local ipath="$1" pg="$2" out active
    if ! out=$(vmware_esxcli read "$ipath" network vswitch standard portgroup policy failover get -p "$pg" 2>&1); then
        log_error "  failover get failed for ${pg}: $(printf '%s\n' "$out" | vmware_redact)"
        return 1
    fi
    active=$(printf '%s\n' "$out" | awk -F: '/^ActiveAdapters:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
    local -a parts=()
    local n=0 one="" part
    IFS=', ' read -r -a parts <<< "$active"
    for part in "${parts[@]}"; do
        [[ -z "$part" ]] && continue
        n=$((n + 1))
        one="$part"
    done
    if [[ "$n" -ne 1 ]]; then
        return 2
    fi
    printf '%s\n' "$one"
    return 0
}

vmware_map_value() {
    local short="$1" pair key
    for pair in ${VMWARE_HOST_MAP}; do
        key="${pair%%=*}"
        if [[ "$key" == "$short" ]]; then
            echo "${pair#*=}"
            return 0
        fi
    done
    return 1
}

vmware_resolve_placement() {
    local ipath="$1" short="$2"
    local vm_vs="${VMW_PG_VS[$VMWARE_VM_PORTGROUP]:-}"
    local ibm_vs="${VMW_PG_VS[ibm]:-}"
    local ibm2_vs="${VMW_PG_VS[ibm2]:-}"

    if [[ -n "$ibm_vs" && -n "$ibm2_vs" ]]; then
        local up_a="" up_b="" rc_a=0 rc_b=0
        up_a=$(vmware_one_active_uplink "$ipath" ibm) || rc_a=$?
        up_b=$(vmware_one_active_uplink "$ipath" ibm2) || rc_b=$?
        if [[ "$rc_a" -eq 1 || "$rc_b" -eq 1 ]]; then
            return 1
        fi
        if [[ "$rc_a" -ne 0 || "$rc_b" -ne 0 ]]; then
            log_error "  ibm/ibm2 do not each have one active uplink; not using ${VMWARE_ANCHOR_VSWITCH}"
            return 1
        fi
        if [[ "$ibm_vs" == "$vm_vs" || "$ibm2_vs" == "$vm_vs" ]]; then
            log_error "  rejected vSwitch ${vm_vs}: it owns ${VMWARE_VM_PORTGROUP}"
            return 1
        fi
        VMW_SRC="portgroup"
        VMW_VS_A="$ibm_vs"
        VMW_UP_A="$up_a"
        VMW_VS_B="$ibm2_vs"
        VMW_UP_B="$up_b"
        return 0
    fi

    local mapval="" csv vs upa upb choice
    mapval=$(vmware_map_value "$short") || mapval=""
    if ! csv=$(vmware_vswitch_uplinks "$ipath" "$VMWARE_ANCHOR_VSWITCH"); then
        return 1
    fi
    if ! choice=$(vmware_parse_anchor "$VMWARE_ANCHOR_VSWITCH" "$csv" "$mapval"); then
        return 1
    fi
    read -r vs upa upb <<< "$choice"
    if [[ "$vs" != "$VMWARE_ANCHOR_VSWITCH" ]]; then
        if ! csv=$(vmware_vswitch_uplinks "$ipath" "$vs"); then
            return 1
        fi
    fi
    if ! vmware_uplink_in_csv "$csv" "$upa" || ! vmware_uplink_in_csv "$csv" "$upb"; then
        log_error "  uplinks ${upa} and ${upb} are not both on ${vs} (${csv})"
        return 1
    fi
    if [[ -n "$vm_vs" && "$vs" == "$vm_vs" ]]; then
        log_error "  rejected vSwitch ${vm_vs}: it owns ${VMWARE_VM_PORTGROUP}"
        return 1
    fi
    VMW_SRC="predefined"
    VMW_VS_A="$vs"
    VMW_UP_A="$upa"
    VMW_VS_B="$vs"
    VMW_UP_B="$upb"
}

vmware_change_allowed() {
    local ipath="$1" ip="$2" out
    if [[ -z "$ip" || "$ip" == "0.0.0.0" ]]; then
        return 0
    fi
    if ! out=$(vmware_esxcli read "$ipath" iscsi session connection list 2>&1); then
        log_error "  cannot read iSCSI sessions for ${ip}; not changing the vmkernel"
        return 1
    fi
    if printf '%s\n' "$out" | awk -v ip="$ip" 'BEGIN{RS=""; found=0}
        {
            local=""; state=""
            n=split($0, lines, "\n")
            for (i=1; i<=n; i++) {
                if (lines[i] ~ /^LocalAddress:/) { split(lines[i], a, ":"); local=a[2]; gsub(/ /,"",local) }
                if (lines[i] ~ /^State:/) { split(lines[i], a, ":"); state=a[2]; gsub(/ /,"",state) }
            }
            if (local==ip && state=="logged_in") found=1
        }
        END{exit found?0:1}'; then
        log_error "  ${ip} has logged_in sessions; not changing VLAN or DHCP"
        return 1
    fi
    return 0
}

vmware_ip_in_subnet() {
    local ip="$1" base="$2"
    [[ "$ip" == "${base}".* && "$ip" != "${base}.0" && "$ip" != "${base}.255" && "$ip" != "0.0.0.0" ]]
}

vmware_vmk_for_pg() {
    local pg="$1" name
    for name in "${!VMW_VMK_PG[@]}"; do
        if [[ "${VMW_VMK_PG[$name]}" == "$pg" ]]; then
            echo "$name"
            return 0
        fi
    done
    return 1
}

vmware_alloc_vmk() {
    local i name
    for i in $(seq 5 32); do
        name="vmk${i}"
        [[ -n "${VMW_VMK_PG[$name]:-}" ]] && continue
        [[ -n "${VMW_PORTAL[$name]:-}" ]] && continue
        echo "$name"
        return 0
    done
    log_error "  no free vmkernel at or above vmk5"
    return 1
}

vmware_strip_tags() {
    local ipath="$1" vmk="$2" out tag
    if ! out=$(vmware_esxcli read "$ipath" network ip interface tag get -i "$vmk" 2>&1); then
        log_error "  tag get failed for ${vmk}"
        return 1
    fi
    for tag in Management VMotion vSphereProvisioning; do
        if printf '%s\n' "$out" | grep -qw "$tag"; then
            vmware_esxcli write "$ipath" network ip interface tag remove -i "$vmk" -t "$tag" || return 1
        fi
    done
}

vmware_wait_dhcp() {
    local ipath="$1" vmk="$2" base="$3" i ip
    for i in $(seq 1 12); do
        vmware_load_ips "$ipath" || return 1
        ip="${VMW_VMK_IP[$vmk]:-}"
        if vmware_ip_in_subnet "$ip" "$base"; then
            echo "$ip"
            return 0
        fi
        sleep 5
    done
    log_error "  ${vmk} did not get a DHCP address in ${base}.0/24"
    return 1
}

vmware_bind_portal() {
    local ipath="$1" vmk="$2"
    if [[ -z "${VMW_PORTAL[$vmk]:-}" ]]; then
        vmware_esxcli write "$ipath" iscsi networkportal add -A "$VMWARE_ISCSI_ADAPTER" -n "$vmk" || return 1
        if [[ "$DRY_RUN" == "true" ]]; then
            return 0
        fi
        vmware_load_portals "$ipath" || return 1
    fi
    if [[ "${VMW_PORTAL[$vmk]:-}" != "compliant" ]]; then
        log_error "  ${vmk} iSCSI portal is '${VMW_PORTAL[$vmk]:-missing}', expected compliant"
        return 1
    fi
}

vmware_pin_matches() {
    local ipath="$1" pg="$2" uplink="$3" out active standby
    if ! out=$(vmware_esxcli read "$ipath" network vswitch standard portgroup policy failover get -p "$pg" 2>&1); then
        log_error "  failover get failed for ${pg}: $(printf '%s\n' "$out" | vmware_redact)"
        return 2
    fi
    active=$(printf '%s\n' "$out" | awk -F: '/^ActiveAdapters:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
    standby=$(printf '%s\n' "$out" | awk -F: '/^StandbyAdapters:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
    if [[ "$active" == "$uplink" && -z "$standby" ]]; then
        return 0
    fi
    return 1
}

vmware_ensure_path() {
    local ipath="$1" vendor="$2" path="$3" vswitch="$4" uplink="$5"
    local pg digit d vlan base vmk ip mtu
    pg=$(vmware_pg_name "$vendor" "$path") || return 1
    digit=$(get_platform_digit_a "$vendor") || return 1
    d="$digit"
    [[ "$path" == "B" ]] && d=$((digit + 1))
    vlan=$(calc_vlan "$d")
    base=$(calc_subnet_base "$d")

    local cur_vs="${VMW_PG_VS[$pg]:-}"
    if [[ -z "$cur_vs" ]]; then
        log "  ${pg}: vlan ${vlan} ${vswitch} uplink ${uplink} dhcp ${base}.0/24 create"
        vmware_esxcli write "$ipath" network vswitch standard portgroup add -p "$pg" -v "$vswitch" || return 1
        vmware_esxcli write "$ipath" network vswitch standard portgroup set -p "$pg" -v "$vlan" || return 1
        vmware_esxcli write "$ipath" network vswitch standard portgroup policy failover set \
            -portgroup-name="$pg" -active-uplinks="$uplink" -standby-uplinks= || return 1
        VMW_PG_VS["$pg"]="$vswitch"
        VMW_PG_VLAN["$pg"]="$vlan"
    elif [[ "$cur_vs" != "$vswitch" ]]; then
        log_error "  ${pg} is on ${cur_vs}, not ${vswitch}"
        return 1
    else
        if [[ "${VMW_PG_VLAN[$pg]}" != "$vlan" ]]; then
            vmk=$(vmware_vmk_for_pg "$pg" || true)
            ip=""
            if [[ -n "$vmk" ]]; then
                ip="${VMW_VMK_IP[$vmk]:-}"
            fi
            vmware_change_allowed "$ipath" "$ip" || return 1
            log "  ${pg}: set vlan ${vlan}"
            vmware_esxcli write "$ipath" network vswitch standard portgroup set -p "$pg" -v "$vlan" || return 1
            VMW_PG_VLAN["$pg"]="$vlan"
        fi
        if vmware_pin_matches "$ipath" "$pg" "$uplink"; then
            :
        else
            local pin_rc=$?
            if [[ "$pin_rc" -ne 1 ]]; then
                return 1
            fi
            log "  ${pg}: pin active ${uplink}"
            vmware_esxcli write "$ipath" network vswitch standard portgroup policy failover set \
                -portgroup-name="$pg" -active-uplinks="$uplink" -standby-uplinks= || return 1
        fi
    fi

    if ! vmk=$(vmware_vmk_for_pg "$pg"); then
        vmk=$(vmware_alloc_vmk) || return 1
        log "  ${pg}: add ${vmk} mtu 9000 dhcp ${base}.0/24"
        vmware_esxcli write "$ipath" network ip interface add -i "$vmk" -p "$pg" || return 1
        vmware_esxcli write "$ipath" network ip interface set -i "$vmk" -m 9000 || return 1
        VMW_VMK_PG["$vmk"]="$pg"
        VMW_VMK_MTU["$vmk"]="9000"
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY-RUN] Would set DHCP on ${vmk}, bind it to ${VMWARE_ISCSI_ADAPTER}, and require ${base}.0/24"
            return 0
        fi
        vmware_strip_tags "$ipath" "$vmk" || return 1
        vmware_esxcli write "$ipath" network ip interface ipv4 set -i "$vmk" -t dhcp || return 1
        ip=$(vmware_wait_dhcp "$ipath" "$vmk" "$base") || return 1
        VMW_VMK_IP["$vmk"]="$ip"
        log "  ${pg}: ${vmk} ${ip}"
        vmware_bind_portal "$ipath" "$vmk" || return 1
        return 0
    fi

    mtu="${VMW_VMK_MTU[$vmk]:-}"
    if [[ "$mtu" != "9000" ]]; then
        vmware_esxcli write "$ipath" network ip interface set -i "$vmk" -m 9000 || return 1
        VMW_VMK_MTU["$vmk"]="9000"
    fi
    vmware_strip_tags "$ipath" "$vmk" || return 1
    ip="${VMW_VMK_IP[$vmk]:-}"
    if ! vmware_ip_in_subnet "$ip" "$base"; then
        vmware_change_allowed "$ipath" "$ip" || return 1
        log "  ${pg}: ${vmk} DHCP for ${base}.0/24"
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY-RUN] Would set DHCP on ${vmk} and require ${base}.0/24"
        else
            vmware_esxcli write "$ipath" network ip interface ipv4 set -i "$vmk" -t dhcp || return 1
            ip=$(vmware_wait_dhcp "$ipath" "$vmk" "$base") || return 1
            VMW_VMK_IP["$vmk"]="$ip"
            log "  ${pg}: ${vmk} ${ip}"
        fi
    fi
    vmware_bind_portal "$ipath" "$vmk" || return 1
    if [[ "${VMW_PG_VLAN[$pg]}" == "$vlan" ]] && vmware_ip_in_subnet "${VMW_VMK_IP[$vmk]:-}" "$base"; then
        log "  ${pg}: vlan ${vlan} ${vswitch} uplink ${uplink} ${vmk} ${VMW_VMK_IP[$vmk]} already matches"
    fi
}

vmware_default_on_vmk0() {
    local ipath="$1" out iface
    if ! out=$(vmware_esxcli read "$ipath" network ip route ipv4 list 2>&1); then
        log_error "  route list failed: $(printf '%s\n' "$out" | vmware_redact)"
        return 1
    fi
    iface=$(printf '%s\n' "$out" | awk '$1=="default" {print $4; found=1} END{exit found?0:1}') || {
        log_error "  no default route found"
        return 1
    }
    if [[ "$iface" != "vmk0" ]]; then
        log_error "  default route is on ${iface}, expected vmk0"
        return 1
    fi
    log "  default route on vmk0"
}

vmware_setup_host() {
    local ipath="$1"
    local short vendor
    short=$(vmware_short_name "$ipath")
    log ""
    log "=== Processing: ${short} (${ipath}) ==="
    vmware_reset_caches
    vmware_load_portgroups "$ipath" || return 1
    vmware_resolve_placement "$ipath" "$short" || return 1
    log "  placement source=${VMW_SRC} pathA=${VMW_VS_A}:${VMW_UP_A} pathB=${VMW_VS_B}:${VMW_UP_B}"
    vmware_load_vmks "$ipath" || return 1
    vmware_load_portals "$ipath" || return 1

    local -a vendors_arr=()
    read -r -a vendors_arr <<< "$STORAGE_ARRAYS"
    for vendor in "${vendors_arr[@]}"; do
        vmware_ensure_path "$ipath" "$vendor" A "$VMW_VS_A" "$VMW_UP_A" || return 1
        vmware_ensure_path "$ipath" "$vendor" B "$VMW_VS_B" "$VMW_UP_B" || return 1
    done
    vmware_default_on_vmk0 "$ipath" || return 1
}

do_host_setup_vmware() {
    vmware_preflight || return 1

    local -a vendors_arr=()
    read -r -a vendors_arr <<< "$STORAGE_ARRAYS"
    local vendor
    for vendor in "${vendors_arr[@]}"; do
        vmware_pg_name "$vendor" A >/dev/null || return 1
    done

    local hosts_out="" sel_status=0
    hosts_out=$(vmware_selected_hosts) || sel_status=$?
    if [[ "$sel_status" -ne 0 || -z "$hosts_out" ]]; then
        return 1
    fi
    local -a selected=()
    mapfile -t selected <<< "$hosts_out"

    log "ESXi hosts from ${VMWARE_HOST_FOLDER}: ${#selected[@]}"
    log "VLAN layout plan (ESXi portgroups, no NIC flip):"
    for vendor in "${vendors_arr[@]}"; do
        local digit d vlan sub pg path
        digit=$(get_platform_digit_a "$vendor") || return 1
        for path in A B; do
            d="$digit"
            [[ "$path" == "B" ]] && d=$((digit + 1))
            vlan=$(calc_vlan "$d")
            sub=$(calc_subnet_base "$d")
            pg=$(vmware_pg_name "$vendor" "$path") || return 1
            log "  ${pg}: vlan${vlan} DHCP ${sub}.0/24 path ${path}"
        done
    done

    local failed=0
    for ipath in "${selected[@]}"; do
        if ! vmware_setup_host "$ipath"; then
            failed=1
        fi
    done

    if [[ "$failed" -ne 0 ]]; then
        log_error "One or more ESXi hosts were skipped or failed"
        return 1
    fi
}

# ---- Main host-setup dispatcher ----------------------------------------------
do_host_setup() {
    log "=== STAGE: host-setup ==="

    if [[ -z "$STORAGE_ARRAYS" ]]; then
        log_error "STORAGE_ARRAYS not set. Cannot determine which VLANs to create."
        return 1
    fi

    log "Target type: ${TARGET_TYPE}"
    if [[ "$TARGET_TYPE" == "vmware" ]]; then
        do_host_setup_vmware || return 1
        return 0
    fi
    log "VLAN layout plan (alternating NIC-to-path mapping):"
    compute_vlan_layout | while read -r bios_nic vlan_id subnet_base vendor path; do
        local vendor_name="${PLATFORM_NAMES[$vendor]:-$vendor}"
        log "  ${bios_nic}: vlan${vlan_id} → ${vendor_name} path ${path} (${subnet_base}.0/24)"
    done

    local json
    json=$(quads_query_hosts) || return 1

    # ---- OCP path: NNCP for VLANs, MachineConfig for multipath, oc debug for iSCSI ----
    if [[ "$TARGET_TYPE" == "ocp" ]]; then
        log ""
        log "--- OCP mode: VLAN interfaces via NNCP ---"
        setup_vlan_interfaces_ocp "$json"

        log ""
        log "--- OCP mode: multipath.conf via worker MachineConfig ---"
        setup_multipath_ocp

        log ""
        log "--- OCP mode: iSCSI initiator via oc debug ---"

        # Get actual OCP worker node names. Run this after the pool rollout so
        # oc debug does not race the reboot.
        local -a ocp_worker_list=()
        if command -v oc &>/dev/null; then
            mapfile -t ocp_worker_list < <(oc get nodes -l node-role.kubernetes.io/worker --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
        fi

        if (( ${#ocp_worker_list[@]} == 0 )); then
            log_warn "  No OCP worker nodes found. Skipping iSCSI initiator setup."
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

                if [[ "$DRY_RUN" != "true" ]]; then
                    log "  Restarting iscsid on ${node}..."
                    run_on_host "$node" "systemctl restart iscsid 2>/dev/null; systemctl enable iscsid 2>/dev/null" || true
                    log_success "  iscsid restarted on ${node}"
                fi
            done
        fi

    # ---- Bare-metal path: SSH + nmcli ----
    else
        log ""
        log "--- Bare-metal mode: SSH + nmcli ---"
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
            setup_multipath_ssh "$worker"

            if [[ "$DRY_RUN" != "true" ]]; then
                log "  Restarting iscsi on ${worker}..."
                run_on_host "$worker" "systemctl restart iscsi 2>/dev/null; systemctl enable iscsid 2>/dev/null" || true
                log_success "  iscsi restarted on ${worker}"
            fi
        done
    fi
}

# =============================================================================
# BWS credential helpers (Bitwarden Secrets Manager CLI)
# =============================================================================
_BWS_CACHE=""
bws_load_cache() {
    if ! command -v bws &>/dev/null; then
        log_error "bws CLI not found. Install Bitwarden Secrets Manager CLI."
        return 1
    fi
    # Keep only storage credentials in the cache; set BWS_PROJECT_ID to
    # scope the list call to a dedicated project.
    local -a bws_list=(bws secret list -o json)
    if [[ -n "${BWS_PROJECT_ID:-}" ]]; then
        bws_list+=("${BWS_PROJECT_ID}")
    fi
    _BWS_CACHE=$("${bws_list[@]}" 2>/dev/null \
        | jq '[.[] | select(.key | startswith("STORAGE_"))]') || {
        log_error "bws secret list failed. Ensure BWS_ACCESS_TOKEN is set."
        return 1
    }
}
bws_get() {
    local key="$1"
    if [[ -z "$_BWS_CACHE" ]]; then
        bws_load_cache || return 1
    fi
    echo "$_BWS_CACHE" | jq -r --arg k "$key" '.[] | select(.key == $k) | .value'
}

storage_ssh() {
    # --read runs svcinfo even during a dry-run. Writes stay logged-only.
    local read_only=false
    if [[ "${1:-}" == "--read" ]]; then
        read_only=true
        shift
    fi
    local vendor="$1"; shift

    if [[ "$DRY_RUN" == "true" && "$read_only" != "true" ]]; then
        log "[DRY-RUN] Would SSH to ${vendor}: $*"
        return 0
    fi
    if [[ "$read_only" == "true" && "$1" != svcinfo && "$1" != svcinfo\ * ]]; then
        log_error "storage_ssh --read only runs svcinfo (refusing: $1)"
        return 1
    fi

    local host user pw
    case "$vendor" in
        ibm)
            host=$(bws_get "STORAGE_IBM_MGMT_IP")
            user=$(bws_get "STORAGE_IBM_USER")
            pw=$(bws_get "STORAGE_IBM_PW") ;;
        netapp-asa)
            host=$(bws_get "STORAGE_NETAPP_ASA_MGMT_IP")
            user=$(bws_get "STORAGE_NETAPP_ASA_USER")
            pw=$(bws_get "STORAGE_NETAPP_ASA_PW") ;;
        netapp-aff)
            host=$(bws_get "STORAGE_NETAPP_AFF_MGMT_IP")
            user=$(bws_get "STORAGE_NETAPP_AFF_USER")
            pw=$(bws_get "STORAGE_NETAPP_AFF_MGMT_PW") ;;
        pure)
            host=$(bws_get "STORAGE_PURE_MGMT_IP")
            user=$(bws_get "STORAGE_PURE_USER")
            pw=$(bws_get "STORAGE_PURE_PW") ;;
        *)
            log_error "Unknown vendor for storage_ssh: $vendor"
            return 1 ;;
    esac

    if [[ -z "$host" || -z "$user" || -z "$pw" ]]; then
        log_error "Missing credentials for ${vendor} (host=${host:-EMPTY}, user=${user:-EMPTY})"
        return 1
    fi

    log_verbose "  storage_ssh ${vendor} (${host}): $*"
    # PubkeyAuthentication=no: arrays authenticate via password only; a local
    # ssh-agent key the array doesn't know makes some arrays (IBM Storage
    # Virtualize: CMMVC7016E) abort the connection instead of falling back.
    sshpass -p "$pw" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o PubkeyAuthentication=no "${user}@${host}" "$@"
}

# Run one storage write. A non-zero status logs the message and the array
# output, then returns 1. Success does not by itself mean the object exists;
# the caller logs [OK] only after this returns 0.
storage_apply() {
    local vendor="$1"
    local message="$2"
    shift 2
    local out status=0 line
    out=$(storage_ssh "$vendor" "$@" 2>&1) || status=$?
    out=${out//$'\r'/$'\n'}
    if [[ "$status" -ne 0 ]]; then
        log_error "  ${message}"
        while IFS= read -r line; do
            [[ -n "$line" ]] && log "    ${line}"
        done <<< "$out"
        return 1
    fi
    while IFS= read -r line; do
        [[ -n "$line" ]] && log "    ${line}"
    done <<< "$out"
}

# =============================================================================
# Collect iSCSI initiator IQNs from workers
# =============================================================================
collect_worker_iqns() {
    local -a iqns=()
    local vmware_iqn_skipped=0

    if [[ "$TARGET_TYPE" == "ocp" ]]; then
        local -a ocp_workers=()
        if command -v oc &>/dev/null; then
            mapfile -t ocp_workers < <(oc get nodes -l node-role.kubernetes.io/worker --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
        fi
        for node in "${ocp_workers[@]}"; do
            if [[ -n "$SINGLE_WORKER" && "$node" != *"$SINGLE_WORKER"* ]]; then
                continue
            fi
            local iqn
            iqn=$(run_on_host "$node" "grep -oP 'InitiatorName=\K.*' /etc/iscsi/initiatorname.iscsi 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
            if [[ -n "$iqn" && "$iqn" == iqn.* ]]; then
                iqns+=("${node}:${iqn}")
                log "  ${node}: ${iqn}"
            else
                log_warn "  ${node}: no valid IQN found"
            fi
        done
    elif [[ "$TARGET_TYPE" == "vmware" ]]; then
        # This loop stays in the current shell. The QUADS arm below is a
        # pipeline, and ESXi has no /etc/iscsi/initiatorname.iscsi to SSH.
        vmware_preflight || return 1
        local hosts_out="" sel_status=0
        hosts_out=$(vmware_selected_hosts) || sel_status=$?
        if [[ "$sel_status" -ne 0 || -z "$hosts_out" ]]; then
            return 1
        fi
        local work idx=0 ipath line f
        local -a pids=()
        work=$(mktemp -d)
        while IFS= read -r ipath; do
            [[ -z "$ipath" ]] && continue
            idx=$((idx + 1))
            (
                name=$(vmware_adapter_iqn "$ipath") || exit 1
                short=$(vmware_short_name "$ipath")
                printf '%s\n' "${short}:${name}" > "${work}/$(printf '%04d' "$idx").ok"
            ) &
            pids+=("$!")
            if (( ${#pids[@]} >= VMWARE_JOB_PARALLEL )); then
                vmware_wait_pids "${pids[@]}"
                vmware_iqn_skipped=$((vmware_iqn_skipped + VMW_WAIT_FAILED))
                pids=()
            fi
        done <<< "$hosts_out"
        if (( ${#pids[@]} > 0 )); then
            vmware_wait_pids "${pids[@]}"
            vmware_iqn_skipped=$((vmware_iqn_skipped + VMW_WAIT_FAILED))
        fi
        for f in "$work"/*.ok; do
            [[ -e "$f" ]] || continue
            line=$(cat "$f")
            [[ -n "$line" ]] || continue
            iqns+=("$line")
            log "  ${line%%:*}: ${line#*:}"
        done
        rm -rf "$work"
    else
        local json
        json=$(quads_query_hosts) || return 1
        parse_hosts "$json" | while read -r hostname model; do
            if [[ -n "$EXCLUDE_HOSTS" ]]; then
                local skip=false
                for excl in $EXCLUDE_HOSTS; do
                    [[ "$hostname" == *"$excl"* ]] && skip=true
                done
                [[ "$skip" == "true" ]] && continue
            fi
            local worker
            worker=$(get_worker_id "$hostname")
            local iqn
            iqn=$(run_on_host "$worker" "grep -oP 'InitiatorName=\K.*' /etc/iscsi/initiatorname.iscsi 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
            if [[ -n "$iqn" && "$iqn" == iqn.* ]]; then
                iqns+=("${worker}:${iqn}")
                log "  ${worker}: ${iqn}"
            else
                log_warn "  ${worker}: no valid IQN found"
            fi
        done
    fi

    # Guard: printf '%s\n' with an empty array still emits one blank line,
    # which mapfile would turn into a phantom empty "worker:iqn" pair.
    if (( ${#iqns[@]} > 0 )); then
        printf '%s\n' "${iqns[@]}"
    fi
    if [[ "$TARGET_TYPE" == "vmware" && "$vmware_iqn_skipped" -gt 0 ]]; then
        if (( ${#iqns[@]} > 0 )); then
            return 2
        fi
        return 1
    fi
}

# =============================================================================
# Parse LUN_SIZE into vendor-specific format
# =============================================================================
parse_lun_size_ibm() {
    local size="$1"
    local num unit
    num=$(echo "$size" | grep -oP '^\d+')
    unit=$(echo "$size" | grep -oP '[A-Za-z]+$' | tr '[:upper:]' '[:lower:]')
    case "$unit" in
        tb) echo "${num} tb" ;;
        gb) echo "${num} gb" ;;
        *)  echo "${num} gb" ;;
    esac
}

# Meibytes for a size such as 1TB or 100.00GB. 1TB and 1.00TB are equal.
# Returns 1 when the string is not a number plus a TB, GB, or MB unit.
ibm_size_mib() {
    local raw="$1" mib
    mib=$(printf '%s\n' "$raw" | tr -d '[:space:]' | awk '
        {
            s = $0
            if (match(s, /[A-Za-z]+$/) == 0) exit 1
            unit = tolower(substr(s, RSTART, RLENGTH))
            num = substr(s, 1, RSTART - 1)
            if (num !~ /^[0-9]+(\.[0-9]+)?$/) exit 1
            factor = 0
            if (unit == "tb" || unit == "t") factor = 1024 * 1024
            else if (unit == "gb" || unit == "g") factor = 1024
            else if (unit == "mb" || unit == "m") factor = 1
            else exit 1
            printf "%.0f\n", num * factor
        }
    ') || return 1
    [[ -n "$mib" ]] || return 1
    printf '%s\n' "$mib"
}

parse_lun_size_pure() {
    local size="$1"
    local num unit
    num=$(echo "$size" | grep -oP '^\d+')
    unit=$(echo "$size" | grep -oP '[A-Za-z]+$' | tr '[:upper:]' '[:lower:]')
    case "$unit" in
        tb) echo "${num}T" ;;
        gb) echo "${num}G" ;;
        *)  echo "${num}G" ;;
    esac
}

# ESXi initiators need ostype vmware. OCP and bare stay on linux.
# The value is used only when the igroup or LUN is created.
storage_target_ostype() {
    if [[ "$TARGET_TYPE" == "vmware" ]]; then
        printf '%s\n' vmware
    else
        printf '%s\n' linux
    fi
}

# Log the ostype already stored on a NetApp object. Does not change it.
# A value that differs from storage_target_ostype is a warning.
netapp_log_ostype() {
    local vendor="$1"
    local label="$2"
    shift 2
    local out stored expected
    out=$(storage_ssh "$vendor" "$*" 2>/dev/null || true)
    stored=$(printf '%s\n' "$out" | tr -d '\r' | awk '
        $1 == "vserver" {
            col = 0
            for (i = 1; i <= NF; i++) if ($i == "ostype") col = i
            next
        }
        col && $1 !~ /^-/ && NF >= col { print $col; exit }
    ')
    stored=${stored//[[:space:]]/}
    expected=$(storage_target_ostype)
    if [[ -z "$stored" ]]; then
        if [[ "$DRY_RUN" != "true" ]]; then
            log_warn "  ${label}: could not read ostype; leaving it unchanged"
        fi
        return 0
    fi
    if [[ "$stored" != "$expected" ]]; then
        log_warn "  ${label} ostype is ${stored}; expected ${expected}; leaving it unchanged"
        return 0
    fi
    log "  ${label} ostype is ${stored}"
}

# 0 when a show row names this LIF. Header and error text do not count.
netapp_lif_named() {
    local lif="$1"
    tr -d '\r' | awk -v lif="$lif" '
        $0 ~ /^Error:/ { next }
        $1 == "vserver" || $1 ~ /^-/ { next }
        {
            for (i = 1; i <= NF; i++) if ($i == lif) found = 1
        }
        END { exit found ? 0 : 1 }
    '
}

# Create one NetApp LIF when that name is absent. An existing name is skipped.
# A create that fails because the name appeared anyway is also skipped.
netapp_ensure_lif() {
    local vendor="$1" svm="$2" lif="$3" create_cmd="$4"
    local show="" show_status=0

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would create LIF ${lif}: ${create_cmd}"
        return 0
    fi

    show=$(storage_ssh "$vendor" "network interface show -vserver ${svm} -lif ${lif} -fields lif" 2>/dev/null) || show_status=$?
    if [[ "$show_status" -eq 0 ]] && netapp_lif_named "$lif" <<< "$show"; then
        log_success "  LIF ${lif} already exists"
        return 0
    fi

    local out="" status=0
    out=$(storage_ssh "$vendor" "$create_cmd" 2>&1) || status=$?
    if [[ "$status" -eq 0 ]]; then
        log_success "  LIF ${lif} created"
        return 0
    fi

    show_status=0
    show=$(storage_ssh "$vendor" "network interface show -vserver ${svm} -lif ${lif} -fields lif" 2>/dev/null) || show_status=$?
    if [[ "$show_status" -eq 0 ]] && netapp_lif_named "$lif" <<< "$show"; then
        log_success "  LIF ${lif} already exists"
        return 0
    fi
    log_error "  Failed to create LIF ${lif}"
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && log "    ${line}"
    done <<< "$out"
    return 1
}

# =============================================================================
# STORAGE-SETUP: NetApp ASA A70
# =============================================================================
storage_setup_netapp_asa() {
    local cloud_name="$1"
    local cloud_nn="$2"
    shift 2
    local -a iqn_pairs=("$@")

    log ""
    log "--- NetApp ASA A70: storage-setup for ${cloud_name} ---"
    local os_type
    os_type=$(storage_target_ostype)

    local svm="svm_${cloud_name}"
    local ipspace="ipspace_${cloud_name}"

    # Derive VLAN IDs and subnets from compute_vlan_layout (filter to netapp-asa)
    local -a vlan_ids=() subnet_bases=() paths=()
    while read -r _nic vlan_id subnet_base _vendor path; do
        [[ "$_vendor" == "netapp-asa" ]] || continue
        vlan_ids+=("$vlan_id")
        subnet_bases+=("$subnet_base")
        paths+=("$path")
    done < <(compute_vlan_layout)

    if (( ${#vlan_ids[@]} == 0 )); then
        log_warn "  No netapp-asa entries in VLAN layout. Skipping."
        return 0
    fi

    # Nodes on the ASA
    local node1="ntap-asa-a70-01"
    local node2="ntap-asa-a70-02"
    local port_a="e1b"
    local port_b="e7b"

    # --- Sub-stage A: verify or create IPspace, broadcast domains, VLAN ports, SVM, LIFs ---
    log "  [A] Checking IPspace, broadcast domains, VLAN ports, SVM, and LIFs..."

    local vlanA="${vlan_ids[0]}"
    local vlanB="${vlan_ids[1]}"
    local subA="${subnet_bases[0]}"
    local subB="${subnet_bases[1]}"
    local bd_a="bd_${cloud_name}_a"
    local bd_b="bd_${cloud_name}_b"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would ensure: ipspace ${ipspace}, broadcast domains, VLAN ports, SVM ${svm}, 4 LIFs"
    else
        # Step 1: IPspace (checked independently)
        local ipspace_check
        ipspace_check=$(storage_ssh netapp-asa "ipspace show -ipspace ${ipspace}" 2>/dev/null | grep -c "${ipspace}" || true)
        if [[ "$ipspace_check" -gt 0 ]]; then
            log_success "  IPspace ${ipspace} already exists"
        else
            storage_apply netapp-asa "Failed to create IPspace ${ipspace}" \
                "ipspace create -ipspace ${ipspace}" || return 1
            log_success "  IPspace ${ipspace} created"
        fi

        # Step 2: Broadcast domains (checked independently — no duplicate-entry noise on re-runs)
        local bd
        for bd in "$bd_a" "$bd_b"; do
            local bd_check
            bd_check=$(storage_ssh netapp-asa "network port broadcast-domain show -broadcast-domain ${bd}" 2>/dev/null | grep -c "${bd}" || true)
            if [[ "$bd_check" -gt 0 ]]; then
                log_success "  Broadcast domain ${bd} already exists"
            else
                storage_apply netapp-asa "Failed to create broadcast domain ${bd}" \
                    "network port broadcast-domain create -broadcast-domain ${bd} -mtu 9000 -ipspace ${ipspace}" || return 1
                log_success "  Broadcast domain ${bd} created"
            fi
        done

        # Step 3: VLAN ports + broadcast-domain membership (reconciled on every run;
        # one port query drives create-if-missing, remove-from-wrong-domain, add-to-target)
        local -a add_a=() add_b=()
        local node vp cur_bd target_bd
        for node in "$node1" "$node2"; do
            for vp in "${port_a}-${vlanA}" "${port_b}-${vlanB}"; do
                if [[ "$vp" == "${port_b}-${vlanB}" ]]; then
                    target_bd="$bd_b"
                else
                    target_bd="$bd_a"
                fi
                cur_bd=$(storage_ssh netapp-asa "network port show -node ${node} -port ${vp} -fields broadcast-domain" 2>/dev/null | grep "${vp}" | awk '{print $3}' || true)
                if [[ -z "$cur_bd" ]]; then
                    # VLAN port doesn't exist yet — create it (auto-assigned to a Default-ipspace domain)
                    storage_apply netapp-asa "Failed to create VLAN port ${node}:${vp}" \
                        "network port vlan create -node ${node} -vlan-name ${vp}" || return 1
                    log_success "  VLAN port ${node}:${vp} created"
                elif [[ "$cur_bd" == "$target_bd" ]]; then
                    log_verbose "  ${node}:${vp} already in ${target_bd}"
                    continue
                elif [[ "$cur_bd" != "-" ]]; then
                    log "  Moving ${node}:${vp} from ${cur_bd} to ${target_bd}"
                    storage_apply netapp-asa "Failed to remove ${node}:${vp} from ${cur_bd}" \
                        "network port broadcast-domain remove-ports -ipspace Default -broadcast-domain ${cur_bd} -ports ${node}:${vp}" || return 1
                fi
                if [[ "$target_bd" == "$bd_a" ]]; then
                    add_a+=("${node}:${vp}")
                else
                    add_b+=("${node}:${vp}")
                fi
            done
        done

        if (( ${#add_a[@]} > 0 )); then
            storage_apply netapp-asa "Failed to add ports to ${bd_a}" \
                "network port broadcast-domain add-ports -ipspace ${ipspace} -broadcast-domain ${bd_a} -ports $(IFS=,; echo "${add_a[*]}")" || return 1
            log_success "  Ports added to ${bd_a}"
        else
            log_success "  Path-A ports already homed in ${bd_a}"
        fi
        if (( ${#add_b[@]} > 0 )); then
            storage_apply netapp-asa "Failed to add ports to ${bd_b}" \
                "network port broadcast-domain add-ports -ipspace ${ipspace} -broadcast-domain ${bd_b} -ports $(IFS=,; echo "${add_b[*]}")" || return 1
            log_success "  Ports added to ${bd_b}"
        else
            log_success "  Path-B ports already homed in ${bd_b}"
        fi

        # Step 4: SVM (checked independently)
        local svm_exists
        svm_exists=$(storage_ssh netapp-asa "vserver show -vserver ${svm} -fields vserver" 2>/dev/null | grep -c "${svm}" || true)
        if [[ "$svm_exists" -gt 0 ]]; then
            log_success "  SVM ${svm} already exists"
        else
            storage_apply netapp-asa "Failed to create SVM ${svm}" \
                "vserver create -vserver ${svm} -ipspace ${ipspace} -rootvolume ${svm}_root -rootvolume-security-style unix" || return 1
            log_success "  SVM ${svm} created"
        fi

        # (No `vserver iscsi create` step: ASA r2 enables the iSCSI service
        #  implicitly — that step is standard-ONTAP/AFF only.)

        # Step 5: LIFs (checked by count, not just displayed)
        local lif_count
        lif_count=$(storage_ssh netapp-asa "network interface show -vserver ${svm} -fields address" 2>/dev/null | grep -c "iscsi_${cloud_name}" || true)
        if [[ "$lif_count" -ge 4 ]]; then
            log_success "  All 4 LIFs already exist"
            local lif_output
            lif_output=$(storage_ssh netapp-asa "network interface show -vserver ${svm} -fields address,status-oper" 2>/dev/null) || true
            log "  LIF status:"
            echo "$lif_output" | grep -E "iscsi|${cloud_name}" | while IFS= read -r line; do
                log "    $line"
            done || true
        else
            log "  Creating LIFs (found ${lif_count}/4)..."
            netapp_ensure_lif netapp-asa "$svm" "iscsi_${cloud_name}_${node1}_a" \
                "network interface create -vserver ${svm} -lif iscsi_${cloud_name}_${node1}_a -data-protocol iscsi -home-node ${node1} -home-port ${port_a}-${vlanA} -address ${subA}.2 -netmask 255.255.255.0 -status-admin up" || return 1
            netapp_ensure_lif netapp-asa "$svm" "iscsi_${cloud_name}_${node2}_a" \
                "network interface create -vserver ${svm} -lif iscsi_${cloud_name}_${node2}_a -data-protocol iscsi -home-node ${node2} -home-port ${port_a}-${vlanA} -address ${subA}.3 -netmask 255.255.255.0 -status-admin up" || return 1
            netapp_ensure_lif netapp-asa "$svm" "iscsi_${cloud_name}_${node1}_b" \
                "network interface create -vserver ${svm} -lif iscsi_${cloud_name}_${node1}_b -data-protocol iscsi -home-node ${node1} -home-port ${port_b}-${vlanB} -address ${subB}.2 -netmask 255.255.255.0 -status-admin up" || return 1
            netapp_ensure_lif netapp-asa "$svm" "iscsi_${cloud_name}_${node2}_b" \
                "network interface create -vserver ${svm} -lif iscsi_${cloud_name}_${node2}_b -data-protocol iscsi -home-node ${node2} -home-port ${port_b}-${vlanB} -address ${subB}.3 -netmask 255.255.255.0 -status-admin up" || return 1
            log_success "  LIF check complete"
        fi
    fi

    # --- Sub-stage B: Volumes/LUNs ---
    log "  [B] Creating LUN(s)..."
    local i
    for (( i=1; i<=LUN_COUNT; i++ )); do
        local lun_name
        lun_name=$(printf "${cloud_name}_iscsi_lta_ntapasa_lun%02d" "$i")
        local lun_check
        lun_check=$(storage_ssh netapp-asa "lun show -vserver ${svm} -path ${lun_name} -fields path" 2>/dev/null | grep -c "${lun_name}" || true)
        if [[ "$lun_check" -gt 0 ]]; then
            log_success "  LUN ${lun_name} already exists"
            netapp_log_ostype netapp-asa "LUN ${lun_name}" "lun show -vserver ${svm} -path ${lun_name} -fields ostype"
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would create: lun create -vserver ${svm} -path ${lun_name} -size ${LUN_SIZE} -ostype ${os_type}"
            else
                storage_apply netapp-asa "Failed to create LUN ${lun_name}" \
                    "lun create -vserver ${svm} -path ${lun_name} -size ${LUN_SIZE} -ostype ${os_type}" || return 1
                log_success "  LUN ${lun_name} created (${LUN_SIZE})"
            fi
        fi
    done

    # --- Sub-stage C: igroup ---
    log "  [C] Creating igroup..."
    local ig_name="${cloud_name}_iscsi_ig"
    local ig_check
    ig_check=$(storage_ssh netapp-asa "lun igroup show -vserver ${svm} -igroup ${ig_name}" 2>/dev/null | grep -c "${ig_name}" || true)

    local iqn_list=""
    for pair in "${iqn_pairs[@]}"; do
        local iqn="${pair#*:}"
        [[ -n "$iqn_list" ]] && iqn_list+=","
        iqn_list+="$iqn"
    done

    if [[ "$ig_check" -gt 0 ]]; then
        log_success "  igroup ${ig_name} already exists"
        netapp_log_ostype netapp-asa "igroup ${ig_name}" "lun igroup show -vserver ${svm} -igroup ${ig_name} -fields ostype"
        # Add any missing initiators
        for pair in "${iqn_pairs[@]}"; do
            local worker_name="${pair%%:*}"
            local iqn="${pair#*:}"
            local already
            already=$(storage_ssh netapp-asa "lun igroup show -vserver ${svm} -igroup ${ig_name} -fields initiator" 2>/dev/null | grep -c "$iqn" || true)
            if [[ "$already" -eq 0 ]]; then
                if [[ "$DRY_RUN" != "true" ]]; then
                    storage_apply netapp-asa "Failed to add initiator ${iqn} to ${ig_name}" \
                        "lun igroup add -vserver ${svm} -igroup ${ig_name} -initiator ${iqn}" || return 1
                    log "  Added initiator ${iqn} (${worker_name}) to ${ig_name}"
                else
                    log "[DRY-RUN] Would add initiator ${iqn} to ${ig_name}"
                fi
            fi
        done
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY-RUN] Would create igroup ${ig_name} -ostype ${os_type} with initiators: ${iqn_list}"
        elif [[ -n "$iqn_list" ]]; then
            storage_apply netapp-asa "Failed to create igroup ${ig_name}" \
                "lun igroup create -vserver ${svm} -igroup ${ig_name} -protocol iscsi -ostype ${os_type} -initiator ${iqn_list}" || return 1
            log_success "  igroup ${ig_name} created with ${#iqn_pairs[@]} initiators"
        else
            log_warn "  No IQNs collected — skipping igroup creation"
        fi
    fi

    # --- Sub-stage D: LUN mapping ---
    log "  [D] Mapping LUN(s) to igroup..."
    for (( i=1; i<=LUN_COUNT; i++ )); do
        local lun_name
        lun_name=$(printf "${cloud_name}_iscsi_lta_ntapasa_lun%02d" "$i")
        local lun_id=$(( i - 1 ))
        local map_check
        map_check=$(storage_ssh netapp-asa "lun mapping show -vserver ${svm} -path ${lun_name} -fields igroup" 2>/dev/null | grep -c "${ig_name}" || true)
        if [[ "$map_check" -gt 0 ]]; then
            log_success "  LUN ${lun_name} already mapped to ${ig_name}"
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would map: lun mapping create -vserver ${svm} -path ${lun_name} -igroup ${ig_name} -lun-id ${lun_id}"
            else
                storage_apply netapp-asa "Failed to map LUN ${lun_name}" \
                    "lun mapping create -vserver ${svm} -path ${lun_name} -igroup ${ig_name} -lun-id ${lun_id}" || return 1
                log_success "  LUN ${lun_name} mapped to ${ig_name} (lun-id ${lun_id})"
            fi
        fi
    done

    # Verify final state
    log "  Verifying final state..."
    local verify_out
    verify_out=$(storage_ssh netapp-asa "lun show -vserver ${svm}" 2>/dev/null) || true
    echo "$verify_out" | grep -E "${cloud_name}" | while IFS= read -r line; do
        log "    $line"
    done || true
    verify_out=$(storage_ssh netapp-asa "lun mapping show -vserver ${svm}" 2>/dev/null) || true
    echo "$verify_out" | grep -E "${cloud_name}" | while IFS= read -r line; do
        log "    $line"
    done || true

    log_success "  NetApp ASA storage-setup complete for ${cloud_name}"
}

# Log each line of a Pure CLI response under the current stage.
pure_log_lines() {
    local text="$1"
    [[ -z "$text" ]] && return 0
    local line
    while IFS= read -r line; do
        log "    ${line}"
    done <<< "$text"
}

# Classify a named Pure object. 0 = present, 1 = Pure says it does not exist, 2 = other failure.
# Dry-run returns 1 without contacting the array. PURE_CLI_OUT holds the CLI text.
pure_object_state() {
    local cmd="$1"
    PURE_CLI_OUT=""
    if [[ "$DRY_RUN" == "true" ]]; then
        return 1
    fi
    local rc=0
    PURE_CLI_OUT=$(storage_ssh pure "$cmd" 2>&1) || rc=$?
    if [[ $rc -eq 0 ]]; then
        return 0
    fi
    if [[ "$PURE_CLI_OUT" == *"does not exist"* ]]; then
        return 1
    fi
    return 2
}

# Create a Pure object when the list command reports it missing.
# Returns 1 on query or create failure. Does not log success after a failed command.
pure_ensure() {
    local what="$1"
    local list_cmd="$2"
    local create_cmd="$3"
    local created_msg="$4"
    local state=0
    pure_object_state "$list_cmd" || state=$?
    if [[ $state -eq 0 ]]; then
        log_success "  ${what} already exists"
        return 0
    fi
    if [[ $state -eq 2 ]]; then
        log_error "  Failed to query ${what}"
        log "    command: ${list_cmd}"
        pure_log_lines "$PURE_CLI_OUT"
        return 1
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would run: ${create_cmd}"
        return 0
    fi
    local rc=0
    PURE_CLI_OUT=$(storage_ssh pure "$create_cmd" 2>&1) || rc=$?
    if [[ $rc -ne 0 ]]; then
        log_error "  Failed to create ${what}"
        log "    command: ${create_cmd}"
        pure_log_lines "$PURE_CLI_OUT"
        return 1
    fi
    pure_log_lines "$PURE_CLI_OUT"
    log_success "  ${created_msg}"
    return 0
}

# Enable a Pure vif when the array created it disabled.
pure_enable_if_needed() {
    local iface="$1"
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would run: purenetwork eth enable ${iface} (if the vif is disabled)"
        return 0
    fi
    local rc=0 out
    out=$(storage_ssh pure "purenetwork eth list ${iface} --nvp" 2>&1) || rc=$?
    if [[ $rc -ne 0 ]]; then
        log_error "  Failed to read interface ${iface}"
        log "    command: purenetwork eth list ${iface} --nvp"
        pure_log_lines "$out"
        return 1
    fi
    if [[ "$out" != *"Enabled=False"* ]]; then
        return 0
    fi
    rc=0
    out=$(storage_ssh pure "purenetwork eth enable ${iface}" 2>&1) || rc=$?
    if [[ $rc -ne 0 ]]; then
        log_error "  Failed to enable interface ${iface}"
        log "    command: purenetwork eth enable ${iface}"
        pure_log_lines "$out"
        return 1
    fi
    pure_log_lines "$out"
    log_success "  Interface ${iface} enabled"
    return 0
}

# =============================================================================
# STORAGE-SETUP: Pure FlashArray X70R5
# Subnets are puresubnet. VLAN portals are purenetwork eth create vif.
# Host groups are purehgroup. Volume connect uses --hgroup.
# =============================================================================
storage_setup_pure() {
    local cloud_name="$1"
    local cloud_nn="$2"
    shift 2
    local -a iqn_pairs=("$@")

    log ""
    log "--- Pure FlashArray X70R5: storage-setup for ${cloud_name} ---"

    # Derive VLAN layout for Pure
    local -a vlan_ids=() subnet_bases=() paths=()
    while read -r _nic vlan_id subnet_base _vendor path; do
        [[ "$_vendor" == "pure" ]] || continue
        vlan_ids+=("$vlan_id")
        subnet_bases+=("$subnet_base")
        paths+=("$path")
    done < <(compute_vlan_layout)

    if (( ${#vlan_ids[@]} == 0 )); then
        log_warn "  No pure entries in VLAN layout. Skipping."
        return 0
    fi

    # This array rejects underscores in subnet, host, and host-group names.
    local hg_name="${cloud_name}-iscsi-hg"
    local pure_failed=0
    PURE_CLI_OUT=""

    # --- Sub-stage A: Create subnets and portal IPs ---
    log "  [A] Creating subnets and portal IPs..."
    local idx
    for (( idx=0; idx<${#vlan_ids[@]}; idx++ )); do
        local vid="${vlan_ids[$idx]}"
        local sub="${subnet_bases[$idx]}"
        local pth="${paths[$idx]}"
        local subnet_name="${cloud_name}-pure-path${pth}"
        local subnet_cmd="puresubnet create --prefix ${sub}.0/24 --vlan ${vid} --gateway ${sub}.1 --mtu 9000 ${subnet_name}"

        if ! pure_ensure "Subnet ${subnet_name}" \
                "puresubnet list ${subnet_name}" \
                "$subnet_cmd" \
                "Subnet ${subnet_name} created (VLAN ${vid})"; then
            pure_failed=1
            continue
        fi

        # One vif per controller on eth14. .2 is ct0, .3 is ct1.
        local ct_idx
        for ct_idx in 0 1; do
            local portal_ip="${sub}.$(( ct_idx + 2 ))"
            local iface="ct${ct_idx}.eth14.${vid}"
            local eth_cmd="purenetwork eth create vif --subnet ${subnet_name} --address ${portal_ip} ${iface}"

            if ! pure_ensure "Interface ${iface}" \
                    "purenetwork eth list ${iface}" \
                    "$eth_cmd" \
                    "Interface ${iface} created (${portal_ip})"; then
                pure_failed=1
                continue
            fi
            if ! pure_enable_if_needed "$iface"; then
                pure_failed=1
            fi
        done
    done

    # --- Sub-stage B: Create volume(s) ---
    log "  [B] Creating volume(s)..."
    local pure_size
    pure_size=$(parse_lun_size_pure "$LUN_SIZE")
    local i
    for (( i=1; i<=LUN_COUNT; i++ )); do
        local vol_name
        vol_name=$(printf "${cloud_name}_iscsi_lta_pure_vol%02d" "$i")
        local vol_cmd="purevol create --size ${pure_size} ${vol_name}"
        if ! pure_ensure "Volume ${vol_name}" \
                "purevol list ${vol_name}" \
                "$vol_cmd" \
                "Volume ${vol_name} created (${pure_size})"; then
            pure_failed=1
        fi
    done

    # --- Sub-stage C: Create hosts and host group ---
    log "  [C] Creating hosts and host group..."
    if ! pure_ensure "Host group ${hg_name}" \
            "purehgroup list ${hg_name}" \
            "purehgroup create ${hg_name}" \
            "Host group ${hg_name} created"; then
        pure_failed=1
    fi

    local pair
    for pair in "${iqn_pairs[@]}"; do
        [[ -z "$pair" ]] && continue
        local worker_name="${pair%%:*}"
        local iqn="${pair#*:}"
        local host_name="${cloud_name}-host-${worker_name}"
        local host_cmd="purehost create --iqnlist ${iqn} ${host_name}"

        if [[ "$DRY_RUN" != "true" ]]; then
            local owner=""
            owner=$(storage_ssh pure "purehost list" 2>&1 | awk -v iqn="$iqn" 'index($0, iqn) { print $1; exit }' || true)
            if [[ -n "$owner" && "$owner" != "$host_name" ]]; then
                log_warn "  IQN ${iqn} is already on Pure host ${owner}; leaving that host unchanged"
                pure_failed=1
                continue
            fi
        fi

        if ! pure_ensure "Host ${host_name}" \
                "purehost list ${host_name}" \
                "$host_cmd" \
                "Host ${host_name} created (${iqn})"; then
            pure_failed=1
            continue
        fi

        local member_cmd="purehgroup setattr --addhostlist ${host_name} ${hg_name}"
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY-RUN] Would run: ${member_cmd}"
            continue
        fi

        local member_out member_rc=0
        member_out=$(storage_ssh pure "purehost list ${host_name} --csv" 2>&1) || member_rc=$?
        if [[ $member_rc -ne 0 ]]; then
            log_error "  Failed to read host group membership for ${host_name}"
            log "    command: purehost list ${host_name} --csv"
            pure_log_lines "$member_out"
            pure_failed=1
            continue
        fi
        if grep -Fq "${hg_name}" <<< "$member_out"; then
            log_success "  Host ${host_name} already in ${hg_name}"
            continue
        fi

        member_rc=0
        member_out=$(storage_ssh pure "$member_cmd" 2>&1) || member_rc=$?
        if [[ $member_rc -ne 0 ]]; then
            log_error "  Failed to add ${host_name} to ${hg_name}"
            log "    command: ${member_cmd}"
            pure_log_lines "$member_out"
            pure_failed=1
            continue
        fi
        pure_log_lines "$member_out"
        log_success "  Host ${host_name} added to ${hg_name}"
    done

    # --- Sub-stage D: Map volume(s) to host group ---
    log "  [D] Mapping volume(s) to host group..."
    for (( i=1; i<=LUN_COUNT; i++ )); do
        local vol_name
        vol_name=$(printf "${cloud_name}_iscsi_lta_pure_vol%02d" "$i")
        local map_cmd="purevol connect --hgroup ${hg_name} ${vol_name}"

        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY-RUN] Would run: ${map_cmd}"
            continue
        fi

        local map_out map_rc=0
        map_out=$(storage_ssh pure "purevol list ${vol_name} --connect" 2>&1) || map_rc=$?
        if [[ $map_rc -ne 0 && "$map_out" != *"does not exist"* ]]; then
            log_error "  Failed to query mapping for ${vol_name}"
            log "    command: purevol list ${vol_name} --connect"
            pure_log_lines "$map_out"
            pure_failed=1
            continue
        fi
        if [[ $map_rc -eq 0 ]] && grep -Fq "${hg_name}" <<< "$map_out"; then
            log_success "  Volume ${vol_name} already mapped to ${hg_name}"
            continue
        fi

        map_rc=0
        map_out=$(storage_ssh pure "$map_cmd" 2>&1) || map_rc=$?
        if [[ $map_rc -ne 0 ]]; then
            log_error "  Failed to map volume ${vol_name} to ${hg_name}"
            log "    command: ${map_cmd}"
            pure_log_lines "$map_out"
            pure_failed=1
            continue
        fi
        pure_log_lines "$map_out"
        log_success "  Volume ${vol_name} mapped to ${hg_name}"
    done

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Pure storage-setup preview complete for ${cloud_name}"
        return 0
    fi

    # --- Verify named objects. Do not scan the full ethernet table. ---
    log "  Verifying final state..."
    local verify_cmd verify_out verify_rc
    for (( idx=0; idx<${#vlan_ids[@]}; idx++ )); do
        local vid="${vlan_ids[$idx]}"
        local sub="${subnet_bases[$idx]}"
        local pth="${paths[$idx]}"
        local subnet_name="${cloud_name}-pure-path${pth}"
        verify_cmd="puresubnet list ${subnet_name}"
        verify_rc=0
        verify_out=$(storage_ssh pure "$verify_cmd" 2>&1) || verify_rc=$?
        pure_log_lines "$verify_out"
        if [[ $verify_rc -ne 0 ]]; then
            log_error "  Verify failed: ${verify_cmd}"
            pure_failed=1
        fi
        local ct_idx
        for ct_idx in 0 1; do
            local iface="ct${ct_idx}.eth14.${vid}"
            verify_cmd="purenetwork eth list ${iface} --nvp"
            verify_rc=0
            verify_out=$(storage_ssh pure "$verify_cmd" 2>&1) || verify_rc=$?
            pure_log_lines "$verify_out"
            if [[ $verify_rc -ne 0 || "$verify_out" == *"Enabled=False"* ]]; then
                log_error "  Verify failed: ${iface} is missing or disabled"
                pure_failed=1
            fi
        done
    done

    verify_cmd="purehgroup list ${hg_name}"
    verify_rc=0
    verify_out=$(storage_ssh pure "$verify_cmd" 2>&1) || verify_rc=$?
    pure_log_lines "$verify_out"
    if [[ $verify_rc -ne 0 ]]; then
        log_error "  Verify failed: ${verify_cmd}"
        pure_failed=1
    fi

    for (( i=1; i<=LUN_COUNT; i++ )); do
        local vol_name
        vol_name=$(printf "${cloud_name}_iscsi_lta_pure_vol%02d" "$i")
        verify_cmd="purevol list ${vol_name} --connect"
        verify_rc=0
        verify_out=$(storage_ssh pure "$verify_cmd" 2>&1) || verify_rc=$?
        pure_log_lines "$verify_out"
        if [[ $verify_rc -ne 0 ]] || ! grep -Fq "${hg_name}" <<< "$verify_out"; then
            log_error "  Verify failed: ${vol_name} is not connected to ${hg_name}"
            pure_failed=1
        fi
    done

    if [[ "$pure_failed" -ne 0 ]]; then
        log_error "  Pure storage-setup failed for ${cloud_name}"
        return 1
    fi
    log_success "  Pure storage-setup complete for ${cloud_name}"
}

# =============================================================================
# IBM host adoption
# A host that already has this IQN is kept.
# chhost runs only for a host this stage just created, or for an empty host
# whose portset is not the cloud portset.
# Cloud vdisks are mapped once to host cluster ${cloud}_iscsi_hc, which is
# the shared mapping for every host this stage puts in that cluster.
# A host in a different cluster is not moved and is not privately mapped.
# =============================================================================
ibm_lshost_field() {
    local field="$1"
    awk -v f="$field" '$1 == f { $1=""; sub(/^[[:space:]]+/, ""); print; exit }'
}

ibm_lowest_free_scsi() {
    local occupied=" $1 "
    local id=0
    while [[ "$occupied" == *" ${id} "* ]]; do
        id=$((id + 1))
        if (( id > 511 )); then
            return 1
        fi
    done
    printf '%s\n' "$id"
}

# Prints lshost detail. Returns 2 when the host does not exist.
ibm_lshost() {
    local name="$1"
    local err status=0 out msg
    err=$(mktemp)
    out=$(storage_ssh --read ibm "svcinfo lshost ${name}" 2>"$err") || status=$?
    msg=$(cat "$err" 2>/dev/null || true)
    rm -f "$err"
    if [[ "$status" -eq 0 ]]; then
        printf '%s\n' "$out"
        return 0
    fi
    if [[ "$msg" == *CMMVC5753E* || "$msg" == *"does not exist"* || "$out" == *CMMVC5753E* ]]; then
        return 2
    fi
    log_error "  lshost ${name} failed: ${msg:-$out}"
    return 1
}

# empty, cloud, or "foreign <vdisk>". Cloud vdisks are this stage's volumes.
ibm_rows_kind() {
    local cloud_name="$1"
    local rows="$2"
    local sid vname kind="empty"
    if [[ -z "$rows" ]]; then
        printf 'empty\n'
        return 0
    fi
    while read -r sid vname; do
        [[ -z "$vname" ]] && continue
        if [[ ! "$vname" =~ ^${cloud_name}_iscsi_lta_ibm_vdisk[0-9]{2}$ ]]; then
            printf 'foreign %s\n' "$vname"
            return 0
        fi
        kind="cloud"
    done <<< "$rows"
    printf '%s\n' "$kind"
}

# Prints "scsi_id vdisk_name" rows. Empty output means the host has no maps.
ibm_vdisk_rows() {
    local host="$1"
    local out status=0
    out=$(storage_ssh --read ibm "svcinfo lshostvdiskmap -nohdr -delim : ${host}" 2>&1) || status=$?
    if [[ "$status" -ne 0 ]]; then
        log_error "  lshostvdiskmap ${host} failed: ${out}"
        return 1
    fi
    printf '%s\n' "$out" | awk -F: 'NF >= 5 && $3 ~ /^[0-9]+$/ { print $3, $5 }'
}

# Prints the host whose iscsi_name is this IQN, or nothing when there is none.
ibm_host_for_iqn() {
    local iqn="$1"
    local cloud_name="$2"
    local short="$3"
    local candidate detail status have
    for candidate in "$short" "${cloud_name}_${short}"; do
        status=0
        detail=$(ibm_lshost "$candidate") || status=$?
        if [[ "$status" -eq 1 ]]; then
            return 1
        fi
        if [[ "$status" -ne 0 ]]; then
            continue
        fi
        have=$(printf '%s\n' "$detail" | ibm_lshost_field iscsi_name)
        if [[ "$have" == "$iqn" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    local list=0 names
    names=$(storage_ssh --read ibm "svcinfo lshost -nohdr -delim :" 2>&1) || list=$?
    if [[ "$list" -ne 0 ]]; then
        log_error "  lshost list failed: ${names}"
        return 1
    fi

    local -a found=()
    local line name dstatus
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        name=$(printf '%s\n' "$line" | awk -F: '{ print $2 }')
        [[ -z "$name" || "$name" == "name" ]] && continue
        [[ "$name" == "$short" || "$name" == "${cloud_name}_${short}" ]] && continue
        dstatus=0
        detail=$(ibm_lshost "$name") || dstatus=$?
        if [[ "$dstatus" -eq 1 ]]; then
            return 1
        fi
        if [[ "$dstatus" -ne 0 ]]; then
            continue
        fi
        have=$(printf '%s\n' "$detail" | ibm_lshost_field iscsi_name)
        if [[ "$have" == "$iqn" ]]; then
            found+=("$name")
        fi
    done <<< "$names"

    if (( ${#found[@]} > 1 )); then
        log_error "  IQN ${iqn} belongs to more than one IBM host: ${found[*]}"
        return 1
    fi
    if (( ${#found[@]} == 1 )); then
        printf '%s\n' "${found[0]}"
    fi
}

ibm_bind_one_host() {
    local cloud_name="$1"
    local portset_name="$2"
    local worker_name="$3"
    local iqn="$4"
    local live=false
    if [[ "$DRY_RUN" != "true" || "$TARGET_TYPE" == "vmware" ]]; then
        live=true
    fi

    local host_name="" status=0 detail="" created=false
    if [[ "$live" == "true" ]]; then
        host_name=$(ibm_host_for_iqn "$iqn" "$cloud_name" "$worker_name") || return 1
    fi

    if [[ -n "$host_name" ]]; then
        log "  IQN ${iqn} already belongs to IBM host ${host_name}"
        status=0
        detail=$(ibm_lshost "$host_name") || status=$?
        if [[ "$status" -ne 0 ]]; then
            log_error "  Could not read IBM host ${host_name}"
            return 1
        fi
    else
        host_name="${cloud_name}_${worker_name}"
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY-RUN] Would create: svctask mkhost -name ${host_name} -iscsiname ${iqn} -iogrp io_grp0 -type generic -portset ${portset_name}"
            created=true
        else
            storage_ssh ibm "svctask mkhost -name ${host_name} -iscsiname ${iqn} -iogrp io_grp0 -type generic -portset ${portset_name}" || {
                log_error "  Failed to create host ${host_name}"
                return 1
            }
            log_success "  Host ${host_name} created (IQN: ${iqn})"
            created=true
            status=0
            detail=$(ibm_lshost "$host_name") || status=$?
            if [[ "$status" -ne 0 ]]; then
                log_error "  Host ${host_name} was created but lshost failed"
                return 1
            fi
        fi
    fi

    local rows="" occupied="" sid vname desc
    if [[ "$created" == "true" && "$DRY_RUN" == "true" ]]; then
        log "  ${host_name} occupied SCSI ids: none"
    else
        rows=$(ibm_vdisk_rows "$host_name") || return 1
        if [[ -z "$rows" ]]; then
            log "  ${host_name} occupied SCSI ids: none"
        else
            desc=""
            while read -r sid vname; do
                [[ -z "$sid" ]] && continue
                occupied+=" ${sid}"
                desc+="${sid}=${vname} "
            done <<< "$rows"
            log "  ${host_name} occupied SCSI ids:${occupied} (${desc% })"
        fi
    fi

    if [[ -n "$detail" ]]; then
        local cur_portset cluster map_lines
        cur_portset=$(printf '%s\n' "$detail" | ibm_lshost_field portset_name)
        cluster=$(printf '%s\n' "$detail" | ibm_lshost_field host_cluster_name)
        map_lines=0
        if [[ -n "$rows" ]]; then
            map_lines=$(printf '%s\n' "$rows" | wc -l)
            map_lines=${map_lines// /}
        fi
        if (( map_lines > 0 )); then
            log "  ${host_name} portset is ${cur_portset:-unset}; leaving it because the host has vdisk maps"
        elif [[ "$cur_portset" != "$portset_name" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would run: svctask chhost -portset ${portset_name} ${host_name}"
            else
                storage_ssh ibm "svctask chhost -portset ${portset_name} ${host_name}" || {
                    log_error "  chhost failed for ${host_name}; existing maps were left in place"
                    return 1
                }
                log "  Moved ${host_name} from portset '${cur_portset}' to '${portset_name}'"
            fi
        fi
        if [[ -n "$cluster" ]]; then
            local hc_name="${cloud_name}_iscsi_hc"
            if [[ "$cluster" == "$hc_name" ]]; then
                log "  ${host_name} is already in host cluster ${hc_name}"
                printf 'ours %s\n' "$host_name"
                return 0
            fi
            local missing=0 i vdisk
            for (( i=1; i<=LUN_COUNT; i++ )); do
                vdisk=$(printf "${cloud_name}_iscsi_lta_ibm_vdisk%02d" "$i")
                if [[ -n "$rows" ]] && printf '%s\n' "$rows" | awk -v v="$vdisk" '$2 == v { found=1 } END { exit found ? 0 : 1 }'; then
                    log_success "  vdisk ${vdisk} already mapped to ${host_name} through host cluster ${cluster}"
                else
                    log_warn "  ${host_name} is a member of host cluster ${cluster}; ${vdisk} is not mapped to that cluster. This stage will not change ${cluster}."
                    missing=1
                fi
            done
            printf 'foreign %s\n' "$host_name"
            if [[ "$missing" -ne 0 ]]; then
                return 1
            fi
            return 0
        fi
    fi

    local kind_line=""
    kind_line=$(ibm_rows_kind "$cloud_name" "$rows")
    if [[ "$kind_line" == foreign\ * ]]; then
        log_error "  ${host_name} has vdisk ${kind_line#foreign }, which is not a ${cloud_name} volume. Not adding ${host_name} to host cluster ${cloud_name}_iscsi_hc."
        printf 'blocked %s\n' "$host_name"
        return 1
    fi
    if [[ "$kind_line" == "cloud" ]]; then
        printf 'none cloud %s\n' "$host_name"
    else
        printf 'none empty %s\n' "$host_name"
    fi
}

# 0 when the cluster exists, 1 when it does not, 2 when the query fails.
ibm_hostcluster_exists() {
    local name="$1"
    local out status=0 line
    out=$(storage_ssh --read ibm "svcinfo lshostcluster -delim :" 2>&1) || status=$?
    if [[ "$status" -ne 0 ]]; then
        log_error "  lshostcluster failed"
        while IFS= read -r line; do
            [[ -n "$line" ]] && log "    ${line}"
        done <<< "$out"
        return 2
    fi
    if printf '%s\n' "$out" | awk -F: -v n="$name" '$2 == n { found=1 } END { exit found ? 0 : 1 }'; then
        return 0
    fi
    return 1
}

# Prints the SCSI id when lsvdiskhostmap shows this cluster. Returns 1 when
# the vdisk is not mapped to the cluster, 2 when the vdisk itself is missing.
ibm_cluster_map_scsi() {
    local vdisk="$1"
    local cluster="$2"
    local out status=0 scsi
    out=$(storage_ssh --read ibm "svcinfo lsvdiskhostmap -delim : ${vdisk}" 2>&1) || status=$?
    scsi=$(printf '%s\n' "$out" | awk -F: -v c="$cluster" 'index($0, c) && $3 ~ /^[0-9]+$/ { print $3; exit }')
    if [[ -n "$scsi" ]]; then
        printf '%s\n' "$scsi"
        return 0
    fi
    if [[ "$status" -ne 0 && ( "$out" == *"does not exist"* || "$out" == *CMMVC5753E* || "$out" == *CMMVC5754E* ) ]]; then
        log_error "  lsvdiskhostmap ${vdisk} failed: ${out}"
        return 2
    fi
    return 1
}

ibm_svctask() {
    local message="$1"
    shift
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would run: svctask $*"
        return 0
    fi
    local out status=0 line
    out=$(storage_ssh ibm "svctask $*" 2>&1) || status=$?
    if [[ "$status" -ne 0 ]]; then
        log_error "  ${message}"
        while IFS= read -r line; do
            [[ -n "$line" ]] && log "    ${line}"
        done <<< "$out"
        return 1
    fi
    while IFS= read -r line; do
        [[ -n "$line" ]] && log "    ${line}"
    done <<< "$out"
    return 0
}

# Prints one member of this host cluster. Returns 1 when it has none, 2 on query failure.
ibm_one_cluster_member() {
    local cluster="$1"
    local names="" status=0 line name detail hc dstatus
    names=$(storage_ssh --read ibm "svcinfo lshost -nohdr -delim :" 2>&1) || status=$?
    if [[ "$status" -ne 0 ]]; then
        log_error "  lshost list failed while looking for members of ${cluster}: ${names}"
        return 2
    fi
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        name=$(printf '%s\n' "$line" | awk -F: '{ print $2 }')
        [[ -z "$name" || "$name" == "name" ]] && continue
        dstatus=0
        detail=$(ibm_lshost "$name") || dstatus=$?
        if [[ "$dstatus" -eq 1 ]]; then
            return 2
        fi
        if [[ "$dstatus" -ne 0 ]]; then
            continue
        fi
        hc=$(printf '%s\n' "$detail" | ibm_lshost_field host_cluster_name)
        if [[ "$hc" == "$cluster" ]]; then
            printf '%s\n' "$name"
            return 0
        fi
    done <<< "$names"
    return 1
}

ibm_unmap_cloud_vdisks() {
    local host="$1"
    local cloud_name="$2"
    local rows="" sid vname
    rows=$(ibm_vdisk_rows "$host") || return 1
    while read -r sid vname; do
        [[ -z "$vname" ]] && continue
        if [[ ! "$vname" =~ ^${cloud_name}_iscsi_lta_ibm_vdisk[0-9]{2}$ ]]; then
            continue
        fi
        ibm_svctask "Failed to remove private map of ${vname} from ${host}" \
            "rmvdiskhostmap -host ${host} ${vname}" || return 1
        if [[ "$DRY_RUN" != "true" ]]; then
            log "  Removed private map of ${vname} from ${host}"
        fi
    done <<< "$rows"
}

# Map this cloud's vdisks once to ${cloud}_iscsi_hc and add unclustered hosts.
# empty_ref / cloud_ref / ours_ref are namerefs to host-name arrays.
ibm_share_vdisks() {
    local cloud_name="$1"
    local -n empty_ref=$2
    local -n cloud_ref=$3
    local -n ours_ref=$4
    local hc="${cloud_name}_iscsi_hc"
    local i vdisk scsi=0 joined h

    if [[ "$DRY_RUN" == "true" && "$TARGET_TYPE" != "vmware" ]]; then
        log "[DRY-RUN] Would create: svctask mkhostcluster -name ${hc}"
        local -a preview=()
        if (( ${#empty_ref[@]} > 0 )); then
            preview+=("${empty_ref[@]}")
        fi
        if (( ${#cloud_ref[@]} > 0 )); then
            preview+=("${cloud_ref[@]}")
        fi
        if (( ${#preview[@]} > 0 )); then
            joined=$(IFS=:; printf '%s' "${preview[*]}")
            log "[DRY-RUN] Would add: svctask addhostclustermember -host ${joined} ${hc}"
        fi
        for (( i=1; i<=LUN_COUNT; i++ )); do
            vdisk=$(printf '%s_iscsi_lta_ibm_vdisk%02d' "$cloud_name" "$i")
            log "[DRY-RUN] Would map: svctask mkvdiskhostmap -hostcluster ${hc} -scsi ${scsi} ${vdisk}"
            scsi=$((scsi + 1))
        done
        return 0
    fi

    local exists=0
    ibm_hostcluster_exists "$hc" || exists=$?
    if [[ "$exists" -eq 2 ]]; then
        return 1
    fi

    local seed=""
    local -a unmap=() add=()
    if [[ "$exists" -eq 1 && ${#cloud_ref[@]} -gt 0 ]]; then
        seed="${cloud_ref[0]}"
        if (( ${#cloud_ref[@]} > 1 )); then
            unmap+=("${cloud_ref[@]:1}")
        fi
    elif (( ${#cloud_ref[@]} > 0 )); then
        unmap+=("${cloud_ref[@]}")
    fi
    if (( ${#empty_ref[@]} > 0 )); then
        add+=("${empty_ref[@]}")
    fi

    if [[ "$exists" -eq 1 ]]; then
        if [[ -n "$seed" ]]; then
            ibm_svctask "Failed to create host cluster ${hc} from ${seed}" \
                "mkhostcluster -name ${hc} -seedfromhost ${seed}" || return 1
            if [[ "$DRY_RUN" != "true" ]]; then
                log_success "  Host cluster ${hc} created from ${seed}"
            fi
        else
            ibm_svctask "Failed to create host cluster ${hc}" \
                "mkhostcluster -name ${hc}" || return 1
            if [[ "$DRY_RUN" != "true" ]]; then
                log_success "  Host cluster ${hc} created"
            fi
        fi
    else
        log_success "  Host cluster ${hc} already exists"
    fi

    if (( ${#unmap[@]} > 0 )); then
        for h in "${unmap[@]}"; do
            ibm_unmap_cloud_vdisks "$h" "$cloud_name" || return 1
            add+=("$h")
        done
    fi

    if (( ${#add[@]} > 0 )); then
        joined=$(IFS=:; printf '%s' "${add[*]}")
        ibm_svctask "Failed to add ${joined} to host cluster ${hc}" \
            "addhostclustermember -host ${joined} ${hc}" || return 1
        if [[ "$DRY_RUN" != "true" ]]; then
            log_success "  Added ${joined} to host cluster ${hc}"
        fi
    fi

    local occupied="" rows="" sid vname map_scsi=0 member="" member_status=0
    declare -A seed_scsi=()
    if [[ -n "$seed" ]]; then
        rows=$(ibm_vdisk_rows "$seed") || return 1
        while read -r sid vname; do
            [[ -z "$sid" ]] && continue
            occupied+=" ${sid}"
            seed_scsi["$vname"]="$sid"
        done <<< "$rows"
    elif (( ${#ours_ref[@]} > 0 )); then
        rows=$(ibm_vdisk_rows "${ours_ref[0]}") || return 1
        while read -r sid vname; do
            [[ -z "$sid" ]] && continue
            occupied+=" ${sid}"
        done <<< "$rows"
    elif [[ "$exists" -eq 0 ]]; then
        member=$(ibm_one_cluster_member "$hc") || member_status=$?
        if [[ "$member_status" -eq 2 ]]; then
            return 1
        fi
        if [[ -n "$member" ]]; then
            rows=$(ibm_vdisk_rows "$member") || return 1
            while read -r sid vname; do
                [[ -z "$sid" ]] && continue
                occupied+=" ${sid}"
            done <<< "$rows"
        fi
    fi

    for (( i=1; i<=LUN_COUNT; i++ )); do
        vdisk=$(printf '%s_iscsi_lta_ibm_vdisk%02d' "$cloud_name" "$i")
        map_scsi=0
        scsi=$(ibm_cluster_map_scsi "$vdisk" "$hc") || map_scsi=$?
        if [[ "$map_scsi" -eq 2 ]]; then
            return 1
        fi
        if [[ "$map_scsi" -eq 0 ]]; then
            if [[ " ${occupied} " != *" ${scsi} "* ]]; then
                occupied+=" ${scsi}"
            fi
            log_success "  vdisk ${vdisk} already mapped to host cluster ${hc}"
            continue
        fi
        if [[ -n "${seed_scsi[$vdisk]:-}" ]]; then
            log "  vdisk ${vdisk} stays on SCSI ${seed_scsi[$vdisk]} through seed host ${seed}"
            continue
        fi
        scsi=$(ibm_lowest_free_scsi "$occupied") || {
            log_error "  No free SCSI id on host cluster ${hc}"
            return 1
        }
        ibm_svctask "Failed to map ${vdisk} to host cluster ${hc}" \
            "mkvdiskhostmap -hostcluster ${hc} -scsi ${scsi} ${vdisk}" || return 1
        if [[ "$DRY_RUN" != "true" ]]; then
            log_success "  vdisk ${vdisk} mapped to host cluster ${hc} (scsi ${scsi})"
        fi
        occupied+=" ${scsi}"
        log "  Lowest free SCSI id used for ${vdisk} on ${hc} is ${scsi}"
    done
}

ibm_bind_hosts() {
    local cloud_name="$1"
    local portset_name="$2"
    shift 2
    local -a iqn_pairs=("$@")

    if [[ "$DRY_RUN" != "true" || "$TARGET_TYPE" == "vmware" ]]; then
        if [[ -z "${_BWS_CACHE}" ]]; then
            bws_load_cache || return 1
            log "Credential cache loaded (${#_BWS_CACHE} bytes, storage credentials only)"
        fi
    fi

    local failed=0 pair worker_name iqn line="" status=0 tag="" a="" b=""
    local -a empty_hosts=() cloud_hosts=() ours_hosts=()
    for pair in "${iqn_pairs[@]}"; do
        [[ -z "$pair" ]] && continue
        worker_name="${pair%%:*}"
        iqn="${pair#*:}"
        line=""
        status=0
        line=$(ibm_bind_one_host "$cloud_name" "$portset_name" "$worker_name" "$iqn") || status=$?
        if [[ -z "$line" ]]; then
            failed=1
            continue
        fi
        read -r tag a b <<< "$line"
        case "$tag" in
            ours) ours_hosts+=("$a") ;;
            none)
                if [[ "$a" == "cloud" ]]; then
                    cloud_hosts+=("$b")
                elif [[ "$a" == "empty" ]]; then
                    empty_hosts+=("$b")
                fi
                ;;
            foreign|blocked) [[ "$status" -ne 0 ]] && failed=1 ;;
        esac
        if [[ "$status" -ne 0 && "$tag" != "foreign" && "$tag" != "blocked" ]]; then
            failed=1
        fi
    done

    if (( ${#empty_hosts[@]} + ${#cloud_hosts[@]} + ${#ours_hosts[@]} > 0 )); then
        ibm_share_vdisks "$cloud_name" empty_hosts cloud_hosts ours_hosts || failed=1
    fi
    if [[ "$failed" -ne 0 ]]; then
        return 1
    fi
}

# 0 when lsip shows this IP in the portset, 1 when it does not, 2 when lsip fails.
# This array rejects svcinfo lsportsetmember, so membership is the portset column of lsip.
ibm_portset_has_ip() {
    local portset="$1"
    local ip="$2"
    local out status=0 line
    out=$(storage_ssh --read ibm "svcinfo lsip -delim :" 2>&1) || status=$?
    if [[ "$status" -ne 0 ]]; then
        log_error "  lsip failed while checking portset ${portset}"
        while IFS= read -r line; do
            [[ -n "$line" ]] && log "    ${line}"
        done <<< "$out"
        return 2
    fi
    if printf '%s\n' "$out" | grep -F "${portset}" | grep -q -F -- "${ip}"; then
        return 0
    fi
    return 1
}

# =============================================================================
# STORAGE-SETUP: IBM FlashSystem 7300
# =============================================================================
storage_setup_ibm() {
    local cloud_name="$1"
    local cloud_nn="$2"
    shift 2
    local -a iqn_pairs=("$@")

    log ""
    log "--- IBM FlashSystem 7300: storage-setup for ${cloud_name} ---"

    # Derive VLAN layout for IBM
    local -a vlan_ids=() subnet_bases=() paths=()
    while read -r _nic vlan_id subnet_base _vendor path; do
        [[ "$_vendor" == "ibm" ]] || continue
        vlan_ids+=("$vlan_id")
        subnet_bases+=("$subnet_base")
        paths+=("$path")
    done < <(compute_vlan_layout)

    if (( ${#vlan_ids[@]} == 0 )); then
        log_warn "  No ibm entries in VLAN layout. Skipping."
        return 0
    fi

    local portset_name="${cloud_name}_iscsi_portset"

    # --- Sub-stage A: Portset + iSCSI VLAN IPs ---
    log "  [A] Creating portset and iSCSI VLAN IPs..."
    local portset_check
    portset_check=$(storage_ssh ibm "svcinfo lsportset -delim :" 2>/dev/null | grep -c "${portset_name}" || true)

    if [[ "$portset_check" -gt 0 ]]; then
        log_success "  Portset ${portset_name} already exists"
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY-RUN] Would create portset: svctask mkportset -name ${portset_name} -type host"
        else
            storage_apply ibm "Failed to create portset ${portset_name}" \
                "svctask mkportset -name ${portset_name} -type host" || return 1
            log_success "  Portset ${portset_name} created"
        fi
    fi

    # Create iSCSI IPs on node ports (node1 ports 5,7; node2 ports 6,8)
    # Path A uses ports 5 (node1) and 6 (node2)
    # Path B uses ports 7 (node1) and 8 (node2)
    local -a ip_configs=()
    if (( ${#vlan_ids[@]} >= 1 )); then
        local vlanA="${vlan_ids[0]}"
        local subA="${subnet_bases[0]}"
        ip_configs+=("node1 5 ${subA}.2 ${vlanA}")
        ip_configs+=("node2 6 ${subA}.3 ${vlanA}")
    fi
    if (( ${#vlan_ids[@]} >= 2 )); then
        local vlanB="${vlan_ids[1]}"
        local subB="${subnet_bases[1]}"
        ip_configs+=("node1 7 ${subB}.2 ${vlanB}")
        ip_configs+=("node2 8 ${subB}.3 ${vlanB}")
    fi

    local -a portal_ips=()
    for cfg in "${ip_configs[@]}"; do
        local node port ip vlan
        read -r node port ip vlan <<< "$cfg"

        # Check if IP already exists
        local ip_check
        ip_check=$(storage_ssh ibm "svcinfo lsip -delim :" 2>/dev/null | grep -c "${ip}" || true)

        if [[ "$ip_check" -gt 0 ]]; then
            log_success "  IP ${ip} already configured on ${node}:port${port}"
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would create: svctask mkip -node ${node} -port ${port} -ip ${ip} -prefix 24 -portset ${portset_name} -vlan ${vlan}"
            else
                storage_apply ibm "Failed to create IP ${ip} on ${node}:port${port}" \
                    "svctask mkip -node ${node} -port ${port} -ip ${ip} -prefix 24 -portset ${portset_name} -vlan ${vlan}" || return 1
                log_success "  IP ${ip} created on ${node}:port${port} (VLAN ${vlan})"
            fi
        fi
        portal_ips+=("$ip")

        # Add to portset. lsip is the membership source; lsportsetmember is not a command here.
        local member_status=0
        ibm_portset_has_ip "$portset_name" "$ip" || member_status=$?
        if [[ "$member_status" -eq 2 ]]; then
            return 1
        fi
        if [[ "$member_status" -ne 0 ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would add: svctask addportsetmember -portset ${portset_name} -ip ${ip}"
            else
                local add_out="" add_status=0 again=0 line
                add_out=$(storage_ssh ibm "svctask addportsetmember -portset ${portset_name} -ip ${ip}" 2>&1) || add_status=$?
                if [[ "$add_status" -ne 0 ]]; then
                    ibm_portset_has_ip "$portset_name" "$ip" || again=$?
                    if [[ "$again" -eq 0 ]]; then
                        log_success "  IP ${ip} already in portset ${portset_name}"
                    else
                        log_error "  Failed to add ${ip} to portset ${portset_name}"
                        while IFS= read -r line; do
                            [[ -n "$line" ]] && log "    ${line}"
                        done <<< "$add_out"
                        return 1
                    fi
                else
                    log "  Added ${ip} to portset ${portset_name}"
                fi
            fi
        fi
    done

    # --- Sub-stage B: Volumes (vdisks) ---
    log "  [B] Creating vdisk(s)..."
    local ibm_size_parts
    ibm_size_parts=$(parse_lun_size_ibm "$LUN_SIZE")
    local ibm_num ibm_unit
    read -r ibm_num ibm_unit <<< "$ibm_size_parts"

    local i
    for (( i=1; i<=LUN_COUNT; i++ )); do
        local vdisk_name
        vdisk_name=$(printf "${cloud_name}_iscsi_lta_ibm_vdisk%02d" "$i")
        local vd_out="" vd_check cap have want
        vd_out=$(storage_ssh ibm "svcinfo lsvdisk ${vdisk_name}" 2>/dev/null || true)
        vd_check=$(printf '%s\n' "$vd_out" | grep -c "${vdisk_name}" || true)
        if [[ "$vd_check" -gt 0 ]]; then
            log_success "  vdisk ${vdisk_name} already exists"
            cap=$(printf '%s\n' "$vd_out" | awk '$1 == "capacity" { print $2; exit }')
            if [[ -z "$cap" ]]; then
                log_warn "  vdisk ${vdisk_name}: could not read capacity; leaving the existing vdisk unchanged"
            else
                want=$(ibm_size_mib "$LUN_SIZE" || true)
                have=$(ibm_size_mib "$cap" || true)
                if [[ -z "$want" || -z "$have" ]]; then
                    log_warn "  vdisk ${vdisk_name}: could not compare capacity ${cap} with LUN_SIZE ${LUN_SIZE}; leaving the existing vdisk unchanged"
                elif [[ "$want" != "$have" ]]; then
                    log_warn "  vdisk ${vdisk_name} capacity is ${cap}; LUN_SIZE is ${LUN_SIZE}; leaving the existing vdisk unchanged"
                fi
            fi
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would create: svctask mkvdisk -mdiskgrp Pool0 -iogrp io_grp0 -size ${ibm_num} -unit ${ibm_unit} -name ${vdisk_name}"
            else
                storage_apply ibm "Failed to create vdisk ${vdisk_name}" \
                    "svctask mkvdisk -mdiskgrp Pool0 -iogrp io_grp0 -size ${ibm_num} -unit ${ibm_unit} -name ${vdisk_name}" || return 1
                log_success "  vdisk ${vdisk_name} created (${LUN_SIZE})"
            fi
        fi
    done

    # --- Sub-stages C and D: adopt the host that already owns the IQN, then map ---
    log "  [C] Resolving host objects by IQN..."
    log "  [D] Mapping vdisk(s) to host cluster ${cloud_name}_iscsi_hc..."
    local bind_status=0
    ibm_bind_hosts "$cloud_name" "$portset_name" "${iqn_pairs[@]}" || bind_status=$?

    # Verify final state
    log "  Verifying final state..."
    local verify_ps verify_ip
    verify_ps=$(storage_ssh ibm "svcinfo lsportset -delim :" 2>/dev/null | grep "${portset_name}" || true)
    [[ -n "$verify_ps" ]] && log "    Portset: ${verify_ps}"
    verify_ip=$(storage_ssh ibm "svcinfo lsip -delim :" 2>/dev/null | grep -E "$(IFS='|'; echo "${portal_ips[*]}")" || true)
    echo "$verify_ip" | while IFS= read -r line; do [[ -n "$line" ]] && log "    IP: $line"; done || true

    if [[ "$bind_status" -ne 0 ]]; then
        log_error "  IBM host mapping failed for one or more hosts"
        return 1
    fi
    log_success "  IBM storage-setup complete for ${cloud_name}"
}

# =============================================================================
# STORAGE-SETUP: NetApp AFF A300
# =============================================================================
storage_setup_netapp_aff() {
    local cloud_name="$1"
    local cloud_nn="$2"
    shift 2
    local -a iqn_pairs=("$@")

    log ""
    log "--- NetApp AFF A300: storage-setup for ${cloud_name} ---"
    local os_type
    os_type=$(storage_target_ostype)

    local svm="svm_${cloud_name}"
    local ipspace="ipspace_${cloud_name}"

    # Derive VLAN layout for netapp-aff
    local -a vlan_ids=() subnet_bases=() paths=()
    while read -r _nic vlan_id subnet_base _vendor path; do
        [[ "$_vendor" == "netapp-aff" ]] || continue
        vlan_ids+=("$vlan_id")
        subnet_bases+=("$subnet_base")
        paths+=("$path")
    done < <(compute_vlan_layout)

    if (( ${#vlan_ids[@]} == 0 )); then
        log_warn "  No netapp-aff entries in VLAN layout. Skipping."
        return 0
    fi

    # Nodes on the A300
    local node1="b02-h37-ntap-a300-01"
    local node2="b02-h37-ntap-a300-02"
    # Data ports — e0g and e0h are the 10GbE data ports on this A300
    local port_a="e0g"
    local port_b="e0h"

    # --- Sub-stage A: verify or create IPspace, SVM, LIFs ---
    log "  [A] Checking IPspace, SVM, iSCSI service, and LIFs..."

    local vlanA="${vlan_ids[0]}"
    local vlanB="${vlan_ids[1]}"
    local subA="${subnet_bases[0]}"
    local subB="${subnet_bases[1]}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would ensure: ipspace ${ipspace}, broadcast domains, VLAN ports, SVM ${svm}, iSCSI service, 4 LIFs"
    else
        # Step 1: IPspace
        local ipspace_check
        ipspace_check=$(storage_ssh netapp-aff "ipspace show -ipspace ${ipspace}" 2>/dev/null | grep -c "${ipspace}" || true)
        if [[ "$ipspace_check" -gt 0 ]]; then
            log_success "  IPspace ${ipspace} already exists"
        else
            storage_apply netapp-aff "Failed to create IPspace ${ipspace}" \
                "ipspace create -ipspace ${ipspace}" || return 1
            log_success "  IPspace ${ipspace} created"
        fi

        # Step 2: Broadcast domains (checked independently — no duplicate-entry noise on re-runs)
        local bd_a="bd_${cloud_name}_a"
        local bd_b="bd_${cloud_name}_b"
        local bd
        for bd in "$bd_a" "$bd_b"; do
            local bd_check
            bd_check=$(storage_ssh netapp-aff "network port broadcast-domain show -broadcast-domain ${bd}" 2>/dev/null | grep -c "${bd}" || true)
            if [[ "$bd_check" -gt 0 ]]; then
                log_success "  Broadcast domain ${bd} already exists"
            else
                storage_apply netapp-aff "Failed to create broadcast domain ${bd}" \
                    "network port broadcast-domain create -broadcast-domain ${bd} -mtu 9000 -ipspace ${ipspace}" || return 1
                log_success "  Broadcast domain ${bd} created"
            fi
        done

        # Step 3: VLAN ports + broadcast-domain membership (reconciled on every run;
        # one port query drives create-if-missing, remove-from-wrong-domain, add-to-target)
        local -a add_a=() add_b=()
        local node vp cur_bd target_bd
        for node in "$node1" "$node2"; do
            for vp in "${port_a}-${vlanA}" "${port_b}-${vlanB}"; do
                if [[ "$vp" == "${port_b}-${vlanB}" ]]; then
                    target_bd="$bd_b"
                else
                    target_bd="$bd_a"
                fi
                cur_bd=$(storage_ssh netapp-aff "network port show -node ${node} -port ${vp} -fields broadcast-domain" 2>/dev/null | grep "${vp}" | awk '{print $3}' || true)
                if [[ -z "$cur_bd" ]]; then
                    # VLAN port doesn't exist yet — create it (auto-assigned to a Default-ipspace domain)
                    storage_apply netapp-aff "Failed to create VLAN port ${node}:${vp}" \
                        "network port vlan create -node ${node} -vlan-name ${vp}" || return 1
                    log_success "  VLAN port ${node}:${vp} created"
                elif [[ "$cur_bd" == "$target_bd" ]]; then
                    log_verbose "  ${node}:${vp} already in ${target_bd}"
                    continue
                elif [[ "$cur_bd" != "-" ]]; then
                    log "  Moving ${node}:${vp} from ${cur_bd} to ${target_bd}"
                    storage_apply netapp-aff "Failed to remove ${node}:${vp} from ${cur_bd}" \
                        "network port broadcast-domain remove-ports -ipspace Default -broadcast-domain ${cur_bd} -ports ${node}:${vp}" || return 1
                fi
                if [[ "$target_bd" == "$bd_a" ]]; then
                    add_a+=("${node}:${vp}")
                else
                    add_b+=("${node}:${vp}")
                fi
            done
        done

        if (( ${#add_a[@]} > 0 )); then
            storage_apply netapp-aff "Failed to add ports to ${bd_a}" \
                "network port broadcast-domain add-ports -ipspace ${ipspace} -broadcast-domain ${bd_a} -ports $(IFS=,; echo "${add_a[*]}")" || return 1
            log_success "  Ports added to ${bd_a}"
        else
            log_success "  Path-A ports already homed in ${bd_a}"
        fi
        if (( ${#add_b[@]} > 0 )); then
            storage_apply netapp-aff "Failed to add ports to ${bd_b}" \
                "network port broadcast-domain add-ports -ipspace ${ipspace} -broadcast-domain ${bd_b} -ports $(IFS=,; echo "${add_b[*]}")" || return 1
            log_success "  Ports added to ${bd_b}"
        else
            log_success "  Path-B ports already homed in ${bd_b}"
        fi

        # Step 4: SVM
        local svm_exists
        svm_exists=$(storage_ssh netapp-aff "vserver show -vserver ${svm} -fields vserver" 2>/dev/null | grep -c "${svm}" || true)
        if [[ "$svm_exists" -gt 0 ]]; then
            log_success "  SVM ${svm} already exists"
        else
            storage_apply netapp-aff "Failed to create SVM ${svm}" \
                "vserver create -vserver ${svm} -ipspace ${ipspace} -rootvolume ${svm}_root -rootvolume-security-style unix" || return 1
            log_success "  SVM ${svm} created"
        fi

        # Step 5: iSCSI service (check independently — may be missing even if SVM exists)
        local iscsi_check
        iscsi_check=$(storage_ssh netapp-aff "vserver iscsi show -vserver ${svm}" 2>/dev/null | grep -c "${svm}" || true)
        if [[ "$iscsi_check" -gt 0 ]]; then
            log_success "  iSCSI service already enabled on ${svm}"
        else
            storage_apply netapp-aff "Failed to enable iSCSI on ${svm}" \
                "vserver iscsi create -vserver ${svm}" || return 1
            log "  iSCSI service enabled on ${svm}"
        fi

        # Step 6: LIFs (check each independently)
        local lif_count
        lif_count=$(storage_ssh netapp-aff "network interface show -vserver ${svm} -fields address" 2>/dev/null | grep -c "iscsi_${cloud_name}" || true)
        if [[ "$lif_count" -ge 4 ]]; then
            log_success "  All 4 LIFs already exist"
            local lif_output
            lif_output=$(storage_ssh netapp-aff "network interface show -vserver ${svm} -fields address,status-oper" 2>/dev/null) || true
            log "  LIF status:"
            echo "$lif_output" | grep -E "iscsi|${cloud_name}" | while IFS= read -r line; do
                log "    $line"
            done || true
        else
            log "  Creating LIFs (found ${lif_count}/4)..."
            netapp_ensure_lif netapp-aff "$svm" "iscsi_${cloud_name}_${node1}_a" \
                "network interface create -vserver ${svm} -lif iscsi_${cloud_name}_${node1}_a -data-protocol iscsi -home-node ${node1} -home-port ${port_a}-${vlanA} -address ${subA}.2 -netmask 255.255.255.0 -status-admin up" || return 1
            netapp_ensure_lif netapp-aff "$svm" "iscsi_${cloud_name}_${node2}_a" \
                "network interface create -vserver ${svm} -lif iscsi_${cloud_name}_${node2}_a -data-protocol iscsi -home-node ${node2} -home-port ${port_a}-${vlanA} -address ${subA}.3 -netmask 255.255.255.0 -status-admin up" || return 1
            netapp_ensure_lif netapp-aff "$svm" "iscsi_${cloud_name}_${node1}_b" \
                "network interface create -vserver ${svm} -lif iscsi_${cloud_name}_${node1}_b -data-protocol iscsi -home-node ${node1} -home-port ${port_b}-${vlanB} -address ${subB}.2 -netmask 255.255.255.0 -status-admin up" || return 1
            netapp_ensure_lif netapp-aff "$svm" "iscsi_${cloud_name}_${node2}_b" \
                "network interface create -vserver ${svm} -lif iscsi_${cloud_name}_${node2}_b -data-protocol iscsi -home-node ${node2} -home-port ${port_b}-${vlanB} -address ${subB}.3 -netmask 255.255.255.0 -status-admin up" || return 1
            log_success "  LIF check complete"
        fi
    fi

    # --- Sub-stage B: Volumes + LUNs (standard ONTAP has both) ---
    log "  [B] Creating volume(s) and LUN(s)..."
    local i
    for (( i=1; i<=LUN_COUNT; i++ )); do
        local vol_name lun_name
        vol_name=$(printf "${cloud_name}_iscsi_lta_ntapaff_vol%02d" "$i")
        lun_name=$(printf "${cloud_name}_lta_ntapaff_lun%02d" "$i")

        local vol_check
        vol_check=$(storage_ssh netapp-aff "volume show -vserver ${svm} -volume ${vol_name} -fields volume" 2>/dev/null | grep -c "${vol_name}" || true)
        if [[ "$vol_check" -gt 0 ]]; then
            log_success "  Volume ${vol_name} already exists"
            # Ensure snapshot reserve is 0 for LUN volumes (may have been created with default 5%)
            if [[ "$DRY_RUN" != "true" ]]; then
                local snap_out="" snap_status=0 snap_line
                snap_out=$(storage_ssh netapp-aff "volume modify -vserver ${svm} -volume ${vol_name} -percent-snapshot-space 0" 2>&1) || snap_status=$?
                if [[ "$snap_status" -ne 0 ]]; then
                    log_warn "  Could not set snapshot reserve to 0 on ${vol_name}"
                    while IFS= read -r snap_line; do
                        [[ -n "$snap_line" ]] && log "    ${snap_line}"
                    done <<< "$snap_out"
                fi
            fi
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would create volume: volume create -vserver ${svm} -volume ${vol_name} -aggregate eng_data_aggr01 -size ${LUN_SIZE} -space-guarantee none -percent-snapshot-space 0"
            else
                storage_apply netapp-aff "Failed to create volume ${vol_name}" \
                    "volume create -vserver ${svm} -volume ${vol_name} -aggregate eng_data_aggr01 -size ${LUN_SIZE} -space-guarantee none -percent-snapshot-space 0" || return 1
                log_success "  Volume ${vol_name} created"
            fi
        fi

        local lun_check
        lun_check=$(storage_ssh netapp-aff "lun show -vserver ${svm} -volume ${vol_name} -lun ${lun_name} -fields lun" 2>/dev/null | grep -c "${lun_name}" || true)
        if [[ "$lun_check" -gt 0 ]]; then
            log_success "  LUN ${lun_name} already exists"
            netapp_log_ostype netapp-aff "LUN ${lun_name}" "lun show -vserver ${svm} -volume ${vol_name} -lun ${lun_name} -fields ostype"
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would create LUN: lun create -vserver ${svm} -volume ${vol_name} -lun ${lun_name} -size ${LUN_SIZE} -ostype ${os_type} -space-reserve disabled"
            else
                storage_apply netapp-aff "Failed to create LUN ${lun_name}" \
                    "lun create -vserver ${svm} -volume ${vol_name} -lun ${lun_name} -size ${LUN_SIZE} -ostype ${os_type} -space-reserve disabled" || return 1
                log_success "  LUN ${lun_name} created (${LUN_SIZE})"
            fi
        fi
    done

    # --- Sub-stage C: igroup ---
    log "  [C] Creating igroup..."
    local ig_name="${cloud_name}_iscsi_ig"
    local ig_check
    ig_check=$(storage_ssh netapp-aff "lun igroup show -vserver ${svm} -igroup ${ig_name}" 2>/dev/null | grep -c "${ig_name}" || true)

    local iqn_list=""
    for pair in "${iqn_pairs[@]}"; do
        local iqn="${pair#*:}"
        [[ -n "$iqn_list" ]] && iqn_list+=","
        iqn_list+="$iqn"
    done

    if [[ "$ig_check" -gt 0 ]]; then
        log_success "  igroup ${ig_name} already exists"
        netapp_log_ostype netapp-aff "igroup ${ig_name}" "lun igroup show -vserver ${svm} -igroup ${ig_name} -fields ostype"
        for pair in "${iqn_pairs[@]}"; do
            local iqn="${pair#*:}"
            local already
            already=$(storage_ssh netapp-aff "lun igroup show -vserver ${svm} -igroup ${ig_name} -fields initiator" 2>/dev/null | grep -c "$iqn" || true)
            if [[ "$already" -eq 0 && "$DRY_RUN" != "true" ]]; then
                storage_apply netapp-aff "Failed to add initiator ${iqn} to ${ig_name}" \
                    "lun igroup add -vserver ${svm} -igroup ${ig_name} -initiator ${iqn}" || return 1
                log "  Added initiator ${iqn} to ${ig_name}"
            fi
        done
    else
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY-RUN] Would create igroup ${ig_name} -ostype ${os_type} with initiators: ${iqn_list}"
        elif [[ -n "$iqn_list" ]]; then
            storage_apply netapp-aff "Failed to create igroup ${ig_name}" \
                "lun igroup create -vserver ${svm} -igroup ${ig_name} -protocol iscsi -ostype ${os_type} -initiator ${iqn_list}" || return 1
            log_success "  igroup ${ig_name} created with ${#iqn_pairs[@]} initiators"
        else
            log_warn "  No IQNs collected — skipping igroup creation"
        fi
    fi

    # --- Sub-stage D: LUN mapping ---
    log "  [D] Mapping LUN(s) to igroup..."
    for (( i=1; i<=LUN_COUNT; i++ )); do
        local vol_name lun_name lun_path
        vol_name=$(printf "${cloud_name}_iscsi_lta_ntapaff_vol%02d" "$i")
        lun_name=$(printf "${cloud_name}_lta_ntapaff_lun%02d" "$i")
        lun_path="/vol/${vol_name}/${lun_name}"
        local lun_id=$(( i - 1 ))

        local map_check
        map_check=$(storage_ssh netapp-aff "lun mapping show -vserver ${svm} -path ${lun_path} -fields igroup" 2>/dev/null | grep -c "${ig_name}" || true)
        if [[ "$map_check" -gt 0 ]]; then
            log_success "  LUN ${lun_path} already mapped to ${ig_name}"
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                log "[DRY-RUN] Would map: lun mapping create -vserver ${svm} -path ${lun_path} -igroup ${ig_name} -lun-id ${lun_id}"
            else
                storage_apply netapp-aff "Failed to map LUN ${lun_path}" \
                    "lun mapping create -vserver ${svm} -path ${lun_path} -igroup ${ig_name} -lun-id ${lun_id}" || return 1
                log_success "  LUN ${lun_path} mapped to ${ig_name} (lun-id ${lun_id})"
            fi
        fi
    done

    log_success "  NetApp AFF A300 storage-setup complete for ${cloud_name}"
}

# True when every portal address has a logged_in iSCSI session.
vmware_portals_logged_in() {
    local text="$1"
    shift
    local addr ip
    for addr in "$@"; do
        ip="${addr%%:*}"
        if ! printf '%s\n' "$text" | awk -v ip="$ip" '
            function ip_re(value,    escaped) {
                escaped = value
                gsub(/\./, "\\.", escaped)
                return "(^|[^0-9])" escaped "([^0-9]|$)"
            }
            BEGIN { ok = 0; cur = 0; re = ip_re(ip) }
            $0 ~ re && $0 ~ /logged_in/ { ok = 1 }
            /^[[:space:]]*RemoteAddress:/ {
                addr = $0
                sub(/^[[:space:]]*RemoteAddress:[[:space:]]*/, "", addr)
                cur = (addr ~ re)
            }
            /^[[:space:]]*State:/ {
                if (cur && $0 ~ /logged_in/) ok = 1
                cur = 0
            }
            END { exit ok ? 0 : 1 }
        '; then
            return 1
        fi
    done
}

# Add missing send targets, rediscover once, then wait for logged_in.
# Dry-run logs the add and rediscover commands and does not run them.
# Rediscover holds this host's iSCSI command path until ESXi finishes.
# The client waits VMWARE_REDISCOVER_TIMEOUT seconds. If that client times
# out, poll iscsi adapter get and then read the session list once.
# logged_in on every portal is success. A host whose adapter does not
# answer is not rediscovered. This function rediscovers a host at most
# once and returns 1 on failure. The caller keeps going.
vmware_discover_host() {
    local ipath="$1"
    shift
    local -a addrs=("$@")
    local adapter="$VMWARE_ISCSI_ADAPTER"

    log ""
    log "  === ESXi discovery on ${ipath} ==="

    if (( ${#addrs[@]} == 0 )); then
        log_error "  ${ipath}: no portal addresses to discover"
        return 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        local addr
        for addr in "${addrs[@]}"; do
            vmware_esxcli write "$ipath" iscsi adapter discovery sendtarget add -A "$adapter" -a "$addr"
        done
        vmware_esxcli write "$ipath" iscsi adapter discovery rediscover -A "$adapter"
        return 0
    fi

    local ag_out="" ag_status=0
    ag_out=$(vmware_iscsi_timeout "$VMWARE_ADAPTER_GET_TIMEOUT" "$ipath" iscsi adapter get -A "$adapter" 2>&1) || ag_status=$?
    if [[ "$ag_status" -ne 0 ]]; then
        if [[ "$ag_status" -eq 124 ]]; then
            log_error "  ${ipath}: iscsi adapter get did not return within ${VMWARE_ADAPTER_GET_TIMEOUT}s; not running rediscover"
        else
            log_error "  ${ipath}: iscsi adapter get failed; not running rediscover: $(printf '%s\n' "$ag_out" | vmware_redact)"
        fi
        return 1
    fi

    local list_out="" list_status=0
    list_out=$(vmware_iscsi_timeout "$VMWARE_SENDTARGET_LIST_TIMEOUT" "$ipath" iscsi adapter discovery sendtarget list -A "$adapter" 2>&1) || list_status=$?
    if [[ "$list_status" -ne 0 ]]; then
        if [[ "$list_status" -eq 124 ]]; then
            log_error "  ${ipath}: sendtarget list did not return within ${VMWARE_SENDTARGET_LIST_TIMEOUT}s"
        else
            log_error "  ${ipath}: sendtarget list failed: $(printf '%s\n' "$list_out" | vmware_redact)"
        fi
        return 1
    fi

    local addr
    for addr in "${addrs[@]}"; do
        if printf '%s\n' "$list_out" | grep -F -q -- "$addr"; then
            log "  ${ipath}: send target ${addr} already listed"
            continue
        fi
        local add_out="" add_status=0
        add_out=$(vmware_esxcli_bounded "$VMWARE_SENDTARGET_ADD_TIMEOUT" "$ipath" iscsi adapter discovery sendtarget add -A "$adapter" -a "$addr" 2>&1) || add_status=$?
        if [[ "$add_status" -eq 0 ]]; then
            log_success "  ${ipath}: added send target ${addr}"
            continue
        fi
        if [[ -n "$add_out" ]]; then
            log "    ${add_out}"
        fi
        local again
        again=$(vmware_iscsi_timeout "$VMWARE_SENDTARGET_LIST_TIMEOUT" "$ipath" iscsi adapter discovery sendtarget list -A "$adapter" 2>&1 || true)
        if printf '%s\n' "$again" | grep -F -q -- "$addr"; then
            log_success "  ${ipath}: send target ${addr} already listed"
            continue
        fi
        if [[ "$add_status" -eq 124 ]]; then
            log_error "  ${ipath}: sendtarget add did not return within ${VMWARE_SENDTARGET_ADD_TIMEOUT}s"
        else
            log_error "  ${ipath}: failed to add send target ${addr}"
        fi
        return 1
    done

    local rd_out="" rd_status=0 rd_line
    rd_out=$(vmware_esxcli_bounded "$VMWARE_REDISCOVER_TIMEOUT" "$ipath" iscsi adapter discovery rediscover -A "$adapter" 2>&1) || rd_status=$?
    while IFS= read -r rd_line; do
        [[ -n "$rd_line" ]] && log "    ${rd_line}"
    done <<< "$rd_out"
    if [[ "$rd_status" -eq 124 ]]; then
        log_warn "  ${ipath}: rediscover did not return within ${VMWARE_REDISCOVER_TIMEOUT}s; waiting for the iSCSI adapter"
        local poll_start=$SECONDS ready=0 poll_status sessions="" sess_status
        while (( SECONDS - poll_start < VMWARE_ADAPTER_POLL_WINDOW )); do
            poll_status=0
            vmware_iscsi_timeout "$VMWARE_ADAPTER_GET_TIMEOUT" "$ipath" iscsi adapter get -A "$adapter" >/dev/null 2>&1 || poll_status=$?
            if [[ "$poll_status" -eq 0 ]]; then
                ready=1
                break
            fi
            if (( SECONDS - poll_start >= VMWARE_ADAPTER_POLL_WINDOW )); then
                break
            fi
            sleep "$VMWARE_ADAPTER_POLL_INTERVAL"
        done
        if [[ "$ready" -ne 1 ]]; then
            log_error "  ${ipath}: iscsi adapter get did not return after rediscover; not reading sessions"
            return 1
        fi
        sess_status=0
        sessions=$(vmware_iscsi_timeout "$VMWARE_SESSION_LIST_TIMEOUT" "$ipath" iscsi session connection list 2>&1) || sess_status=$?
        if [[ "$sess_status" -eq 0 ]] && vmware_portals_logged_in "$sessions" "${addrs[@]}"; then
            log_success "  ${ipath}: logged_in to ${addrs[*]}"
            return 0
        fi
        log_error "  ${ipath}: rediscover client timed out and sessions are not logged_in"
        return 1
    fi
    if [[ "$rd_status" -ne 0 ]]; then
        log_error "  ${ipath}: rediscover failed"
        return 1
    fi

    local start=$SECONDS sessions="" sess_status
    while true; do
        sess_status=0
        sessions=$(vmware_iscsi_timeout "$VMWARE_SESSION_LIST_TIMEOUT" "$ipath" iscsi session connection list 2>&1) || sess_status=$?
        if [[ "$sess_status" -eq 0 ]] && vmware_portals_logged_in "$sessions" "${addrs[@]}"; then
            log_success "  ${ipath}: logged_in to ${addrs[*]}"
            return 0
        fi
        if (( SECONDS - start >= 60 )); then
            log_error "  ${ipath}: timed out after 60s waiting for logged_in sessions"
            return 1
        fi
        sleep 5
    done
}

storage_discovery_vmware() {
    vmware_preflight || return 1

    local hosts_out="" sel_status=0
    hosts_out=$(vmware_selected_hosts) || sel_status=$?
    if [[ "$sel_status" -ne 0 || -z "$hosts_out" ]]; then
        return 1
    fi

    local -a selected=()
    mapfile -t selected <<< "$hosts_out"

    local failed=0 ipath
    local -a pids=()
    for ipath in "${selected[@]}"; do
        vmware_discover_host "$ipath" "$@" &
        pids+=("$!")
        if (( ${#pids[@]} >= VMWARE_JOB_PARALLEL )); then
            vmware_wait_pids "${pids[@]}"
            if [[ "$VMW_WAIT_FAILED" -gt 0 ]]; then
                failed=1
            fi
            pids=()
        fi
    done
    if (( ${#pids[@]} > 0 )); then
        vmware_wait_pids "${pids[@]}"
        if [[ "$VMW_WAIT_FAILED" -gt 0 ]]; then
            failed=1
        fi
    fi
    if [[ "$failed" -ne 0 ]]; then
        return 1
    fi
}

# =============================================================================
# STORAGE-SETUP: iSCSI Discovery + Login + Validation (Sub-stage E)
# =============================================================================
storage_discovery_and_verify() {
    local cloud_name="$1"
    shift
    local -a vendors_to_discover=("$@")

    log ""
    log "--- Sub-stage E: iSCSI discovery + login + verification ---"

    # Collect portal IPs per vendor (.2 and .3 for dual-controller arrays like IBM)
    declare -A vendor_portals
    while read -r _nic vlan_id subnet_base vendor path; do
        for last_octet in 2 3; do
            local portal_ip="${subnet_base}.${last_octet}"
            if [[ -n "${vendor_portals[$vendor]:-}" ]]; then
                # Avoid duplicates (same IP from different layout entries)
                [[ " ${vendor_portals[$vendor]} " == *" ${portal_ip} "* ]] && continue
                vendor_portals[$vendor]+=" ${portal_ip}"
            else
                vendor_portals[$vendor]="$portal_ip"
            fi
        done
    done < <(compute_vlan_layout)

    if [[ "$TARGET_TYPE" == "vmware" ]]; then
        local -a portal_addrs=()
        local vendor portal_ip
        for vendor in "${vendors_to_discover[@]}"; do
            for portal_ip in ${vendor_portals[$vendor]:-}; do
                portal_addrs+=("${portal_ip}:3260")
            done
        done
        storage_discovery_vmware "${portal_addrs[@]}" || return 1
        return 0
    fi

    # Get OCP worker list
    local -a workers=()
    if [[ "$TARGET_TYPE" == "ocp" ]]; then
        if command -v oc &>/dev/null; then
            mapfile -t workers < <(oc get nodes -l node-role.kubernetes.io/worker --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)
        fi
    fi

    if (( ${#workers[@]} == 0 )); then
        log_warn "  No workers found for discovery. Skipping Sub-stage E."
        return 0
    fi

    # Run discovery on each worker for each vendor's portals
    for node in "${workers[@]}"; do
        if [[ -n "$SINGLE_WORKER" && "$node" != *"$SINGLE_WORKER"* ]]; then
            continue
        fi

        log ""
        log "  === Discovery on ${node} ==="

        for vendor in "${vendors_to_discover[@]}"; do
            local portals="${vendor_portals[$vendor]:-}"
            if [[ -z "$portals" ]]; then
                continue
            fi

            local vendor_name="${PLATFORM_NAMES[$vendor]:-$vendor}"
            log "    ${vendor_name} portals: ${portals}"

            for portal_ip in $portals; do
                if [[ "$DRY_RUN" == "true" ]]; then
                    log "    [DRY-RUN] Would discover: iscsiadm -m discovery -t st -p ${portal_ip}"
                    continue
                fi

                local disc_out
                disc_out=$(run_on_host "$node" "iscsiadm -m discovery -t st -p ${portal_ip} 2>&1" 2>/dev/null) || true
                if [[ -n "$disc_out" && "$disc_out" != *"error"* && "$disc_out" != *"No portals"* ]]; then
                    log_success "    Discovery on ${portal_ip}: targets found"
                    echo "$disc_out" | head -5 | while IFS= read -r line; do
                        log "      $line"
                    done
                else
                    log_warn "    Discovery on ${portal_ip}: no targets (portals may not be ready)"
                fi
            done
        done

        # Login to all discovered targets
        if [[ "$DRY_RUN" != "true" ]]; then
            log "    Logging in to all discovered targets..."
            run_on_host "$node" "iscsiadm -m node --login 2>/dev/null || true" 2>/dev/null || true
            log "    Waiting 10s for paths to settle..."
            sleep 10
        fi
    done

    # Verification: multipath
    log ""
    log "  === Multipath Verification ==="
    log ""
    printf "  %-25s %-15s %-40s %-8s %-8s\n" "Worker" "Vendor" "LUN" "Paths" "Status"
    printf "  %-25s %-15s %-40s %-8s %-8s\n" "-------------------------" "---------------" "----------------------------------------" "--------" "--------"

    for node in "${workers[@]}"; do
        if [[ -n "$SINGLE_WORKER" && "$node" != *"$SINGLE_WORKER"* ]]; then
            continue
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            for vendor in "${vendors_to_discover[@]}"; do
                printf "  %-25s %-15s %-40s %-8s %-8s\n" "$node" "$vendor" "(dry-run)" "N/A" "DRY-RUN"
            done
            continue
        fi

        local mpath_out
        mpath_out=$(run_on_host "$node" "multipath -ll 2>/dev/null" 2>/dev/null) || mpath_out=""

        for vendor in "${vendors_to_discover[@]}"; do
            local vendor_name="${PLATFORM_NAMES[$vendor]:-$vendor}"
            local vendor_pattern=""
            case "$vendor" in
                ibm)        vendor_pattern="IBM,2145" ;;
                pure)       vendor_pattern="PURE,FlashArray" ;;
                netapp-asa) vendor_pattern="NETAPP,LUN" ;;
                netapp-aff) vendor_pattern="NETAPP,LUN" ;;
            esac

            # Count either header shape: a raw WWID, or an mpath alias
            # with the WWID in parentheses. Path lines are the H:C:T:L rows
            # under that device, until the next header.
            local lun_count path_count
            read -r lun_count path_count < <(awk -v pat="$vendor_pattern" '
                function header(line) { return line ~ "^[^[:space:]].* dm-[0-9]+ " }
                header($0) && $0 ~ pat { luns++; current = 1; next }
                header($0) { current = 0; next }
                current && $0 ~ /[0-9]+:[0-9]+:[0-9]+:[0-9]+/ { paths++ }
                END { print luns + 0, paths + 0 }
            ' <<< "$mpath_out")

            local status="OK"
            if [[ "$lun_count" -eq 0 || "$path_count" -eq 0 ]]; then
                status="NO_PATHS"
            fi

            printf "  %-25s %-15s %-40s %-8s %-8s\n" "$node" "$vendor_name" "${lun_count} LUN(s)" "${path_count}" "$status"
        done
    done
    log ""
}

# =============================================================================
# STAGE: storage-setup (orchestrator)
# =============================================================================
do_storage_setup() {
    log "=== STAGE: storage-setup ==="

    if [[ -z "$STORAGE_ARRAYS" ]]; then
        log_error "STORAGE_ARRAYS not set. Cannot configure storage."
        return 1
    fi

    # Pre-populate bws credential cache so $() subshells inherit it
    if [[ "$DRY_RUN" != "true" ]]; then
        bws_load_cache || return 1
        log "Credential cache loaded (${#_BWS_CACHE} bytes, storage credentials only)"
    fi

    local cloud_name="cloud$(printf '%02d' "$CLOUD_ID")"
    local cloud_nn=$(printf '%02d' "$CLOUD_ID")

    log "Volume/LUN configuration: size=${LUN_SIZE}, count=${LUN_COUNT}"
    log ""

    # Collect IQNs from workers. VMware reads govc on a dry-run too.
    # OCP and bare dry-runs keep the placeholder and do not touch a host.
    log "Collecting iSCSI initiator IQNs from workers..."
    local -a iqn_pairs=()
    local collect_partial=0
    if [[ "$DRY_RUN" == "true" && "$TARGET_TYPE" != "vmware" ]]; then
        log "[DRY-RUN] Would collect IQNs from workers via oc debug"
        iqn_pairs=("worker-dry-run:iqn.2026-01.com.example:dry-run")
    else
        local iqn_output="" collect_status=0 pair
        iqn_output=$(collect_worker_iqns) || collect_status=$?
        if [[ "$collect_status" -eq 2 ]]; then
            collect_partial=1
        elif [[ "$collect_status" -ne 0 ]]; then
            log_error "Failed to collect iSCSI initiator IQNs"
            return 1
        fi
        if [[ -n "$iqn_output" ]]; then
            mapfile -t iqn_pairs <<< "$iqn_output"
        fi
        local -a kept=()
        if (( ${#iqn_pairs[@]} > 0 )); then
            for pair in "${iqn_pairs[@]}"; do
                [[ -n "$pair" ]] && kept+=("$pair")
            done
        fi
        iqn_pairs=()
        if (( ${#kept[@]} > 0 )); then
            iqn_pairs=("${kept[@]}")
        fi
        if (( ${#iqn_pairs[@]} == 0 )); then
            log_error "No iSCSI initiator IQNs collected"
            return 1
        fi
    fi
    log "Collected ${#iqn_pairs[@]} IQN(s)"
    log ""

    local -a vendors_arr
    read -r -a vendors_arr <<< "$STORAGE_ARRAYS"

    # A failed vendor does not skip the vendors after it. Sub-stage E
    # receives only the vendors that returned 0.
    local setup_failed=$collect_partial
    local -a discover_vendors=()
    local vendor vendor_rc
    for vendor in "${vendors_arr[@]}"; do
        vendor_rc=0
        case "$vendor" in
            netapp-asa)  storage_setup_netapp_asa  "$cloud_name" "$cloud_nn" "${iqn_pairs[@]}" || vendor_rc=$? ;;
            pure)        storage_setup_pure         "$cloud_name" "$cloud_nn" "${iqn_pairs[@]}" || vendor_rc=$? ;;
            ibm)         storage_setup_ibm          "$cloud_name" "$cloud_nn" "${iqn_pairs[@]}" || vendor_rc=$? ;;
            netapp-aff)  storage_setup_netapp_aff  "$cloud_name" "$cloud_nn" "${iqn_pairs[@]}" || vendor_rc=$? ;;
            *)           log_warn "Unknown vendor '${vendor}' — skipping storage-setup"; continue ;;
        esac
        if [[ "$vendor_rc" -ne 0 ]]; then
            setup_failed=1
        else
            discover_vendors+=("$vendor")
        fi
    done

    if (( ${#discover_vendors[@]} > 0 )); then
        storage_discovery_and_verify "$cloud_name" "${discover_vendors[@]}" || setup_failed=1
    fi

    log ""
    if [[ "$setup_failed" -ne 0 ]]; then
        log_error "=== storage-setup incomplete ==="
        return 1
    fi
    log_success "=== storage-setup complete ==="
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

    local json=""
    if [[ "$TARGET_TYPE" != "vmware" ]]; then
        json=$(quads_query_hosts) || return 1
    fi

    # Build list of portal IPs to check (first portal IP per path: .2)
    local -a portal_ips=()
    compute_vlan_layout | while read -r bios_nic vlan_id subnet_base vendor path; do
        echo "${subnet_base}.2"
    done | sort -u > /tmp/_portal_ips_$$
    mapfile -t portal_ips < /tmp/_portal_ips_$$
    rm -f /tmp/_portal_ips_$$

    log "Portal IPs to check: ${portal_ips[*]}"

    # OCP uses worker node names. VMware pings through govc. Bare metal uses QUADS hosts.
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
    elif [[ "$TARGET_TYPE" == "vmware" ]]; then
        vmware_preflight || return 1
        local hosts_out="" sel_status=0
        hosts_out=$(vmware_selected_hosts) || sel_status=$?
        if [[ "$sel_status" -ne 0 || -z "$hosts_out" ]]; then
            return 1
        fi
        local ipath portal_ip ping_out ping_rc
        while IFS= read -r ipath; do
            [[ -z "$ipath" ]] && continue
            log "  Checking ${ipath}..."
            for portal_ip in "${portal_ips[@]}"; do
                if [[ "$DRY_RUN" == "true" ]]; then
                    log "    [DRY-RUN] Would ping ${portal_ip} from ${ipath}"
                    continue
                fi
                ping_rc=0
                ping_out=$(timeout 30 govc host.esxcli -host.ipath "$ipath" network diag ping -c 2 -W 3 -H "$portal_ip" 2>&1) || ping_rc=$?
                if [[ "$ping_rc" -eq 0 ]] && printf '%s\n' "$ping_out" | grep -Eq 'Re(ce|cie)ived:[[:space:]]*[1-9]'; then
                    log_success "    ${portal_ip}: reachable"
                else
                    log_warn "    ${portal_ip}: ping failed ($(printf '%s\n' "$ping_out" | vmware_redact | tr '\n' ' '))"
                fi
            done
        done <<< "$hosts_out"
        return 0
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
            collect|verify|jira-draft|host-setup|storage-setup|check|all)
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
        collect)       do_collect ;;
        verify)        do_verify ;;
        jira-draft)    do_jira_draft ;;
        host-setup)    do_host_setup ;;
        storage-setup) do_storage_setup ;;
        check)         do_check ;;
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
