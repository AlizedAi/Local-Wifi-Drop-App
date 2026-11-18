## 2026-11-18 — Windows x64 build 1.1.00
- Fixed selected-file size display and total-size calculation by using PlatformFile.lengthSync() with an asynchronous PlatformFile.length() fallback when the picker does not report a size.
- Updated Windows build metadata and artifact version to 1.1.00.
- Portable ZIP now contains only the executable, runtime/plugin DLLs and Flutter data required to run; debug symbols and documentation are excluded.

## 2026-11-17 — Windows x64 build 1.0.159 verified
- Windows CI run #7 passed `flutter analyze`, all Windows-hosted tests (163 passed, 2 Android-specific tests skipped), Release compilation, package checks and artifact upload.
- Downloaded and inspected the portable ZIP. It contains `Local-Wifi-Drop.exe`, Flutter assets, `flutter_windows.dll`, `msvcp140.dll`, `vcruntime140.dll` and `vcruntime140_1.dll`.
- Confirmed `dartjni.dll` and `jvm.dll` are absent. The portable package does not require Java/JDK or a separate Visual C++ runtime installation.
- Version: 1.0.159. Physical Windows↔Android interoperability remains to be tested.

## 2026-11-17 — Remove unused JVM DLL from portable bundle
- Run #5 confirmed that removing the `jni` entry from generated CMake alone did not prevent Flutter from copying `dartjni.dll` into the Release directory.
- The packaging step now explicitly deletes that unused DLL from the Release bundle and checks that it is absent before creating the portable ZIP. The app has no Windows code path that calls JNI, so it does not need a JVM.
- The ZIP README now states that Java/JDK is not required.
- Run #6 must verify the Java-free ZIP. Runs #4 and #5 are not distribution packages.

## 2026-11-17 — Remove unused JVM dependency from Windows bundle
- Windows CI run #4 passed analysis, the Windows test suite and the Release build.
- Inspecting the actual PE imports in the portable ZIP found `dartjni.dll` importing `jvm.dll`. The app does not use JNI on Windows, so shipping that unused DLL would unnecessarily require a Java runtime on every user's PC.
- The workflow now removes the unused `jni` FFI plugin entry from the generated Windows CMake plugin list before configuration, builds with `--no-pub`, and fails packaging if `dartjni.dll` remains.
- Run #4's ZIP is not the final user package. Run #5 must confirm the JNI-free portable ZIP and the complete Release contents.

## 2026-11-17 — Windows test portability fixes
- Windows CI run #3 passed `flutter analyze` and executed the test suite: 159 passed, 4 failed, 2 skipped.
- Two cancellation tests expected POSIX forward-slash paths. Their assertions now use `Platform.pathSeparator`, preserving the same transfer behavior across Windows and Android/Linux.
- The Windows About version suffix now uses real newline escapes rather than displaying literal backslash-n text. Existing English/Persian About tests now allow the Windows-only version suffix.
- Windows CI run #4 is pending. No Windows executable has been produced yet.

## 2026-11-17 — Repaired Windows workflow version-step YAML
- Windows CI run #2 was rejected before a job started because the generated version-validation script had malformed YAML after the initial edit.
- Replaced the workflow file with a clean, complete version. It reads the build version from `windows_version.txt` and validates the three numeric segments without changing the Android package version.
- Run #1's analyzer blocker remains fixed with a targeted deprecation suppression; run #3 will verify the full pipeline.
- No Windows EXE/ZIP has been built yet.

## 2026-11-17 — Fixed first Windows CI analyzer blocker
- The first Windows workflow run generated the Windows runner and resolved all packages, then stopped at `flutter analyze` because the shared directory-picker call is deprecated in the current `file_picker` API.
- Kept the existing picker call and added a targeted `deprecated_member_use` suppression. This preserves the Android runtime behavior and keeps the Windows directory picker on the already-supported API.
- Windows build version is now controlled by root file `windows_version.txt`, initially 1.0.159. Failed CI attempts do not consume a version number.
- Updated the Windows Exit action to close the desktop process directly; Android continues using its existing `SystemNavigator.pop` behavior.
- Corrected stale UI/project documentation to reflect the removed matrix background and the current in-process message receiver.
- Windows workflow retry is pending; no Windows executable has been produced yet.

## 2026-11-17 — Windows x64 client port (implementation in progress)
- Started the Windows client on the isolated `windows-from-1.0.158` branch, based on commit `4b7385eef268e29d01414f0bcc9c8e49b949e519`. The Android release branch and `main` are not modified.
- Reused the existing TCP file-transfer protocol, HELLO pairing, receiver approval, bounded streaming, incremental SHA-256 and independent message transport. No wire-format or security-model change.
- Added Windows-safe UDP socket binding (`reusePort` disabled on Windows), guarded Android-only LAN inventory scanning, and preserved received files when removing their entries from the Windows in-app list.
- Added a Windows x64 CI workflow that generates the standard Flutter Windows runner, resolves dependencies, runs analysis and tests on Windows, builds a portable Release package and uploads it as an artifact.
- Windows app-peer discovery, firewall behavior, Windows file picker/storage/open behavior and Android↔Windows interoperability remain unverified until the workflow and physical two-device tests pass.
- Windows CI build numbering starts at `1.0.159` (158 + this workflow's run number). The base commit's `pubspec.yaml` still says `1.0.148+148`; Android version metadata is not changed by this Windows-only workflow.

## 2026-11-14 — Addressed current Android UI test findings; LAN discovery changed to broadcast
- Replaced the native subnet/ARP/ICMP/TCP host scan in the Send peer picker with direct UDP broadcast discovery on the existing message-discovery port 39476. The picker now lists only active Local WiFi Drop message responders; manual IP verification remains unchanged.
- Newly selected files are inserted at the beginning of the outgoing selection list.
- Kept the Options popup at 200 logical pixels wide while reducing its height. Alert, Log and Languages are centered; EN/FA are centered below Languages.
- Reduced the Alert List panel to 180 logical pixels wide, changed its heading to “Alert List”, and anchored the Alert popup opened from Options below the header Alert button.
- Added widget coverage for Alert List placement/width/title and Options label/language layout; updated the peer-picker test for broadcast discovery timing.
- The user still reports the header Alert icon is not visible despite its keyed widget existing. The Log panel is still reported in the wrong location; its intended original anchor needs clarification and has not been changed.
- Fresh CI is required for the final source and documentation commits. Two-device Android discovery and transfer testing remain outstanding. No new APK has been built yet.

## 2026-11-14 — Verified latest checks-only CI and closed UDP discovery test regression
- Latest Flutter checks (no APK) run #701 on commit `21da186725f94b3842300a30a285ada719d14fa4` passed dependency resolution (`flutter pub get`; 79 dependencies resolved), `flutter analyze` (`No issues found!`) and all 150 tests. [Run #701](https://github.com/AlizedAi/Local-Wifi-Drop/actions/runs/43389942889).
- Investigated failed run #686: the message-peer discovery test started its responder on ephemeral UDP port 0, while the client correctly queried the fixed message discovery port. The test therefore received no peers.
- Existing commit `5b15b50345e759a1cbd9fc90878994b3841db9c9` corrected the test responder to bind `LocalPeerDiscoveryClient.messagePort`; run #687 passed, and run #701 confirms the regression remains fixed. No production-code change was needed in this maintenance pass.
- No APK was built, uploaded or released. Android native compilation and physical two-device interoperability remain unverified.

## 2026-11-13 — Synchronized direct message transport across code, UI and project records
- Corrected the Send peer picker and manual-IP validation to use `discoverMessagePeers`, which reads the message discovery response's IP and advertised TCP port. The file-discovery parser expects an invitation and must not be used for messages.
- Confirmed the message path is direct plain TCP: no encryption, HELLO, password, pairing token, session credential or peer authentication. The receiver stores the message before automatically returning ACCEPT; ACCEPT confirms storage only.
- Kept file transfer unchanged: its separate discovery endpoint, invitation, HELLO authentication and receiver approval remain.
- Updated the product spec, security model, transfer protocol, UI design, architecture, README, status, handoff, decisions, known issues, next step and UI session notes to match.
- CI run #687 passed dependency resolution, `flutter analyze` and all Flutter tests before this UI-discovery correction. Fresh CI is required for this correction. Android native compilation and two-device interoperability remain unverified. No APK was built.

## 2026-11-13 — Removed message pairing and authentication
- Message discovery now returns only the active receiver IP and open TCP port.
- The sender connects directly to that IP/port and sends TEXT_MESSAGE without HELLO, password, token, session credential or authentication.
- The background message service accepts a direct TCP connection. File-transfer pairing/authentication is unchanged.
- Kept discovery-based online-device filtering and the receiver persistence-before-ACCEPT delivery acknowledgement.
- Added direct-connect and message-discovery tests. Fresh CI validation is pending; no APK was built.

## 2026-11-13 — Separated Message from file transfer and shared both Message windows
- Added a dedicated message discovery endpoint on UDP 39476; file discovery remains on UDP 39475, avoiding responder port contention.
- Added LocalMessageClient. Each message uses its own authenticated TCP connection and TEXT_MESSAGE frame; the receiver persists it before ACCEPT.
- Both Send and Receive screens now use one app-wide ChatStore. Both Message windows use the same selected peer IP; an incoming message selects its sender as the peer, so either tab can send.
- The Android foreground message service owns the message listener while the UI is foregrounded or backgrounded. Notification permission is requested, and notifications include the received message text.
- Peer selection and manual IP entry require a live message-service discovery response; offline or non-app devices are not selectable as message destinations.
- Removed foreground Receive-screen message approval and persistent chat-socket dependencies. File transfer continues on its separate listener and discovery port.
- Added ChatStore, independent message transport, discovery-port and shared Send/Receive widget tests.
- CI run #654 stopped at analysis because of one unused test import; the import was removed.
- CI run #655 passed analysis and 142 tests. Three widget tests were updated to reflect the live-peer filter and shared transcript.
- CI run #656 passed analysis and 144 tests; the remaining peer-picker widget test still depended on real UDP timing.
- CI run #657 passed analysis and 144 tests; peer filtering was extracted into an injectable class and the widget test no longer depends on real UDP.
- CI run #658 passed analysis and 148 tests; the shared-selected-peer widget assertion was corrected to inspect the selector's displayed text rather than casting its InkWell wrapper.
- CI run #659 stopped at analysis on one `prefer_const_constructors` lint in the new filter test; corrected.
- CI run #660 passed dependency resolution, `flutter analyze` and all 149 tests. Android native compilation and two-device testing remain outstanding.
- **CI verified; device unverified** pending two-physical-device Android testing. No APK was built.

## 2026-11-13 — Expanded operational event logging and verified Log suite
- Added records for Options menu open/dismiss, file-picker outcomes, manual destination selection, Send file removal, received-file list expansion/selection, Receive-screen incoming/reply message outcomes, paste outcomes and transfer-history clearing.
- Message contents remain excluded from logs.
- Added a test proving transfer-history clearing is recorded.
- CI run #643 on commit `8688484edef611393744ed7aee1f064cbd1f415c`: dependency resolution, `flutter analyze` and all 140 tests passed.
- Android-device persistence, clipboard and touch behavior remain unverified. No APK was built.

## 2026-11-13 — Completed Application Log hardening and CI verification
- Fixed the asynchronous restore race, isolated malformed saved records, and coalesced private/public persistence writes to prevent unbounded obsolete-snapshot queues.
- Kept the Log panel selection attached to stable entry identities and corrected the selection/copy test to verify copied text belongs to the intended Log entry.
- Verified the existing three-dot Options > Log route from both Send and Receive; panel geometry, Clear-only header and Copy / Select all toolbar passed automated tests.
- CI run #626 on commit `d2381d3ebd9286524ef771bf66c65eb9bae7c632`: dependency resolution, `flutter analyze` and all 139 tests passed.
- Android-device persistence, clipboard and touch behavior remain unverified. No APK was built.

## 2026-11-13 — Corrected Log copy assertion
- Confirmed Flutter long-press selects the word under the pointer; the clipboard test now verifies that copied text comes from the exact Log entry and is not the Options menu label.
- CI run #625: analysis passed; 138 tests passed and one clipboard assertion failed due to expecting the entire line from a word selection. Fresh CI validation pending. No APK was built.

## 2026-11-13 — Corrected Log storage callback types
- Updated the default storage callbacks to use explicitly typed methods; the first persistence-coalescing CI run caught a Dart constructor-initializer typing error.
- Fresh CI validation pending. No APK was built.

## 2026-11-13 — Prevented Log persistence backlog
- Coalesced concurrent persistence requests so frequent transfer-progress events cannot queue many obsolete full-history JSON writes.
- Added injectable storage callbacks for deterministic tests of restore races, malformed saved records and write coalescing.
- Fresh CI validation pending. No APK was built.

## 2026-11-13 — Hardened Log restoration and Options access
- Fixed a restore race so log events recorded while saved history is loading are retained.
- A malformed saved entry is skipped without discarding other valid entries.
- Log row selection now tracks entry objects rather than list positions, preventing a newly recorded event from shifting selection to a different row.
- Scoped the text-selection test to the exact test entry inside the Log overlay; the newest menu-selection event can appear above it.
- Added severity/listener controller tests and a Receive > Options > Log widget test. The Send > Options > Log route remains covered.
- Fresh CI validation pending. No APK was built.

## 2026-11-13 — Corrected Log selection toolbar test scope
- The previous CI failure was a false positive: the test searched for Paste across the entire screen and matched the Send screen's own Paste button.
- Scoped Copy, Select all, Cut and Paste assertions to the floating AdaptiveTextSelectionToolbar. The Log panel already filters its toolbar to Copy and Select all; no production UI behavior changed.
- Fresh CI validation is pending. No APK was built.

## 2026-11-13 — Added lightweight acknowledged chat transcript
- Replaced the single latest-message display with a compact in-memory transcript on Send and Receive, capped at 30 recent entries per screen; no foreground chat-history database or disk persistence was added.
- Kept the three-line composer text black. Incoming messages remain black; outgoing messages stay black while pending and turn green only after the matching delivery acknowledgement.
- Added protocol-v2 CHAT_MESSAGE / CHAT_ACK frames with sender-local message IDs so acknowledgements remain distinguishable when both peers send messages.
- The first foreground message still uses the existing receiver approval and ACCEPT/REJECT flow. Background inbox delivery remains one-way and continues to persist before ACCEPT.
- Added protocol codec, TCP loopback acknowledgement and widget color/transcript tests.
- Implemented — unverified pending fresh CI and two-physical-device Android testing. No APK was built.

## 2026-11-13 — Restricted Log text selection menu
- Kept the Log panel header with Clear log as its only action.
- Configured each read-only log entry's floating text-selection menu to show Copy and Select all only; Cut and Paste are omitted.
- Added a widget test for the two allowed actions, absence of Cut/Paste, and successful clipboard copy.
- CI validation is pending. Physical-device behavior remains unverified; no APK was built.

## 2026-11-12 — Simplified Log panel header
- Removed the Copy selected and Copy all buttons from the Log panel header; Clear log is now its only action.
- Kept the SYSTEM LOG title, event count, selectable log rows and manual text selection/copying.
- Added widget assertions that the two copy buttons are absent and Clear log remains.
- CI run #610 passed dependency resolution, `flutter analyze` and all 124 tests, including the Log geometry test; the earlier 32-pixel RenderFlex overflow did not recur.
- Physical-device layout remains unverified. No APK was built.

undefined## 2026-11-12 — Fixed Options label hit testing and Log overlay anchor
- Attached `_logMenuLabelKey` to the actual Log text so the overlay can resolve its position instead of returning without opening.
- Updated the settings-navigation and Log widget tests to wait until the visible menu label is genuinely hit-testable before tapping it; tests still tap the text itself.
- Preserved the menu, popup dimensions, colors, typography, spacing and all settings destinations.
- No transfer protocol, storage, permissions or native Android implementation changed. These layers are unaffected by this UI-anchor/test synchronization fix.
- Implemented — unverified pending a fresh full CI run and physical-device interaction check. No APK was built.

- Options menu: assigned stable keys to the Wi-Fi, Notifications and Storage text labels so tests tap the actual labels; widget tests now wait until the popup transition completes before tapping. No visual dimensions or destination behavior changed.
## 2026-11-12 — Added background message delivery ordering tests
- Extracted the background message sequence into `BackgroundMessageDelivery`: persist the message, send ACCEPT, notify the main isolate, then show the Android notification.
- Added tests for the successful order, persistence failure (no ACCEPT), and acknowledgement failure (no UI/notification handoff).
- The Android service now delegates to this tested sequence. Device-level foreground-service and notification behavior remains unverified; no APK was built.

## 2026-11-12 — Stabilized animated widget tests
- Run #604 passed dependency resolution and `flutter analyze`, but 3 widget tests timed out because `pumpAndSettle` cannot settle the app's continuous background animation.
- Replaced unbounded settling in the affected Options/Log widget tests with bounded 300 ms pumps. No app behavior changed.
- A fresh full CI run must validate this test-only correction and the background message delivery tests.

## 2026-11-12 — Removed inner Alert Action List cards
- Removed the SEND DATA and RECEIVE DATA inner cards, including their headings, counters, file records, status labels and empty-state text, as requested.
- Kept the outer Alert > Action List popup, its title, Clear history control, and existing popup/panel dimensions.
- Updated widget tests to assert the removed content stays absent and Clear history still clears the controller.
- Updated the UI, product, architecture, status, handoff, next-step, known-issues and README records. Fresh CI validation is pending; no APK was built.

## 2026-11-12 — Removed unnecessary non-null assertion
- Removed the redundant `!` from `connection` at `lib/main.dart:433`; flow analysis already guarantees it is non-null at that point.
- No UI, messaging, network or runtime behavior was intentionally changed.
- CI run #578 failed at analysis on this warning and skipped tests. Fresh CI must confirm analysis and run the full test suite before the Alert Action List sizing change can be considered verified.
- No APK was built.

## 2026-11-12 — Resized Alert Action List inner cards
- Kept the outer popup at 220 logical pixels and the inner panel at 200; reduced each SEND DATA / RECEIVE DATA card to 180 pixels wide using 10-pixel horizontal insets.
- Preserved popup/panel heights, labels, records and actions. Added widget assertions for both inner card widths.
- Implemented — unverified pending CI and physical-device review; no APK was built.

## 2026-11-12 — Fixed widget-test file structure
- Moved the Options settings-navigation and Log-panel widget tests back inside `main()` in `test/widget_test.dart`; no app UI or runtime behavior was changed.
- Updated project status, next-step, handoff and known-issues records to document CI run #566's analyzer failure and the pending validation of this correction.
- Fresh CI validation is pending; no APK was built.

## 2026-11-12 — Connected Options menu settings navigation
- Wi-Fi, Notifications and Storage menu labels now invoke their corresponding Android settings destinations; no ON/OFF switches are shown.
- Storage opens Android App info because a direct Permissions deep link is not guaranteed across Android versions. The user can select Permissions there.
- Added a widget test for all three MethodChannel calls. Implemented — unverified on physical Android devices; fresh CI validation is required. No APK was built.

## 2026-11-12 — Narrowed the three-dot Options menu
- Reduced the Options popup width from 300 to 200 logical pixels, corresponding to the requested change from approximately 4.5 cm to 3 cm on the user's phone.
- The current Options menu source contains no ON/OFF controls; no unrelated controls were removed.
- Added a widget test for the 200-pixel menu width and absence of ON/OFF labels. Fresh CI validation is required; no APK was built.

## 2026-11-12 — Connected message UI to TCP delivery
- Connected the Send Message action to the authenticated TCP TEXT_MESSAGE flow.
- New message connections now wait for receiver ACCEPT/REJECT before showing successful delivery; rejection is shown distinctly from network failure.
- Foreground Receive now sends ACCEPT/REJECT after the user decision and retains accepted connections for two-way messages.
- Manual-IP discovery tries the foreground Receive listener first, then the background inbox responder.
- Android background inbox sends ACCEPT only after the message has been persisted, then raises the existing notification.
- Removed message text from message-related application log entries.
- Synchronized README, architecture, product spec, protocol, UI design, status, next-step, handoff, known risks and UI session notes.
- Fresh Flutter CI is required; no APK was built.

## 2026-11-12 — Removed camera-based pairing
- Removed the unused scanning screen and its Flutter package dependencies.
- Removed stale pairing instructions and UI references; connections use LAN peer discovery or manual IP/session details.
- Existing TCP transfer, one-time session authentication and receiver approval flows remain.

## 2026-11-11 — Enforced APK hold across all workflows
- Flutter checks run #449 on main commit `e3f730f49d24253ce38f8583291c5a45a1e7c853` passed dependency resolution, `flutter analyze` and all 118 Flutter tests. This predates the current messaging changes.
- Removed push triggers from both APK-producing workflows; both require manual `workflow_dispatch`.
- Historical APK artifacts/releases were left untouched and must not be distributed.
- Standard Flutter CI remains checks-only.

## 2026-11-12 — Repositioned and narrowed the Log panel
- Set the Log overlay to 200 logical pixels wide and aligned its top edge with the Log label in Options.
- On Send, anchored the lower edge 8 logical pixels above the large bottom Send button; on Receive, constrained it to the visible viewport above the keyboard/safe bottom.
- Added a widget test for width, label alignment and Send-button clearance. CI/device validation is pending; no APK was built.

- Bounded the outside-tap dismissal layer as well, so the main Send button remains interactive while Log is open.

- Compacted the Log header action buttons and footer text so the existing copy/clear actions fit the new width without layout overflow.

## 2026-11-12 — Narrowed Alert Action List
- Reduced the outer popup width from 278 to 220 logical pixels and inner panel width from 258 to 200.
- Preserved existing heights and all content/actions; added a widget assertion for inner width and height.
- CI/device validation pending; no APK built.


## 2026-11-14 — 60-second idle sessions and final-save confirmation
- Set file and message connection idle/handshake windows to 60 seconds.
- Added final FILE_OK acknowledgement: sender success waits until receiver has completed final storage/publication.
- Limit pending incoming messages and visible chat history to 10 entries.
- Clear chat history when the app detaches/closes.
- Received-file Delete now removes only the app list entry; it keeps the stored file.
- Reset Receive screen 10 seconds after a successful batch.
- Require Android notification permission for message sending and background receiving.
- Display a no-encryption warning on both main screens.
- Updated UI guide, protocol, product and security documentation. Checks CI #737 passed all 150 tests and analyzer; universal APK workflow #80 is running.


## 2026-11-15 — Final requested UI and message corrections
- Changed the Send IP selector's inner field to white with black, single-line IP text; the outer card remains black.
- Added separate native Android notification-stream tones for successfully sent and received messages, including Send and Receive replies. No persistent notification is created.
- Reversed chat bubble placement: outgoing on the left, incoming on the right.
- Remove a selected file from the Send list only after the full batch completes successfully.
- Rebuilt the About dialog with the requested Persian content and English translation; all content is centered.
- Recreate the Send header after app resume so the Options and Alert controls return.
- Close the Options popup after language selection to avoid stale positioning.
- Added regression tests for the UI, tone dispatch, transcript alignment and successful-batch file removal.
- Status: source/tests updated; current CI and APK workflow results pending. Screen-off sound and two-device behavior remain physical-device checks.
