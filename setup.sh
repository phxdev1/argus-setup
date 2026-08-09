#!/bin/bash
# setup.sh - Bootstrap any Linux machine into an argus node
# Usage: curl https://raw.githubusercontent.com/phxdev1/argus-setup/master/setup.sh | bash
# Or: TAILSCALE_KEY=... ./setup.sh

set -euo pipefail

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

if ! grep -qi debian /etc/os-release 2>/dev/null; then
  echo "ERROR: This script requires a Debian-based system"
  exit 1
fi

# Check for basic utilities
for cmd in apt-get curl sed; do
  if ! command -v $cmd &>/dev/null; then
    echo "ERROR: Required utility '$cmd' not found"
    echo "This environment is too minimal. Use a standard Debian/Ubuntu image."
    exit 1
  fi
done

# Prompt for key if not provided
if [[ -z "$TAILSCALE_KEY" ]]; then
  echo
  read -sp "Tailscale Auth Key (tskey-...): " TAILSCALE_KEY
  echo
  if [[ -z "$TAILSCALE_KEY" ]]; then
    echo "ERROR: Tailscale key required"
    exit 1
  fi
fi

echo "Tailscale Key: ${TAILSCALE_KEY:0:20}..."

# Ensure systemd is installed
if ! command -v systemctl &>/dev/null; then
  echo "Installing systemd..."
  apt-get update -qq
  apt-get install -y -qq systemd
fi

# Check if already configured
if systemctl is-enabled argus-first-boot.service 2>/dev/null; then
  echo "Node already configured. Remove /etc/systemd/system/argus-first-boot.service to reconfigure."
  exit 0
fi

echo "Environment OK"
echo

# Install substrate
echo "[2/5] Installing substrate (Tailscale + Redis)..."

apt-get update -qq
apt-get install -y -qq curl ca-certificates redis-tools

# Install Tailscale
if ! command -v tailscale &>/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 || {
    # Fallback manual installation
    curl -fsSL https://pkgs.tailscale.com/stable/debian/tailscale.asc | apt-key add -
    echo "deb https://pkgs.tailscale.com/stable/debian $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/tailscale.list
    apt-get update -qq
    apt-get install -y -qq tailscale
  }
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
hostnamectl set-hostname "$HOSTNAME"
echo "[first-boot] Hostname: $HOSTNAME"

# Join Tailscale
echo "[first-boot] Joining Tailscale mesh..."
tailscale up --authkey="$TAILSCALE_KEY" --hostname="$HOSTNAME" 2>/dev/null || true

# Wait for Tailscale
echo "[first-boot] Waiting for mesh connection..."
for i in {1..30}; do
  if tailscale status 2>/dev/null | grep -q "your own"; then
    echo "[first-boot] Connected to mesh"
    break
  fi
  sleep 1
done

# Connect to mothership
echo "[first-boot] Connecting to mothership..."
MOTHERSHIP_HOST="${MOTHERSHIP_ADDR%:*}"
MOTHERSHIP_PORT="${MOTHERSHIP_ADDR#*:}"

# Verify mothership reachable
if ! redis-cli -h "$MOTHERSHIP_HOST" -p "$MOTHERSHIP_PORT" ping 2>/dev/null | grep -q PONG; then
  echo "[first-boot] WARNING: Mothership unreachable, retrying..."
  for i in {1..5}; do
    sleep 5
    if redis-cli -h "$MOTHERSHIP_HOST" -p "$MOTHERSHIP_PORT" ping 2>/dev/null | grep -q PONG; then
      echo "[first-boot] Connected to mothership"
      break
    fi
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

# Create systemd service
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
echo

# Summary
echo "[4/5] Configuration complete"
echo
echo "=== Bootstrap Summary ==="
echo "Hostname: $HOSTNAME_PREFIX-{random}"
echo "Mothership: $MOTHERSHIP_ADDR"
echo "Status: Ready to bootstrap"
echo

# Start first-boot (if systemd is running)
echo "[5/5] Starting bootstrap..."
if systemctl is-system-running 2>/dev/null; then
  systemctl start argus-first-boot.service &
  echo "First-boot service started"
  echo "Check status with: journalctl -u argus-first-boot -f"
else
  echo "Systemd not running. Service will start on next boot."
  echo "To start now manually: systemctl start argus-first-boot.service"
fi

echo
echo "Node will join Tailscale, then wait for mothership setup commands."
echo
