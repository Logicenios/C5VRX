# C5VRX repository grounding

`Twotoz/C5VRX` is the canonical project repository.

- Current implementation: `/main`
- Current hardware-proven findings: `/docs`
- Historical experiments: `/legacy/c5vrx1` and `/legacy/c5vrx2`
- Preserved archive discussions: `/docs/legacy-issues`

`legacy/c5vrx1` is reference material, not current production code. Always
search it when investigating ESP32-C5 RF/PHY, MODEM_DIAG, IQ capture, analog
video, WBFM, PARLIO, DAC hardware, receiver-console behavior, or an architecture
that may already have been attempted.

When historical assumptions conflict with newer physical C5VRX evidence,
current hardware findings in `/docs` take precedence. Do not reintroduce a
rejected architecture before reading the corresponding current and legacy
findings that explain its failure.

## Current realtime invariants

- VTX presence and USB must never gate or pace IQ production.
- The normal live source is MODEM_DIAG Q4/I4 captured by PARLIO RX; active
  MAC-owned dump SRAM is a diagnostic writer, not a readable live source.
- Do not turn a physical SRAM or DMA block boundary into a DSP reset.
- Do not claim sample-gapless RF or AV transport without its physical proof.
- The normal live path recovers the transmitted composite waveform; it does not
  decode pixels or regenerate PAL/NTSC.
- Keep USB/debug outside realtime pacing.
- Do not silently change the tested XIAO D4..D9 DAC pin order or the physical
  8.2k/3.9k/2k/1k/470R/240R plus 200R network.


## Releases, PR builds, and web flasher deployment

The web flasher has one production host: **GitHub Pages** at
`https://twotoz.github.io/C5VRX/`. Do not add or document a VPS, proxy
application server, second production host, or per-PR website deployment unless
the project explicitly changes hosting architecture.

### Website deployment

- `.github/workflows/deploy-web.yml` is the only production web deployment.
- It always checks out trusted `main` before constructing the Pages artifact.
- It publishes `web/` plus a generated same-origin `firmware/` mirror.
- It runs for web changes on `main`, manually, and after successful Production
  CI so new/updated/removed PR builds and new releases refresh the mirror.
- Browser release discovery should use the generated
  `firmware/releases.json` manifest first.

### Normal release versioning

`.github/workflows/build.yml` only mints semantic versions on a **push to
`main`**. Development branches and PR builds do not receive a normal version.

The next version is derived from commits since the latest stable tag:

- `BREAKING CHANGE` or a conventional-commit `!` -> major bump.
- `feat:` / `feat(scope):` -> minor bump.
- `fix:`, `chore:`, `docs:`, tests, and other changes -> patch bump.
- If the repository has no stable tag but has the current prerelease line,
  the first stable release promotes that prerelease base (for example
  `v3.0.0-rc1` -> `v3.0.0`).
- The resolved numeric version is written to `version.txt` before the
  ESP-IDF build so firmware metadata and the GitHub release stay aligned.
- Stable semantic-version release assets are immutable. Never reuse a stable
  version tag for different firmware.

Because commit prefixes affect the next release number, choose conventional
commit prefixes intentionally.

### PR firmware publication

For a same-repository pull request targeting `main`:

1. CI validates the architecture/DSP contract.
2. CI builds the firmware and creates the normal release artifacts, including
   `c5vrx3.bin`, `c5vrx3_merged.bin`, bootloader, partition table,
   `flasher_args.json`, and checksums.
3. `publish-pr-build` creates a GitHub **prerelease** tagged
   `pr-<PR_NUMBER>` and targets it at the current PR head SHA.
4. Every new PR commit recreates that mutable `pr-<number>` prerelease so its
   assets always correspond to the latest tested PR head.
5. When the PR closes or merges, `cleanup-pr-build` deletes the temporary
   prerelease and tag.

Fork PRs must not receive write-capable release publication. Keep the
same-repository guard on `publish-pr-build`.

### How PR builds reach the flasher

Do not commit generated PR binaries into `web/` and do not deploy untrusted
PR web code. The production Pages deployment always checks out trusted
`main`, then mirrors firmware release assets server-side into the Pages
artifact.

```text
PR commit
  -> build.yml validates + builds firmware
  -> GitHub prerelease tag pr-<number>
  -> Production CI completes successfully
  -> deploy-web.yml checks out main
  -> tools/prepare_pages_site.sh downloads current release assets server-side
  -> Pages artifact contains firmware/pr-<number>/...
  -> firmware/releases.json adds same-origin local_url entries
  -> PR Builds tab downloads from twotoz.github.io itself
  -> user explicitly confirms experimental flash
```

The **Releases** tab contains semantic-version releases; **PR Builds** contains
only `pr-<number>` prereleases. The Pages mirror keeps the newest 20 semantic
firmware releases plus all currently active PR prereleases.

A web UI change made in a PR is still not deployed until merged into `main`.
PR firmware can trigger a Pages **mirror refresh**, but that refresh checks out
`main` and therefore cannot deploy unmerged PR HTML/JavaScript.


### CI concurrency on merge

A merged pull request generates two relevant events almost simultaneously:
`pull_request: closed` and `push` to `main`. For a merged/closed PR GitHub
can expose `github.ref` as `refs/heads/main`, so a concurrency group based
only on `github.ref` is unsafe: the lightweight PR cleanup run can cancel the
real main firmware build and semantic release.

Keep Production CI concurrency separated by event type and PR identity:

```yaml
group: ${{ github.workflow }}-${{ github.event_name }}-${{ github.event.pull_request.number || github.ref }}
```

Do not simplify this back to `${{ github.workflow }}-${{ github.ref }}`.
The latter caused main release runs after merged PRs to be cancelled within
seconds.


### Browser download path for release assets

The production browser must download firmware **same-origin from GitHub
Pages**. Direct browser fetches of GitHub Release assets are not reliable:
GitHub can redirect binary requests to storage origins that do not satisfy the
browser CORS request.

`tools/prepare_pages_site.sh` runs inside GitHub Actions, where CORS does not
apply. It downloads selected GitHub Release assets and places them under
`firmware/<tag>/` in the Pages artifact. It also generates
`firmware/releases.json`, adding `local_url` to each mirrored asset.

`web/app.js` must prefer `asset.local_url`. GitHub asset/API URLs are only a
development fallback when the Pages manifest is unavailable. Never add a
third-party CORS proxy, and do not make production flashing depend on
cross-origin GitHub binary fetches.


## IQ Fusion Engine experimental contract

The experimental `FUSION EXP` profile may combine multiple estimators from a
completed Q4/I4 control snapshot, but it must never insert CPU processing into
the 40 MS/s realtime path.

Useful fusion evidence includes adjacent 25 ns phase deltas, 50 ns endpoint
winding disagreement, lag-4 disagreement, robust local phase-slope consensus,
near-origin confidence, Q_phase, clipping, I/Q centering/skew and bounded
semantic-video validation.

The slow learner may select only PHY states whose actuator semantics are
already established. A symbol name in the closed PHY blob is not sufficient
evidence for production use. Undocumented LNA/BB/filter controls require a
prototype, register-diff and raw-Q4 A/B before becoming learner actions.

At the range edge, loss of sync/video is never by itself evidence to reduce
sensitivity. NO_CARRIER must return to the known high-gain survival state.
Clean/high-confidence IQ should produce zero PHY writes.

Exact adjacent-FM waveform fusion remains gated by issue #23. Every 40 MS/s IQ
sample must participate before 2:1 reduction, and a live implementation must
prove sustained hardware throughput plus state continuity before replacing the
current gapless BitScrambler path.
