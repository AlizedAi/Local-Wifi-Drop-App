# Roadmap

## Phase 0 — Product and architecture
- [x] Local-first Android-first product scope.
- [x] Direct plain-TCP decision and documented security limitations.
- [x] Flutter/Dart architecture and shared protocol baseline.
- [ ] Complete threat-model review and protocol hardening.

## Phase 1 — UI and app foundation
- [x] Flutter Send/Receive screens and shared navigation.
- [x] File picker, peer discovery and manual private IPv4.
- [x] Matrix background, progress, cancellation and Alerts/history UI.
- [x] Message fields and Send/Paste controls.
- [ ] Full phone-size visual, accessibility and localization review.
- [ ] Complete all options-menu settings and About behavior.

## Phase 2 — Protocol and messaging integration
- [x] Framed TCP transport, HELLO pairing and UDP app-peer discovery.
- [x] Bounded file streaming and incremental SHA-256.
- [x] File receiver approval, cancellation and per-file outcomes.
- [x] Dedicated message discovery/TCP endpoint, separate from file transfer.
- [x] Android foreground service receives and persists messages while the app UI is backgrounded.
- [x] Shared ChatStore used by both Send and Receive Message windows.
- [x] Receiver persistence acknowledgement and notification containing message text.
- [x] Peer picker and manual IP entry verify the active message endpoint.
- [x] Fresh CI verification of the independent message transport, shared transcript and selected peer (run #660: 149 tests passed).
- [ ] Two-device Android foreground/background message tests.

## Phase 3 — Android V1 validation
- [ ] Two-physical-device file transfer and message interoperability.
- [ ] Router, hotspot and client-isolation tests.
- [ ] Background execution and notification tests across OEM battery policies.
- [ ] Low-storage, network-loss, reconnect and lifecycle tests.
- [ ] Throughput, CPU, peak RAM and thermal benchmarks.
- [ ] Full source, security and dependency review.

## Phase 4 — Windows client
- [ ] Windows UI, file dialogs, listener/firewall integration and native CI.
- [ ] Android↔Windows interoperability.

## Phase 5 — iOS client
- [ ] iOS UI, document picker, Local Network permission and foreground-first lifecycle.
- [ ] Android↔iOS interoperability.

## Final gate
- [ ] Entire Android app complete and reviewed.
- [ ] Automated checks and physical-device tests pass.
- [ ] Only after the user explicitly authorizes it, create a test APK.
- [ ] Fix and retest device-reported issues.

Do not claim platform support based only on compilation or loopback tests.
