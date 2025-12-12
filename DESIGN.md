# Design

## Overview

This package enables WebAuthn/passkey authentication as a standalone login method for Proxmox VE, bypassing password entry entirely.

## Architecture

### Integration Strategy

The package integrates with Proxmox without modifying system files:

1. **Binary Wrappers**: Uses `dpkg-divert` to intercept pveproxy and pvedaemon binaries, loading the custom Perl module before the original services start.

2. **API Endpoints**: Registers two new endpoints on `PVE::API2::AccessControl`:
   - `POST /access/webauthn-challenge` - Generate a signed challenge for a user
   - `POST /access/webauthn-login` - Verify WebAuthn response and issue session ticket

3. **Frontend**: Injects JavaScript into the login page that adds a "Login with Passkey" button and handles the WebAuthn browser API.

### Authentication Flow

```
User enters username
        │
        ▼
[Login with Passkey] ──► Backend generates challenge
        │                 (signed ticket with 60s timeout)
        ▼
Browser WebAuthn API ──► User authenticates with passkey
        │
        ▼
Backend verifies ──► Issues session ticket + CSRF token
```

### Graceful Degradation

The module is designed to fail safely. If loading fails due to Proxmox API changes, the wrappers catch the error and start the original services normally. Proxmox continues to function without passkey login.

## Security Model

- Challenge tickets are cryptographically signed with Proxmox's RSA key
- 60-second challenge timeout
- WebAuthn origin verification handled by the browser standard
- Only users with registered WebAuthn credentials can use this flow
- User must exist and be enabled in Proxmox
- All authentication attempts are logged to syslog
- Generic error messages prevent username enumeration

## Auto-Update Mechanism

A daily systemd timer checks for updates:

1. Validates release tag format (prevents injection)
2. Downloads and verifies signed `compatibility.json`
3. Checks if current Proxmox version has a compatible release
4. Downloads `.deb` and verifies GPG signature against hardcoded fingerprint
5. Installs only after all checks pass
6. Saves installed `.deb` for potential rollback

All release artifacts (`.deb`, `install.sh`, `compatibility.json`) are GPG-signed.
