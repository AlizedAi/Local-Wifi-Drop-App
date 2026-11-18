# AI handoff — Windows client branch

## Required starting point
- Repository: `AlizedAi/Local-Wifi-Drop`
- Active branch: `windows-from-1.0.158`
- Base commit: `4b7385eef268e29d01414f0bcc9c8e49b949e519`
- Never continue this task on `main` or the Android release branch.
- Read `PROJECT_STATUS.md`, `NEXT_STEP.md`, `CHANGELOG.md`, `BUGS.md`, `docs/PRODUCT_SPEC.md`, `ARCHITECTURE.md` and `docs/TRANSFER_PROTOCOL.md` before further edits.

## User constraints
- Reply concisely in Persian.
- Do not change the Android app or its behavior; all work stays on the isolated Windows branch.
- Do not add personal design choices, optional improvements or scope changes without approval.
- No cloud, account, relay, internet dependency or paid service.
- Keep RAM bounded; never buffer whole files.
- Do not add encryption or change protocol semantics.
- Do not build an APK as part of this Windows task.
- Keep source, UI, tests, docs, status and handoff synchronized.
- Never claim CI or physical testing passed unless the actual result is visible.
- Ask only when a genuine blocking ambiguity or issue appears; do not ask for screenshots.

## Existing protocol — preserve exactly
- File discovery: UDP 39475; short-lived `lwd://connect` invitation; direct TCP; HELLO with one-time pairing credentials; MANIFEST; receiver ACCEPT/REJECT; bounded streaming; incremental SHA-256; FILE_OK only after final storage.
- Message discovery: UDP 39476; direct TCP TEXT_MESSAGE; no HELLO, pairing or authentication; ACCEPT after receiver storage in the active in-memory ChatStore.
- Both use plain unencrypted TCP. Warn users not to send sensitive content on untrusted networks.
- Do not change frame codes, protocol version, ports, nonce format, invitation format, timeout or transfer state machine without explicit user approval.

## Windows implementation scope
- Reuse the existing Flutter Send/Receive UI and Dart TCP/UDP protocol core.
- Windows runner is generated in CI with `flutter create --platforms=windows --project-name local_wifi_drop .`; the workflow builds a portable x64 ZIP containing the EXE, DLLs and Flutter data.
- Windows build version is read from root file `windows_version.txt` (initially 1.0.159); keep it unchanged for retries and increment only for a new intended build.
- Windows uses Flutter file_picker/open_filex and a user-selected receive folder.
- Windows discovery uses portable UDP broadcast and manual private IPv4 entry. It does not currently enumerate every router client.
- Windows inbound TCP/UDP requires Windows Defender Firewall permission on Private networks. The portable ZIP must exclude `dartjni.dll`/`jvm.dll` and bundle `msvcp140.dll`, `vcruntime140.dll` and `vcruntime140_1.dll`; the app must not require Java or a separate VC++ runtime install.
- Windows message reception exists only while the app process is running. Native notifications, native tones, Android settings and persistent Log storage are not implemented on Windows.
- Removing a received-file row on Windows must preserve the file on disk.
- Windows UDP responder uses `reusePort: false`; do not revert this platform guard.
- Android-only network inventory is called only on Android. Android settings rows are hidden on Windows.

## Validation requirements
1. Windows CI run #7 passed analysis, 163 tests (2 Android-only skips), Release compilation and package validation. The inspected 1.0.159 ZIP contains the EXE, Flutter assets, `flutter_windows.dll` and the three required VC runtime DLLs; no `dartjni.dll`/`jvm.dll` remains. Physical Windows↔Android tests are still required.
2. Confirm the ZIP contains the EXE, `data/flutter_assets`, required DLLs and README.
3. Confirm Android source/behavior remains unchanged by platform guards; do not trigger Android APK workflows.
4. Physical tests required in both directions: Windows↔Android file transfer, message delivery, receiver approval/rejection, large files, firewall and storage behavior.
5. Record actual results in `docs/DEVICE_TEST_MATRIX.md`; CI alone does not verify interoperability.

## Important version note
The release label used as the branch base is 1.0.158, but the base commit's `pubspec.yaml` reports `1.0.148+148`. Keep the Android package version untouched. The Windows workflow passes its own build version starting at 1.0.159.

## Handoff
Update `PROJECT_STATUS.md`, `NEXT_STEP.md`, `BUGS.md`, `CHANGELOG.md`, README and relevant technical docs in the same change set. Explicitly list any remaining build or device-validation gaps.
