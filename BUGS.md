# Known bugs and risks

## Windows client — implementation in progress; physical validation pending
- Windows CI run #7 passed analysis, 163 tests (2 Android-only skips), Release build and package validation. The final 1.0.159 ZIP includes the required Visual C++ runtime DLLs and excludes `dartjni.dll`/`jvm.dll`; no known build blocker remains. Physical Windows↔Android transfers, firewall behavior and VPN/adapter routing still require testing.
- PE import inspection found the executable also needs `msvcp140.dll`, `vcruntime140.dll` and `vcruntime140_1.dll`. Run #7 now bundles these three x64 runtime DLLs and verifies their presence. The final package is not confirmed until run #7 completes and its ZIP is inspected.
- Windows discovery lists active Local Wi-Fi Drop app peers through UDP broadcast. It does not enumerate every router client; manual private IPv4 entry remains available.
- Windows inbound TCP and UDP discovery may be blocked by Windows Defender Firewall. Users must allow the app on Private networks for peer discovery and transfers.
- Windows app logs are in-memory only; Android-only log persistence, settings panels, sound and storage MethodChannels are not implemented on Windows.
- Windows language selection is session-only and is not persisted between app launches.
- File receive folder selection, file opening, list-only Delete behavior and both transfer directions still need real Windows↔Android tests.
- Windows interface selection prefers private IPv4 interfaces named Wi-Fi/WLAN; VPN and virtual-adapter routing still need validation.
- The portable ZIP must be extracted as a whole; running only the EXE without its adjacent `data` and DLL files will not work.

## Existing Android validation risks
- `ActiveMessageReceiver` runs in the app process, not a foreground service. Android may suspend or terminate it; message reception is not guaranteed after force-stop or process termination.
- Actual sent/received sound output while the screen is off requires physical-device testing.
- Two-physical-device Android message and file interoperability still requires testing.
- Wi-Fi broadcast discovery depends on router/AP broadcast behavior and client-isolation settings.
- The Log panel's original intended position remains unresolved; do not change it without confirming the user's intended anchor.
- Plain TCP messaging and file transfer are not encrypted. Other devices on the LAN may observe or interfere with traffic.
- The 60-second idle timeout and file finalization still require physical-device validation.
