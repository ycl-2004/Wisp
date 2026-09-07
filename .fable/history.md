# Wisp 0.3.0 Release Preparation

## Status
Complete: source, tag, and hosted GitHub Release are published as Wisp 0.3.0.

## Goal
Prepare a verified Wisp 0.3.0 package from the latest `origin/main`, with all release metadata and user-facing documentation synchronized.

## Acceptance Criteria
- Local work is based on the latest fetched `origin/main` without overwriting unrelated user changes.
- Every authoritative release/version entry is updated to `0.3.0`.
- README/release documentation reflects the current release when an update is warranted.
- The repository's release build/package workflow succeeds and its artifacts are identified.
- No remote push or hosted release is performed without separate explicit authorization.

## Requirements
1. Use the latest remote `main` as the release baseline.
2. Upgrade the release version to `0.3.0` using the latest code.
3. Update all release-related metadata consistently.
4. Review and update README content as needed.
5. Build/package and verify the release.
6. Use the product name `Antigravity` instead of `AGY` in both READMEs while preserving the `agy` CLI command.
7. Publish `v0.3.0` on GitHub and make it the Latest release with both verified assets attached.

## Decision Log
- Treat `docs/agy-cli-research.md` as unrelated user work and preserve it untouched.
- Interpret “打包一份” as producing and verifying local release artifacts; publishing/pushing remains out of scope until explicitly authorized.

## Evidence
- Fetched and fast-forwarded local `main` to `origin/main` commit `943a816`.
- `xcodegen generate` succeeded with XcodeGen 2.45.4.
- `xcodebuild test ... CODE_SIGNING_ALLOWED=NO` succeeded: 11 tests, 0 failures.
- Universal 2 Release build succeeded with Xcode 26.6.
- Built bundle reports `CFBundleShortVersionString=0.3.0` and `CFBundleVersion=5`.
- `lipo -info` reports `x86_64 arm64`; strict deep signature verification succeeds; `get-task-allow` is absent.
- ZIP round-trip signature verification succeeds; archive has no `__MACOSX` or `._` entries.
- `dist/Wisp-macOS-universal.zip.sha256` verifies; SHA-256 is `bdf652aa0eef505945933af269755c08feb6ffdbfc3cf773b71284d85acd93b1`.
- At the local preparation checkpoint, GitHub still listed `v0.2.0` as latest; no tag or hosted Release was created.
- Release preparation committed as `c312d86` and pushed to `origin/main`; independent `git ls-remote` verification returned the same full commit hash.
- Antigravity README correction committed as `b665041` and pushed to `origin/main`.
- Annotated tag `v0.3.0` resolves to `b665041` locally and on GitHub.
- GitHub Release `Wisp 0.3.0` is published, non-draft, non-prerelease, and marked Latest.
- Both assets report uploaded state; the ZIP's remote digest matches the locally verified SHA-256 `bdf652aa0eef505945933af269755c08feb6ffdbfc3cf773b71284d85acd93b1`.
