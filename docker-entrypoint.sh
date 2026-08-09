#!/bin/sh
# Docker entrypoint for Argus Node
# Runs first-boot setup when container starts

set -eu

echo "=== Argus Node (Docker) ==="

# Validate environment variables
if [ -z "${TAILSCALE_KEY:-}" ]; then
  echo "ERROR: TAILSCALE_KEY environment variable required"
  echo "Usage: docker run -e TAILSCALE_KEY=tskey-... argus-node"
  exit 1
fi

MOTHERSHIP_ADDR="${MOTHERSHIP_ADDR:-argus.soay-boa.ts.net:6379}"
HOSTNAME_PREFIX="${HOSTNAME_PREFIX:-argus}"

echo "Mothership: $MOTHERSHIP_ADDR"
echo

# Store configuration
mkdir -p /etc/argus
echo "$TAILSCALE_KEY" > /etc/argus/tailscale.key
echo "$MOTHERSHIP_ADDR" > /etc/argus/mothership.addr
chmod 600 /etc/argus/tailscale.key

echo "[bootstrap] Starting Tailscale..."
tailscale up --authkey="$TAILSCALE_KEY" --hostname="${HOSTNAME_PREFIX}-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' ')" 2>/dev/null || true

echo "[bootstrap] Waiting for Tailscale connection..."
i=0
while [ $i -lt 30 ]; do
  if tailscale status 2>/dev/null | grep -q "your own"; then
    echo "[bootstrap] Connected to mesh"
    break
  fi
  sleep 1
  i=$((i + 1))
done

echo "[bootstrap] Connecting to mothership..."
MOTHERSHIP_HOST="${MOTHERSHIP_ADDR%:*}"
MOTHERSHIP_PORT="${MOTHERSHIP_ADDR#*:}"

if redis-cli -h "$MOTHERSHIP_HOST" -p "$MOTHERSHIP_PORT" ping 2>/dev/null | grep -q PONG; then
  echo "[bootstrap] Connected to mothership"

  # Signal mothership: node is ready
  HOSTNAME=$(hostname)
  redis-cli -h "$MOTHERSHIP_HOST" -p "$MOTHERSHIP_PORT" LPUSH "argus:setup:pending" "$HOSTNAME" >/dev/null
  echo "[bootstrap] Signaled mothership: $HOSTNAME"
  echo "[bootstrap] Node ready for work assignments"

  # Keep container alive
  echo "[bootstrap] Listening for work commands..."
  while true; do sleep 60; done
else
  echo "[bootstrap] WARNING: Cannot reach mothership at $MOTHERSHIP_ADDR"
  echo "[bootstrap] Waiting indefinitely..."
  tail -f /dev/null
fi
