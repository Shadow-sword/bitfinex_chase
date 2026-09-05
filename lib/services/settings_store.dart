import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_window_state.dart';

enum AppThemePreference { system, light, dark }

class SettingsStore {
  static const _kIsTestnet = 'is_testnet';
  static const _kRememberCreds = 'remember_credentials';
  static const _kClientId = 'client_id';
  static const _kClientSecret = 'client_secret';
  static const _kMaxSpreadPercent = 'max_spread_percent';
  static const _kCustomPairs = 'custom_trading_pairs';
  static const _kConnPanelExpanded = 'ui_conn_panel_expanded';
  static const _kSettingsPanelExpanded = 'ui_settings_panel_expanded';
  static const _kCustomPanelExpanded = 'ui_custom_panel_expanded';
  static const _kHistoryFiltersExpanded = 'ui_history_filters_expanded';
  static const _kHistoryPositionsExpanded = 'ui_history_positions_expanded';
  static const _kPairOptionsExpanded = 'ui_pair_options_expanded_map';
  static const _kHideZeroCurrencies = 'ui_hide_zero_currencies';
  static const _kPercentSizingBuffer = 'percent_sizing_buffer';
  static const _kThemePreference = 'ui_theme_preference';
  static const _kDesktopWindowState = 'ui_desktop_window_state_v1';
  static const _kUsdCnyRate = 'fiat_usd_cny_rate';
  static const _kUsdCnyRateSourceDate = 'fiat_usd_cny_source_date';
  static const _kUsdCnyRateFetchedAt = 'fiat_usd_cny_fetched_at';

  static Future<bool> loadIsTestnet() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_kIsTestnet) ?? true;
  }

  static Future<void> saveIsTestnet(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kIsTestnet, v);
  }

  static Future<bool> loadRememberCredentials() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_kRememberCreds) ?? false;
  }

  static Future<void> saveRememberCredentials(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kRememberCreds, v);
  }

  static Future<Credentials> loadCredentials() async {
    final sp = await SharedPreferences.getInstance();
    return Credentials(
      clientId: sp.getString(_kClientId) ?? '',
      clientSecret: sp.getString(_kClientSecret) ?? '',
    );
  }

  static Future<void> saveCredentials(
    String clientId,
    String clientSecret,
  ) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kClientId, clientId);
    await sp.setString(_kClientSecret, clientSecret);
  }

  static Future<void> clearCredentials() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kClientId);
    await sp.remove(_kClientSecret);
  }

  static Future<double> loadMaxSpreadPercent() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getDouble(_kMaxSpreadPercent) ?? 0.8;
  }

  static Future<void> saveMaxSpreadPercent(double v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble(_kMaxSpreadPercent, v);
  }

  static Future<List<Map<String, dynamic>>> loadCustomTradingPairsRaw() async {
    final sp = await SharedPreferences.getInstance();
    final json = sp.getString(_kCustomPairs);
    if (json == null || json.isEmpty) return [];
    try {
      final decoded = (jsonDecode(json) as List).cast<Map<String, dynamic>>();
      return decoded;
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveCustomTradingPairsRaw(
    List<Map<String, dynamic>> pairs,
  ) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kCustomPairs, jsonEncode(pairs));
  }

  // UI panel expansions
  static Future<bool> loadConnPanelExpanded() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_kConnPanelExpanded) ?? true;
  }

  static Future<void> saveConnPanelExpanded(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kConnPanelExpanded, v);
  }

  static Future<bool> loadSettingsPanelExpanded() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_kSettingsPanelExpanded) ?? true;
  }

  static Future<void> saveSettingsPanelExpanded(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kSettingsPanelExpanded, v);
  }

  static Future<bool> loadCustomPanelExpanded() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_kCustomPanelExpanded) ?? false;
  }

  static Future<void> saveCustomPanelExpanded(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kCustomPanelExpanded, v);
  }

  static Future<bool> loadHistoryFiltersExpanded() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_kHistoryFiltersExpanded) ?? true;
  }

  static Future<void> saveHistoryFiltersExpanded(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kHistoryFiltersExpanded, v);
  }

  static Future<bool> loadHistoryPositionsExpanded() async {
    final sp = await SharedPreferences.getInstance();
    // Default collapsed for small screens convenience
    return sp.getBool(_kHistoryPositionsExpanded) ?? false;
  }

  static Future<void> saveHistoryPositionsExpanded(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kHistoryPositionsExpanded, v);
  }

  // Per-pair options expanded map (symbol -> bool)
  static Future<Map<String, bool>> loadPairOptionsExpandedMap() async {
    final sp = await SharedPreferences.getInstance();
    final s = sp.getString(_kPairOptionsExpanded);
    if (s == null || s.isEmpty) return {};
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, v == true));
    } catch (_) {
      return {};
    }
  }

  static Future<void> savePairOptionsExpandedMap(Map<String, bool> m) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kPairOptionsExpanded, jsonEncode(m));
  }

  // Account tab settings
  static Future<bool> loadHideZeroCurrencies() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_kHideZeroCurrencies) ?? false;
  }

  static Future<void> saveHideZeroCurrencies(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kHideZeroCurrencies, v);
  }

  // Percent sizing buffer for leveraged percent-based sizing (fraction 0..1)
  static Future<double> loadPercentSizingBuffer() async {
    final sp = await SharedPreferences.getInstance();
    final v = sp.getDouble(_kPercentSizingBuffer);
    if (v == null) return 0.95; // default: use 95% of funds
    // Clamp to sensible range
    if (v < 0.1) return 0.1;
    if (v > 1.0) return 1.0;
    return v;
  }

  static Future<void> savePercentSizingBuffer(double v) async {
    final sp = await SharedPreferences.getInstance();
    final clamped = v.clamp(0.1, 1.0);
    await sp.setDouble(_kPercentSizingBuffer, clamped);
  }

  static Future<AppThemePreference> loadThemePreference() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kThemePreference);
    return AppThemePreference.values.firstWhere(
      (v) => v.name == raw,
      orElse: () => AppThemePreference.system,
    );
  }

  static Future<void> saveThemePreference(AppThemePreference v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kThemePreference, v.name);
  }

  static Future<DesktopWindowState?> loadDesktopWindowState() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kDesktopWindowState);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      return DesktopWindowState.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveDesktopWindowState(DesktopWindowState state) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kDesktopWindowState, jsonEncode(state.toJson()));
  }

  // USD→CNY 参考汇率缓存（Frankfurter 官方中间价，日频）。
  // sourceDate = ECB 发布日（数据实际日期）；fetchedAt = 本地拉取时间（用于 TTL 判断）。
  static Future<({double rate, DateTime sourceDate, DateTime fetchedAt})?>
  loadUsdCnyRate() async {
    final sp = await SharedPreferences.getInstance();
    final r = sp.getDouble(_kUsdCnyRate);
    final src = sp.getInt(_kUsdCnyRateSourceDate);
    final fetched = sp.getInt(_kUsdCnyRateFetchedAt);
    if (r == null || r <= 0 || src == null || fetched == null) return null;
    return (
      rate: r,
      sourceDate: DateTime.fromMillisecondsSinceEpoch(src),
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(fetched),
    );
  }

  static Future<void> saveUsdCnyRate(
    double rate,
    DateTime sourceDate,
    DateTime fetchedAt,
  ) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble(_kUsdCnyRate, rate);
    await sp.setInt(_kUsdCnyRateSourceDate, sourceDate.millisecondsSinceEpoch);
    await sp.setInt(_kUsdCnyRateFetchedAt, fetchedAt.millisecondsSinceEpoch);
  }
}

class Credentials {
  final String clientId;
  final String clientSecret;
  Credentials({required this.clientId, required this.clientSecret});
}
