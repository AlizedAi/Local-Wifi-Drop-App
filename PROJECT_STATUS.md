# Project status — Windows client branch

**Last updated:** 2026-11-17  
**Repository:** AlizedAi/Local-Wifi-Drop  
**Active branch:** `windows-from-1.0.158`  
**Base commit:** `4b7385eef268e29d01414f0bcc9c8e49b949e519`  
**Base release label:** Local Wifi Drop 1.0.158  
**Windows build version:** 1.0.159 (planned; stored in `windows_version.txt`).

## Branch isolation
- This branch was created from the commit associated with the confirmed 1.0.158 release label.
- `main` and the Android release branch are not modified.
- No Android APK has been built by this Windows work.
- The base commit's `pubspec.yaml` contains `version: 1.0.148+148`, which does not match the 1.0.158 release label. The Windows workflow supplies its own Windows build version (starting at 1.0.159) without changing the shared Android package version.

## Goal
Build a Windows 10/11 x64 desktop client that exchanges files and text with the existing Android app over the same local Wi-Fi/LAN/hotspot. No cloud, account, relay, internet service or encryption is added.

## Implementation status
- Shared Flutter Send/Receive UI and existing Dart protocol core are reused.
- File transfer retains UDP discovery port 39475, short-lived invitation, HELLO authentication, receiver approval, bounded TCP streaming, incremental SHA-256 and final FILE_OK.
- Messaging retains its independent UDP discovery port 39476 and direct TCP TEXT_MESSAGE/ACCEPT flow.
- Windows UDP responder disables `reusePort` while keeping the shared discovery ports.
- Android-only LAN inventory MethodChannel is guarded; Windows uses portable UDP discovery of active app peers and manual private IPv4 entry.
- Android-only settings rows are hidden on Windows. The About dialog displays the Windows build version supplied by CI.
- Windows received-file list removal preserves the file on disk.
- Windows file selection, folder selection and opening use the existing Flutter desktop plugin paths.
- Android-only settings, native sound, storage publishing and persistent log storage are not provided on Windows.
- Windows runner generation, dependency resolution, analysis, tests and Release build are automated in `.github/workflows/windows-x64.yml`.

## Validation state
- Windows CI run #7 passed on the Windows x64 hosted runner: `flutter analyze` succeeded, 163 tests passed and 2 Android-specific tests were skipped, the Release executable built, and the portable ZIP was uploaded. The downloaded ZIP was inspected: it contains `Local-Wifi-Drop.exe`, Flutter assets, `flutter_windows.dll`, and `msvcp140.dll`/`vcruntime140.dll`/`vcruntime140_1.dll`; it contains neither `dartjni.dll` nor `jvm.dll`. Version is 1.0.159. Physical Windows↔Android interoperability is the only major validation still pending.
- No physical Windows↔Android test has been performed.
- No claims of verified Windows support until the Windows workflow passes and physical two-device testing is completed.
- The app uses unencrypted plain TCP. Do not transfer sensitive files or messages over untrusted networks.

## Required physical tests
1. Windows Receive ↔ Android Send: discovery, accept/reject, small and large file, SHA-256 integrity.
2. Android Receive ↔ Windows Send: discovery, accept/reject and successful file finalization.
3. Message delivery in both directions while both apps are running.
4. Windows Defender Firewall prompt and Private-network access.
5. Windows folder picker, open file, recent-list removal preserving disk file.
6. Wi-Fi reconnect, VPN/virtual adapter selection and client-isolation behavior.

## Versioning
- Windows build version is read from `windows_version.txt`; failed workflow retries do not consume a version number.
- Artifact name: `Local-Wifi-Drop-1.0.xxx-Windows-x64.zip`.
- Android package version remains unchanged in this branch unless separately approved.
