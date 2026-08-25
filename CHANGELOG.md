# Changelog

## [0.2.0] - 2026-08-25

- Add opt-in, registry-driven periodic project maintenance with read-only
  `fetch-only` as the default and immutable approved-release staging that never
  switches `current`.
- Add hardened user service/timer templates, private atomic status reports,
  render-only installation, strict registry validation, and offline fixtures.
- Reserve `auto-deploy` in the registry contract while rejecting its execution
  until a separate reviewed deployment policy exists.
- Normalize client delivery addresses to `https://APP_ID.SERVER_NAME.local/`
  while retaining aliases only as an explicit migration measure.

## Unreleased

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
