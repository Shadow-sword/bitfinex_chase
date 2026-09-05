import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/account.dart';
import '../models/trading_pair.dart';
import '../models/withdrawal.dart';

/// Cached metadata is display-only. Live prices, balances and trading trust are
/// never restored from disk. Account entries are isolated by environment/key.
class LocalCacheStore {
  static String _environment(bool paper) => paper ? 'paper' : 'live';
  static String _account(bool paper, String key) {
    if (key.trim().isEmpty) {
      throw ArgumentError('Account cache requires an API key');
    }
    return 'account:${_environment(paper)}:${sha256.convert(utf8.encode(key.trim()))}';
  }

  static Future<({dynamic value, DateTime savedAt})?> _read(String key) async {
    final sp = await SharedPreferences.getInstance();
    final encoded = sp.getString('bitfinex_cache:$key');
    if (encoded == null) return null;
    final data = jsonDecode(encoded);
    if (data is! Map<String, dynamic> ||
        data['version'] != 1 ||
        data['savedAt'] is! int ||
        !data.containsKey('value')) {
      throw const FormatException('Invalid local cache envelope');
    }
    return (
      value: data['value'],
      savedAt: DateTime.fromMillisecondsSinceEpoch(data['savedAt'] as int),
    );
  }

  static Future<void> _write(String key, Object value) async {
    final encoded = jsonEncode({
      'version': 1,
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'value': value,
    });
    if (encoded.length > 10 * 1024 * 1024) {
      throw StateError('Local cache exceeds 10 MiB');
    }
    final sp = await SharedPreferences.getInstance();
    if (!await sp.setString('bitfinex_cache:$key', encoded)) {
      throw StateError('Cache write failed');
    }
  }

  static Future<List<TradingPair>> loadMarket(bool paper) async {
    final snapshot = await _read('market:${_environment(paper)}');
    if (snapshot == null) return [];
    return (snapshot.value as List)
        .map(
          (raw) => TradingPair.fromMap(Map<String, dynamic>.from(raw as Map)),
        )
        .toList();
  }

  static Future<void> saveMarket(bool paper, Iterable<TradingPair> pairs) =>
      _write(
        'market:${_environment(paper)}',
        pairs.where((p) => p.isVerified).map((p) => p.toMap()).toList(),
      );

  static Future<({AccountSummaries value, DateTime savedAt})?> loadIdentity(
    bool paper,
    String apiKey,
  ) async {
    final snapshot = await _read('${_account(paper, apiKey)}:identity');
    if (snapshot == null) return null;
    return (
      value: AccountSummaries.fromMap({
        ...Map<String, dynamic>.from(snapshot.value as Map),
        'summaries': <dynamic>[],
      }),
      savedAt: snapshot.savedAt,
    );
  }

  static Future<void> saveIdentity(
    bool paper,
    String apiKey,
    AccountSummaries account,
  ) => _write('${_account(paper, apiKey)}:identity', {
    'id': account.id,
    'type': account.type,
    'username': account.username,
    'email': account.email,
    'mandatory_tfa': account.mandatoryTfa,
    'security_keys_enabled': account.securityKeysEnabled,
  });

  static Future<({List<Withdrawal> value, DateTime savedAt})?> loadWithdrawals(
    bool paper,
    String apiKey,
    String currency,
    int offset,
  ) async {
    final snapshot = await _read(
      '${_account(paper, apiKey)}:withdrawals:${currency.toUpperCase()}:$offset',
    );
    if (snapshot == null) return null;
    return (
      value: (snapshot.value as List)
          .map(
            (raw) => Withdrawal.fromMap(Map<String, dynamic>.from(raw as Map)),
          )
          .toList(),
      savedAt: snapshot.savedAt,
    );
  }

  static Future<void> saveWithdrawals(
    bool paper,
    String apiKey,
    String currency,
    int offset,
    List<Withdrawal> values,
  ) => _write(
    '${_account(paper, apiKey)}:withdrawals:${currency.toUpperCase()}:$offset',
    values.map((w) => w.toMap()).toList(),
  );
}
