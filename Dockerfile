# Dockerfile for Argus Node
# Minimal container with Tailscale + Redis substrate
# Based on Alpine Linux

FROM alpine:latest

LABEL description="Argus autonomous mesh node"
LABEL maintainer="phxdev1"

# Install substrate: Tailscale + Redis client
RUN apk add --no-cache \
    bash \
    curl \
    ca-certificates \
    redis \
    tailscale

# Create runtime directories
RUN mkdir -p /etc/argus /usr/local/lib/argus

# Copy bootstrap script
COPY docker-entrypoint.sh /usr/local/lib/argus/entrypoint.sh
RUN chmod +x /usr/local/lib/argus/entrypoint.sh

# Container runs bootstrap on start
ENTRYPOINT ["/usr/local/lib/argus/entrypoint.sh"]

# Usage:
#   docker build -t argus-node .
#
#   docker run --cap-add=NET_ADMIN \
#     -e TAILSCALE_KEY=tskey-... \
#     -e MOTHERSHIP_ADDR=argus.soay-boa.ts.net:6379 \
#     argus-node
#
# Environment Variables:
#   TAILSCALE_KEY (required)  - Tailscale auth key
#   MOTHERSHIP_ADDR (optional) - Mothership Redis address
#   HOSTNAME_PREFIX (optional) - Hostname prefix (default: argus)
