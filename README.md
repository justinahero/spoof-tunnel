# Spoof Tunnel

A VXLAN-based spoof-tunnel deployment and management suite for bypassing network restrictions.

Written: March 4 – 7, 2026
Author: [justinahero](https://github.com/justinahero)

---

## What is Spoof Tunnel?

Spoof Tunnel creates a VXLAN tunnel between two servers (one inside Iran, one outside) using IP spoofing as the source address. This allows traffic to bypass network filters that block international connections, since the packets appear to originate from a trusted local IP rather than the real server IP.

How it works:

1. The Iran-side server binds a spoof IP (e.g. a local CDN or ISP IP) to its loopback interface
2. VXLAN packets are sent with that IP as the source address
3. The firewall sees a trusted local IP and allows the traffic through
4. The outside server receives the packets and responds back through the tunnel

---

## Requirements

- Two Linux servers (Ubuntu/Debian recommended) — one inside Iran, one outside
- Root access on both servers
- The Iran-side server must be on an ISP or datacenter that allows IP spoofing (spoof-friendly)
- `iperf3` — installed automatically if missing

---

## Installation

```bash
wget https://raw.githubusercontent.com/justinahero/spoof-tunnel/main/spoof-tunnel.sh
chmod +x spoof-tunnel.sh
sudo bash spoof-tunnel.sh --install
```

After install, run from anywhere:

```bash
sudo spooftun
```

---

## Usage

### Interactive Wizard (recommended)

```bash
sudo spooftun
```

Launches a step-by-step wizard — no config files to edit manually.

The wizard will ask you:
1. Server role (iran / kh)
2. Real IP of the remote server
3. Tunnel ID (1–254)
4. Spoof IP pool (one or more IPs)
5. Deploy method (up / auto-benchmark)
6. Whether to enable auto-start on boot (systemd)

### Direct CLI

```bash
sudo spooftun iran up 1       # Bring tunnel 1 up (Iran role)
sudo spooftun kh down 1       # Bring tunnel 1 down (KH role)
sudo spooftun iran auto 1     # Auto-benchmark and pick fastest spoof IP
```

### Other Options

```
--list, --status       List all tunnels and their status
--health               Health check (interface + traffic stats)
--logs                 View recent log entries
--snapshot <ID>        Snapshot tunnel config
--rollback <ID>        Rollback tunnel config to a previous snapshot
--optimize             Apply kernel optimizations for tunneling
--install              Install to /usr/local/bin/spooftun
--uninstall            Remove from system
--version              Show version
--help                 Show help
```

---

## Auto-Benchmark

When you choose the `auto` deploy mode, Spoof Tunnel will:

1. Test each spoof IP in your pool one by one
2. Measure the speed through each IP using `iperf3`
3. Automatically pick the fastest working IP
4. Bring the tunnel up with the winner

> **Note:** For auto-benchmark to work, the remote server must already be running with `up` mode.

---

## Spoof IP Pool

The spoof IPs are the source addresses used for VXLAN packets. They should be IPs that:

- Are routable from your Iran server
- Are not blocked by the firewall (e.g. IPs belonging to Iranian CDNs or ISPs)
- Are bound or routable to your Iran server (not random internet IPs)

You can add multiple IPs — the auto-benchmark will find the fastest one.

---

## Config & Logs

| Path | Description |
|------|-------------|
| `/etc/spooftun/tun<ID>.conf` | Per-tunnel config |
| `/etc/spooftun/snapshots/` | Config snapshots |
| `/var/log/spooftun/spooftun.log` | Log file |
| `/etc/sysctl.d/99-spooftun.conf` | Kernel tuning params |

---

## Systemd

If you enable auto-start during the wizard, Spoof Tunnel creates a systemd service:

```
spooftun-tun1.service
```

Manage it manually:

```bash
systemctl start spooftun-tun1
systemctl stop spooftun-tun1
systemctl status spooftun-tun1
```

---

## Donation

If you find this project useful, consider supporting it:

| Network | Address |
|---------|---------|
| TRX (Tron) | `TBMenySPuZYyre5S5imWJbvXXHSrXZcE3x` |
| TON | `UQDfANFVOcM_vsVXGgXmEYcMJvbGklcOHyTCtGguOjMn0QsL` |

---

## License

MIT
