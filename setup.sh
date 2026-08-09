#!/bin/sh
# setup.sh - Bootstrap any Linux machine into an argus node
# Supports: Alpine, Debian, Ubuntu, Raspberry Pi OS
# Compatible with sh, bash, dash, and other POSIX shells
# Usage: wget -O - https://raw.githubusercontent.com/phxdev1/argus-setup/master/setup.sh | sh
# Or: TAILSCALE_KEY=... ./setup.sh

set -eu

TAILSCALE_KEY="${TAILSCALE_KEY:-${1:-}}"
MOTHERSHIP_ADDR="${MOTHERSHIP_ADDR:-argus.soay-boa.ts.net:6379}"
HOSTNAME_PREFIX="${HOSTNAME_PREFIX:-argus}"

echo "=== Argus Node Bootstrap ==="
echo "Mothership: $MOTHERSHIP_ADDR"
echo

# Validate environment
echo "[1/5] Validating environment..."

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Must run as root or with sudo"
  exit 1
fi

# Detect Linux distribution
if [ -f /etc/alpine-release ]; then
  DISTRO="alpine"
  PKG_MGR="apk"
elif [ -f /etc/debian_version ]; then
  DISTRO="debian"
  PKG_MGR="apt"
elif grep -qi "^ID=debian\|^ID=ubuntu" /etc/os-release 2>/dev/null; then
  DISTRO="debian"
  PKG_MGR="apt"
else
  echo "ERROR: Unsupported Linux distribution"
  echo "Supported: Alpine, Debian, Ubuntu, Raspberry Pi OS"
  exit 1
fi

echo "Detected: $DISTRO ($PKG_MGR)"

# Check for basic utilities
for cmd in curl sed; do
  if ! command -v $cmd &>/dev/null; then
    echo "ERROR: Required utility '$cmd' not found"
    exit 1
  fi
done

# Prompt for key if not provided
if [ -z "$TAILSCALE_KEY" ]; then
  echo
  printf "Tailscale Auth Key (tskey-...): "
  read -r TAILSCALE_KEY
  echo
  if [ -z "$TAILSCALE_KEY" ]; then
    echo "ERROR: Tailscale key required"
    exit 1
  fi
fi

echo "Tailscale Key: $(printf '%.20s' "$TAILSCALE_KEY")..."
echo "Environment OK"
echo

# Install substrate
echo "[2/5] Installing substrate (Tailscale + Redis)..."

if [ "$PKG_MGR" = "apk" ]; then
  apk update
  # Alpine: install bash and curl first (needed for rest of script)
  apk add --no-cache bash curl ca-certificates redis
elif [ "$PKG_MGR" = "apt" ]; then
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates redis-tools
fi

# Install Tailscale
if ! command -v tailscale &>/dev/null; then
  if [ "$DISTRO" = "alpine" ]; then
    apk add --no-cache tailscale
  else
    curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1
  fi
fi

echo "Substrate installed"
echo

# Create directories
echo "[3/5] Setting up first-boot automation..."

mkdir -p /etc/argus
mkdir -p /usr/local/lib/argus

# Store mothership address
echo "$MOTHERSHIP_ADDR" > /etc/argus/mothership.addr
echo "$TAILSCALE_KEY" > /etc/argus/tailscale.key
chmod 600 /etc/argus/tailscale.key

# Create first-boot script
tee /usr/local/lib/argus/first-boot.sh > /dev/null << 'EOF'
#!/bin/bash
# First-boot: Join Tailscale, bootstrap from mothership

set -euo pipefail

TAILSCALE_KEY=$(cat /etc/argus/tailscale.key)
MOTHERSHIP_ADDR=$(cat /etc/argus/mothership.addr)
HOSTNAME_PREFIX="${HOSTNAME_PREFIX:-argus}"

echo "[first-boot] Starting bootstrap..."

# Generate hostname
HOSTNAME="${HOSTNAME_PREFIX}-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' ')"

# Set hostname (compatible with both systemd and non-systemd systems)
if command -v hostnamectl &>/dev/null; then
  hostnamectl set-hostname "$HOSTNAME"
else
  echo "$HOSTNAME" > /etc/hostname
  hostname "$HOSTNAME" 2>/dev/null || true
fi

echo "[first-boot] Hostname: $HOSTNAME"

# Join Tailscale
echo "[first-boot] Joining Tailscale mesh..."
tailscale up --authkey="$TAILSCALE_KEY" --hostname="$HOSTNAME" 2>/dev/null || true

# Wait for Tailscale
echo "[first-boot] Waiting for mesh connection..."
i=0
while [ $i -lt 30 ]; do
  if tailscale status 2>/dev/null | grep -q "your own"; then
    echo "[first-boot] Connected to mesh"
    break
  fi
  sleep 1
  i=$((i + 1))
done

# Connect to mothership
echo "[first-boot] Connecting to mothership..."
MOTHERSHIP_HOST="${MOTHERSHIP_ADDR%:*}"
MOTHERSHIP_PORT="${MOTHERSHIP_ADDR#*:}"

# Verify mothership reachable
if ! redis-cli -h "$MOTHERSHIP_HOST" -p "$MOTHERSHIP_PORT" ping 2>/dev/null | grep -q PONG; then
  echo "[first-boot] WARNING: Mothership unreachable, retrying..."
  i=0
  while [ $i -lt 5 ]; do
    sleep 5
    if redis-cli -h "$MOTHERSHIP_HOST" -p "$MOTHERSHIP_PORT" ping 2>/dev/null | grep -q PONG; then
      echo "[first-boot] Connected to mothership"
      break
    fi
    i=$((i + 1))
  done
fi

# Signal mothership: ready for setup
echo "[first-boot] Signaling mothership..."
echo "$HOSTNAME" | redis-cli -h "$MOTHERSHIP_HOST" -p "$MOTHERSHIP_PORT" LPUSH "argus:setup:pending" "$HOSTNAME" >/dev/null

# TODO: Listen for setup commands
echo "[first-boot] Waiting for mothership setup commands..."
sleep 300

echo "[first-boot] Bootstrap complete"
EOF

chmod +x /usr/local/lib/argus/first-boot.sh

# Create init service based on distro
echo "[3/5] Configuring first-boot automation..."

if [ "$DISTRO" = "alpine" ]; then
  # OpenRC service for Alpine
  mkdir -p /etc/init.d
  tee /etc/init.d/argus-first-boot > /dev/null << 'EOF'
#!/sbin/openrc-run

description="Argus First-Boot Bootstrap"
depend() {
  after network-online tailscale
}

start() {
  ebegin "Starting Argus first-boot"
  /usr/local/lib/argus/first-boot.sh
  eend $?
}
EOF
  chmod +x /etc/init.d/argus-first-boot

  # Enable service
  if command -v rc-update &>/dev/null; then
    rc-update add argus-first-boot default 2>/dev/null || true
    echo "First-boot automation configured"

    # Try to start if OpenRC is running
    if rc-service argus-first-boot start 2>/dev/null; then
      echo "First-boot service started"
    else
      echo "Will start on next boot"
    fi
  fi
else
  # systemd service for Debian/Ubuntu
  mkdir -p /etc/systemd/system
  tee /etc/systemd/system/argus-first-boot.service > /dev/null << 'EOF'
[Unit]
Description=Argus First-Boot Bootstrap
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/lib/argus/first-boot.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal
SyslogIdentifier=argus-first-boot

[Install]
WantedBy=multi-user.target
EOF

  # Enable and reload systemd (if running)
  if systemctl is-system-running 2>/dev/null; then
    systemctl daemon-reload
    systemctl enable argus-first-boot.service
    echo "First-boot automation configured and enabled"
  else
    echo "First-boot automation configured (systemd not running, will enable on next boot)"
  fi
fi

echo

# Summary
echo "[4/5] Configuration complete"
echo
echo "=== Bootstrap Summary ==="
echo "Distribution: $DISTRO"
echo "Init System: $([ "$DISTRO" = "alpine" ] && echo "OpenRC" || echo "systemd")"
echo "Hostname: $HOSTNAME_PREFIX-{random}"
echo "Mothership: $MOTHERSHIP_ADDR"
echo "Status: Ready to bootstrap"
echo

# Start first-boot
echo "[5/5] Starting bootstrap..."
if [ "$DISTRO" = "alpine" ]; then
  echo "Alpine: Will start on next boot (or run: rc-service argus-first-boot start)"
else
  if systemctl is-system-running 2>/dev/null; then
    systemctl start argus-first-boot.service &
    echo "First-boot service started"
    echo "Check status with: journalctl -u argus-first-boot -f"
  else
    echo "Systemd not running. Service will start on next boot."
  fi
fi

echo
echo "Node will join Tailscale, then wait for mothership setup commands."
echo
