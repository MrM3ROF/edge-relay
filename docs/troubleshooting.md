# Troubleshooting

Work from the tunnel outward. Do not expose RDP/SMB or disable the Windows
Firewall as a test.

## 1. Confirm the Linux VM is reachable

```bash
ssh ubuntu@PUBLIC_VM_IP
ip -4 route show default
sudo ss -lunp | grep 51820
```

The cloud security list must allow TCP `22` and UDP `51820`. Each public
service needs its own cloud ingress rule.

## 2. Check WireGuard

Linux:

```bash
sudo systemctl status wg-quick@wg0 --no-pager
sudo wg show
ping -c 4 10.77.0.2
```

Windows PowerShell:

```powershell
Get-Service 'WireGuardTunnel$edge-relay'
& "$env:ProgramFiles\WireGuard\wg.exe" show
Test-Connection 10.77.0.1 -Count 4
```

If there is no handshake:

- confirm the Windows endpoint uses the reserved public VM address;
- confirm UDP `51820` is allowed by the cloud security list;
- confirm `sudo ss -lunp` shows WireGuard listening;
- confirm the Linux peer public key in Windows and Windows peer public key on
  Linux are not swapped; and
- keep `PersistentKeepalive = 25` on the CGNAT-side Windows peer.

## 3. Check routing and forwarding

```bash
sysctl net.ipv4.ip_forward
ip route get 10.77.0.2
ip route get TARGET_IP
sudo nft list chain ip filter EDGE_RELAY_INPUT
sudo nft list chain ip filter EDGE_RELAY_FORWARD
sudo nft list table ip edge_relay_nat -a
```

`net.ipv4.ip_forward` must be `1`. A configured Windows target address should
route through `wg0`.

Reapply the generated rules:

```bash
sudo systemctl restart edge-relay.service
sudo journalctl -u edge-relay.service -n 100 --no-pager
```

## 4. Check the Windows service

Confirm the real application is listening on the configured target port:

```powershell
Get-NetTCPConnection -State Listen -LocalPort 25565 -ErrorAction SilentlyContinue
Get-NetUDPEndpoint -LocalPort 19132 -ErrorAction SilentlyContinue
Get-NetFirewallRule -DisplayName 'Edge Relay - *' |
    Format-Table DisplayName, Enabled, Direction, Action
```

The application should listen on the LAN address or all interfaces. If it only
listens on `127.0.0.1`, traffic forwarded to the LAN address cannot reach it.

## 5. Observe a live external test

On Linux, replace the ports if needed:

```bash
sudo tcpdump -ni any 'tcp port 25565 or udp port 19132 or udp port 51820'
```

Interpretation:

- Nothing arrives on the public interface: check the client address and cloud
  security list.
- Traffic arrives publicly but not on `wg0`: check nftables rules and service
  configuration.
- Traffic reaches `wg0` with no reply: check the Windows application, Windows
  Firewall, and WireGuard peer settings.
- Replies cross `wg0` but not the public interface: check Linux forwarding and
  connection tracking.

## UDP testing

A generic UDP probe can report success even when no application replies. Test
with the real application client and confirm packet/counter changes with
`tcpdump`, `nft -a`, and `wg show`.

## MTU symptoms

If the handshake works and small pings succeed but larger transfers stall, try
reducing `WIREGUARD_MTU` in `relay.env` from `1380` to `1360`, rerun both setup
scripts, and retest.

## Safe disable and rollback

Disable only the relay rules and tunnel on Linux:

```bash
sudo systemctl disable --now edge-relay.service
sudo systemctl disable --now wg-quick@wg0.service
```

This does not change Tailscale.

Remove the Windows WireGuard tunnel service from an elevated PowerShell:

```powershell
& "$env:ProgramFiles\WireGuard\wireguard.exe" /uninstalltunnelservice edge-relay
Get-NetFirewallRule -DisplayName 'Edge Relay - *' | Remove-NetFirewallRule
```

Do not delete key material until you are sure it is no longer needed.
