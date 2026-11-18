import 'dart:io';

/// Best-effort IPv4 LAN inventory for Windows.
class WindowsLanScanner {
  const WindowsLanScanner();

  static const int _maxHosts = 1022;
  static const int _parallelism = 40;

  Future<List<String>> scan() async {
    final config = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r"""
$ErrorActionPreference = 'SilentlyContinue'
Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter "IPEnabled = TRUE" |
  Where-Object { $_.DefaultIPGateway } |
  ForEach-Object {
    $addresses = $_.IPAddress
    $masks = $_.IPSubnet
    for ($i = 0; $i -lt $addresses.Length; $i++) {
      $ip = $addresses[$i]
      if ($ip -match '^(\d{1,3}\.){3}\d{1,3}$') {
        $mask = [Net.IPAddress]::Parse($masks[$i]).GetAddressBytes()
        $prefix = 0
        foreach ($byte in $mask) {
          for ($bit = 7; $bit -ge 0; $bit--) {
            if (($byte -band (1 -shl $bit)) -ne 0) { $prefix++ }
          }
        }
        "$ip|$prefix"
      }
    }
  }
""",
      ],
    ).timeout(const Duration(seconds: 8));

    if (config.exitCode != 0) {
      throw ProcessException(
        'powershell.exe',
        const ['WMI IPv4 interface query'],
        config.stderr.toString(),
        config.exitCode,
      );
    }

    final networks = <_Ipv4Network>{};
    for (final line in config.stdout.toString().split(RegExp(r'\r?\n'))) {
      final parts = line.trim().split('|');
      if (parts.length != 2) continue;
      final address = InternetAddress.tryParse(parts[0]);
      final prefix = int.tryParse(parts[1]);
      if (address == null ||
          address.type != InternetAddressType.IPv4 ||
          prefix == null ||
          prefix < 1 ||
          prefix > 30 ||
          !_isPrivate(address)) {
        continue;
      }
      networks.add(_Ipv4Network(address, prefix));
    }

    if (networks.isEmpty) {
      throw const SocketException(
        'No active private IPv4 network with a default gateway was found.',
      );
    }

    final found = <String>{};
    for (final network in networks) {
      final hosts = network.hostAddresses();
      if (hosts.isEmpty) continue;

      // Populate the Windows ARP cache before reading it. This UDP probe is
      // best-effort; ICMP and existing ARP entries remain useful if blocked.
      RawDatagramSocket? probeSocket;
      try {
        probeSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        for (final ip in hosts) {
          probeSocket.send(const [0], InternetAddress(ip), 9);
        }
        await Future<void>.delayed(const Duration(milliseconds: 350));
      } catch (_) {
        // Continue with ICMP and the existing ARP cache.
      } finally {
        probeSocket?.close();
      }

      var next = 0;
      final workers = List<Future<void>>.generate(
        _parallelism.clamp(1, hosts.length).toInt(),
        (_) async {
          while (true) {
            final index = next++;
            if (index >= hosts.length) return;
            final ip = hosts[index];
            try {
              final result = await Process.run(
                'ping.exe',
                ['-n', '1', '-w', '300', ip],
              ).timeout(const Duration(seconds: 2));
              if (result.exitCode == 0) found.add(ip);
            } catch (_) {
              // Continue scanning other hosts.
            }
          }
        },
      );
      await Future.wait(workers);

      try {
        final arp = await Process.run('arp.exe', ['-a'])
            .timeout(const Duration(seconds: 4));
        for (final match in RegExp(
          r'(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])',
        ).allMatches(arp.stdout.toString())) {
          final candidate = InternetAddress.tryParse(match.group(0)!);
          if (candidate != null &&
              network.contains(candidate) &&
              candidate.address != network.address) {
            found.add(candidate.address);
          }
        }
      } catch (_) {
        // Ping results are still useful.
      }
    }
    return found.toList()..sort(_compareIpv4);
  }

  static bool _isPrivate(InternetAddress address) {
    final b = address.rawAddress;
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168);
  }

  static int _compareIpv4(String left, String right) {
    final a = InternetAddress(left).rawAddress;
    final b = InternetAddress(right).rawAddress;
    for (var i = 0; i < 4; i++) {
      final result = a[i].compareTo(b[i]);
      if (result != 0) return result;
    }
    return 0;
  }
}

class _Ipv4Network {
  _Ipv4Network(InternetAddress address, this.prefix)
      : address = address.address,
        _value = _toInt(address.rawAddress),
        _mask = (0xffffffff << (32 - prefix)) & 0xffffffff;

  final String address;
  final int prefix;
  final int _value;
  final int _mask;

  int get _network => _value & _mask;
  int get _broadcast => _network | (~_mask & 0xffffffff);

  bool contains(InternetAddress candidate) {
    if (candidate.type != InternetAddressType.IPv4) return false;
    return (_toInt(candidate.rawAddress) & _mask) == _network;
  }

  List<String> hostAddresses() {
    var first = _network + 1;
    var last = _broadcast - 1;
    if (last < first) return const [];
    if (last - first + 1 > WindowsLanScanner._maxHosts) {
      final local24 = _value & 0xffffff00;
      first = local24 + 1;
      last = local24 + 254;
    }
    final own = _value;
    return [
      for (var value = first; value <= last; value++)
        if (value != own) _fromInt(value),
    ];
  }

  static int _toInt(List<int> bytes) =>
      (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];

  static String _fromInt(int value) =>
      '${(value >> 24) & 255}.${(value >> 16) & 255}.${(value >> 8) & 255}.${value & 255}';
}
