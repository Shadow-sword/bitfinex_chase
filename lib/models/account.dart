class AccountSummaryCurrency {
  static const double _displayZeroThreshold = 0.0000005;

  final String currency;
  final double equity;
  final double balance;
  final double availableFunds;
  final double availableWithdrawalFunds;
  final double maintenanceMargin;
  final double initialMargin;
  final double marginBalance;
  final double feeBalance;
  final double lockedBalance;
  final double optionsValue;
  final String? depositAddress;
  final String marginModel;
  final Map<String, double>? estimatedLiquidationRatioMap;
  final double sessionUpl;
  final double sessionRpl;
  final double futuresSessionUpl;
  final double futuresSessionRpl;
  final double optionsSessionUpl;
  final double optionsSessionRpl;
  final double optionsPl;
  final double futuresPl;
  final double totalPl;

  const AccountSummaryCurrency({
    required this.currency,
    required this.equity,
    required this.balance,
    required this.availableFunds,
    required this.availableWithdrawalFunds,
    required this.maintenanceMargin,
    required this.initialMargin,
    required this.marginBalance,
    required this.feeBalance,
    required this.lockedBalance,
    required this.optionsValue,
    this.depositAddress,
    required this.marginModel,
    this.estimatedLiquidationRatioMap = const {},
    this.sessionUpl = 0.0,
    this.sessionRpl = 0.0,
    this.futuresSessionUpl = 0.0,
    this.futuresSessionRpl = 0.0,
    this.optionsSessionUpl = 0.0,
    this.optionsSessionRpl = 0.0,
    this.optionsPl = 0.0,
    this.futuresPl = 0.0,
    this.totalPl = 0.0,
  });

  static bool _isDisplayZero(double value) =>
      value.abs() < _displayZeroThreshold;

  bool get hasDisplayableEquity => !_isDisplayZero(equity);

  bool get isDisplayZero => balance.abs() < 1e-10;

  bool get hasValuationExposure => equity.abs() >= 1e-10;

  factory AccountSummaryCurrency.fromMap(Map<String, dynamic> m) {
    double numValue(dynamic v) => (v as num?)?.toDouble() ?? 0.0;
    Map<String, double> numMap(dynamic v) {
      final out = <String, double>{};
      if (v is Map) {
        v.forEach((key, value) {
          if (key is String) out[key] = (value as num?)?.toDouble() ?? 0.0;
        });
      }
      return out;
    }

    return AccountSummaryCurrency(
      currency: ((m['currency'] as String?) ?? '').trim().toUpperCase(),
      equity: numValue(m['equity']),
      balance: numValue(m['balance']),
      availableFunds: numValue(m['available_funds']),
      availableWithdrawalFunds: numValue(m['available_withdrawal_funds']),
      maintenanceMargin: numValue(m['maintenance_margin']),
      initialMargin: numValue(m['initial_margin']),
      marginBalance: numValue(m['margin_balance']),
      feeBalance: numValue(m['fee_balance']),
      lockedBalance: numValue(m['locked_balance']),
      optionsValue: numValue(m['options_value']),
      depositAddress: m['deposit_address'] as String?,
      marginModel: (m['margin_model'] as String?) ?? '',
      estimatedLiquidationRatioMap: numMap(
        m['estimated_liquidation_ratio_map'],
      ),
      sessionUpl: numValue(m['session_upl']),
      sessionRpl: numValue(m['session_rpl']),
      futuresSessionUpl: numValue(m['futures_session_upl']),
      futuresSessionRpl: numValue(m['futures_session_rpl']),
      optionsSessionUpl: numValue(m['options_session_upl']),
      optionsSessionRpl: numValue(m['options_session_rpl']),
      optionsPl: numValue(m['options_pl']),
      futuresPl: numValue(m['futures_pl']),
      totalPl: numValue(m['total_pl']),
    );
  }
}

class AccountSummaries {
  final int id;
  final String type;
  final String username;
  final String email;
  final bool mandatoryTfa;
  final bool securityKeysEnabled;
  final List<AccountSummaryCurrency> summaries;

  const AccountSummaries({
    required this.id,
    required this.type,
    required this.username,
    required this.email,
    required this.mandatoryTfa,
    required this.securityKeysEnabled,
    required this.summaries,
  });

  factory AccountSummaries.fromMap(Map<String, dynamic> m) {
    final list =
        (m['summaries'] as List?)?.whereType<Map<String, dynamic>>().toList() ??
        const [];
    return AccountSummaries(
      id: (m['id'] as num?)?.toInt() ?? 0,
      type: (m['type'] as String?) ?? '',
      username: (m['username'] as String?) ?? '',
      email: (m['email'] as String?) ?? '',
      mandatoryTfa: m['mandatory_tfa'] == true,
      securityKeysEnabled: m['security_keys_enabled'] == true,
      summaries: list.map(AccountSummaryCurrency.fromMap).toList(),
    );
  }
}
