# Changelog

All notable changes to this fork are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Upstream history before the refactor is in `git log` (baseline `upstream/main` = `96446ed`).

## [Unreleased]

### Added
- Phase 0 recon: `docs/refactor/00-recon.md` covers the baseline build (ESP-IDF v6.0.2,
  1,113,280-byte app, no compiler warnings, 2 Kconfig warnings) and an architecture map of the
  RF → MODEM_DIAG → PARLIO → BitScrambler → DAC path. It also covers DSP facts checked against
  FM theory, RF gain-loop classification, a receive-only audit, dead code, stale claims and
  magic constants.
- `docs/UPSTREAM_TRIAGE.md`: verdicts for all 67 upstream issues and PRs, plus the
  hardware-measured facts and TX concerns found in them.
