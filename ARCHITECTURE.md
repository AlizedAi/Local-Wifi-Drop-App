# Architecture

**Current platforms:** Flutter/Dart Android application plus an in-progress Windows x64 client on branch `windows-from-1.0.158`. The shared presentation, application and protocol layers are reused; platform-specific storage/settings integrations remain isolated.

## Application layers
1. **Presentation:** Send and Receive screens in `lib/main.dart`; shared header, bounded in-memory chat transcript, black message composer, file controls, progress and transfer alerts.
2. **Application orchestration:** screen lifecycle, invitation discovery, file-batch approval, notifications and pending-message presentation.
3. **Protocol/domain:** pairing invitations and credentials for file transfer, protocol-v2 HELLO authentication for file transfer, framed file and independent unauthenticated TEXT_MESSAGE transport, protocol guards, transfer manifests and state.
4. **Transport/storage:** TCP client/server and framed connection, bounded file streaming, SHA-256 verification, temporary files and Android shared-storage publishing.
5. **Message reception:** `ActiveMessageReceiver` owns the in-process message TCP listener and UDP responder. It stores an incoming message, sends ACCEPT, then requests a native Android received tone. The listener stops when the app process is detached/disposed.
6. **Android integration:** native MethodChannels provide notification-stream message tones, Android file storage publishing, network scanning and navigation to Wi-Fi, app-notification and app-information settings. These calls are guarded to Android and are not required by the Windows client. Windows uses Flutter file_picker/open_filex and a user-selected receive folder; settings shortcuts, native tones and persistent log storage are not provided on Windows. The Options > Log overlay is anchored to the actual Log text through `_logMenuLabelKey`.

## Network model
- File transfer and text messaging use separate discovery endpoints and separate TCP endpoints; only file transfer uses pairing invitations. File discovery uses UDP port 39475; message discovery uses UDP port 39476.
- The Send peer picker and manual-IP validation use `discoverMessagePeers`, which reads the message discovery response's IP and advertised TCP port. The selected peer IP is shared by both Message windows. Only an active Local Wi-Fi Drop message receiver is selectable. Message traffic uses direct plain TCP without encryption, HELLO, pairing or peer authentication; the file-transfer path retains its separate authenticated session. Manual IP entry performs the same check.
- The app-process `ActiveMessageReceiver` owns the message TCP listener and UDP responder while the app process remains active on Android and Windows. It is not a Windows service or Android foreground service; reception is not guaranteed after the app process exits or is terminated. The Receive screen's file listener is not involved in text messaging.
- Each message uses a fresh direct TCP connection to the discovered IP and port and a TEXT_MESSAGE frame. Message HELLO and pairing credentials are not used. The receiver adds the message to its in-memory ChatStore before sending ACCEPT. The sender marks the message delivered only after this in-process acknowledgement.
- After storing an incoming message and sending ACCEPT, the active receiver plays a native received tone. A successful sender plays a sent tone after ACCEPT. No persistent notification is posted; actual screen-off playback is a device-validation item.
- Both screens observe one app-wide ChatStore, including the selected peer IP, and show the same bounded 10-entry transcript. An incoming message selects its sender as the shared peer, so either tab can send to that device. Incoming entries are black; outgoing entries turn green after the receiver's persistence acknowledgement.
- Message connections close after one persisted message. No persistent chat socket is tied to the Receive tab, and file-transfer sessions do not carry message frames.
- Plain TCP remains observable/interferable by capable LAN participants. SHA-256 is integrity checking only.

## Windows platform adapter\n- Windows binds the shared UDP discovery responder with `reusePort: false`; the fixed file/message discovery ports remain 39475/39476.\n- Windows skips the Android-only native LAN inventory MethodChannel and uses active app-peer UDP discovery plus manual private IPv4 entry.\n- Received files are written directly to the folder selected by the user. Open delegates to the platform file opener. Removing a received-file row from the in-app list does not delete the stored file.\n- Windows has no Android settings, notification or native tone channels. Its diagnostic Log is in-memory only.\n\n## Resource rules
- Never load a whole file into RAM.
- One active batch and one file stream initially.
- 64 KiB initial file chunks, bounded buffers and socket backpressure.
- Incremental SHA-256; no second sender-side file read.
- No compression or parallel workers by default.

## Lifecycle and safety
- Close listeners, discovery sockets and TCP connections on terminal outcomes or disposal.
- Validate frame lengths, metadata, names, sizes, offsets and message ordering.
- Never silently overwrite, execute received files, expose remote commands or log message contents/tokens.
- Android API 24+ is a target only; physical-device validation is still required.

## Application Log
- `AppLogController` records timestamped INFO/WARNING/ERROR/SUCCESS events and caps retained history at 3,000 entries.
- On Android, saved history is restored from foreground-task private storage and exported to `Documents/Local Wi-Fi Drop/logs/app-log.json`; storage failures are best-effort and must not interrupt transfers.
- Restore preserves events recorded during its asynchronous read and skips malformed individual records. Persistence requests are coalesced so a slow storage write cannot accumulate an unbounded backlog of obsolete full-history snapshots.
- The shared Options menu opens the same Log overlay from Send and Receive. Operational records cover Options interactions, file picker outcomes, destination selection, Send/Receive file actions, foreground chat delivery, paste outcomes and transfer-history clearing without recording message contents. The panel tracks selected entries by object identity; its header exposes Clear log only and its text-selection toolbar exposes Copy and Select all only. CI run #643 passed all 140 tests.

## Validation boundary
Unit/loopback tests do not prove Android device-to-device interoperability, background execution across OEM battery policies, throughput or thermal performance. Those remain open validation tasks.

- The Options > Log overlay is CI-verified in run #643 for Send and Receive access, 200-pixel width, Send-button clearance and text selection. Physical-device behavior remains outstanding. The overlay is positioned from the Log menu row/label geometry. Its width is 200 logical pixels. On Send, a GlobalKey anchor on the large bottom Send button determines the lower boundary, with an 8 logical-pixel clearance; on Receive, the lower boundary uses the visible viewport/keyboard inset because there is no large bottom Send button. The overlay is dismissed by tapping outside it.

- The Log overlay's dismissible hit-test layer ends at the panel's lower edge; it does not intercept touches on the large bottom Send button below the panel.

- `lib/src/app_log_panel.dart` exposes only Clear log as a header action. Each log entry remains a read-only `SelectableText`; its native floating selection toolbar is filtered to Copy and Select all only. Cut and Paste are omitted.

- Alert > Action List: `_AlertDropdownButton` keeps the 220-pixel popup and `TransferHistoryPanel` keeps its 200×344 shell. The two inner cards and their labels/data/status/empty-state text are removed for later redesign. The outer title and Clear history control remain.

## Current connection and completion rules
- Accepted file and message TCP sessions use a 60-second idle timeout. Every received protocol frame resets the idle window; this is not a 60-second maximum duration for an active transfer.
- File receiver sends FILE_OK only after the complete batch has been verified and final storage/publication has succeeded. Sender does not mark files sent or report success before FILE_OK.
- Received-file Delete removes only the UI list entry. It does not delete the file from Documents or staging storage.
- Receive UI resets 10 seconds after successful file receipt. The current in-process message path does not require Android notification permission.
- Both Send and Receive show the no-encryption warning.
