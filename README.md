# edge-relay

`edge-relay` turns a small public Linux VM into a TCP/UDP gateway for a server
behind CGNAT. The private server initiates a WireGuard tunnel to the VM, and
the VM forwards only the services listed in a configuration file.

The base design uses WireGuard, Linux IP forwarding, and nftables. It does not
require router port forwarding, a public address at the private site, Docker,
or an application proxy.

```text
Internet client
      |
Public Linux VM
      |
  WireGuard
      |
Windows server behind CGNAT
```

## Important properties

- Only explicitly configured TCP/UDP ports are forwarded.
- The Windows peer does not receive a default route from WireGuard.
- Existing Tailscale and other outbound remote-access tools are left alone.
- DNAT forwards each public service to its configured destination.
- SNAT makes replies reliably return through WireGuard without changing the
  Windows default gateway. The destination server sees `10.77.0.1` as the
  client address.
- Rules are recreated after reboot without flushing Oracle's existing
  iptables-nft rules.

## Files

```text
edge-relay/
├── README.md
├── oracle/
│   ├── setup.sh
│   └── apply-services.sh
├── windows/
│   └── setup.ps1
├── config/
│   ├── relay.example.env
│   └── services.example.conf
├── docs/
│   └── troubleshooting.md
├── .gitignore
└── LICENSE
```

## Prerequisites

- A public Ubuntu VM with an IPv4 address.
- UDP `51820` allowed to the VM for WireGuard.
- Each public service port allowed by the cloud firewall/security list.
- SSH key access to the VM.
- WireGuard for Windows installed from the official WireGuard installer.
- Administrator access on Windows.

The examples use this private tunnel:

```text
Linux gateway:  10.77.0.1/24
Windows peer:   10.77.0.2/32
WireGuard UDP:  51820
```

These addresses are independent of the LAN and Tailscale networks.

## 1. Create local configuration files

Never edit the example files with real values. Copy them to the ignored local
files instead:

```bash
cp config/relay.example.env config/relay.env
cp config/services.example.conf config/services.conf
```

Edit `config/relay.env`. At first, set the public VM address and Linux
WireGuard public key. Leave `WINDOWS_PUBLIC_KEY` unset until the Windows setup
script prints it.

The Linux public key is safe to share and can be displayed on the VM with:

```bash
sudo cat /etc/wireguard/server.pub
```

## 2. Configure Windows

Open **Windows PowerShell as Administrator**, move into this repository, and
run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\windows\setup.ps1 -ConfigFile .\config\relay.env -ServicesFile .\config\services.conf
```

The script:

- generates or reuses a protected Windows WireGuard key;
- installs an automatic WireGuard tunnel service;
- routes only `10.77.0.1/32` through WireGuard;
- enables weak-host send/receive only on the WireGuard adapter so a service can
  be addressed by the Windows LAN IP;
- creates narrow Windows Firewall rules for locally hosted services; and
- prints `WINDOWS_PUBLIC_KEY=...` without printing the private key.

Copy that public key into `config/relay.env` as `WINDOWS_PUBLIC_KEY`.

## 3. Configure the Linux gateway

Copy or clone the repository and the two local configuration files onto the
VM. Then run:

```bash
sudo ./oracle/setup.sh \
  --config ./config/relay.env \
  --services ./config/services.conf
```

The script installs required packages, enables IPv4 forwarding, configures
WireGuard, installs the nftables rule generator, applies the services, and
enables both services after reboot.

It preserves the operating system's existing firewall rules. It never runs
`nft flush ruleset`.

## 4. Verify the tunnel

On Linux:

```bash
sudo wg show
ping -c 4 10.77.0.2
```

Look for a recent WireGuard handshake and increasing transfer counters. On
Windows:

```powershell
& "$env:ProgramFiles\WireGuard\wg.exe" show
Test-Connection 10.77.0.1 -Count 4
```

## 5. Add or remove public services

Each non-comment line in `services.conf` has five fields:

```text
NAME PROTOCOL PUBLIC_PORT TARGET_IP TARGET_PORT
```

Example:

```text
minecraft-java    tcp 25565 192.168.1.50 25565
minecraft-bedrock udp 19132 192.168.1.50 19132
```

Use one line per port. Port ranges are intentionally not implicit, so a typo
cannot expose a large range.

After changing the Linux copy of `/etc/edge-relay/services.conf`, apply it:

```bash
sudo /usr/local/sbin/edge-relay-apply
```

If the service runs on the Windows WireGuard peer, rerun `windows/setup.ps1`
after changing the local services file so the matching Windows Firewall rule
is created. Services hosted on another LAN device require forwarding on the
Windows peer and a correct return route; that advanced topology is not enabled
by the base setup.

Also add the same public protocol/port to the Oracle security list. The cloud
security list and nftables both have to allow a service.

## 6. Test from outside

Test from a device that is not on the same LAN and is not using the private
tailnet.

TCP example:

```bash
nc -vz PUBLIC_VM_IP 25565
```

UDP does not have a universal connect test. Use the real UDP client and watch
counters on Linux:

```bash
sudo nft list table ip edge_relay_nat -a
sudo wg show
```

## DNS

A domain is optional. First confirm both services using the reserved public IP.
After that, create a DNS-only `A` record such as `relay.example.com` pointing to
the reserved public IP. Do not place WireGuard or game UDP behind an HTTP-only
proxy.

## Security

Never commit private keys, SSH keys, passwords, cloud credentials, tokens, or
the local `relay.env`/`services.conf` files. The supplied `.gitignore` excludes
the expected local files, but always inspect `git diff --cached` before a public
push.

See [docs/troubleshooting.md](docs/troubleshooting.md) for diagnostics and safe
rollback instructions.
