import '../models/market_data.dart';
import '../models/trading_pair.dart';
import 'decimal_utils.dart';

enum ManualOrderAmountUnit { base, quote, apiUsd }

enum ManualOrderType { limit, market }

typedef AmountReference = ({double? price, String? label});

bool isValidPositionPercentage(double? percentage) =>
    percentage != null &&
    percentage.isFinite &&
    percentage > 0 &&
    percentage <= 100;

bool isSemanticallyFullPercentage(double percentage) =>
    isValidPositionPercentage(percentage) && percentage == 100.0;

class OrderAmountConversion {
  final TradingPair pair;
  final double inputAmount;
  final ManualOrderAmountUnit inputUnit;
  final ManualOrderType orderType;
  final String direction;
  final double? referencePrice;
  final String? referenceLabel;
  final double apiAmount;
  final double rawApiAmount;
  final double baseAmount;
  final double notional;
  final bool roundedUp;
  final bool roundedDown;
  final String? errorMessage;

  const OrderAmountConversion({
    required this.pair,
    required this.inputAmount,
    required this.inputUnit,
    required this.orderType,
    required this.direction,
    required this.referencePrice,
    required this.referenceLabel,
    required this.apiAmount,
    this.rawApiAmount = 0,
    required this.baseAmount,
    required this.notional,
    required this.roundedUp,
    this.roundedDown = false,
    this.errorMessage,
  });

  bool get canSubmit =>
      errorMessage == null && apiAmount.isFinite && apiAmount > 0;
  bool get isInverseFuture => isInverseFuturePair(pair);
}

bool isInverseFuturePair(TradingPair pair) => pair.isInverseFuture;

class ApiAmountNormalization {
  final double rawAmount;
  final double apiAmount;
  final bool roundedDown;
  final bool preservedExact;
  final String? errorMessage;

  const ApiAmountNormalization({
    required this.rawAmount,
    required this.apiAmount,
    required this.roundedDown,
    required this.preservedExact,
    this.errorMessage,
  });

  bool get canSubmit =>
      errorMessage == null && apiAmount.isFinite && apiAmount > 0;
}

double floorToContractSize(double amount, double contractSize) {
  if (!amount.isFinite ||
      !contractSize.isFinite ||
      amount <= 0 ||
      contractSize <= 0) {
    return amount;
  }
  final amountD = dFrom(amount);
  final stepD = dFrom(contractSize);
  final quotient = amountD / stepD;
  final floorQ = quotient.toBigInt();
  return dToDouble(stepD * dParse(floorQ.toString()));
}

ApiAmountNormalization normalizeApiAmount({
  required TradingPair pair,
  required double rawApiAmount,
  bool preserveExact = false,
}) {
  if (!pair.isVerified) {
    return _unverifiedAmountNormalization(rawApiAmount, preserveExact);
  }
  if (rawApiAmount <= 0 || rawApiAmount.isNaN || rawApiAmount.isInfinite) {
    return ApiAmountNormalization(
      rawAmount: rawApiAmount,
      apiAmount: 0,
      roundedDown: false,
      preservedExact: preserveExact,
      errorMessage: 'Invalid order amount',
    );
  }

  final apiAmount = preserveExact
      ? rawApiAmount
      : floorToContractSize(rawApiAmount, pair.contractSize);
  if (apiAmount <= 0 || apiAmount < pair.minTradeAmount) {
    return ApiAmountNormalization(
      rawAmount: rawApiAmount,
      apiAmount: apiAmount,
      roundedDown: apiAmount < rawApiAmount,
      preservedExact: preserveExact,
      errorMessage:
          'Order amount is below minimum ${pair.minTradeAmount} ${pair.apiAmountCurrency}',
    );
  }
  return ApiAmountNormalization(
    rawAmount: rawApiAmount,
    apiAmount: apiAmount,
    roundedDown: apiAmount < rawApiAmount,
    preservedExact: preserveExact,
  );
}

double positionNativeApiAmount(TradingPair pair, Position position) {
  _requireVerifiedPair(pair);
  if (pair.isInverseFuture) return position.size.abs();
  if (pair.type == TradingPairType.future) return position.sizeCurrency.abs();
  return position.sizeCurrency == 0
      ? position.size.abs()
      : position.sizeCurrency.abs();
}

double apiAmountToBaseExposure(
  TradingPair pair,
  double apiAmount,
  double? referencePrice,
) {
  _requireVerifiedPair(pair);
  if (!pair.isInverseFuture) return apiAmount;
  if (referencePrice == null || referencePrice <= 0) return 0;
  return apiAmount / referencePrice;
}

double apiAmountToQuoteNotional(
  TradingPair pair,
  double apiAmount,
  double? referencePrice,
) {
  _requireVerifiedPair(pair);
  if (pair.isInverseFuture) return apiAmount;
  if (referencePrice == null || referencePrice <= 0) return 0;
  return apiAmount * referencePrice;
}

ApiAmountNormalization positionPercentageApiAmount({
  required TradingPair pair,
  required Position position,
  required double percentage,
  bool preserveFullPosition = false,
}) {
  if (!pair.isVerified) {
    return _unverifiedAmountNormalization(0, false);
  }
  if (!isValidPositionPercentage(percentage)) {
    return ApiAmountNormalization(
      rawAmount: 0,
      apiAmount: 0,
      roundedDown: false,
      preservedExact: false,
      errorMessage: 'Percentage must be greater than 0 and at most 100',
    );
  }
  final nativeAmount = positionNativeApiAmount(pair, position);
  final isFull = isSemanticallyFullPercentage(percentage);
  final rawAmount = preserveFullPosition && isFull
      ? nativeAmount
      : nativeAmount * (percentage / 100);
  return normalizeApiAmount(
    pair: pair,
    rawApiAmount: rawAmount,
    preserveExact: preserveFullPosition && isFull,
  );
}

ApiAmountNormalization reversePositionApiAmount({
  required TradingPair pair,
  required Position position,
  required double targetPercentage,
}) {
  if (!pair.isVerified) {
    return _unverifiedAmountNormalization(0, false);
  }
  if (!isValidPositionPercentage(targetPercentage)) {
    return ApiAmountNormalization(
      rawAmount: 0,
      apiAmount: 0,
      roundedDown: false,
      preservedExact: false,
      errorMessage: 'Target percentage must be greater than 0 and at most 100',
    );
  }
  final nativeAmount = positionNativeApiAmount(pair, position);
  return normalizeApiAmount(
    pair: pair,
    rawApiAmount: nativeAmount * (1 + targetPercentage / 100),
  );
}

double explicitAmountToRawApi({
  required TradingPair pair,
  required double amount,
  required bool isQuoteCurrency,
  required double? referencePrice,
}) {
  _requireVerifiedPair(pair);
  if (!amount.isFinite || amount <= 0) return 0;
  if (isQuoteCurrency) {
    if (pair.isInverseFuture) return amount;
    if (referencePrice == null ||
        !referencePrice.isFinite ||
        referencePrice <= 0) {
      return 0;
    }
    return amount / referencePrice;
  }
  if (!pair.isInverseFuture) return amount;
  if (referencePrice == null ||
      !referencePrice.isFinite ||
      referencePrice <= 0) {
    return 0;
  }
  return amount * referencePrice;
}

AmountReference resolvePositionAmountReference({
  required Position position,
  double? preferredPrice,
  String preferredLabel = 'Limit Price',
  double? latestMarkPrice,
  double? fallbackPrice,
  String fallbackLabel = 'Trigger Price',
}) {
  final candidates = <(double?, String)>[
    (preferredPrice, preferredLabel),
    (position.markPrice, 'Mark Price'),
    (latestMarkPrice, 'Mark Price'),
    (fallbackPrice, fallbackLabel),
    (position.averagePrice, 'Average Price'),
  ];
  for (final candidate in candidates) {
    final price = candidate.$1;
    if (price != null && price.isFinite && price > 0) {
      return (price: price, label: candidate.$2);
    }
  }
  return (price: null, label: null);
}

OrderAmountConversion convertPositionAmountForApi({
  required TradingPair pair,
  required double inputAmount,
  required ManualOrderAmountUnit inputUnit,
  required ManualOrderType orderType,
  required String direction,
  required AmountReference reference,
}) {
  if (!pair.isVerified) {
    return _unverifiedOrderAmountConversion(
      pair: pair,
      inputAmount: inputAmount,
      inputUnit: inputUnit,
      orderType: orderType,
      direction: direction,
      reference: reference,
    );
  }
  final isQuoteCurrency =
      inputUnit == ManualOrderAmountUnit.quote ||
      inputUnit == ManualOrderAmountUnit.apiUsd;
  final rawApiAmount = explicitAmountToRawApi(
    pair: pair,
    amount: inputAmount,
    isQuoteCurrency: isQuoteCurrency,
    referencePrice: reference.price,
  );
  final normalized = normalizeApiAmount(pair: pair, rawApiAmount: rawApiAmount);
  final referencePrice = reference.price;
  final requiresReference =
      (pair.isInverseFuture && !isQuoteCurrency) ||
      (!pair.isInverseFuture && isQuoteCurrency);
  final missingReference =
      requiresReference &&
      (referencePrice == null ||
          !referencePrice.isFinite ||
          referencePrice <= 0);
  final errorMessage = !inputAmount.isFinite || inputAmount <= 0
      ? '请输入有效的下单数量'
      : missingReference
      ? '缺少参考价格，无法换算 API 下单数量'
      : normalized.errorMessage;
  final apiAmount = errorMessage == null ? normalized.apiAmount : 0.0;

  return OrderAmountConversion(
    pair: pair,
    inputAmount: inputAmount,
    inputUnit: inputUnit,
    orderType: orderType,
    direction: direction.toLowerCase(),
    referencePrice: referencePrice,
    referenceLabel: reference.label,
    apiAmount: apiAmount,
    rawApiAmount: rawApiAmount,
    baseAmount: apiAmountToBaseExposure(pair, apiAmount, referencePrice),
    notional: apiAmountToQuoteNotional(pair, apiAmount, referencePrice),
    roundedUp: false,
    roundedDown: normalized.roundedDown,
    errorMessage: errorMessage,
  );
}

OrderAmountConversion convertOrderAmountForApi({
  required TradingPair pair,
  required double inputAmount,
  required ManualOrderAmountUnit inputUnit,
  required ManualOrderType orderType,
  required String direction,
  double? limitPrice,
  double? bestBid,
  double? bestAsk,
}) {
  final normalizedDirection = direction.toLowerCase();
  final reference = _resolveReferencePrice(
    orderType: orderType,
    direction: normalizedDirection,
    limitPrice: limitPrice,
    bestBid: bestBid,
    bestAsk: bestAsk,
  );

  if (!pair.isVerified) {
    return _unverifiedOrderAmountConversion(
      pair: pair,
      inputAmount: inputAmount,
      inputUnit: inputUnit,
      orderType: orderType,
      direction: normalizedDirection,
      reference: reference,
    );
  }

  if (inputAmount <= 0 || inputAmount.isNaN || inputAmount.isInfinite) {
    return OrderAmountConversion(
      pair: pair,
      inputAmount: inputAmount,
      inputUnit: inputUnit,
      orderType: orderType,
      direction: normalizedDirection,
      referencePrice: reference.price,
      referenceLabel: reference.label,
      apiAmount: 0,
      baseAmount: 0,
      notional: 0,
      roundedUp: false,
      errorMessage: '请输入有效的下单数量',
    );
  }

  final isInverse = isInverseFuturePair(pair);
  final isSpotQuote =
      pair.type == TradingPairType.spot &&
      inputUnit == ManualOrderAmountUnit.quote;
  if (!isInverse && !isSpotQuote) {
    final refPrice = reference.price;
    final normalized = normalizeApiAmount(
      pair: pair,
      rawApiAmount: inputAmount,
    );
    return OrderAmountConversion(
      pair: pair,
      inputAmount: inputAmount,
      inputUnit: inputUnit,
      orderType: orderType,
      direction: normalizedDirection,
      referencePrice: refPrice,
      referenceLabel: reference.label,
      apiAmount: normalized.apiAmount,
      rawApiAmount: inputAmount,
      baseAmount: normalized.apiAmount,
      notional: apiAmountToQuoteNotional(pair, normalized.apiAmount, refPrice),
      roundedUp: false,
      roundedDown: normalized.roundedDown,
      errorMessage: normalized.errorMessage,
    );
  }

  final refPrice = reference.price;
  if (isSpotQuote) {
    if (refPrice == null || refPrice <= 0) {
      return OrderAmountConversion(
        pair: pair,
        inputAmount: inputAmount,
        inputUnit: inputUnit,
        orderType: orderType,
        direction: normalizedDirection,
        referencePrice: refPrice,
        referenceLabel: reference.label,
        apiAmount: 0,
        baseAmount: 0,
        notional: 0,
        roundedUp: false,
        errorMessage: '缺少参考价格，无法将 quote 金额换算为下单数量',
      );
    }
    final rawBaseAmount = inputAmount / refPrice;
    final normalized = normalizeApiAmount(
      pair: pair,
      rawApiAmount: rawBaseAmount,
    );
    final apiAmount = normalized.apiAmount;
    if (!normalized.canSubmit) {
      return OrderAmountConversion(
        pair: pair,
        inputAmount: inputAmount,
        inputUnit: inputUnit,
        orderType: orderType,
        direction: normalizedDirection,
        referencePrice: refPrice,
        referenceLabel: reference.label,
        apiAmount: apiAmount,
        rawApiAmount: rawBaseAmount,
        baseAmount: 0,
        notional: 0,
        roundedUp: false,
        roundedDown: rawBaseAmount > 0,
        errorMessage:
            '换算后的下单数量低于最小交易数量 ${pair.minTradeAmount} ${pair.baseCurrency}',
      );
    }
    return OrderAmountConversion(
      pair: pair,
      inputAmount: inputAmount,
      inputUnit: inputUnit,
      orderType: orderType,
      direction: normalizedDirection,
      referencePrice: refPrice,
      referenceLabel: reference.label,
      apiAmount: apiAmount,
      rawApiAmount: rawBaseAmount,
      baseAmount: apiAmount,
      notional: apiAmount * refPrice,
      roundedUp: false,
      roundedDown: apiAmount < rawBaseAmount,
    );
  }

  if (inputUnit == ManualOrderAmountUnit.base) {
    if (refPrice == null || refPrice <= 0) {
      return OrderAmountConversion(
        pair: pair,
        inputAmount: inputAmount,
        inputUnit: inputUnit,
        orderType: orderType,
        direction: normalizedDirection,
        referencePrice: refPrice,
        referenceLabel: reference.label,
        apiAmount: 0,
        baseAmount: inputAmount,
        notional: 0,
        roundedUp: false,
        errorMessage: '缺少参考价格，无法将币本位数量换算为 API ${pair.apiAmountCurrency} amount',
      );
    }
    final rawApiAmount = inputAmount * refPrice;
    final normalized = normalizeApiAmount(
      pair: pair,
      rawApiAmount: rawApiAmount,
    );
    final apiAmount = normalized.apiAmount;
    return OrderAmountConversion(
      pair: pair,
      inputAmount: inputAmount,
      inputUnit: inputUnit,
      orderType: orderType,
      direction: normalizedDirection,
      referencePrice: refPrice,
      referenceLabel: reference.label,
      apiAmount: apiAmount,
      rawApiAmount: rawApiAmount,
      baseAmount: apiAmount / refPrice,
      notional: apiAmount,
      roundedUp: false,
      roundedDown: normalized.roundedDown,
      errorMessage: normalized.errorMessage == null
          ? null
          : '换算后的下单数量低于最小交易数量 ${pair.minTradeAmount} ${pair.apiAmountCurrency}',
    );
  }

  final normalized = normalizeApiAmount(pair: pair, rawApiAmount: inputAmount);
  return OrderAmountConversion(
    pair: pair,
    inputAmount: inputAmount,
    inputUnit: inputUnit,
    orderType: orderType,
    direction: normalizedDirection,
    referencePrice: refPrice,
    referenceLabel: reference.label,
    apiAmount: normalized.apiAmount,
    rawApiAmount: inputAmount,
    baseAmount: apiAmountToBaseExposure(pair, normalized.apiAmount, refPrice),
    notional: normalized.apiAmount,
    roundedUp: false,
    roundedDown: normalized.roundedDown,
    errorMessage: normalized.errorMessage,
  );
}

ApiAmountNormalization _unverifiedAmountNormalization(
  double rawAmount,
  bool preserveExact,
) => ApiAmountNormalization(
  rawAmount: rawAmount,
  apiAmount: 0,
  roundedDown: false,
  preservedExact: preserveExact,
  errorMessage: 'Verified instrument metadata is required',
);

OrderAmountConversion _unverifiedOrderAmountConversion({
  required TradingPair pair,
  required double inputAmount,
  required ManualOrderAmountUnit inputUnit,
  required ManualOrderType orderType,
  required String direction,
  required AmountReference reference,
}) => OrderAmountConversion(
  pair: pair,
  inputAmount: inputAmount,
  inputUnit: inputUnit,
  orderType: orderType,
  direction: direction.toLowerCase(),
  referencePrice: reference.price,
  referenceLabel: reference.label,
  apiAmount: 0,
  baseAmount: 0,
  notional: 0,
  roundedUp: false,
  errorMessage: 'Verified instrument metadata is required',
);

void _requireVerifiedPair(TradingPair pair) {
  if (!pair.isVerified) {
    throw StateError(
      'Verified instrument metadata is required for ${pair.symbol}',
    );
  }
}

({double? price, String? label}) _resolveReferencePrice({
  required ManualOrderType orderType,
  required String direction,
  double? limitPrice,
  double? bestBid,
  double? bestAsk,
}) {
  if (orderType == ManualOrderType.limit) {
    final price = limitPrice != null && limitPrice > 0 ? limitPrice : null;
    return (price: price, label: price == null ? null : 'Limit Price');
  }

  if (direction == 'buy') {
    final price = bestAsk != null && bestAsk > 0 ? bestAsk : null;
    return (price: price, label: price == null ? null : 'Best Ask');
  }
  if (direction == 'sell') {
    final price = bestBid != null && bestBid > 0 ? bestBid : null;
    return (price: price, label: price == null ? null : 'Best Bid');
  }

  final bid = bestBid ?? 0;
  final ask = bestAsk ?? 0;
  if (bid > 0 && ask > 0) {
    return (price: (bid + ask) / 2, label: 'Mid');
  }
  return (price: null, label: null);
}
