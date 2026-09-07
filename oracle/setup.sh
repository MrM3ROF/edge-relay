#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE=
SERVICES_FILE=

usage() {
  cat <<'EOF'
Usage: setup.sh --config PATH --services PATH

Configure an Ubuntu edge-relay gateway. The configuration file must contain a
valid WINDOWS_PUBLIC_KEY. Existing WireGuard server keys are reused.
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
      PUBLIC_INTERFACE|WIREGUARD_INTERFACE|WIREGUARD_PORT|WIREGUARD_SERVER_IP|WIREGUARD_CLIENT_IP|WIREGUARD_MTU|WINDOWS_PUBLIC_KEY)
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
[[ -n "$CONFIG_FILE" ]] || die "--config is required"
[[ -n "$SERVICES_FILE" ]] || die "--services is required"
[[ -f "$SERVICES_FILE" ]] || die "services file not found: $SERVICES_FILE"

WIREGUARD_INTERFACE=wg0
WIREGUARD_PORT=51820
WIREGUARD_SERVER_IP=10.77.0.1
WIREGUARD_CLIENT_IP=10.77.0.2
WIREGUARD_MTU=1380
PUBLIC_INTERFACE=
WINDOWS_PUBLIC_KEY=

load_config "$CONFIG_FILE"

valid_ipv4 "$WIREGUARD_SERVER_IP" || die "invalid WIREGUARD_SERVER_IP"
valid_ipv4 "$WIREGUARD_CLIENT_IP" || die "invalid WIREGUARD_CLIENT_IP"
[[ "$WIREGUARD_PORT" =~ ^[0-9]+$ && 10#$WIREGUARD_PORT -ge 1 && 10#$WIREGUARD_PORT -le 65535 ]] || die "invalid WIREGUARD_PORT"
[[ "$WIREGUARD_MTU" =~ ^[0-9]+$ && 10#$WIREGUARD_MTU -ge 1280 && 10#$WIREGUARD_MTU -le 1420 ]] || die "WIREGUARD_MTU must be between 1280 and 1420"
[[ "$WINDOWS_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "replace WINDOWS_PUBLIC_KEY with the key printed by windows/setup.ps1"
[[ "$WIREGUARD_INTERFACE" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "invalid WireGuard interface"

if [[ -z "$PUBLIC_INTERFACE" ]]; then
  PUBLIC_INTERFACE=$(ip -4 route show default | awk 'NR == 1 { print $5 }')
fi
[[ "$PUBLIC_INTERFACE" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "invalid public interface"
ip link show dev "$PUBLIC_INTERFACE" >/dev/null 2>&1 || die "interface not found: $PUBLIC_INTERFACE"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y wireguard-tools nftables iproute2

install -d -m 700 /etc/wireguard
install -d -m 755 /etc/edge-relay
install -m 600 "$CONFIG_FILE" /etc/edge-relay/relay.env
install -m 644 "$SERVICES_FILE" /etc/edge-relay/services.conf

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
install -m 755 "$SCRIPT_DIR/apply-services.sh" /usr/local/sbin/edge-relay-apply

if [[ ! -s /etc/wireguard/server.key ]]; then
  umask 077
  wg genkey > /etc/wireguard/server.key
fi
chmod 600 /etc/wireguard/server.key
wg pubkey < /etc/wireguard/server.key > /etc/wireguard/server.pub
chmod 644 /etc/wireguard/server.pub

declare -A TARGETS=()
while IFS= read -r raw || [[ -n "$raw" ]]; do
  raw=${raw%$'\r'}
  line=${raw%%#*}
  line=$(trim "$line")
  [[ -z "$line" ]] && continue
  read -r _ _ _ target_ip _ _ <<< "$line"
  valid_ipv4 "$target_ip" || die "invalid target address in services file: $target_ip"
  TARGETS[$target_ip]=1
done < "$SERVICES_FILE"

peer_allowed_ips="${WIREGUARD_CLIENT_IP}/32"
for target_ip in "${!TARGETS[@]}"; do
  [[ "$target_ip" == "$WIREGUARD_CLIENT_IP" ]] && continue
  peer_allowed_ips+=", ${target_ip}/32"
done

wg_temp=$(mktemp)
trap 'rm -f "$wg_temp"' EXIT
server_private_key=$(< /etc/wireguard/server.key)
cat > "$wg_temp" <<EOF
[Interface]
Address = ${WIREGUARD_SERVER_IP}/24
ListenPort = ${WIREGUARD_PORT}
PrivateKey = ${server_private_key}
MTU = ${WIREGUARD_MTU}
SaveConfig = false

[Peer]
PublicKey = ${WINDOWS_PUBLIC_KEY}
AllowedIPs = ${peer_allowed_ips}
EOF
install -m 600 "$wg_temp" "/etc/wireguard/${WIREGUARD_INTERFACE}.conf"

cat > /etc/sysctl.d/99-edge-relay.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null

cat > /etc/systemd/system/edge-relay.service <<EOF
[Unit]
Description=Apply edge-relay nftables rules
After=network-online.target netfilter-persistent.service wg-quick@${WIREGUARD_INTERFACE}.service
Wants=network-online.target
Requires=wg-quick@${WIREGUARD_INTERFACE}.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/edge-relay-apply --config /etc/edge-relay/relay.env --services /etc/edge-relay/services.conf
ExecReload=/usr/local/sbin/edge-relay-apply --config /etc/edge-relay/relay.env --services /etc/edge-relay/services.conf

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "wg-quick@${WIREGUARD_INTERFACE}.service"
systemctl restart "wg-quick@${WIREGUARD_INTERFACE}.service"
systemctl enable edge-relay.service
systemctl restart edge-relay.service

echo
echo "Linux WireGuard public key: $(< /etc/wireguard/server.pub)"
echo "Public interface: $PUBLIC_INTERFACE"
echo "IPv4 forwarding: $(sysctl -n net.ipv4.ip_forward)"
echo
wg show "$WIREGUARD_INTERFACE"
echo
echo "Gateway setup is complete. A handshake appears after the Windows peer connects."
