import 'dart:io';
import 'hello_payload.dart';
import 'pairing_session_authenticator.dart';
import 'protocol_frame.dart';
import 'tcp_frame_connection.dart';

/// Single-session receiver listener bound to one explicitly selected LAN IP.
class TcpTransferServer {
  TcpTransferServer._(this._server);
  final ServerSocket _server;
  bool _acceptStarted = false;
  bool _closed = false;
  InternetAddress get address => _server.address;
  int get port => _server.port;
  bool get isClosed => _closed;

  static Future<TcpTransferServer> bind({
    required InternetAddress address,
    int port = 0,
    bool shared = false,
  }) async {
    if (port < 0 || port > 65535) throw ArgumentError.value(port, 'port');
    return TcpTransferServer._(
      await ServerSocket.bind(address, port, shared: shared),
    );
  }

  /// Accepts one direct TCP connection without a pairing handshake.
  Future<TcpFrameConnection> accept({
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (_closed) throw StateError('Listener is closed.');
    if (_acceptStarted) throw StateError('This listener accepts only one session.');
    _acceptStarted = true;
    try {
      final socket = await _server.first.timeout(timeout);
      await close();
      return TcpFrameConnection.fromSocket(socket);
    } on Object {
      await close();
      rethrow;
    }
  }

  /// Closes the listening socket after one peer connects, then validates HELLO.
  Future<TcpFrameConnection> acceptAuthenticated({
    required PairingSessionAuthenticator authenticator,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (_closed) throw StateError('Listener is closed.');
    if (_acceptStarted) throw StateError('This listener accepts only one session.');
    _acceptStarted = true;
    Socket? socket;
    TcpFrameConnection? connection;
    try {
      socket = await _server.first.timeout(timeout);
      await close();
      connection = TcpFrameConnection.fromSocket(socket);
      final frame = await connection.readFrame().timeout(const Duration(seconds: 60));
      if (frame == null || frame.type != ProtocolMessageType.hello) {
        throw const FormatException('Expected HELLO as the first frame.');
      }
      if (!authenticator.authenticate(HelloPayload.decode(frame.payload))) {
        throw const FormatException('Pairing credentials are invalid or expired.');
      }
      return connection;
    } on Object {
      if (connection != null) {
        await connection.close();
      } else {
        socket?.destroy();
      }
      await close();
      rethrow;
    }
  }
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close();
  }
}
