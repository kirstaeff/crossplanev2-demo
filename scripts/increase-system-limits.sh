#!/bin/bash
# Helper script to increase system limits for running multiple kind clusters
# This script requires sudo privileges

set -e

echo "=========================================="
echo "Increasing System Limits for Kind Clusters"
echo "=========================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run with sudo privileges."
  echo "Usage: sudo ./scripts/increase-system-limits.sh"
  exit 1
fi

echo "Step 1: Increasing inotify limits"
echo "----------------------------------"

# Display current limits
echo "Current limits:"
echo "  fs.inotify.max_user_watches = $(sysctl -n fs.inotify.max_user_watches)"
echo "  fs.inotify.max_user_instances = $(sysctl -n fs.inotify.max_user_instances)"

# Set new limits
sysctl -w fs.inotify.max_user_watches=524288
sysctl -w fs.inotify.max_user_instances=512

echo ""
echo "New limits:"
echo "  fs.inotify.max_user_watches = $(sysctl -n fs.inotify.max_user_watches)"
echo "  fs.inotify.max_user_instances = $(sysctl -n fs.inotify.max_user_instances)"

echo ""
echo "Step 2: Making limits persistent"
echo "---------------------------------"

# Create sysctl config file if it doesn't exist
SYSCTL_CONF="/etc/sysctl.d/99-kind-clusters.conf"

cat > "$SYSCTL_CONF" <<EOF
# System limits for running multiple kind clusters
# Created by crossplane v2 POC setup

# Increase inotify limits for file watching
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512

# Increase max file descriptors
fs.file-max=2097152
EOF

echo "Configuration saved to: $SYSCTL_CONF"

# Apply settings
sysctl -p "$SYSCTL_CONF"

echo ""
echo "Step 3: Increasing file descriptor limits"
echo "------------------------------------------"

# Update limits.conf for file descriptors
LIMITS_CONF="/etc/security/limits.d/99-kind-clusters.conf"

cat > "$LIMITS_CONF" <<EOF
# File descriptor limits for running multiple kind clusters
# Created by crossplane v2 POC setup

*               soft    nofile          65536
*               hard    nofile          65536
*               soft    nproc           65536
*               hard    nproc           65536
EOF

echo "Configuration saved to: $LIMITS_CONF"

echo ""
echo "=========================================="
echo "System Limits Updated Successfully!"
echo "=========================================="
echo ""
echo "Applied limits:"
echo "  - inotify max_user_watches: 524288"
echo "  - inotify max_user_instances: 512"
echo "  - file-max: 2097152"
echo "  - nofile (soft/hard): 65536"
echo "  - nproc (soft/hard): 65536"
echo ""
echo "⚠ IMPORTANT:"
echo "  - Logout and login again for file descriptor limits to take effect"
echo "  - Or run: exec su -l $SUDO_USER"
echo ""
echo "You can now run: ./scripts/cluster-setup.sh"
echo ""
