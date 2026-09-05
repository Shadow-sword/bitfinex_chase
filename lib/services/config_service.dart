import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart' as pc;

import 'settings_store.dart';
import '../models/trading_pair.dart';

/// Provides import/export of app configuration with optional AES encryption.
class ConfigService {
  static const int _version = 1;

  /// Build a plain settings map collecting persisted preferences.
  static Future<Map<String, dynamic>> buildPlainSettings() async {
    final isTestnet = await SettingsStore.loadIsTestnet();
    final rememberCreds = await SettingsStore.loadRememberCredentials();
    final creds = await SettingsStore.loadCredentials();
    final maxSpreadPercent = await SettingsStore.loadMaxSpreadPercent();
    final percentSizingBuffer = await SettingsStore.loadPercentSizingBuffer();
    final customPairs = await SettingsStore.loadCustomTradingPairsRaw();
    final connExpanded = await SettingsStore.loadConnPanelExpanded();
    final settingsExpanded = await SettingsStore.loadSettingsPanelExpanded();
    final customExpanded = await SettingsStore.loadCustomPanelExpanded();
    final historyFiltersExpanded =
        await SettingsStore.loadHistoryFiltersExpanded();
    final historyPositionsExpanded =
        await SettingsStore.loadHistoryPositionsExpanded();
    final pairOptionsExpandedMap =
        await SettingsStore.loadPairOptionsExpandedMap();
    final hideZeroCurrencies = await SettingsStore.loadHideZeroCurrencies();
    final themePreference = await SettingsStore.loadThemePreference();

    return {
      'app': {
        'isTestnet': isTestnet,
        'androidBackgroundKeepAlive':
            await SettingsStore.loadAndroidBackgroundKeepAlive(),
        'rememberCredentials': rememberCreds,
        'clientId': creds.clientId,
        'clientSecret': creds.clientSecret,
        'maxSpreadPercent': maxSpreadPercent,
        'percentSizingBuffer': percentSizingBuffer,
        'hideZeroCurrencies': hideZeroCurrencies,
        'themePreference': themePreference.name,
      },
      'pairs': {'customTradingPairs': customPairs},
      'ui': {
        'connPanelExpanded': connExpanded,
        'settingsPanelExpanded': settingsExpanded,
        'customPanelExpanded': customExpanded,
        'historyFiltersExpanded': historyFiltersExpanded,
        'historyPositionsExpanded': historyPositionsExpanded,
        'pairOptionsExpandedMap': pairOptionsExpandedMap,
      },
    };
  }

  /// Export config to a string. If [password] provided, returns JSON with encrypted payload.
  static Future<String> exportConfig({String? password}) async {
    final settings = await buildPlainSettings();
    final base = {
      'dc': 'config',
      'version': _version,
      'exportedAt': DateTime.now().toIso8601String(),
    };
    if (password != null && password.isNotEmpty) {
      final encObj = _encryptJson(settings, password);
      final obj = {...base, 'encrypted': true, 'enc': encObj};
      return const JsonEncoder.withIndent('  ').convert(obj);
    } else {
      final obj = {...base, 'encrypted': false, 'settings': settings};
      return const JsonEncoder.withIndent('  ').convert(obj);
    }
  }

  /// Parse a config string and return the plain settings map.
  /// If the content is encrypted, [password] must be provided.
  static Future<Map<String, dynamic>> parseConfig(
    String text, {
    String? password,
  }) async {
    final root = jsonDecode(text);
    if (root is! Map) {
      throw FormatException('Invalid config format');
    }
    final encrypted = root['encrypted'] == true;
    if (!encrypted) {
      final settings = root['settings'];
      if (settings is! Map) {
        throw FormatException('Missing settings in config');
      }
      return (settings.cast<String, dynamic>());
    }
    if (password == null || password.isEmpty) {
      throw ArgumentError('Password required to decrypt config');
    }
    final encObj = root['enc'];
    if (encObj is! Map) {
      throw FormatException('Invalid encrypted payload');
    }
    final plain = _decryptToString(encObj.cast<String, dynamic>(), password);
    final settings = jsonDecode(plain);
    if (settings is! Map) {
      throw FormatException('Decrypted payload is invalid');
    }
    return settings.cast<String, dynamic>();
  }

  /// Apply settings back to SharedPreferences only.
  /// UI/ViewModel updates should be handled by the caller.
  static Future<void> applySettingsToPrefs(
    Map<String, dynamic> settings,
  ) async {
    final app = (settings['app'] as Map?)?.cast<String, dynamic>() ?? {};
    final pairs = (settings['pairs'] as Map?)?.cast<String, dynamic>() ?? {};
    final ui = (settings['ui'] as Map?)?.cast<String, dynamic>() ?? {};

    final backgroundKeepAlive = app['androidBackgroundKeepAlive'];
    if (backgroundKeepAlive is bool) {
      await SettingsStore.saveAndroidBackgroundKeepAlive(backgroundKeepAlive);
    }
    final isTestnet = app['isTestnet'];
    if (isTestnet is bool) {
      await SettingsStore.saveIsTestnet(isTestnet);
    }

    final remember = app['rememberCredentials'];
    if (remember is bool) {
      await SettingsStore.saveRememberCredentials(remember);
    }
    final clientId = app['clientId'];
    final clientSecret = app['clientSecret'];
    if (clientId is String && clientSecret is String) {
      await SettingsStore.saveCredentials(clientId, clientSecret);
    }
    final maxSpreadPercent = app['maxSpreadPercent'];
    if (maxSpreadPercent is num) {
      await SettingsStore.saveMaxSpreadPercent(maxSpreadPercent.toDouble());
    }
    final percentSizingBuffer = app['percentSizingBuffer'];
    if (percentSizingBuffer is num) {
      await SettingsStore.savePercentSizingBuffer(
        percentSizingBuffer.toDouble(),
      );
    }
    final hideZero = app['hideZeroCurrencies'];
    if (hideZero is bool) {
      await SettingsStore.saveHideZeroCurrencies(hideZero);
    }
    final themePreference = app['themePreference'];
    if (themePreference is String) {
      final preference = AppThemePreference.values.firstWhere(
        (v) => v.name == themePreference,
        orElse: () => AppThemePreference.system,
      );
      await SettingsStore.saveThemePreference(preference);
    }

    final customTradingPairs = pairs['customTradingPairs'];
    if (customTradingPairs is List) {
      final defaults = TradingPair.defaultPairs()
          .map((pair) => pair.symbol)
          .toSet();
      final canonical = <String, Map<String, dynamic>>{};
      for (final raw in customTradingPairs.cast<Map>()) {
        final pair = TradingPair.fromMap(raw.cast<String, dynamic>());
        if (pair.symbol.isEmpty || defaults.contains(pair.symbol)) continue;
        canonical.putIfAbsent(pair.symbol, pair.toMap);
      }
      final list = canonical.values.toList();
      await SettingsStore.saveCustomTradingPairsRaw(list);
    }

    // UI state
    final connExpanded = ui['connPanelExpanded'];
    if (connExpanded is bool) {
      await SettingsStore.saveConnPanelExpanded(connExpanded);
    }
    final settingsExpanded = ui['settingsPanelExpanded'];
    if (settingsExpanded is bool) {
      await SettingsStore.saveSettingsPanelExpanded(settingsExpanded);
    }
    final customExpanded = ui['customPanelExpanded'];
    if (customExpanded is bool) {
      await SettingsStore.saveCustomPanelExpanded(customExpanded);
    }
    final historyFiltersExpanded = ui['historyFiltersExpanded'];
    if (historyFiltersExpanded is bool) {
      await SettingsStore.saveHistoryFiltersExpanded(historyFiltersExpanded);
    }
    final historyPositionsExpanded = ui['historyPositionsExpanded'];
    if (historyPositionsExpanded is bool) {
      await SettingsStore.saveHistoryPositionsExpanded(
        historyPositionsExpanded,
      );
    }
    final pairOptionsExpandedMap = ui['pairOptionsExpandedMap'];
    if (pairOptionsExpandedMap is Map) {
      final typed = pairOptionsExpandedMap.map<String, bool>(
        (k, v) => MapEntry(k.toString(), v == true),
      );
      await SettingsStore.savePairOptionsExpandedMap(typed);
    }
  }

  // ----- Internal encryption helpers -----

  static Map<String, dynamic> _encryptJson(
    Map<String, dynamic> jsonMap,
    String password,
  ) {
    final plain = jsonEncode(jsonMap);
    final rnd = Random.secure();
    final salt = Uint8List.fromList(
      List<int>.generate(16, (_) => rnd.nextInt(256)),
    );
    final ivBytes = Uint8List.fromList(
      List<int>.generate(16, (_) => rnd.nextInt(256)),
    );
    // Strong KDF: PBKDF2-HMAC-SHA256
    const iter = 200000;
    const dkLen = 32;
    final keyBytes = _deriveKeyPbkdf2(password, salt, iter, dkLen);
    final key = enc.Key(keyBytes);
    final iv = enc.IV(ivBytes);
    final aes = enc.Encrypter(
      enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'),
    );
    final encrypted = aes.encrypt(plain, iv: iv);
    return {
      'algo': 'AES-CBC-PKCS7',
      'v': 2,
      'salt': base64Encode(salt),
      'iv': base64Encode(ivBytes),
      'ct': encrypted.base64,
      'kdf': {'name': 'PBKDF2-HMAC-SHA256', 'iter': iter, 'dkLen': dkLen},
    };
  }

  static String _decryptToString(Map<String, dynamic> encObj, String password) {
    final saltB64 = encObj['salt'] as String?;
    final ivB64 = encObj['iv'] as String?;
    final ctB64 = encObj['ct'] as String?;
    if (saltB64 == null || ivB64 == null || ctB64 == null) {
      throw const FormatException('Encrypted payload missing fields');
    }
    final salt = base64Decode(saltB64);
    final ivBytes = base64Decode(ivB64);
    // Determine KDF
    final kdf = encObj['kdf'];
    Uint8List keyBytes;
    if (kdf is Map) {
      final name = (kdf['name'] as String? ?? '').toUpperCase();
      final iter = (kdf['iter'] as num?)?.toInt() ?? 200000;
      final dkLen = (kdf['dkLen'] as num?)?.toInt() ?? 32;
      if (name.contains('PBKDF2') && name.contains('SHA256')) {
        keyBytes = _deriveKeyPbkdf2(
          password,
          Uint8List.fromList(salt),
          iter,
          dkLen,
        );
      } else {
        // Unknown map format -> fallback to legacy derivation
        keyBytes = _deriveKeyLegacy(password, Uint8List.fromList(salt));
      }
    } else if (kdf is String && kdf.contains('sha256(password+salt)')) {
      // Legacy exports
      keyBytes = _deriveKeyLegacy(password, Uint8List.fromList(salt));
    } else {
      // Default to legacy for maximum compatibility
      keyBytes = _deriveKeyLegacy(password, Uint8List.fromList(salt));
    }
    final key = enc.Key(keyBytes);
    final iv = enc.IV(ivBytes);
    final aes = enc.Encrypter(
      enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'),
    );
    try {
      return aes.decrypt64(ctB64, iv: iv);
    } catch (e) {
      throw ArgumentError('Decryption failed. Wrong password?');
    }
  }

  static Uint8List _deriveKeyLegacy(String password, Uint8List salt) {
    final pwdBytes = utf8.encode(password);
    final combined = Uint8List(salt.length + pwdBytes.length)
      ..setRange(0, salt.length, salt)
      ..setRange(salt.length, salt.length + pwdBytes.length, pwdBytes);
    final digest = crypto.sha256.convert(combined);
    return Uint8List.fromList(digest.bytes);
  }

  static Uint8List _deriveKeyPbkdf2(
    String password,
    Uint8List salt,
    int iterations,
    int keyLength,
  ) {
    final derivator = pc.PBKDF2KeyDerivator(pc.HMac(pc.SHA256Digest(), 64));
    derivator.init(pc.Pbkdf2Parameters(salt, iterations, keyLength));
    final passBytes = Uint8List.fromList(utf8.encode(password));
    return Uint8List.fromList(derivator.process(passBytes));
  }
}
