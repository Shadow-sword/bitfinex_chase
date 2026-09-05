import 'dart:math' as math;

class TradingPair {
  final String symbol;
  final String baseCurrency;
  final String quoteCurrency;
  final String settlementCurrency;
  final double tickSize;
  final TradingPairType type;
  final InstrumentType instrumentType;
  final double minTradeAmount;
  final double contractSize;
  final double maxPriceDeviationPercent;
  final int maxLeverage;
  final bool isVerified;

  const TradingPair({
    required this.symbol,
    required this.baseCurrency,
    required this.quoteCurrency,
    required this.settlementCurrency,
    required this.tickSize,
    required this.type,
    required this.instrumentType,
    required this.minTradeAmount,
    required this.contractSize,
    this.maxPriceDeviationPercent = 0.3,
    this.maxLeverage = 50,
  }) : isVerified = false;

  const TradingPair._verified({
    required this.symbol,
    required this.baseCurrency,
    required this.quoteCurrency,
    required this.settlementCurrency,
    required this.tickSize,
    required this.type,
    required this.instrumentType,
    required this.minTradeAmount,
    required this.contractSize,
    required this.maxPriceDeviationPercent,
    required this.maxLeverage,
  }) : isVerified = true;

  const TradingPair.unverified(
    this.symbol, {
    this.maxPriceDeviationPercent = 0.3,
  }) : baseCurrency = '',
       quoteCurrency = '',
       settlementCurrency = '',
       tickSize = 0,
       type = TradingPairType.unknown,
       instrumentType = InstrumentType.unknown,
       minTradeAmount = 0,
       contractSize = 0,
       maxLeverage = 1,
       isVerified = false;

  TradingPair withMaxPriceDeviationPercent(double value) {
    if (!isVerified) {
      return TradingPair(
        symbol: symbol,
        baseCurrency: baseCurrency,
        quoteCurrency: quoteCurrency,
        settlementCurrency: settlementCurrency,
        tickSize: tickSize,
        type: type,
        instrumentType: instrumentType,
        minTradeAmount: minTradeAmount,
        contractSize: contractSize,
        maxPriceDeviationPercent: value,
        maxLeverage: maxLeverage,
      );
    }
    return TradingPair._verified(
      symbol: symbol,
      baseCurrency: baseCurrency,
      quoteCurrency: quoteCurrency,
      settlementCurrency: settlementCurrency,
      tickSize: tickSize,
      type: type,
      instrumentType: instrumentType,
      minTradeAmount: minTradeAmount,
      contractSize: contractSize,
      maxPriceDeviationPercent: value,
      maxLeverage: maxLeverage,
    );
  }

  bool get isInverseFuture =>
      type == TradingPairType.future &&
      instrumentType == InstrumentType.reversed;

  AmountUnit get amountUnit =>
      isInverseFuture ? AmountUnit.usd : AmountUnit.base;

  String get marginCurrency =>
      settlementCurrency.isNotEmpty ? settlementCurrency : quoteCurrency;

  String get apiAmountCurrency =>
      isInverseFuture ? quoteCurrency : baseCurrency;

  static String canonicalSymbol(String raw) {
    final trimmed = raw.trim();
    return (trimmed.startsWith('t') ? trimmed.substring(1) : trimmed)
        .toUpperCase();
  }

  /// Bitfinex prices use 5 significant figures, with at most 8 decimals.
  double tickSizeAt(double price) {
    if (!price.isFinite || price <= 0) {
      throw ArgumentError('Invalid reference price');
    }
    final exponent = int.parse(price.toStringAsExponential().split('e').last);
    return math.pow(10, math.max(-8, exponent - 4)).toDouble();
  }

  factory TradingPair.fromBitfinexConfig(
    String symbol,
    List<dynamic> config, {
    required bool isFuture,
  }) {
    if (config.length < 10) {
      throw const FormatException('Incomplete pair metadata');
    }
    final normalized = canonicalSymbol(symbol);
    final currencies = normalized.contains(':')
        ? normalized.split(':')
        : [normalized.substring(0, 3), normalized.substring(3)];
    double requiredPositiveNumber(int index, String field) {
      final raw = config[index];
      final value = raw is num
          ? raw.toDouble()
          : raw is String
          ? double.tryParse(raw)
          : null;
      if (value == null || !value.isFinite || value <= 0) {
        throw FormatException('Invalid $field for $normalized');
      }
      return value;
    }

    final minimum = requiredPositiveNumber(3, 'minimum order size');
    // Exchange-only pairs have no margin parameters. They are valid spot
    // instruments and must not prevent the rest of the catalogue from loading.
    final initialMargin = isFuture
        ? requiredPositiveNumber(8, 'initial margin')
        : null;
    if (currencies.length != 2 || currencies.any((c) => c.isEmpty)) {
      throw const FormatException('Invalid pair metadata');
    }
    return TradingPair._verified(
      symbol: normalized,
      baseCurrency: currencies[0],
      quoteCurrency: currencies[1],
      settlementCurrency: currencies[1],
      tickSize: 0.00000001,
      type: isFuture ? TradingPairType.future : TradingPairType.spot,
      instrumentType: isFuture ? InstrumentType.linear : InstrumentType.spot,
      minTradeAmount: minimum,
      contractSize: 0.00000001,
      maxLeverage: isFuture ? (1 / initialMargin!).round() : 1,
      maxPriceDeviationPercent: 0.3,
    );
  }

  factory TradingPair.fromMap(Map<String, dynamic> map) {
    final type = _tradingPairTypeFromString(map['type'] as String?);
    var instrumentType = _instrumentTypeFromString(
      map['instrumentType'] as String?,
      kind: type,
    );

    // Legacy configurations did not persist instrumentType. Preserve the
    // explicit amountUnit when present, but never infer from currency names.
    if (instrumentType == InstrumentType.unknown) {
      final legacyAmountUnit = (map['amountUnit'] as String? ?? '')
          .toLowerCase();
      if (type == TradingPairType.future && legacyAmountUnit == 'usd') {
        instrumentType = InstrumentType.reversed;
      } else if (type == TradingPairType.future && legacyAmountUnit == 'base') {
        instrumentType = InstrumentType.linear;
      } else if (type == TradingPairType.spot) {
        instrumentType = InstrumentType.spot;
      }
    }

    final symbol = canonicalSymbol(map['symbol'] as String? ?? '');
    final baseCurrency = (map['baseCurrency'] as String? ?? '')
        .trim()
        .toUpperCase();
    final quoteCurrency = (map['quoteCurrency'] as String? ?? '')
        .trim()
        .toUpperCase();
    final settlementCurrency =
        (map['settlementCurrency'] as String?)?.trim().toUpperCase() ??
        (instrumentType == InstrumentType.reversed
            ? baseCurrency
            : quoteCurrency);
    final minTradeAmount =
        (map['minTradeAmount'] as num?)?.toDouble() ?? 0.0001;
    return TradingPair(
      symbol: symbol,
      baseCurrency: baseCurrency,
      quoteCurrency: quoteCurrency,
      settlementCurrency: settlementCurrency,
      tickSize: (map['tickSize'] as num?)?.toDouble() ?? 0.1,
      type: type,
      instrumentType: instrumentType,
      minTradeAmount: minTradeAmount,
      contractSize: (map['contractSize'] as num?)?.toDouble() ?? minTradeAmount,
      maxPriceDeviationPercent:
          (map['maxPriceDeviationPercent'] as num?)?.toDouble() ?? 0.3,
      maxLeverage: (map['maxLeverage'] as num?)?.toInt() ?? 50,
    );
  }

  Map<String, dynamic> toMap() => {
    'symbol': symbol,
    'baseCurrency': baseCurrency,
    'quoteCurrency': quoteCurrency,
    'settlementCurrency': settlementCurrency,
    'tickSize': tickSize,
    'type': type.name,
    'instrumentType': instrumentType.name,
    'minTradeAmount': minTradeAmount,
    'contractSize': contractSize,
    'amountUnit': amountUnit.name,
    'maxPriceDeviationPercent': maxPriceDeviationPercent,
    'maxLeverage': maxLeverage,
  };

  static List<TradingPair> defaultPairs({bool paper = true}) => paper
      ? const [
          TradingPair.unverified('TESTBTC:TESTUSD'),
          TradingPair.unverified('TESTETH:TESTUSD'),
          TradingPair.unverified('TESTBTCF0:TESTUSDTF0'),
        ]
      : const [
          TradingPair.unverified('BTCUSD'),
          TradingPair.unverified('ETHUSD'),
          TradingPair.unverified('BTCF0:USTF0'),
        ];
}

TradingPairType _tradingPairTypeFromString(String? raw) {
  switch ((raw ?? '').toLowerCase()) {
    case 'spot':
      return TradingPairType.spot;
    case 'future':
      return TradingPairType.future;
    default:
      return TradingPairType.unknown;
  }
}

InstrumentType _instrumentTypeFromString(
  String? raw, {
  required TradingPairType kind,
}) {
  switch ((raw ?? '').toLowerCase()) {
    case 'spot':
      return InstrumentType.spot;
    case 'linear':
      return InstrumentType.linear;
    case 'reversed':
      return InstrumentType.reversed;
    default:
      return kind == TradingPairType.spot
          ? InstrumentType.spot
          : InstrumentType.unknown;
  }
}

enum TradingPairType { spot, future, unknown }

enum InstrumentType { spot, linear, reversed, unknown }

enum AmountUnit { base, usd }
