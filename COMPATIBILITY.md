# Compatibility Matrix

This document tracks Proxmox component versions that this plugin has been tested against.

## Last Tested

| Component | Version | Date | Notes |
|-----------|---------|------|-------|
| Proxmox VE | 8.x | 2025-12-11 | Initial release |
| pve-access-control | - | 2025-12-11 | Uses verify_ticket, assemble_ticket |
| pve-manager | - | 2025-12-11 | Patches pveproxy service |
| pve-http-server | - | 2025-12-11 | Overrides auth_handler |
| proxmox-widget-toolkit | - | 2025-12-11 | Integrates with LoginWindow |

## Upstream Repositories

These are the Proxmox repositories that may affect this plugin:

- [pve-access-control](https://github.com/proxmox/pve-access-control) - Authentication and ticket handling
- [pve-manager](https://github.com/proxmox/pve-manager) - PVE web UI and pveproxy service
- [pve-http-server](https://github.com/proxmox/pve-http-server) - HTTP server and auth handler
- [proxmox-widget-toolkit](https://github.com/proxmox/proxmox-widget-toolkit) - ExtJS components including LoginWindow

## Update Notifications

A GitHub Action runs daily to check for updates to upstream Proxmox repositories.
When updates are detected, an issue is automatically created for validation.
