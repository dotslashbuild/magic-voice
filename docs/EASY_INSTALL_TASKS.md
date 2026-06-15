# Easy Install Task Plan

This plan continues PR #1 (`feat-onboarding`) toward a no-terminal install path for normal Mac users.

Current state:

- PR: https://github.com/dotslashbuild/magic-voice/pull/1
- Branch: `feat-onboarding`
- First-run setup UI/state exists in the menu-bar popover.
- `SettingsStore` tracks setup completion per selected model.
- `ManagedUvRuntimeLocator` expects a bundled `uv` executable and copies `sidecar.py`, `pyproject.toml`, and `uv.lock` into Application Support before running `uv run --frozen --managed-python`.
- Known blocker: the Xcode project bundles `sidecar.py` and `pyproject.toml`, but not `uv.lock` or `uv`.

## Subagent Architecture

Engineering Manager owns sequencing, task boundaries, and final verification.

Scout Programmer handles read-only research:

- Inspect Xcode project resource wiring, signing settings, and release docs.
- Confirm how `uv` should be placed in the bundle and how bundled resources are resolved at runtime.
- Identify gaps between README, packaging docs, and app behavior.

Builder Programmer handles implementation:

- Make narrow commits with tests where practical.
- Keep PR #1 focused on first-run setup and packaged-runtime readiness.
- Defer release automation and public docs that do not block the current PR.

Verification/QA owns clean-run proof:

- Run unit tests and build checks.
- Inspect built `.app` contents.
- Run first-run smoke checks with a clean Application Support/defaults state.

## Recommended Order

1. MV-INSTALL-01: bundle locked sidecar resources.
2. MV-INSTALL-02: bundle and validate `uv`.
3. MV-INSTALL-03: add packaged-app resource verification.
4. MV-INSTALL-04: run clean first-run QA.
5. MV-INSTALL-05: update install-facing README copy.
6. MV-INSTALL-06: add local DMG/release script.
7. MV-INSTALL-07: license inventory.

Tasks 01-05 should be PR #1 follow-up commits. Tasks 06-07 should be separate PRs unless PR #1 stays open specifically to cover packaging.

## Task Cards

### MV-INSTALL-01 - Bundle `uv.lock` With The App

- Owner: Builder Programmer
- PR target: PR #1 follow-up commit
- Context:
  - `magic-voice.xcodeproj/project.pbxproj` currently lists `sidecar.py` and `pyproject.toml` in Copy Bundle Resources, but not `uv.lock`.
  - `ManagedUvRuntimeLocator.prepareManagedProject` copies `uv.lock` from the bundled sidecar directory into Application Support.
  - `docs/PACKAGING.md` already documents this as a release blocker.
- Scope:
  - Add `sidecar/uv.lock` to the project group and app target Copy Bundle Resources.
  - Do not change sidecar dependency resolution.
- Acceptance criteria:
  - A Debug or Release build includes `uv.lock` next to `sidecar.py` and `pyproject.toml` in `Magic Voice.app/Contents/Resources`.
  - Existing `SidecarRuntimeLocatorTests.managedUvCopiesLockedProjectIntoApplicationSupport` still passes.
- Verification:
  - `xcodebuild -project magic-voice.xcodeproj -scheme magic-voice -configuration Debug build CODE_SIGNING_ALLOWED=NO`
  - `find ~/Library/Developer/Xcode/DerivedData -path '*Magic Voice.app/Contents/Resources/uv.lock' -print | head`
  - `xcodebuild -project magic-voice.xcodeproj -scheme magic-voice test`
- Dependencies/blockers:
  - None.

### MV-INSTALL-02 - Bundle `uv` Runtime For Product Builds

- Owner: Scout Programmer then Builder Programmer
- PR target: PR #1 follow-up commit
- Context:
  - `ManagedUvRuntimeLocator` defaults to `Bundle.main.url(forResource: "uv", withExtension: nil)`.
  - Public builds must not show `brew install uv`.
  - The first public release is Apple Silicon-only, so start with an arm64 `uv` binary.
- Scope:
  - Scout confirms the local source path for the `uv` binary to vendor or stage. Prefer a deterministic script or documented local input over committing an opaque downloaded binary without review.
  - Builder adds a repeatable path for placing `uv` into `Contents/Resources`.
  - Ensure the resource is executable in the built app.
  - Do not bundle Python or the speech model.
- Acceptance criteria:
  - Built app contains `Contents/Resources/uv`.
  - `FileManager.default.isExecutableFile` would return true for the bundled `uv`.
  - If `uv` is missing, the app still reports the existing clear runtime error.
- Verification:
  - `xcodebuild -project magic-voice.xcodeproj -scheme magic-voice -configuration Debug build CODE_SIGNING_ALLOWED=NO`
  - `test -x "<built app>/Contents/Resources/uv"`
  - `"<built app>/Contents/Resources/uv" --version`
  - `xcodebuild -project magic-voice.xcodeproj -scheme magic-voice test`
- Dependencies/blockers:
  - Need a decision on whether the `uv` binary is checked into the repo, fetched by a packaging script, or provided as a local build input.
  - Need license note for redistributed `uv` before public release.

### MV-INSTALL-03 - Add Packaged-App Resource Verification

- Owner: Builder Programmer
- PR target: PR #1 follow-up commit
- Context:
  - Unit tests validate runtime-locator behavior, but not Xcode bundle output.
  - CI already builds the app with `CODE_SIGNING_ALLOWED=NO`.
- Scope:
  - Add a lightweight script or CI step that checks the built app resources include `sidecar.py`, `pyproject.toml`, `uv.lock`, and `uv`.
  - Keep it path-tolerant for DerivedData.
  - Avoid model downloads in CI.
- Acceptance criteria:
  - CI fails if required resources are absent from the built app.
  - The check does not require signing credentials or network access.
- Verification:
  - `xcodebuild -project magic-voice.xcodeproj -scheme magic-voice -configuration Debug build CODE_SIGNING_ALLOWED=NO`
  - Run the new resource-check script/step locally.
- Dependencies/blockers:
  - Depends on MV-INSTALL-01.
  - For `uv` checks, depends on MV-INSTALL-02.

### MV-INSTALL-04 - Clean First-Run QA Pass

- Owner: Verification/QA
- PR target: PR #1 follow-up commit only if bugs are found; otherwise no code commit
- Context:
  - First-run setup starts after Microphone and Accessibility permissions.
  - Dictation is blocked until the selected model is marked setup-complete.
  - Setup completion marker is stored per `STTModel.rawValue`.
- Scope:
  - Exercise a clean state on Apple Silicon with no developer `uv` requirement.
  - Confirm first-run setup downloads Python dependencies and model into Application Support.
  - Verify retry behavior by simulating a failed setup when practical.
- Acceptance criteria:
  - Fresh launch shows permission banner first.
  - After permissions, menu bar shows `Setting Up`.
  - Dictation cannot start while setup is incomplete.
  - Successful setup records the selected model marker and starts the engine.
  - Relaunch shows `Ready` without repeating setup.
  - Switching to the 8-bit model triggers setup for that model; switching back does not.
- Verification:
  - `xcodebuild -project magic-voice.xcodeproj -scheme magic-voice test`
  - Manual clean run after clearing app defaults/Application Support for the test account.
  - Optional sidecar protocol smoke: `uv run --project sidecar python scripts/smoke_sidecar.py`
- Dependencies/blockers:
  - Depends on MV-INSTALL-01 and MV-INSTALL-02 for a realistic packaged run.
  - Requires Apple Silicon hardware and time for first model download.

### MV-INSTALL-05 - Update Install-Facing README Copy

- Owner: Builder Programmer
- PR target: PR #1 follow-up commit
- Context:
  - `README.md` still says packaged runtime is pending and Quick Start is developer-only.
  - The strategic first public release is Apple Silicon-only, manual updates, signed/notarized DMG, first-run model download.
- Scope:
  - Add a short "Public Install Status" or "Coming Public Install" section.
  - Keep developer Quick Start intact until a signed DMG exists.
  - Mention Apple Silicon, no terminal for public builds, and first-run download size/expectation.
- Acceptance criteria:
  - README no longer implies Homebrew/terminal will be required for the public easy-install path.
  - Developer instructions still clearly require `uv`.
  - README, `CONTEXT.md`, and `docs/PACKAGING.md` do not contradict each other.
- Verification:
  - Manual markdown review.
  - `rg -n "brew install uv|Apple Silicon|DMG|packaged runtime|public binary" README.md docs/PACKAGING.md CONTEXT.md`
- Dependencies/blockers:
  - Best done after MV-INSTALL-01/02 implementation details are known.

### MV-INSTALL-06 - Add Local DMG Build Script

- Owner: Scout Programmer then Builder Programmer
- PR target: separate PR
- Context:
  - `docs/PACKAGING.md` has manual archive/notarization notes but no repeatable script.
  - First release uses manual updates and a drag-to-Applications DMG.
- Scope:
  - Add a local script that archives/exports the app and creates a DMG.
  - If signing/notarization environment variables are absent, script should fail clearly or run an unsigned local-only mode.
  - Do not add Sparkle or auto-update.
- Acceptance criteria:
  - One documented command produces a DMG artifact.
  - Signing/notarization steps are explicit and do not hard-code credentials.
  - Output DMG contains `Magic Voice.app` and an Applications symlink.
- Verification:
  - Script dry run or unsigned local run.
  - `xcrun stapler validate "<artifact>"` for signed/notarized builds.
  - Manual install from generated DMG on a clean account.
- Dependencies/blockers:
  - Requires Developer ID credentials for final notarized verification.
  - Should follow MV-INSTALL-01 and MV-INSTALL-02.

### MV-INSTALL-07 - Third-Party License Inventory

- Owner: Scout Programmer
- PR target: separate PR
- Context:
  - `docs/PACKAGING.md` requires license inventory before publishing binaries.
  - Redistributed/downloaded pieces include `uv`, Python packages, and Hugging Face models.
- Scope:
  - Inventory `sidecar/pyproject.toml`, `sidecar/uv.lock`, bundled `uv`, and model license terms.
  - Add a concise docs file or release checklist section.
- Acceptance criteria:
  - Release manager can tell what is redistributed in the DMG versus downloaded on first run.
  - Any license that requires notice is captured.
  - Any model/package license risk is surfaced before public binary release.
- Verification:
  - Manual review of generated inventory.
  - `uv tree --project sidecar` or equivalent dependency listing.
- Dependencies/blockers:
  - Need final decision from MV-INSTALL-02 on how `uv` is sourced.
  - May require web research against upstream license pages before public release.
