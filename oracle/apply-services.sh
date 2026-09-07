#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE=/etc/edge-relay/relay.env
SERVICES_FILE=/etc/edge-relay/services.conf

usage() {
  cat <<'EOF'
Usage: apply-services.sh [--config PATH] [--services PATH]

Build and atomically apply edge-relay nftables rules. Existing system and OCI
firewall rules are preserved.
EOF
}

die() {
  echo "edge-relay: $*" >&2
  exit 1
}

trim() {
  local value=$1
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

load_config() {
  local path=$1 raw line key value
  [[ -f "$path" ]] || die "configuration file not found: $path"

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw=${raw%$'\r'}
    line=$(trim "$raw")
    [[ -z "$line" || ${line:0:1} == "#" ]] && continue
    [[ "$line" == *=* ]] || die "invalid configuration line: $raw"
    key=$(trim "${line%%=*}")
    value=$(trim "${line#*=}")

    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
      value=${value:1:${#value}-2}
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
      value=${value:1:${#value}-2}
    fi

    case "$key" in
      PUBLIC_INTERFACE|WIREGUARD_INTERFACE|WIREGUARD_PORT|WIREGUARD_SERVER_IP|WIREGUARD_CLIENT_IP|WIREGUARD_MTU)
        printf -v "$key" '%s' "$value"
        ;;
      *) ;;
    esac
  done < "$path"
}

valid_ipv4() {
  local ip=$1 octet
  local -a octets
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a octets <<< "$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ && 10#$octet -le 255 ]] || return 1
  done
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ && 10#$1 -ge 1 && 10#$1 -le 65535 ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || die "--config needs a path"
      CONFIG_FILE=$2
      shift 2
      ;;
    --services)
      [[ $# -ge 2 ]] || die "--services needs a path"
      SERVICES_FILE=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run this script as root"
command -v nft >/dev/null 2>&1 || die "nft is not installed"

WIREGUARD_INTERFACE=${WIREGUARD_INTERFACE:-wg0}
WIREGUARD_PORT=${WIREGUARD_PORT:-51820}
WIREGUARD_SERVER_IP=${WIREGUARD_SERVER_IP:-10.77.0.1}
PUBLIC_INTERFACE=${PUBLIC_INTERFACE:-}

load_config "$CONFIG_FILE"

if [[ -z "$PUBLIC_INTERFACE" ]]; then
  PUBLIC_INTERFACE=$(ip -4 route show default | awk 'NR == 1 { print $5 }')
fi

[[ "$PUBLIC_INTERFACE" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "invalid public interface"
[[ "$WIREGUARD_INTERFACE" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "invalid WireGuard interface"
valid_port "$WIREGUARD_PORT" || die "invalid WIREGUARD_PORT"
valid_ipv4 "$WIREGUARD_SERVER_IP" || die "invalid WIREGUARD_SERVER_IP"
[[ -f "$SERVICES_FILE" ]] || die "services file not found: $SERVICES_FILE"
ip link show dev "$PUBLIC_INTERFACE" >/dev/null 2>&1 || die "interface not found: $PUBLIC_INTERFACE"
ip link show dev "$WIREGUARD_INTERFACE" >/dev/null 2>&1 || die "interface not found: $WIREGUARD_INTERFACE"

declare -a SERVICE_NAMES=()
declare -a SERVICE_PROTOCOLS=()
declare -a SERVICE_PUBLIC_PORTS=()
declare -a SERVICE_TARGET_IPS=()
declare -a SERVICE_TARGET_PORTS=()
declare -A SEEN_PUBLIC_PORTS=()

line_number=0
while IFS= read -r raw || [[ -n "$raw" ]]; do
  line_number=$((line_number + 1))
  raw=${raw%$'\r'}
  line=${raw%%#*}
  line=$(trim "$line")
  [[ -z "$line" ]] && continue

  read -r name protocol public_port target_ip target_port extra <<< "$line"
  [[ -z "${extra:-}" && -n "${target_port:-}" ]] || die "invalid service at line $line_number"
  [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid service name at line $line_number"
  protocol=${protocol,,}
  [[ "$protocol" == tcp || "$protocol" == udp ]] || die "protocol must be tcp or udp at line $line_number"
  valid_port "$public_port" || die "invalid public port at line $line_number"
  valid_ipv4 "$target_ip" || die "invalid target IPv4 address at line $line_number"
  valid_port "$target_port" || die "invalid target port at line $line_number"

  duplicate_key="${protocol}:${public_port}"
  [[ -z "${SEEN_PUBLIC_PORTS[$duplicate_key]:-}" ]] || die "duplicate public endpoint $duplicate_key"
  SEEN_PUBLIC_PORTS[$duplicate_key]=1

  SERVICE_NAMES+=("$name")
  SERVICE_PROTOCOLS+=("$protocol")
  SERVICE_PUBLIC_PORTS+=("$public_port")
  SERVICE_TARGET_IPS+=("$target_ip")
  SERVICE_TARGET_PORTS+=("$target_port")
done < "$SERVICES_FILE"

nft list table ip filter >/dev/null 2>&1 || die "the host iptables-nft filter table is missing; refusing to create a permissive replacement"
nft list chain ip filter INPUT >/dev/null 2>&1 || die "the host INPUT chain is missing"
nft list chain ip filter FORWARD >/dev/null 2>&1 || die "the host FORWARD chain is missing"
if ! nft list chain ip filter EDGE_RELAY_INPUT >/dev/null 2>&1; then
  nft add chain ip filter EDGE_RELAY_INPUT
fi
if ! nft list chain ip filter EDGE_RELAY_FORWARD >/dev/null 2>&1; then
  nft add chain ip filter EDGE_RELAY_FORWARD
fi
input_chain=$(nft list chain ip filter INPUT)
forward_chain=$(nft list chain ip filter FORWARD)
if ! grep -q 'jump EDGE_RELAY_INPUT' <<< "$input_chain"; then
  nft 'insert rule ip filter INPUT jump EDGE_RELAY_INPUT comment "edge-relay input hook"'
fi
if ! grep -q 'jump EDGE_RELAY_FORWARD' <<< "$forward_chain"; then
  nft 'insert rule ip filter FORWARD jump EDGE_RELAY_FORWARD comment "edge-relay forward hook"'
fi

if ! nft list table ip edge_relay_nat >/dev/null 2>&1; then
  nft add table ip edge_relay_nat
fi
if ! nft list chain ip edge_relay_nat prerouting >/dev/null 2>&1; then
  nft 'add chain ip edge_relay_nat prerouting { type nat hook prerouting priority dstnat; policy accept; }'
fi
if ! nft list chain ip edge_relay_nat postrouting >/dev/null 2>&1; then
  nft 'add chain ip edge_relay_nat postrouting { type nat hook postrouting priority srcnat; policy accept; }'
fi

batch_file=$(mktemp)
trap 'rm -f "$batch_file"' EXIT

{
  echo 'flush chain ip filter EDGE_RELAY_INPUT'
  echo 'flush chain ip filter EDGE_RELAY_FORWARD'
  echo 'flush chain ip edge_relay_nat prerouting'
  echo 'flush chain ip edge_relay_nat postrouting'
  printf 'add rule ip filter EDGE_RELAY_INPUT udp dport %s accept comment "edge-relay WireGuard"\n' "$WIREGUARD_PORT"
  printf 'add rule ip filter EDGE_RELAY_FORWARD iifname "%s" oifname "%s" ct status dnat accept comment "edge-relay inbound services"\n' "$PUBLIC_INTERFACE" "$WIREGUARD_INTERFACE"
  printf 'add rule ip filter EDGE_RELAY_FORWARD iifname "%s" oifname "%s" ct state established,related accept comment "edge-relay service replies"\n' "$WIREGUARD_INTERFACE" "$PUBLIC_INTERFACE"

  for index in "${!SERVICE_NAMES[@]}"; do
    printf 'add rule ip edge_relay_nat prerouting iifname "%s" %s dport %s dnat to %s:%s comment "edge-relay %s"\n' \
      "$PUBLIC_INTERFACE" \
      "${SERVICE_PROTOCOLS[$index]}" \
      "${SERVICE_PUBLIC_PORTS[$index]}" \
      "${SERVICE_TARGET_IPS[$index]}" \
      "${SERVICE_TARGET_PORTS[$index]}" \
      "${SERVICE_NAMES[$index]}"
  done

  printf 'add rule ip edge_relay_nat postrouting oifname "%s" ct status dnat snat to %s comment "edge-relay return path"\n' \
    "$WIREGUARD_INTERFACE" "$WIREGUARD_SERVER_IP"
} > "$batch_file"

nft -c -f "$batch_file"
nft -f "$batch_file"

echo "Applied ${#SERVICE_NAMES[@]} edge-relay service(s):"
for index in "${!SERVICE_NAMES[@]}"; do
  printf '  %-24s %s/%s -> %s:%s\n' \
    "${SERVICE_NAMES[$index]}" \
    "${SERVICE_PROTOCOLS[$index]}" \
    "${SERVICE_PUBLIC_PORTS[$index]}" \
    "${SERVICE_TARGET_IPS[$index]}" \
    "${SERVICE_TARGET_PORTS[$index]}"
done
