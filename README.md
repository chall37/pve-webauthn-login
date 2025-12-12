# pve-webauthn-login

WebAuthn passwordless login for Proxmox VE. Enables TouchID, Windows Hello, hardware security keys, and other passkey authenticators as a standalone login method, bypassing password entry.

## Features

- **Passwordless authentication** using WebAuthn/FIDO2
- **Support for** TouchID, Windows Hello, YubiKey, and other security keys
- **No modification to Proxmox system files**
- **Easy installation** via install script or Debian package

## Requirements

- Proxmox VE 8.4.14 or 9.1.2 (see [COMPATIBILITY.md](COMPATIBILITY.md) for tested versions)
- WebAuthn must be configured in Datacenter options
- User must have a WebAuthn credential registered (via Two Factor settings)

## Installation

Run on your Proxmox server:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/chall37/pve-webauthn-login/main/install.sh)"
```

The script automatically detects your Proxmox version and installs the correct package.

### Manual installation

Download the .deb for your Proxmox version from [GitHub Releases](https://github.com/chall37/pve-webauthn-login/releases):

```bash
wget https://github.com/chall37/pve-webauthn-login/releases/download/v2025.12.2/pve-webauthn-login_2025.12.2_all.deb
dpkg -i pve-webauthn-login_2025.12.2_all.deb
```

### Building from source

```bash
git clone https://github.com/chall37/pve-webauthn-login.git
cd pve-webauthn-login
dpkg-buildpackage -us -uc -b
dpkg -i ../pve-webauthn-login_*.deb
```

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
- Wrapper scripts that load the module before pveproxy/pvedaemon start

The wrappers use `dpkg-divert` to intercept the original binaries. No Proxmox system files are modified directly.

## Upgrades

**Important:** This package requires an exact Proxmox version match. When Proxmox updates to a new version, this package will be automatically removed to prevent conflicts. Re-run the install script to install a compatible version:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/chall37/pve-webauthn-login/main/install.sh)"
```

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
