# Changelog

## [0.2.2] - 2026-08-26

- Remove the accidental ripgrep runtime dependency from audit, rendering, and
  self-test scripts by using baseline `grep` and `find` operations.
- Add a regression that places a failing ripgrep sentinel first in `PATH` and
  proves production renderers do not invoke it or silently ignore its absence.

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

## [0.2.1] - 2026-08-26

- Reject symbolic-link or overlapping project-sync state directories before
  granting write access or creating reports.
- Isolate staged-release verification hooks with Bubblewrap so they can write
  only to the temporary candidate release, not retained or active releases.

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
