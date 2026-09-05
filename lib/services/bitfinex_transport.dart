import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

class BitfinexApiException implements Exception {
  final Object code;
  final String message;
  const BitfinexApiException(this.code, this.message);
  @override
  String toString() => 'Bitfinex API ($code): $message';
}

/// REST writes are serialized so nonce ordering follows wire ordering. A timed
/// out write is never retried: the exchange may already have accepted it.
class BitfinexTransport {
  final http.Client _http = http.Client();
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _subscription;
  final messages = StreamController<dynamic>.broadcast();
  final disconnected = StreamController<String>.broadcast();
  final List<_PendingRequest> _pending = [];
  Future<void> _restQueue = Future<void>.value();
  Timer? _heartbeat;
  DateTime _lastMessage = DateTime.now();
  int _nonce = 0;
  int _generation = 0;
  bool _disposed = false;
  bool isConnected = false;
  String? _apiKey;
  String? _secret;

  String nextNonce() {
    final now = DateTime.now().microsecondsSinceEpoch;
    _nonce = now > _nonce ? now : _nonce + 1;
    return _nonce.toString();
  }

  void setCredentials(String key, String secret) {
    _apiKey = key;
    _secret = secret;
  }

  void clearCredentials() {
    _apiKey = null;
    _secret = null;
  }

  String signature(String payload) {
    final secret = _secret;
    if (secret == null) throw StateError('API credentials are not set');
    return Hmac(
      sha384,
      utf8.encode(secret),
    ).convert(utf8.encode(payload)).toString();
  }

  Future<dynamic> publicGet(String path) async {
    final response = await _http
        .get(Uri.https('api-pub.bitfinex.com', '/$path'))
        .timeout(const Duration(seconds: 20));
    return _decode(response);
  }

  Future<dynamic> privatePost(
    String path, [
    Map<String, dynamic> body = const {},
  ]) {
    final generation = _generation;
    final key = _apiKey;
    final result = _restQueue.then((_) async {
      if (_disposed ||
          key == null ||
          key != _apiKey ||
          generation != _generation) {
        throw StateError('Private session is no longer active');
      }
      final nonce = nextNonce();
      final encoded = jsonEncode(body);
      final response = await _http
          .post(
            Uri.https('api.bitfinex.com', '/$path'),
            headers: {
              'content-type': 'application/json',
              'bfx-apikey': key,
              'bfx-nonce': nonce,
              'bfx-signature': signature('/api/$path$nonce$encoded'),
            },
            body: encoded,
          )
          .timeout(const Duration(seconds: 20));
      final value = _decode(response);
      if (generation != _generation || key != _apiKey) {
        throw StateError('Private session changed while awaiting response');
      }
      return value;
    });
    // Keep the queue usable; the caller still receives the original failure.
    _restQueue = result.then<void>(
      (_) {},
      onError: (Object e, StackTrace s) {},
    );
    return result;
  }

  dynamic _decode(http.Response response) {
    final dynamic value;
    try {
      value = jsonDecode(response.body);
    } on FormatException {
      if (response.statusCode != 200) {
        throw BitfinexApiException(response.statusCode, 'HTTP request failed');
      }
      rethrow;
    }
    if (value is List && value.isNotEmpty && value.first == 'error') {
      throw BitfinexApiException(
        value[1] as Object,
        'HTTP ${response.statusCode}: ${value[2]}',
      );
    }
    if (response.statusCode != 200) {
      throw BitfinexApiException(response.statusCode, 'HTTP request failed');
    }
    return value;
  }

  Future<void> connect() async {
    if (_disposed) throw StateError('Transport disposed');
    await disconnect();
    final generation = _generation;
    final socket = WebSocketChannel.connect(
      Uri.parse('wss://api.bitfinex.com/ws/2'),
    );
    _socket = socket;
    final ready = Completer<void>();
    _subscription = socket.stream.listen(
      (raw) {
        if (generation != _generation) return;
        _lastMessage = DateTime.now();
        try {
          final event = jsonDecode(raw as String);
          if (event is Map && event['event'] == 'info') {
            if (event['version'] == 2 && event['platform']?['status'] == 1) {
              isConnected = true;
              if (!ready.isCompleted) ready.complete();
            } else if (event['code'] == 20051 ||
                event['code'] == 20060 ||
                event['platform']?['status'] == 0) {
              throw const BitfinexApiException(
                'maintenance',
                'Exchange unavailable; reconnect after maintenance',
              );
            }
          }
          for (final pending in List<_PendingRequest>.of(_pending)) {
            if (pending.matches(event)) {
              _pending.remove(pending);
              pending.result.complete(event);
              break;
            }
          }
          messages.add(event);
        } catch (e) {
          if (!ready.isCompleted) ready.completeError(e);
          fail('Invalid or unavailable WebSocket stream: $e');
        }
      },
      onError: (Object error) {
        if (!ready.isCompleted) {
          ready.completeError(StateError('WebSocket connection failed'));
        }
        if (generation == _generation) fail('WebSocket connection failed');
      },
      onDone: () {
        if (!ready.isCompleted) {
          ready.completeError(StateError('WebSocket closed before ready'));
        }
        if (generation == _generation) fail('WebSocket closed');
      },
    );
    try {
      await ready.future.timeout(const Duration(seconds: 20));
      if (generation != _generation) throw StateError('Connection superseded');
      _heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
        if (DateTime.now().difference(_lastMessage).inSeconds > 45) {
          fail('Heartbeat expired');
        } else if (isConnected) {
          send({'event': 'ping', 'cid': DateTime.now().millisecondsSinceEpoch});
        }
      });
    } catch (_) {
      await disconnect();
      rethrow;
    }
  }

  void send(Object data) {
    if (!isConnected || _socket == null) {
      throw StateError('WebSocket disconnected');
    }
    _socket!.sink.add(jsonEncode(data));
  }

  Future<Map<String, dynamic>> requestEvent(
    Map<String, dynamic> payload,
    bool Function(Map<dynamic, dynamic>) matches,
  ) async {
    final raw = await requestMessage(
      payload,
      (event) => event is Map && matches(event),
    );
    final event = Map<String, dynamic>.from(raw as Map);
    if (event['event'] == 'error' || event['status'] == 'FAILED') {
      throw BitfinexApiException(
        event['code'] ?? 'error',
        event['msg']?.toString() ?? 'Request rejected',
      );
    }
    return event;
  }

  Future<dynamic> requestMessage(
    Object payload,
    bool Function(dynamic) matches,
  ) async {
    final pending = _PendingRequest(matches);
    _pending.add(pending);
    try {
      send(payload);
      return await pending.result.future.timeout(const Duration(seconds: 15));
    } finally {
      _pending.remove(pending);
    }
  }

  void fail(String reason) {
    final wasConnected = isConnected;
    isConnected = false;
    clearCredentials();
    _heartbeat?.cancel();
    for (final p in _pending) {
      if (!p.result.isCompleted) p.result.completeError(StateError(reason));
    }
    _pending.clear();
    _socket?.sink.close();
    if (wasConnected && !disconnected.isClosed) disconnected.add(reason);
  }

  Future<void> disconnect() async {
    _generation++;
    fail('Disconnected');
    await _subscription?.cancel();
    _subscription = null;
    await _socket?.sink.close();
    _socket = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(disconnect());
    _http.close();
    unawaited(messages.close());
    unawaited(disconnected.close());
  }
}

class _PendingRequest {
  final bool Function(dynamic) matches;
  final result = Completer<dynamic>();
  _PendingRequest(this.matches);
}
