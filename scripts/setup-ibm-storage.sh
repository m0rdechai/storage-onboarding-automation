#!/bin/bash
#
# setup-ibm-storage.sh
# 
# Automates IBM storage configuration on OpenShift worker nodes:
# - Verifies MTU 9000 on storage interfaces
# - Tests connectivity to storage IPs
# - Configures multipath for IBM 2145 devices
# - Runs iSCSI discovery
# - Restarts required services
# - Verifies IBM LUN visibility
#

set -o pipefail

# =============================================================================
# Configuration Variables
# =============================================================================
STORAGE_IPS=("192.168.200.10" "192.168.201.10" "192.168.20.10" "192.168.21.10")
SSH_USER="core"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
ISCSI_DISCOVERY_TARGET="192.168.20.10"

# Script options
DRY_RUN=false
VERBOSE=false
SINGLE_WORKER=""
LOG_DIR="/home/kni/MTV/logs"
LOG_FILE=""

# IBM multipath configuration block
IBM_DEVICE_CONFIG='devices {
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

# Result tracking arrays
declare -A RESULTS_MTU
declare -A RESULTS_PING
declare -A RESULTS_MULTIPATH_CONFIG
declare -A RESULTS_ISCSI
declare -A RESULTS_SERVICES
declare -A RESULTS_LUN

# =============================================================================
# Utility Functions
# =============================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Configure IBM storage on OpenShift worker nodes.

Options:
    -n          Dry-run mode: show what would be done without making changes
    -w <ip>     Single-node mode: run on specific worker IP only
    -v          Verbose mode: show detailed SSH output
    -h          Show this help message

Examples:
    $(basename "$0")                    # Run on all workers
    $(basename "$0") -n                 # Dry-run on all workers
    $(basename "$0") -w 10.0.1.5        # Run on specific worker
    $(basename "$0") -v -w 10.0.1.5     # Verbose mode on specific worker

EOF
    exit 0
}

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >&2
    if [[ -n "$LOG_FILE" ]]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        log "[VERBOSE] $*"
    fi
}

log_error() {
    log "[ERROR] $*"
}

log_success() {
    log "[SUCCESS] $*"
}

log_warn() {
    log "[WARNING] $*"
}

run_ssh() {
    local worker_ip="$1"
    shift
    local cmd="$*"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would execute on $worker_ip: $cmd"
        return 0
    fi
    
    log_verbose "Executing on $worker_ip: $cmd"
    
    local output
    local rc
    output=$(ssh $SSH_OPTS "${SSH_USER}@${worker_ip}" "$cmd" 2>&1)
    rc=$?
    
    if [[ "$VERBOSE" == "true" ]] && [[ -n "$output" ]]; then
        echo "$output" | while IFS= read -r line; do
            log_verbose "  $line"
        done
    fi
    
    echo "$output"
    return $rc
}

# =============================================================================
# Worker Node Discovery
# =============================================================================

get_worker_ips() {
    log "Discovering worker node IPs from OpenShift cluster..."
    
    if ! command -v oc &> /dev/null; then
        log_error "'oc' command not found. Please ensure OpenShift CLI is installed and in PATH."
        exit 1
    fi
    
    local worker_ips
    worker_ips=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>&1)
    
    if [[ $? -ne 0 ]] || [[ -z "$worker_ips" ]]; then
        log_error "Failed to get worker node IPs from cluster: $worker_ips"
        exit 1
    fi
    
    echo "$worker_ips"
}

# =============================================================================
# Configuration Check Functions
# =============================================================================

check_mtu() {
    local worker_ip="$1"
    log "  Checking MTU 9000 on 192.168.x.x interfaces..."
    
    local output
    output=$(run_ssh "$worker_ip" "ip addr show | grep -B2 'inet 192\\.168\\.' | grep -E 'mtu [0-9]+' | awk '{for(i=1;i<=NF;i++) if(\$i==\"mtu\") print \$(i+1)}'")
    local rc=$?
    
    if [[ "$DRY_RUN" == "true" ]]; then
        RESULTS_MTU[$worker_ip]="DRY-RUN"
        return 0
    fi
    
    if [[ $rc -ne 0 ]] || [[ -z "$output" ]]; then
        log_warn "  Could not find interfaces with 192.168.x.x IPs or check MTU"
        RESULTS_MTU[$worker_ip]="FAIL"
        return 1
    fi
    
    # Check if all MTUs are 9000
    local all_9000=true
    while IFS= read -r mtu; do
        if [[ "$mtu" != "9000" ]]; then
            log_warn "  Found interface with MTU $mtu (expected 9000)"
            all_9000=false
        fi
    done <<< "$output"
    
    if [[ "$all_9000" == "true" ]]; then
        log_success "  MTU 9000 verified on all 192.168.x.x interfaces"
        RESULTS_MTU[$worker_ip]="PASS"
        return 0
    else
        RESULTS_MTU[$worker_ip]="FAIL"
        return 1
    fi
}

check_ping() {
    local worker_ip="$1"
    log "  Testing connectivity to storage IPs..."
    
    local all_pass=true
    local ping_results=""
    
    for storage_ip in "${STORAGE_IPS[@]}"; do
        local output
        output=$(run_ssh "$worker_ip" "ping -c 2 -W 3 $storage_ip" 2>&1)
        local rc=$?
        
        if [[ "$DRY_RUN" == "true" ]]; then
            ping_results+="${storage_ip}:DRY-RUN "
            continue
        fi
        
        if [[ $rc -eq 0 ]]; then
            log_success "  Ping to $storage_ip: OK"
            ping_results+="${storage_ip}:PASS "
        else
            log_warn "  Ping to $storage_ip: FAILED"
            ping_results+="${storage_ip}:FAIL "
            all_pass=false
        fi
    done
    
    RESULTS_PING[$worker_ip]="$ping_results"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        return 0
    fi
    
    if [[ "$all_pass" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

update_multipath_conf() {
    local worker_ip="$1"
    log "  Checking/updating multipath.conf..."
    
    # First check if IBM config already exists
    local check_output
    check_output=$(run_ssh "$worker_ip" "grep -q 'vendor.*\"IBM\"' /etc/multipath.conf 2>/dev/null && echo 'EXISTS' || echo 'NOT_FOUND'")
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would check and potentially update /etc/multipath.conf"
        RESULTS_MULTIPATH_CONFIG[$worker_ip]="DRY-RUN"
        return 0
    fi
    
    if [[ "$check_output" == "EXISTS" ]]; then
        log "  IBM device configuration already exists in multipath.conf"
        RESULTS_MULTIPATH_CONFIG[$worker_ip]="EXISTS"
        return 0
    fi
    
    # Add IBM device configuration BEFORE the blacklist section
    log "  Adding IBM device configuration to multipath.conf (before blacklist section)..."
    
    # Write the IBM config to a temp file on the remote host, then use awk to insert before blacklist
    local add_output
    add_output=$(ssh $SSH_OPTS "${SSH_USER}@${worker_ip}" bash -s <<'REMOTE_SCRIPT'
set -e

# Create the IBM config in a temp file
cat > /tmp/ibm_device_config.txt <<'EOFCONFIG'
devices {
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
}
EOFCONFIG

# Backup original file
sudo cp /etc/multipath.conf /etc/multipath.conf.bak

# Check if blacklist section exists and insert config before it
if grep -q '^blacklist' /etc/multipath.conf; then
    # Use awk to insert the IBM config before blacklist section
    sudo awk '
        /^blacklist/ {
            while ((getline line < "/tmp/ibm_device_config.txt") > 0) {
                print line
            }
            print ""
        }
        { print }
    ' /etc/multipath.conf.bak | sudo tee /etc/multipath.conf > /dev/null
else
    # No blacklist section, append at the end
    cat /tmp/ibm_device_config.txt | sudo tee -a /etc/multipath.conf > /dev/null
fi

rm -f /tmp/ibm_device_config.txt
echo "SUCCESS"
REMOTE_SCRIPT
)
    
    if [[ "$add_output" == *"SUCCESS"* ]]; then
        log_success "  IBM device configuration added to multipath.conf"
        RESULTS_MULTIPATH_CONFIG[$worker_ip]="ADDED"
        return 0
    else
        log_error "  Failed to update multipath.conf: $add_output"
        RESULTS_MULTIPATH_CONFIG[$worker_ip]="FAIL"
        return 1
    fi
}

run_iscsi_discovery() {
    local worker_ip="$1"
    log "  Running iSCSI discovery on $ISCSI_DISCOVERY_TARGET..."
    
    local output
    output=$(run_ssh "$worker_ip" "sudo iscsiadm -m discovery -t st -p $ISCSI_DISCOVERY_TARGET")
    local rc=$?
    
    if [[ "$DRY_RUN" == "true" ]]; then
        RESULTS_ISCSI[$worker_ip]="DRY-RUN"
        return 0
    fi
    
    if [[ $rc -eq 0 ]]; then
        log_success "  iSCSI discovery completed successfully"
        log_verbose "  Discovery results: $output"
        RESULTS_ISCSI[$worker_ip]="PASS"
        return 0
    else
        log_error "  iSCSI discovery failed"
        log_verbose "  Error: $output"
        RESULTS_ISCSI[$worker_ip]="FAIL"
        return 1
    fi
}

restart_services() {
    local worker_ip="$1"
    log "  Restarting iscsi and multipathd services..."
    
    local output
    output=$(run_ssh "$worker_ip" "sudo systemctl restart iscsi multipathd && echo 'OK' || echo 'FAILED'")
    
    if [[ "$DRY_RUN" == "true" ]]; then
        RESULTS_SERVICES[$worker_ip]="DRY-RUN"
        return 0
    fi
    
    if [[ "$output" == *"OK"* ]]; then
        log_success "  Services restarted successfully"
        RESULTS_SERVICES[$worker_ip]="PASS"
        
        # Give services time to initialize
        log "  Waiting 5 seconds for services to initialize..."
        sleep 5
        return 0
    else
        log_error "  Failed to restart services"
        RESULTS_SERVICES[$worker_ip]="FAIL"
        return 1
    fi
}

verify_multipath() {
    local worker_ip="$1"
    log "  Verifying IBM LUN visibility..."
    
    local output
    output=$(run_ssh "$worker_ip" "sudo multipath -ll 2>/dev/null | grep -A5 'IBM,2145'")
    local rc=$?
    
    if [[ "$DRY_RUN" == "true" ]]; then
        RESULTS_LUN[$worker_ip]="DRY-RUN"
        return 0
    fi
    
    if [[ $rc -eq 0 ]] && [[ -n "$output" ]]; then
        log_success "  IBM LUN detected in multipath output"
        log_verbose "  Multipath details:"
        echo "$output" | while IFS= read -r line; do
            log_verbose "    $line"
        done
        RESULTS_LUN[$worker_ip]="YES"
        return 0
    else
        log_warn "  No IBM LUN found in multipath output (may appear after LUN mapping)"
        RESULTS_LUN[$worker_ip]="NO"
        return 1
    fi
}

# =============================================================================
# Report Generation
# =============================================================================

print_summary_report() {
    local workers=("$@")
    
    log ""
    log "============================================================================="
    log "                         IBM STORAGE SETUP SUMMARY                          "
    log "============================================================================="
    log ""
    
    # Calculate column widths
    printf "%-20s | %-8s | %-40s | %-12s | %-8s | %-10s | %-8s\n" \
        "Worker IP" "MTU" "Ping Tests" "Multipath" "iSCSI" "Services" "IBM LUN" >&2
    printf "%-20s-+-%-8s-+-%-40s-+-%-12s-+-%-8s-+-%-10s-+-%-8s\n" \
        "--------------------" "--------" "----------------------------------------" \
        "------------" "--------" "----------" "--------" >&2
    
    for worker_ip in "${workers[@]}"; do
        local mtu_result="${RESULTS_MTU[$worker_ip]:-N/A}"
        local ping_result="${RESULTS_PING[$worker_ip]:-N/A}"
        local multipath_result="${RESULTS_MULTIPATH_CONFIG[$worker_ip]:-N/A}"
        local iscsi_result="${RESULTS_ISCSI[$worker_ip]:-N/A}"
        local services_result="${RESULTS_SERVICES[$worker_ip]:-N/A}"
        local lun_result="${RESULTS_LUN[$worker_ip]:-N/A}"
        
        # Truncate ping results if too long
        if [[ ${#ping_result} -gt 40 ]]; then
            ping_result="${ping_result:0:37}..."
        fi
        
        printf "%-20s | %-8s | %-40s | %-12s | %-8s | %-10s | %-8s\n" \
            "$worker_ip" "$mtu_result" "$ping_result" "$multipath_result" \
            "$iscsi_result" "$services_result" "$lun_result" >&2
    done
    
    log ""
    log "============================================================================="
    log ""
    
    # Detailed ping results
    log "Detailed Ping Results:"
    log "-----------------------"
    for worker_ip in "${workers[@]}"; do
        log "  $worker_ip:"
        local ping_result="${RESULTS_PING[$worker_ip]:-N/A}"
        for pair in $ping_result; do
            local ip="${pair%%:*}"
            local status="${pair##*:}"
            log "    - $ip: $status"
        done
    done
    
    log ""
    if [[ -n "$LOG_FILE" ]]; then
        log "Full log saved to: $LOG_FILE"
    fi
}

# =============================================================================
# Main Processing Function
# =============================================================================

process_worker() {
    local worker_ip="$1"
    
    log ""
    log "=== Processing worker: $worker_ip ==="
    log ""
    
    # Test SSH connectivity first
    if [[ "$DRY_RUN" != "true" ]]; then
        log "  Testing SSH connectivity..."
        if ! ssh $SSH_OPTS "${SSH_USER}@${worker_ip}" "echo 'SSH OK'" &>/dev/null; then
            log_error "  Cannot SSH to $worker_ip - skipping this worker"
            RESULTS_MTU[$worker_ip]="SSH_FAIL"
            RESULTS_PING[$worker_ip]="SSH_FAIL"
            RESULTS_MULTIPATH_CONFIG[$worker_ip]="SSH_FAIL"
            RESULTS_ISCSI[$worker_ip]="SSH_FAIL"
            RESULTS_SERVICES[$worker_ip]="SSH_FAIL"
            RESULTS_LUN[$worker_ip]="SSH_FAIL"
            return 1
        fi
        log_success "  SSH connection established"
    fi
    
    # Step 1: Check MTU 9000
    check_mtu "$worker_ip"
    
    # Step 2: Ping storage IPs
    check_ping "$worker_ip"
    
    # Step 3: Update multipath.conf (check if IBM config exists first)
    update_multipath_conf "$worker_ip"
    
    # Step 4: iSCSI discovery
    run_iscsi_discovery "$worker_ip"
    
    # Step 5: Restart services
    restart_services "$worker_ip"
    
    # Step 6: Verify multipath
    verify_multipath "$worker_ip"
    
    log ""
    log "=== Completed processing: $worker_ip ==="
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
    # Parse command line arguments
    while getopts "nvw:h" opt; do
        case $opt in
            n)
                DRY_RUN=true
                ;;
            v)
                VERBOSE=true
                ;;
            w)
                SINGLE_WORKER="$OPTARG"
                ;;
            h)
                usage
                ;;
            \?)
                echo "Invalid option: -$OPTARG" >&2
                usage
                ;;
        esac
    done
    
    # Setup logging
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    if [[ -d "$LOG_DIR" ]]; then
        LOG_FILE="${LOG_DIR}/ibm-storage-setup_$(date '+%Y%m%d_%H%M%S').log"
    fi
    
    log "============================================================================="
    log "           IBM Storage Setup Script - $(date)"
    log "============================================================================="
    log ""
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN MODE] No changes will be made"
        log ""
    fi
    
    if [[ "$VERBOSE" == "true" ]]; then
        log "[VERBOSE MODE] Detailed output enabled"
        log ""
    fi
    
    # Get worker IPs
    local worker_ips_string
    if [[ -n "$SINGLE_WORKER" ]]; then
        log "Single-node mode: targeting $SINGLE_WORKER only"
        worker_ips_string="$SINGLE_WORKER"
    else
        worker_ips_string=$(get_worker_ips)
    fi
    
    # Convert to array
    read -r -a worker_ips <<< "$worker_ips_string"
    
    if [[ ${#worker_ips[@]} -eq 0 ]]; then
        log_error "No worker nodes found!"
        exit 1
    fi
    
    log "Found ${#worker_ips[@]} worker node(s): ${worker_ips[*]}"
    log ""
    log "Storage targets: ${STORAGE_IPS[*]}"
    log ""
    
    # Process each worker
    for worker_ip in "${worker_ips[@]}"; do
        process_worker "$worker_ip"
    done
    
    # Print summary report
    print_summary_report "${worker_ips[@]}"
    
    log "IBM Storage Setup Script completed."
}

# Run main function
main "$@"
