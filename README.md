# Argus Node Setup

Bootstrap any Linux machine into an autonomous argus mesh node.

## Quick Start

```bash
export TAILSCALE_KEY="tskey-auth-..."
curl https://raw.githubusercontent.com/phxdev1/argus-setup/master/setup.sh | bash
```

Or with sudo:

```bash
sudo TAILSCALE_KEY="tskey-auth-..." bash -c 'curl https://raw.githubusercontent.com/phxdev1/argus-setup/master/setup.sh | bash'
```

## What It Does

1. **Validates environment** — checks OS, permissions, network
2. **Installs substrate** — Tailscale, Redis tools
3. **Configures first-boot** — systemd service that bootstraps from mothership
4. **Signals mothership** — waits for setup commands

## Requirements

- Linux (Debian/Ubuntu-based): Ubuntu 20.04+, Debian 11+, Raspberry Pi OS
- Root or sudo access
- Internet connectivity (for initial bootstrap)
- Tailscale auth key (pre-generate in Tailscale admin)

## Environment Variables

- `TAILSCALE_KEY` (required) — Tailscale auth key for mesh
- `MOTHERSHIP_ADDR` (optional) — Mothership Redis address (default: `argus.soay-boa.ts.net:6379`)
- `HOSTNAME_PREFIX` (optional) — Hostname prefix (default: `argus`)

## Targets

- Raspberry Pi (any OS)
- Ubuntu VM/Cloud image
- Debian server
- Any Debian-based Linux

## What Happens on Boot

1. Node joins Tailscale mesh
2. Generates unique hostname (`argus-{random}`)
3. Connects to mothership Redis
4. Waits for setup commands from mothership
5. Executes setup scripts (install tools, configure services, etc.)
6. Signals "ready" to mothership
7. Enters work loop, waiting for job assignments

## Verification

```bash
# Check first-boot status
journalctl -u argus-first-boot -f

# Verify Tailscale
tailscale status

# Verify Redis connection
redis-cli -h <mothership> ping
```

## Notes

- Setup is idempotent (safe to run multiple times)
- First-boot runs once, then `RemainAfterExit=yes` prevents re-run
- Mothership manages all node configuration via Redis
- To reset a node, remove `/etc/systemd/system/argus-first-boot.service`

## For Developers

See `argus-fleet` private repo for:
- Mothership setup dispatcher
- Job queue protocol
- Node provisioning details
