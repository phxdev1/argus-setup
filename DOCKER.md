# Argus Node Docker Container

Run an Argus mesh node in Docker.

## Build

```bash
docker build -t argus-node .
```

## Run

```bash
docker run --cap-add=NET_ADMIN \
  -e TAILSCALE_KEY=tskey-... \
  -e MOTHERSHIP_ADDR=argus.soay-boa.ts.net:6379 \
  argus-node
```

## Environment Variables

- **TAILSCALE_KEY** (required) — Tailscale auth key for mesh
- **MOTHERSHIP_ADDR** (optional) — Mothership Redis address (default: `argus.soay-boa.ts.net:6379`)
- **HOSTNAME_PREFIX** (optional) — Hostname prefix (default: `argus`)

## What Happens

1. Container starts
2. Joins Tailscale mesh using auth key
3. Connects to mothership Redis
4. Waits for work assignments
5. Keeps running (tail /dev/null)

## Example: Docker Compose

```yaml
version: '3.8'
services:
  argus-node:
    build: .
    cap_add:
      - NET_ADMIN
    environment:
      TAILSCALE_KEY: tskey-...
      MOTHERSHIP_ADDR: argus.soay-boa.ts.net:6379
    restart: unless-stopped
```

Then:

```bash
docker-compose up -d
docker-compose logs -f argus-node
```

## Logs

```bash
docker logs <container-id>
docker logs -f <container-id>  # Follow logs
```

## Notes

- Container needs `--cap-add=NET_ADMIN` to run Tailscale
- Requires valid Tailscale auth key
- Mothership must be reachable via Tailscale mesh
- Container runs indefinitely, waiting for work commands
