#!/usr/bin/env bash
#
# storage-lta-subnet-calc.sh — VLAN/subnet/IP calculator for the Storage LTA
#
# Implements the formulas from vlan-ip-convention.md §1-2 (sourced from
# "Storage Network Changes.md"):
#
#   VLAN   = storage_digit(1-8) x 100 + cloud_id(01-99)
#   Subnet = 172.(15 + storage_digit).(100 + cloud_id).0/24
#
# Each storage platform owns two consecutive storage digits (path A = the
# lower/odd digit, path B = the higher/even digit). Given a cloud ID, this
# prints the full VLAN/subnet/IP breakdown for all four storage arrays x
# both multipath legs — no lookup table, no manual arithmetic.
#
# Usage:
#   ./storage-lta-subnet-calc.sh [cloud_id]        human-readable report
#   ./storage-lta-subnet-calc.sh --dnsmasq [cloud_id]   dnsmasq.conf stanzas
#   ./storage-lta-subnet-calc.sh -h|--help
#
# If cloud_id is omitted, you'll be prompted for it.

set -euo pipefail

PROG="$(basename "$0")"

usage() {
  cat <<EOF
Usage: ${PROG} [--dnsmasq] [cloud_id]
       ${PROG} -h | --help

Prints the Storage LTA VLAN/subnet/IP breakdown for a given cloud ID,
across all four storage arrays and both multipath legs (path A/B).

Options:
  --dnsmasq   Emit ready-to-paste dnsmasq.conf 'interface='/'dhcp-range='
              stanzas (one per VLAN) instead of the human-readable report.
  -h, --help  Show this help text.

Arguments:
  cloud_id    The existing cloudNN identifier from the Quads/wiki
              assignments page (1-99). Prompted interactively if omitted.

Examples:
  ${PROG} 32
  ${PROG} --dnsmasq 44
EOF
}

DNSMASQ_MODE=0
CLOUD_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --dnsmasq)
      DNSMASQ_MODE=1
      shift
      ;;
    *)
      CLOUD_ID="$1"
      shift
      ;;
  esac
done

if [[ -z "${CLOUD_ID}" ]]; then
  read -r -p "Enter cloud ID (1-99, e.g. 32): " CLOUD_ID
fi

if ! [[ "${CLOUD_ID}" =~ ^[0-9]+$ ]]; then
  echo "Error: cloud_id must be an integer between 1 and 99 (got '${CLOUD_ID}')." >&2
  exit 1
fi

# Force base-10 interpretation *before* any arithmetic comparison — a
# leading zero (e.g. "08") would otherwise make bash misparse it as an
# invalid octal literal at the first `((...))` use and silently skip the
# range check below instead of failing it. cloud_id must stay a plain
# integer 1-99 for the formulas either way (vlan-ip-convention.md's
# "zero-pad for the formula" note is a display convention, not a math
# one — 172.16.104.0/24 and 172.16.4.0/24 are different things).
CLOUD_ID=$((10#${CLOUD_ID}))

if (( CLOUD_ID < 1 || CLOUD_ID > 99 )); then
  echo "Error: cloud_id must be an integer between 1 and 99 (got '${CLOUD_ID}')." >&2
  exit 1
fi

# name|pathA_digit — path B is always pathA_digit + 1
PLATFORMS=(
  "IBM FlashSystem 7300|1"
  "NetApp ASA A70|3"
  "Pure FlashArray X70R5|5"
  "NetApp AFF A300 (old, pending decommission)|7"
)

DHCP_POOL_SIZE=$(( 254 - 20 + 1 ))

print_dnsmasq_block() {
  local vlan="$1" subnet_base="$2"
  cat <<EOF
##############################
# cloud${CLOUD_ID} — VLAN ${vlan} — ${subnet_base}.0/24
##############################
interface=eno1.${vlan}
dhcp-range=${subnet_base}.20,${subnet_base}.254,255.255.255.0,12h
# dnsmasq sub-if: ${subnet_base}.1  |  static portal IPs: ${subnet_base}.2-.9
# add dhcp-host=<mac>,<name>,${subnet_base}.N,infinite lines for known ports

EOF
}

if (( DNSMASQ_MODE == 1 )); then
  echo "# dnsmasq.conf stanzas for cloud${CLOUD_ID} — paste into dnsmasq.conf and add dhcp-host lines"
  echo
  for entry in "${PLATFORMS[@]}"; do
    for path in A B; do
      digitA="${entry##*|}"
      digit=$digitA
      [[ "${path}" == "B" ]] && digit=$(( digitA + 1 ))
      vlan=$(( digit * 100 + CLOUD_ID ))
      octet2=$(( 15 + digit ))
      octet3=$(( 100 + CLOUD_ID ))
      subnet_base="172.${octet2}.${octet3}"
      print_dnsmasq_block "${vlan}" "${subnet_base}"
    done
  done
  exit 0
fi

echo "Storage LTA — VLAN/Subnet breakdown for cloud${CLOUD_ID}"
echo "Base pool: 172.16.0.0/13  (see vlan-ip-convention.md)"
echo

for entry in "${PLATFORMS[@]}"; do
  name="${entry%%|*}"
  digitA="${entry##*|}"
  echo "${name}"
  for path in A B; do
    digit=$digitA
    [[ "${path}" == "B" ]] && digit=$(( digitA + 1 ))
    vlan=$(( digit * 100 + CLOUD_ID ))
    octet2=$(( 15 + digit ))
    octet3=$(( 100 + CLOUD_ID ))
    subnet_base="172.${octet2}.${octet3}"

    printf "  Path %s  VLAN %-4s  Subnet %s.0/24\n" "${path}" "${vlan}" "${subnet_base}"
    printf "    dnsmasq sub-if : %s.1\n" "${subnet_base}"
    printf "    static portal  : %s.2 - %s.9      (iSCSI portal / NFS LIF IPs)\n" "${subnet_base}" "${subnet_base}"
    printf "    static reserved: %s.10 - %s.19    (future use)\n" "${subnet_base}" "${subnet_base}"
    printf "    DHCP pool      : %s.20 - %s.254   (%d addresses, keyed by MAC)\n" "${subnet_base}" "${subnet_base}" "${DHCP_POOL_SIZE}"
  done
  echo
done

if [[ "${CLOUD_ID}" == "20" || "${CLOUD_ID}" == "32" || "${CLOUD_ID}" == "44" ]]; then
  cat <<EOF
Note: cloud${CLOUD_ID} is one of IBM's live tenants today (VLAN ${CLOUD_ID},
via portset_host/portset_cloud${CLOUD_ID}), but currently on a single
non-split VLAN — not yet on the path A/B dual-VLAN scheme shown above. See
mac-wwpn-inventory.md. Migrating it onto this convention is a separate,
deferred decision.
EOF
  echo
fi

echo "Tip: run '${PROG} --dnsmasq ${CLOUD_ID}' to emit paste-ready dnsmasq.conf stanzas for this cloud."
