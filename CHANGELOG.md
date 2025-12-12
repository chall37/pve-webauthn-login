# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Auto-update mechanism via daily systemd timer
- Graceful degradation - module is designed to fail safely if incompatible
- Client-side error handling for backend unavailability
- Troubleshooting section in README
- `--no-auto-update` flag for install.sh to disable auto-updates on install
- Documentation for disabling/re-enabling auto-updates

### Security
- GPG signature verification for all package downloads
- GPG fingerprint hardcoded to prevent key substitution attacks
- Tag format validation prevents injection in update script
- Fix username enumeration via error code differences
- Secure temp file handling (mktemp -d)
- Release workflow signs both .deb packages and install.sh
- Public key bundled with package for offline verification
- Auto-update downloads from releases (not main branch) with signature verification
- Signed compatibility.json prevents downgrade attacks
- Rollback support: installed .deb saved to /var/cache/pve-webauthn-login/

### Changed
- Update script rewritten as self-contained check-then-act (no longer calls install.sh)
- Wrappers now use eval to catch load failures
- Package dependency loosened to pve-manager >= 9.1.2 (persists across upgrades)
- Package upgrades preserve auto-update timer enabled/disabled state
- README disclaimer expanded with supply chain and fitness warnings
- API endpoints return appropriate error messages:
  - Auth failures: generic "authentication failure"
  - Config issues: specific guidance (e.g., "WebAuthn is not configured")
  - Internal errors: version conflict guidance with syslog reference
- Perl module path is now version-agnostic

### Fixed
- Unknown users now return same error as disabled users (prevents enumeration)

### Removed
