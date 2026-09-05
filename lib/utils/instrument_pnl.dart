import 'package:decimal/decimal.dart';

import '../models/market_data.dart';
import '../models/trading_pair.dart';
import 'decimal_utils.dart';

const int _divisionScale = 24;

class PositionPnl {
  final Decimal settlementAmount;
  final String settlementCurrency;
  final Decimal? quoteEquivalent;
  final String? quoteCurrency;
  final bool isFallback;

  const PositionPnl({
    required this.settlementAmount,
    required this.settlementCurrency,
    required this.quoteEquivalent,
    required this.quoteCurrency,
    required this.isFallback,
  });

  double get settlementAmountAsDouble => dToDouble(settlementAmount);

  double? get quoteEquivalentAsDouble {
    final value = quoteEquivalent;
    return value == null ? null : dToDouble(value);
  }
}

PositionPnl calculatePositionPnl({
  required TradingPair pair,
  required Position position,
  double? markPrice,
}) {
  _requireVerifiedPair(pair);
  _requireMatchingInstrument(pair, position.instrumentName);
  if (pair.type != TradingPairType.future &&
      !(pair.type == TradingPairType.spot && position.kind == 'margin')) {
    throw ArgumentError.value(
      pair.type,
      'pair',
      'Position PnL requires derivatives or a margin position',
    );
  }

  final effectiveMark = markPrice ?? position.markPrice;
  final validMark = _isPositiveFinite(effectiveMark);
  final validEntry = _isPositiveFinite(position.averagePrice);
  final directionSign = switch (position.direction.trim().toLowerCase()) {
    'buy' => Decimal.one,
    'sell' => -Decimal.one,
    _ => null,
  };
  final nativeAmount = pair.isInverseFuture
      ? position.size.abs()
      : position.sizeCurrency.abs();
  final validAmount = _isPositiveFinite(nativeAmount);
  final canCalculate =
      validMark && validEntry && validAmount && directionSign != null;

  late final Decimal settlementAmount;
  if (!canCalculate) {
    if (position.kind == 'margin') {
      throw ArgumentError('Margin PnL requires valid prices and exposure');
    }
    settlementAmount = _finiteDecimalOrZero(position.floatingProfitLoss);
  } else {
    final amount = dFrom(nativeAmount);
    final entry = dFrom(position.averagePrice);
    final mark = dFrom(effectiveMark);
    if (pair.isInverseFuture) {
      settlementAmount =
          (directionSign.toRational() *
                  amount.toRational() *
                  (Decimal.one / entry - Decimal.one / mark))
              .toDecimal(scaleOnInfinitePrecision: _divisionScale);
    } else {
      settlementAmount = directionSign * amount * (mark - entry);
    }
  }

  Decimal? quoteEquivalent;
  String? quoteCurrency;
  if (pair.isInverseFuture && validMark) {
    quoteEquivalent = settlementAmount * dFrom(effectiveMark);
    quoteCurrency = pair.quoteCurrency;
  }

  return PositionPnl(
    settlementAmount: settlementAmount,
    settlementCurrency: pair.settlementCurrency,
    quoteEquivalent: quoteEquivalent,
    quoteCurrency: quoteCurrency,
    isFallback: !canCalculate,
  );
}

Decimal tradeQuoteNotional({
  required TradingPair pair,
  required TradeHistory trade,
}) {
  _requireVerifiedPair(pair);
  _requireMatchingInstrument(pair, trade.instrumentName);
  if (!_isNonNegativeFinite(trade.amount)) {
    throw ArgumentError.value(
      trade.amount,
      'trade.amount',
      'Trade amount must be finite and non-negative',
    );
  }

  final amount = dFrom(trade.amount);
  if (pair.isInverseFuture) return amount;
  if (!_isPositiveFinite(trade.price)) {
    throw ArgumentError.value(
      trade.price,
      'trade.price',
      'Trade price must be finite and greater than zero',
    );
  }
  return amount * dFrom(trade.price);
}

Decimal? tryTradeQuoteNotional({
  required TradingPair pair,
  required TradeHistory trade,
}) {
  if (!pair.isVerified ||
      pair.symbol != trade.instrumentName.trim().toUpperCase() ||
      !_isNonNegativeFinite(trade.amount) ||
      (!pair.isInverseFuture && !_isPositiveFinite(trade.price))) {
    return null;
  }
  return tradeQuoteNotional(pair: pair, trade: trade);
}

void _requireVerifiedPair(TradingPair pair) {
  if (!pair.isVerified) {
    throw StateError(
      'Verified instrument metadata is required for ${pair.symbol}',
    );
  }
}

void _requireMatchingInstrument(TradingPair pair, String instrumentName) {
  if (pair.symbol != instrumentName.trim().toUpperCase()) {
    throw ArgumentError.value(
      instrumentName,
      'instrumentName',
      'Instrument does not match metadata for ${pair.symbol}',
    );
  }
}

bool _isPositiveFinite(double value) => value.isFinite && value > 0;

bool _isNonNegativeFinite(double value) => value.isFinite && value >= 0;

Decimal _finiteDecimalOrZero(double value) =>
    value.isFinite ? dFrom(value) : Decimal.zero;
