# C5VRX repository grounding

`Twotoz/C5VRX` is the canonical project repository.

- Current implementation: `/main`
- Current hardware-proven findings: `/docs`
- Historical experiments: `/legacy/c5vrx1`
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
- It publishes the static `web/` directory from `main` to GitHub Pages.
- It runs when `web/**` (or the Pages workflow itself) changes on `main`, or
  when manually dispatched.
- Firmware-only PRs and firmware releases do not need a Pages deployment.
- The deployed JavaScript discovers firmware dynamically through the public
  GitHub Releases API.

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

Do not copy PR binaries into `web/` and do not create a PR-specific Pages
deployment. The flow is:

```text
PR commit
  -> build.yml
  -> validated firmware artifacts
  -> GitHub prerelease tag pr-<number>
  -> existing GitHub Pages app queries /releases at runtime
  -> PR Builds tab filters prerelease tags matching ^pr-[0-9]+$
  -> user explicitly selects and confirms experimental flash
```

The **Releases** tab must contain only semantic-version releases. Experimental
`pr-<number>` firmware belongs only in the separate **PR Builds** tab and must
never become the default selection.

A web UI change made in a PR is not visible on the production Pages site until
that change is merged into `main` and `deploy-web.yml` completes. The PR
firmware prerelease itself can still be discovered by whatever flasher UI is
currently deployed.


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

The web flasher must not depend on a third-party CORS proxy for firmware
downloads. Release discovery still uses GitHub's Releases API, but binary
downloads should prefer each asset's API `url` with:

```http
Accept: application/octet-stream
X-GitHub-Api-Version: 2022-11-28
```

Public release assets can be downloaded through this GitHub endpoint without a
user token. The asset's `browser_download_url` may be kept only as a GitHub
fallback. Do not reintroduce `corsproxy.io` or another external proxy into
the production flasher.
