import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the Android process at foreground-service priority while a connection
/// is desired. iOS does not permit an indefinite background WebSocket, so its
/// connection is verified and restored by the lifecycle resume handler.
class MobileConnectionKeepAlive {
  MobileConnectionKeepAlive._();

  static const MethodChannel _channel = MethodChannel(
    'com.snli.bitfinex_chase/connection_keep_alive',
  );

  static bool _started = false;

  static Future<void> start() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('start');
      _started = true;
    } on MissingPluginException {
      // Unit tests and unsupported embedders have no native implementation.
    } on PlatformException {
      // Connection recovery remains available if the foreground service fails.
    }
  }

  static Future<void> stop() async {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        !_started) {
      return;
    }
    _started = false;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Unit tests and unsupported embedders have no native implementation.
    } on PlatformException {
      // The operating system may already have stopped the service.
    }
  }
}
