class OrderBookData {
  final String instrumentName;
  final int timestamp;
  final List<List<dynamic>> asks;
  final List<List<dynamic>> bids;

  const OrderBookData({
    required this.instrumentName,
    required this.timestamp,
    required this.asks,
    required this.bids,
  });

  double get bestAsk => asks.isNotEmpty ? _toDouble(asks.first.first) : 0.0;
  double get bestBid => bids.isNotEmpty ? _toDouble(bids.first.first) : 0.0;
  double get spread => bestAsk - bestBid;

  static double _toDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }
}

class TickerData {
  final String instrumentName;
  final int timestamp;
  final double markPrice;
  final double indexPrice;
  final double? bestBid;
  final double? bestAsk;

  const TickerData({
    required this.instrumentName,
    required this.timestamp,
    required this.markPrice,
    required this.indexPrice,
    this.bestBid,
    this.bestAsk,
  });
}

class Position {
  final String instrumentName;
  final String kind;
  final double size;
  final double sizeCurrency;
  final String direction; // 'buy' | 'sell'
  final double averagePrice;
  final double? averagePriceUsd;
  final double markPrice;
  final double indexPrice;
  final double settlementPrice;
  final double leverage;
  final double maintenanceMargin;
  final double initialMargin;
  final double openOrdersMargin;
  final double delta;
  final double? gamma;
  final double? theta;
  final double? vega;
  final double floatingProfitLoss;
  final double realizedProfitLoss;
  final double totalProfitLoss;
  final double realizedFunding;
  final double interestValue;
  final double? estimatedLiquidationPrice;

  const Position({
    required this.instrumentName,
    required this.kind,
    required this.size,
    required this.sizeCurrency,
    required this.direction,
    required this.averagePrice,
    this.averagePriceUsd,
    required this.markPrice,
    required this.indexPrice,
    required this.settlementPrice,
    required this.leverage,
    required this.maintenanceMargin,
    required this.initialMargin,
    required this.openOrdersMargin,
    required this.delta,
    this.gamma,
    this.theta,
    this.vega,
    required this.floatingProfitLoss,
    required this.realizedProfitLoss,
    required this.totalProfitLoss,
    required this.realizedFunding,
    required this.interestValue,
    this.estimatedLiquidationPrice,
  });

  bool get isLong => direction == 'buy';
  bool get isShort => direction == 'sell';
}

class Order {
  final String orderId;
  final String instrumentName;
  final String direction; // 'buy' | 'sell'
  final double amount;
  final double price;
  final String orderState; // 'open', 'filled', etc.
  final String orderType;
  final bool isExchange;
  final int flags;
  bool get postOnly => flags & 4096 != 0;
  bool get reduceOnly => flags & 1024 != 0;
  final double? stopPrice;
  final String? trigger; // mark_price | index_price | last_price
  final double? trailing; // trailing offset for trailing_stop
  // Filled metrics (if provided by the API)
  final double? averageExecutedPrice;
  final double? filledAmount;
  final int creationTimestamp;
  final int lastUpdateTimestamp;

  const Order({
    required this.orderId,
    required this.instrumentName,
    required this.direction,
    required this.amount,
    required this.price,
    required this.orderState,
    required this.orderType,
    required this.isExchange,
    required this.flags,
    this.stopPrice,
    this.trigger,
    this.trailing,
    this.averageExecutedPrice,
    this.filledAmount,
    required this.creationTimestamp,
    required this.lastUpdateTimestamp,
  });

  bool get isOpen => orderState == 'open';
  bool get isBuy => direction == 'buy';
  bool get isSell => direction == 'sell';
  bool get isActive => orderState == 'open' || orderState == 'untriggered';
  bool get isFilled => orderState == 'filled';
}

class TradeHistory {
  final String tradeId;
  final String instrumentName;
  final String direction;
  final double amount;
  final double price;
  final int timestamp;
  final String orderId;
  final double fee;
  final String feeCurrency;
  final String orderType;
  final double? iv;
  final double markPrice;

  const TradeHistory({
    required this.tradeId,
    required this.instrumentName,
    required this.direction,
    required this.amount,
    required this.price,
    required this.timestamp,
    required this.orderId,
    required this.fee,
    required this.feeCurrency,
    required this.orderType,
    this.iv,
    required this.markPrice,
  });

  bool? get isExchange => orderType.trim().isEmpty
      ? null
      : orderType.trim().toUpperCase().startsWith('EXCHANGE ');

  bool get isBuy => direction == 'buy';
  bool get isSell => direction == 'sell';
}

class UserChanges {
  final List<TradeHistory> trades;
  final List<Order> orders;
  final List<Position> positions;

  const UserChanges({
    this.trades = const [],
    this.orders = const [],
    this.positions = const [],
  });
}
