#!/bin/bash
# pve-webauthn-login installer
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/chall37/pve-webauthn-login/main/install.sh)"
#        curl ... | bash -s -- --no-auto-update

set -e

# Parse arguments
NO_AUTO_UPDATE=false
for arg in "$@"; do
    case $arg in
        --no-auto-update)
            NO_AUTO_UPDATE=true
            ;;
    esac
done

REPO="chall37/pve-webauthn-login"
COMPAT_URL="https://raw.githubusercontent.com/$REPO/main/compatibility.json"
KEY_URL="https://raw.githubusercontent.com/$REPO/main/keys/pve-webauthn-login.asc"
EXPECTED_FINGERPRINT="D408D1D8A4B730F47EE17FE7FD3723E6F0A2ABD7"

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

# Download .deb (use secure temp directory)
DEB_FILE="pve-webauthn-login_${RELEASE_VERSION}_all.deb"
DEB_URL="https://github.com/$REPO/releases/download/$RELEASE/$DEB_FILE"
SIG_URL="${DEB_URL}.asc"
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT
TMP_DEB="$TMP_DIR/$DEB_FILE"
TMP_SIG="$TMP_DIR/${DEB_FILE}.asc"

info "Downloading $DEB_FILE..."
curl -fsSL "$DEB_URL" -o "$TMP_DEB" || error "Failed to download $DEB_URL"

# Download and verify GPG signature
info "Downloading signature..."
curl -fsSL "$SIG_URL" -o "$TMP_SIG" || error "Failed to download signature. Release may not be signed."

info "Verifying GPG signature..."
# Import public key (suppressing output, will fail silently if already imported)
curl -fsSL "$KEY_URL" 2>/dev/null | gpg --import 2>/dev/null || true

# Verify the key fingerprint matches expected (security: ensure our key, not any valid key)
if ! gpg --fingerprint "$EXPECTED_FINGERPRINT" >/dev/null 2>&1; then
    error "GPG key fingerprint mismatch - possible tampering detected"
fi

# Verify signature
if ! gpg --verify "$TMP_SIG" "$TMP_DEB" 2>/dev/null; then
    error "GPG signature verification failed! The package may have been tampered with.

If this is a new installation, ensure you're using the official repository.
If updating, this could indicate a security issue - do not proceed."
fi
info "Signature verified successfully"

# Install
info "Installing package..."
dpkg -i "$TMP_DEB" || error "Package installation failed"

# Cleanup handled by trap

info "Successfully installed pve-webauthn-login $RELEASE_VERSION"

# Disable auto-update timer if requested
if [ "$NO_AUTO_UPDATE" = true ]; then
    info "Disabling auto-update timer (--no-auto-update specified)"
    systemctl disable pve-webauthn-login-update.timer 2>/dev/null || true
    systemctl stop pve-webauthn-login-update.timer 2>/dev/null || true
fi

echo ""
echo "Next steps:"
echo "  1. Configure WebAuthn in Datacenter → Options → WebAuthn Settings"
echo "  2. Register a passkey in Datacenter → Permissions → Two Factor"
echo "  3. Use 'Login with Passkey' button on the login page"
echo ""
echo "For more info: https://github.com/$REPO"
