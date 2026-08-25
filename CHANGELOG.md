# Changelog

## [0.1.0] - 2026-08-25

- Document the complete WSL2 server, Windows LAN boundary, local Workbench,
  authenticated WebUI gateway, and application ownership model.
- Add versioned application deployments with `releases`, `shared`, `current`,
  atomic switching, health gates, and automatic rollback.
- Record source commit and retained previous release metadata in the registry.
- Add registry-backed WebUI application links to the local Workbench while
  filtering internal applications, invalid hostnames, and secret paths.
- Extend render-only installation, strict validation, and self-tests for the
  versioned deployment contract and legacy registry compatibility.
