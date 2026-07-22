# Magic Voice Direct-Distribution Runbook

Magic Voice is distributed outside the Mac App Store. App Sandbox must remain
off: global activation-key monitoring, Accessibility insertion, clipboard paste
fallback, and the Python sidecar process do not fit the current sandbox design.

> **Release gate:** no distributable release is ready until Developer ID signing,
> Apple notarization, stapling, Gatekeeper verification, clean-account runtime
> smoke testing, and the dependency/model license review all pass.

## Release architecture

The app bundles four runtime resources at the top of `Contents/Resources` and a
native process supervisor beside the main executable:

```text
Magic Voice.app/Contents/
  MacOS/
    Magic Voice
    MagicVoiceProcessSupervisor
  Resources/
    sidecar.py
    pyproject.toml
    uv.lock
    uv
```

`ManagedRuntimeProvisioner` resolves those exact `Bundle.main` resource names.
On first run it copies them into the user's Application Support directory, then
runs the bundled `uv` with `--frozen`, managed Python 3.12, and the checked-in
lockfile. Python, locked packages, and the selected model require network access
on a clean machine; they are not embedded in the DMG.

The `uv` executable is deliberately not committed or added to Xcode's Copy
Bundle Resources phase. `scripts/release_macos.sh` downloads it, verifies it,
injects it at `Contents/Resources/uv`, and signs it before signing the app.

`MagicVoiceProcessSupervisor` is a native Xcode target embedded in the app. It
launches each owned command as the leader of a dedicated process group while
preserving the command's standard streams. The production sidecar, one-shot
model download, app sidecar smoke path, and managed-runtime provisioning all go
through this helper; therefore the group includes any `uv`, Python, and deeper
worker descendants created by those paths.

The helper registers `EVFILT_PROC`/`NOTE_EXIT` with `kqueue` for the exact Magic
Voice parent PID before it launches the worker. This avoids PID polling and PID
reuse races. If that parent crashes or is Force Quit, the helper sends `SIGTERM`
to the entire worker process group, waits three seconds, then sends `SIGKILL` to
the group and reaps its direct child. The helper exits after cleanup; it is not a
persistent daemon. This boundary covers descendants launched through the helper,
not unrelated processes, power loss, or an operating-system crash.

Normal app termination is cooperative first: Magic Voice sends the sidecar's
JSON `shutdown` message and returns `terminateLater` while bounded teardown runs.
If the worker does not exit, terminating the helper invokes the same process-group
`SIGTERM`/three-second/`SIGKILL` sequence. This termination deferral is important:
do not replace it with cleanup that depends only on object deinitialization.

## Fixed release inputs

`scripts/fetch_uv.sh` pins the official Astral `uv` macOS arm64 artifact:

- Version: `0.11.31`
- Asset: `uv-aarch64-apple-darwin.tar.gz`
- SHA-256: `b2b93e82a6786f9c7cb89fd4ca0e859a147b292ae8f6f95784f9742f0efec39e`
- Origin: `https://github.com/astral-sh/uv/releases/tag/0.11.31`

The acquisition step downloads both the archive and its official `.sha256`
file. It requires the official checksum to equal the trusted value pinned in
the script, verifies the archive bytes, confirms the extracted file is an arm64
Mach-O executable, and installs only `uv`. If Astral's checksum and the trusted
pin differ, the release fails with an instruction to review the release. To
upgrade `uv`, review Astral's release notes and update the version, asset, and
checksum together in one auditable change.

The sidecar's Python and dependency inputs remain pinned by:

- `sidecar/.python-version`
- `sidecar/pyproject.toml`
- `sidecar/uv.lock`

## Xcode and signing policy

The Release app target has:

- `ENABLE_HARDENED_RUNTIME = YES`
- `ENABLE_APP_SANDBOX = NO`
- `CODE_SIGN_ENTITLEMENTS = magic-voice/magic-voice.entitlements`
- bundle identifier `ai.arailabs.magic-voice`
- `LSUIElement = YES`
- microphone and Apple Events usage descriptions

The release pipeline creates an unsigned arm64 archive first. It then signs in
this order with Developer ID Application, `--options runtime`, and a secure
timestamp:

1. Every Mach-O file inside the app, including bundled `uv`,
   `Contents/MacOS/MagicVoiceProcessSupervisor`, native libraries, and other
   executables.
2. Nested frameworks, XPC services, app extensions, bundles, plugins, and apps,
   depth-first.
3. `Magic Voice.app` last, with `magic-voice.entitlements`.
4. The finished DMG container.

The verifier runs `codesign --verify --deep --strict`, checks each Mach-O has a
Developer ID signature from the app's Team ID, Hardened Runtime, and a secure
timestamp, and fails if the app contains `com.apple.security.get-task-allow`.
It separately requires the named process supervisor to be an executable arm64
Mach-O and records that this exact path passed the per-file Developer ID checks;
finding some other signed Mach-O is not sufficient. It also confirms the
required runtime resources and arm64 `uv` are present.

Do not use ad-hoc signing for a production artifact and do not replace this
ordering with `codesign --deep --sign`; `--deep` is a verification convenience,
not a safe signing strategy.

## Library-validation tradeoff

`magic-voice.entitlements` intentionally enables
`com.apple.security.cs.disable-library-validation`. The managed environment is
created after installation and includes MLX, NumPy, and other native `.so` or
`.dylib` code that cannot be Developer ID signed by this build pipeline. Without
this entitlement, Hardened Runtime may prevent the sidecar from loading those
downloaded libraries.

This weakens one Hardened Runtime protection: code loaded by the app's process
tree does not have to be signed by the same Apple team. It does not disable the
rest of Hardened Runtime, and the release pipeline still signs all native code
that is present inside the shipped app. Removing the entitlement requires a new
runtime design that embeds and signs every native dependency before distribution.

## One-time signing setup

Install a valid **Developer ID Application** certificate in the signing
keychain. Confirm the exact identity without exporting private key material:

```sh
security find-identity -v -p codesigning
```

Store notarization credentials in Keychain. Omitting `--password` makes
`notarytool` prompt instead of placing the app-specific password in shell history:

```sh
xcrun notarytool store-credentials "magic-voice-notary" \
  --apple-id "release@example.com" \
  --team-id "YOURTEAMID"
```

The scripts accept only that Keychain profile name. They do not accept, export,
or print Apple passwords, private keys, or App Store Connect API secrets.

## Release commands

First exercise all local control flow without network, certificates, or Apple
credentials:

```sh
scripts/test_release_scripts.sh
scripts/release_macos.sh --dry-run
```

Acquire and inspect the exact pinned runtime independently when needed:

```sh
scripts/fetch_uv.sh --output dist/runtime/uv
shasum -a 256 dist/runtime/uv
file dist/runtime/uv
```

For a real release, supply non-secret identifiers through the environment and
run the complete pipeline:

```sh
export MARKETING_VERSION="1.0.0"
export BUILD_NUMBER="100"
export DEVELOPER_ID_APPLICATION="Developer ID Application: Example Company (YOURTEAMID)"
export NOTARYTOOL_PROFILE="magic-voice-notary"

scripts/release_macos.sh
```

The fixed output names are:

```text
dist/archive/Magic-Voice-<version>-<build>.xcarchive
dist/release/Magic-Voice-<version>-<build>.dmg
dist/release/Magic-Voice-<version>-<build>.dmg.notary-result.json
```

The top-level script refuses to overwrite an existing archive or DMG. The DMG
always contains exactly `Magic Voice.app` and an `Applications` symlink with
normalized staging timestamps. Secure timestamps and filesystem metadata mean
the signed DMG is not byte-for-byte reproducible, but its name and layout are
deterministic for a given version and build number.

Stages can also be audited or rerun individually:

```sh
scripts/sign_macos_release.sh \
  "dist/archive/Magic-Voice-1.0.0-100.xcarchive/Products/Applications/Magic Voice.app"

scripts/verify_macos_release.sh \
  "dist/archive/Magic-Voice-1.0.0-100.xcarchive/Products/Applications/Magic Voice.app"

scripts/package_macos_release.sh \
  --output "dist/release/Magic-Voice-1.0.0-100.dmg" \
  "dist/archive/Magic-Voice-1.0.0-100.xcarchive/Products/Applications/Magic Voice.app"

scripts/notarize_macos_release.sh \
  "dist/release/Magic-Voice-1.0.0-100.dmg"
```

After acceptance, the notarization stage runs `stapler staple`, `stapler
validate`, and:

```sh
spctl --assess --type open --context context:primary-signature --verbose=4 \
  "dist/release/Magic-Voice-1.0.0-100.dmg"
```

## Bundled-resource verification

Before signing, or from the archived app, verify the release-only injection:

```sh
APP="dist/archive/Magic-Voice-1.0.0-100.xcarchive/Products/Applications/Magic Voice.app"
test -f "$APP/Contents/Resources/sidecar.py"
test -f "$APP/Contents/Resources/pyproject.toml"
test -f "$APP/Contents/Resources/uv.lock"
test -x "$APP/Contents/Resources/uv"
test -x "$APP/Contents/MacOS/MagicVoiceProcessSupervisor"
file "$APP/Contents/MacOS/MagicVoiceProcessSupervisor"
lipo -archs "$APP/Contents/Resources/uv"
lipo -archs "$APP/Contents/MacOS/MagicVoiceProcessSupervisor"
```

After signing, use the repository verifier and inspect entitlements explicitly:

```sh
scripts/verify_macos_release.sh "$APP"
codesign -d --entitlements :- "$APP"
codesign --verify --strict --verbose=2 \
  "$APP/Contents/MacOS/MagicVoiceProcessSupervisor"
codesign -dvvv "$APP/Contents/MacOS/MagicVoiceProcessSupervisor"
```

The entitlement output must include
`com.apple.security.cs.disable-library-validation`, and must not include
`com.apple.security.get-task-allow`.

## Third-party license gate

Before publishing, create and review a redistributable license/notices inventory
for all shipped or downloaded components, including:

- the pinned `uv` executable and its license/notices;
- Python 3.12 downloaded by `uv`;
- every direct and transitive package in `sidecar/uv.lock`, especially native
  MLX, NumPy, audio, codec, and Hugging Face components;
- `mlx-community/nemotron-3.5-asr-streaming-0.6b` and the low-memory model variant,
  including model-card terms, weights license, attribution, and acceptable use;
- any bundled Apple-platform assets or third-party notices added later.

The repository's MIT license covers Magic Voice source. It does not grant rights
to redistribute `uv`, Python, downloaded packages, or model weights. A successful
notarization is a malware/signature check, not a license approval.

## Clean-account smoke checklist

Run this on a separate Apple Silicon Mac or fresh macOS account that has never
installed Magic Voice, `uv`, Homebrew Python, the model, or the sidecar packages.
Do not claim release readiness from the developer account alone.

- Confirm the DMG passes the `spctl` command above and has a valid stapled ticket.
- Mount the DMG, confirm it contains one `Magic Voice.app` and the Applications
  shortcut, then drag the app to `/Applications` and launch it from Finder.
- Confirm Gatekeeper opens the app without an override and the app has no Dock
  icon while its menu-bar item appears.
- Confirm the installed app contains executable arm64
  `Contents/Resources/uv`, an executable arm64 and Developer ID-signed
  `Contents/MacOS/MagicVoiceProcessSupervisor`, plus `sidecar.py`,
  `pyproject.toml`, and `uv.lock`.
- With no system `uv` or Python available, begin first-run setup. Confirm the app
  downloads managed Python 3.12 and exactly the frozen dependencies, reports
  progress, and reaches ready state. Test retry after interrupting the network.
- Confirm the selected Nemotron model downloads, progress does not hang, and the
  model/license disclosure matches the actual artifact. Budget roughly 1.2 GB
  for the default model plus Python, packages, and caches.
- Grant Microphone and Accessibility permissions. Verify hold-to-talk and
  double-tap toggle from another app on real hardware.
- Verify final text is inserted only once. Force Accessibility fallback and
  confirm every original clipboard item is restored after success and failure.
- With `fn` selected, verify the original `AppleFnUsageType` behavior returns
  after pause, normal quit, force quit plus relaunch, and crash recovery.
- Cancel one transcription and immediately complete another; no stale event may
  appear. Quit during the main sidecar, one-shot model download, app smoke, and
  managed-runtime provisioning paths and confirm no supervisor, sidecar, `uv`,
  Python, or deeper worker remains orphaned. Repeat with Force Quit and the
  repository host-death fixture; descendants that ignore `SIGTERM` must be gone
  after the three-second grace and `SIGKILL` escalation.
- Restart the Mac/account and repeat launch and dictation from `/Applications`.
  Confirm no developer checkout path, Homebrew tool, or Xcode environment is used.

Record the macOS version, hardware, DMG SHA-256, signing Team ID, notarization
submission ID, model IDs/licenses, and checklist result with the release record.
