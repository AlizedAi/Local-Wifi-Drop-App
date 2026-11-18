# Next step — Windows client

## Active branch
`windows-from-1.0.158` only. Do not switch to or modify `main` or the Android release branch.

## Immediate validation
1. Perform physical Windows↔Android interoperability tests using the 1.1.00 portable ZIP: transfer files in both directions, send messages in both directions, verify receiver Accept/Reject, large-file integrity, Windows Defender Firewall and Wi-Fi/hotspot behavior.
2. If package resolution, analysis, tests or the Windows Release build fails, inspect the exact failing step and fix it on this branch.
3. Confirm the portable ZIP contains `Local-Wifi-Drop.exe`, Flutter `data`, `flutter_windows.dll`, `msvcp140.dll`, `vcruntime140.dll` and `vcruntime140_1.dll`, and does not contain `dartjni.dll` or `jvm.dll`.
4. Confirm the artifact is versioned 1.1.00 from `windows_version.txt`. A failed CI attempt does not consume a version.
5. Only after CI passes, hand the ZIP to the user for a physical Windows↔Android test.

## Required physical tests
- Windows Receive ↔ Android Send.
- Android Receive ↔ Windows Send.
- Text messages in both directions while both apps are running.
- Windows Defender Firewall permission on Private networks.
- Received folder selection, opening a file and removing a recent-file row without deleting the file.
- Test with Wi-Fi and hotspot; record VPN/virtual adapter issues.

## Constraints
- Do not change Android behavior or build an APK as part of this Windows task.
- Do not change protocol frame codes, invitation format, ports, authentication, transfer approval or hashing.
- No cloud, relay, encryption, new account system or extra features.
- Windows peer discovery lists active app peers only; do not claim it enumerates every LAN device.
- Keep code, tests, README, architecture, protocol, status, handoff and changelog synchronized.
- Report every unverified behavior honestly. Automated CI is not physical interoperability evidence.
