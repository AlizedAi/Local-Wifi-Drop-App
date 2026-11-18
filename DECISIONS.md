# Decision log

Record settled decisions with date, reason, impact and status.

## 2026-11-08 — Repository is the source of truth
- Project state, design handoff and continuation instructions live in this repository.
- Update source, tests, status, next-step, changelog and affected technical/UI docs together.

## 2026-11-08 — Local-first and Android first
- No internet, account, cloud, relay, ads or paid services.
- Android first; Windows and iOS follow after Android is stable.

## 2026-11-08 — V1 transfer baseline
- Multi-file batches, receiver approval, streaming, progress/cancel, SHA-256 integrity and collision-safe saving.
- Folders and automatic resume are excluded.

## 2026-11-08 — Performance-first plain TCP V1
- Direct unencrypted TCP on the reachable local network; no TLS, certificate generation or payload encryption in Android V1.
- Reason: speed, low RAM, small app size and low complexity take priority.
- Retain short-lived pairing credentials, receiver approval, bounded framing, strict validation and SHA-256 integrity.
- Risk: another device able to observe the same LAN may read or interfere with traffic.

## 2026-11-12 — Text message delivery semantics (superseded 2026-11-13)
- The initial design used foreground Receive approval and a persistent bidirectional chat connection, with a one-way background fallback.
- This design was replaced because Message must not depend on the file Receive screen or file-transfer listener.

## 2026-11-13 — Independent shared Message subsystem
- Message must be independent from file transfer and the Receive screen's file listener.
- Use separate UDP discovery ports: file 39475 and message 39476. The message peer picker and manual IP entry require a live message-service response.
- The Android foreground message service remains the receiver while the app UI is backgrounded. It persists each TEXT_MESSAGE before returning ACCEPT and shows the actual text in a notification.
- Both Send and Receive windows use one shared in-memory ChatStore, capped at 30 entries, including the selected peer IP. An incoming message selects its sender as the shared peer, so either tab can send to that device.
- Superseded by the 2026-11-13 decision below: message connections are direct unauthenticated TCP. File transfer continues on its separate listener and authenticated protocol flow.
- Keep the selected peer IP synchronized across both windows. Keep the composer and incoming messages black. Turn outgoing text green only after receiver persistence is confirmed. Never log message contents.


## 2026-11-13 — Remove pairing from text messaging
- Text messages connect directly to the selected peer IP and the TCP port advertised by its active message discovery responder.
- No message HELLO, password, pairing token, session credential or peer authentication.
- Keep the UDP discovery response as the app-availability check and keep ACCEPT as the receiver-storage acknowledgement.
- This decision applies only to text messaging. File transfer keeps its existing pairing and receiver approval flow.
