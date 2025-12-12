# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Auto-update mechanism via daily systemd timer
- Graceful degradation - module fails safely if incompatible, Proxmox runs normally
- Client-side error handling for backend unavailability
- Troubleshooting section in README

### Security
- GPG signature verification for all package downloads
- GPG signature verification for install.sh during auto-updates
- Release workflow signs both .deb packages and install.sh
- Public key bundled with package for offline verification
- Auto-update downloads from releases (not main branch) with signature verification

### Changed
- Wrappers now use eval to catch load failures
- API endpoints return appropriate error messages:
  - Auth failures: generic "authentication failure"
  - Config issues: specific guidance (e.g., "WebAuthn is not configured")
  - Internal errors: version conflict guidance with syslog reference
- Perl module path is now version-agnostic

### Fixed

### Removed
