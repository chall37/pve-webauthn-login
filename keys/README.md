# GPG Public Key

This directory contains the GPG public key used to verify signed releases.

## `pve-webauthn-login.asc`

The public key file used by `install.sh` to verify package signatures.

To generate this file:

```bash
gpg --armor --export YOUR_KEY_ID > keys/pve-webauthn-login.asc
```

Replace `YOUR_KEY_ID` with your GPG key ID (e.g., email or key fingerprint).
