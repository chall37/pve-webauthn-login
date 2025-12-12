#!/bin/bash
# pve-webauthn-login installer
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/chall37/pve-webauthn-login/main/install.sh)"

set -e

REPO="chall37/pve-webauthn-login"
COMPAT_URL="https://raw.githubusercontent.com/$REPO/main/compatibility.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "Please run as root (e.g., sudo bash install.sh)"
fi

# Check if this is a Proxmox system
if ! command -v pveversion &> /dev/null; then
    error "pveversion not found. Is this a Proxmox VE system?"
fi

# Get PVE version
PVE_VERSION=$(dpkg-query -W -f='${Version}' pve-manager 2>/dev/null) || error "Could not determine pve-manager version"
info "Detected Proxmox VE version: $PVE_VERSION"

# Fetch compatibility map
info "Checking compatibility..."
COMPAT_JSON=$(curl -fsSL "$COMPAT_URL" 2>/dev/null) || error "Could not fetch compatibility data from GitHub"

# Find matching release (using grep/sed since jq might not be installed)
RELEASE=$(echo "$COMPAT_JSON" | grep "\"$PVE_VERSION\"" | sed 's/.*: *"\([^"]*\)".*/\1/')

if [ -z "$RELEASE" ]; then
    error "No compatible release found for PVE $PVE_VERSION

Check https://github.com/$REPO/releases for available versions.
If you believe this version should be supported, please open an issue."
fi

info "Found compatible release: $RELEASE"

# Check current installation (must be actually installed, not just config-files)
CURRENT=""
if dpkg-query -W -f='${db:Status-Status}' pve-webauthn-login 2>/dev/null | grep -q "^installed$"; then
    CURRENT=$(dpkg-query -W -f='${Version}' pve-webauthn-login 2>/dev/null)
fi
RELEASE_VERSION="${RELEASE#v}"  # Strip 'v' prefix

if [ "$CURRENT" = "$RELEASE_VERSION" ]; then
    info "Already installed at latest compatible version ($CURRENT)"
    exit 0
elif [ -n "$CURRENT" ]; then
    info "Upgrading from $CURRENT to $RELEASE_VERSION"
else
    info "Installing version $RELEASE_VERSION"
fi

# Download .deb
DEB_FILE="pve-webauthn-login_${RELEASE_VERSION}_all.deb"
DEB_URL="https://github.com/$REPO/releases/download/$RELEASE/$DEB_FILE"
TMP_DEB="/tmp/$DEB_FILE"

info "Downloading $DEB_FILE..."
curl -fsSL "$DEB_URL" -o "$TMP_DEB" || error "Failed to download $DEB_URL"

# Install
info "Installing package..."
dpkg -i "$TMP_DEB" || error "Package installation failed"

# Cleanup
rm -f "$TMP_DEB"

info "Successfully installed pve-webauthn-login $RELEASE_VERSION"
echo ""
echo "Next steps:"
echo "  1. Configure WebAuthn in Datacenter → Options → WebAuthn Settings"
echo "  2. Register a passkey in Datacenter → Permissions → Two Factor"
echo "  3. Use 'Login with Passkey' button on the login page"
echo ""
echo "For more info: https://github.com/$REPO"
