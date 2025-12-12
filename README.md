# pve-webauthn-login

WebAuthn passwordless login for Proxmox VE. Enables TouchID, Windows Hello, hardware security keys, and other passkey authenticators as a standalone login method, bypassing password entry.

## Features

- **Passwordless authentication** using WebAuthn/FIDO2
- **Support for** TouchID, Windows Hello, YubiKey, and other security keys
- **No modification to Proxmox system files** - survives updates
- **Easy installation** via Debian package

## Requirements

- Proxmox VE 8.0 or later
- WebAuthn must be configured in Datacenter options
- User must have a WebAuthn credential registered (via Two Factor settings)

## Installation

### From .deb package

```bash
# Copy the package to your Proxmox server (replace VERSION with actual version)
scp pve-webauthn-login_VERSION-1_all.deb root@proxmox:/tmp/

# Install
ssh root@proxmox "dpkg -i /tmp/pve-webauthn-login_*_all.deb"
```

### Building from source

On a Debian/Ubuntu system with build tools:

```bash
git clone https://github.com/chall37/pve-webauthn-login.git
cd pve-webauthn-login
dpkg-buildpackage -us -uc -b
```

The package will be created in the parent directory.

## Usage

1. **Configure WebAuthn** in Proxmox:
   - Go to Datacenter → Options → WebAuthn Settings
   - Set the Relying Party, Origin, and ID to match your Proxmox URL

2. **Register a WebAuthn credential** for your user:
   - Go to Datacenter → Permissions → Two Factor
   - Add → WebAuthn
   - Follow the prompts to register your TouchID/security key

3. **Login with Passkey**:
   - On the login page, enter your username
   - Click "Login with Passkey"
   - Authenticate with TouchID/security key

## How It Works

This package installs:

- A Perl module that registers new API endpoints for passwordless WebAuthn login
- JavaScript that adds a "Login with Passkey" button to the login form
- A systemd drop-in that loads the module when pveproxy starts

No Proxmox system files are modified. Everything is installed to `/usr/local/` and `/etc/systemd/system/`, which are not touched by Proxmox updates.

## Uninstallation

```bash
apt remove pve-webauthn-login
```

## Security

- WebAuthn challenges include a 60-second timeout
- Challenge tickets are cryptographically signed with Proxmox's RSA key
- Only users with registered WebAuthn credentials can use this flow
- User must exist and be enabled in Proxmox
- Origin verification is handled by the WebAuthn standard
- All authentication attempts are logged

## License

MIT License - see [LICENSE](LICENSE) for details.

## Contributing

Pull requests welcome! Please open an issue first to discuss proposed changes.
