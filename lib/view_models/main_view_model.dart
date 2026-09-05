import '../services/local_cache_store.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';

import '../models/market_data.dart';
import '../models/account.dart';
import '../models/announcement.dart';
import 'package:decimal/decimal.dart';
import '../utils/decimal_utils.dart';
import '../utils/instrument_pnl.dart';
import '../models/trading_pair.dart';
import '../services/trading_service.dart';
import '../services/mobile_connection_keep_alive.dart';
import '../services/settings_store.dart';
import '../services/fiat_rate_service.dart';
import '../models/address_book.dart';
import '../models/withdrawal.dart';

class TradingPairVM {
  TradingPair pair;
  bool isSubscribed;
  double bestBid;
  double bestAsk;
  DateTime? lastUpdate;

  // Quick order inputs
  double buyAmount;
  double sellAmount;
  double? buyLimitPrice;
  double? sellLimitPrice;
  int buyOffsetTicks;
  int sellOffsetTicks;
  bool optionsExpanded;
  // Futures-only helpers
  int leverage;
  bool usePercentInput;
  double buyPercent;
  double sellPercent;

  TradingPairVM(
    this.pair, {
    this.isSubscribed = false,
    this.bestBid = 0,
    this.bestAsk = 0,
    this.lastUpdate,
  }) : buyAmount = pair.minTradeAmount,
       sellAmount = pair.minTradeAmount,
       buyOffsetTicks = 0,
       sellOffsetTicks = 0,
       optionsExpanded = false,
       leverage = 1,
       usePercentInput = false,
       buyPercent = 10,
       sellPercent = 10,
       useMarketOrder = false;

  String get symbol => pair.symbol;
  // Spot-only setting: when true, place market orders (no price input)
  bool useMarketOrder;
}

class OrderVM {
  Order order;
  bool isModifying = false;
  double editablePrice;
  double editableAmount;

  OrderVM(this.order)
    : editablePrice = order.price,
      editableAmount = order.amount;
}

class PositionVM {
  Position position;
  PositionVM(this.position);
}

class TradeHistoryEntryVM {
  final TradeHistory trade;
  final int sourceOrder;
  bool isSelected;
  TradeHistoryEntryVM(
    this.trade, {
    this.sourceOrder = 0,
    this.isSelected = true,
  });
  DateTime get executedAtLocal =>
      DateTime.fromMillisecondsSinceEpoch(trade.timestamp).toLocal();
}

int compareTradeHistoryEntries(TradeHistoryEntryVM a, TradeHistoryEntryVM b) {
  final byExecutedAt = a.executedAtLocal.compareTo(b.executedAtLocal);
  return byExecutedAt != 0
      ? byExecutedAt
      : a.sourceOrder.compareTo(b.sourceOrder);
}

bool isTradeHistoryEntryStructurallyValid(TradeHistoryEntryVM entry) {
  final trade = entry.trade;
  final direction = trade.direction.trim().toLowerCase();
  return trade.instrumentName.trim().isNotEmpty &&
      trade.amount.isFinite &&
      trade.amount > 0 &&
      trade.price.isFinite &&
      trade.price > 0 &&
      (direction == 'buy' || direction == 'sell');
}

bool _isTradeHistoryEntryPnlEligible(
  TradeHistoryEntryVM entry,
  TradingPair? instrument,
) {
  if (!isTradeHistoryEntryStructurallyValid(entry) ||
      instrument == null ||
      !instrument.isVerified) {
    return false;
  }
  return entry.trade.instrumentName.trim().toUpperCase() ==
      TradingPair.canonicalSymbol(instrument.symbol);
}

class TradeHistoryFeeAmount {
  final String currency;
  final double amount;

  const TradeHistoryFeeAmount(this.currency, this.amount);
}

class _TradeHistoryOpenLot {
  final bool isBuy;
  final Decimal price;
  Decimal remainingAmount;

  _TradeHistoryOpenLot({
    required this.isBuy,
    required this.price,
    required this.remainingAmount,
  });
}

class _TradeHistoryMatchResult {
  final Decimal realizedPnl;
  final Decimal matchedAmount;
  final Decimal openAmount;

  const _TradeHistoryMatchResult({
    required this.realizedPnl,
    required this.matchedAmount,
    required this.openAmount,
  });
}

_TradeHistoryMatchResult? _matchSelectedTradeHistoryLots(
  Iterable<TradeHistoryEntryVM> entries,
  TradingPair instrument,
) {
  if (!instrument.isVerified) return null;
  final ordered = entries.toList()..sort(compareTradeHistoryEntries);
  if (ordered.any(
    (entry) => !_isTradeHistoryEntryPnlEligible(entry, instrument),
  )) {
    return null;
  }

  final openLots = <_TradeHistoryOpenLot>[];
  var realizedPnl = Decimal.zero;
  var matchedAmount = Decimal.zero;
  for (final entry in ordered) {
    final trade = entry.trade;
    final amount = dFrom(trade.amount);
    final price = dFrom(trade.price);
    final isBuy = trade.direction.trim().toLowerCase() == 'buy';

    var remaining = amount;
    while (remaining > Decimal.zero &&
        openLots.isNotEmpty &&
        openLots.first.isBuy != isBuy) {
      final open = openLots.first;
      final matched = remaining < open.remainingAmount
          ? remaining
          : open.remainingAmount;
      final direction = open.isBuy ? Decimal.one : -Decimal.one;
      if (instrument.isInverseFuture) {
        realizedPnl +=
            (direction.toRational() *
                    matched.toRational() *
                    (Decimal.one / open.price - Decimal.one / price))
                .toDecimal(scaleOnInfinitePrecision: 24);
      } else {
        realizedPnl += matched * (price - open.price) * direction;
      }
      matchedAmount += matched;
      remaining -= matched;
      open.remainingAmount -= matched;
      if (open.remainingAmount == Decimal.zero) openLots.removeAt(0);
    }
    if (remaining > Decimal.zero) {
      openLots.add(
        _TradeHistoryOpenLot(
          isBuy: isBuy,
          price: price,
          remainingAmount: remaining,
        ),
      );
    }
  }

  final openAmount = openLots.fold<Decimal>(
    Decimal.zero,
    (sum, lot) =>
        sum + (lot.isBuy ? lot.remainingAmount : -lot.remainingAmount),
  );
  return _TradeHistoryMatchResult(
    realizedPnl: realizedPnl,
    matchedAmount: matchedAmount,
    openAmount: openAmount,
  );
}

class TradeHistoryRowVM {
  final List<TradeHistoryEntryVM> children;
  bool isExpanded;

  TradeHistoryRowVM(Iterable<TradeHistoryEntryVM> children)
    : children = (children.toList()
        ..sort((a, b) => compareTradeHistoryEntries(b, a))),
      isExpanded = false {
    if (this.children.isEmpty) {
      throw ArgumentError.value(children, 'children', 'must not be empty');
    }
  }

  bool get isMerged => children.length > 1;
  Iterable<TradeHistoryEntryVM> get leafEntries => children;
  TradeHistoryEntryVM get primaryEntry => children.first;
  TradeHistory get primaryTrade => primaryEntry.trade;
  String get instrumentName => primaryTrade.instrumentName;
  String get orderId => primaryTrade.orderId;
  String get shortOrderId => _shortOrderId(orderId);
  DateTime get newestExecutedAtLocal => primaryEntry.executedAtLocal;
  DateTime get oldestExecutedAtLocal => children.last.executedAtLocal;
  double get displayAmount =>
      children.fold(0.0, (sum, child) => sum + child.trade.amount);

  bool? get triState {
    final selected = children.where((child) => child.isSelected).length;
    if (selected == 0) return false;
    if (selected == children.length) return true;
    return null;
  }

  bool get isSelected => triState == true;

  String get displaySide {
    final sides = children
        .map((child) => child.trade.direction.toLowerCase())
        .where((side) => side.isNotEmpty)
        .toSet();
    if (sides.length == 1) return sides.single;
    return 'mixed';
  }

  double? displayQuoteNotional({required TradingPair instrument}) {
    if (!_matchesVerifiedInstrument(instrument)) return null;
    var total = Decimal.zero;
    for (final child in children) {
      final notional = tryTradeQuoteNotional(
        pair: instrument,
        trade: child.trade,
      );
      if (notional == null) return null;
      total += notional;
    }
    return dToDouble(total);
  }

  double? displayAveragePrice({required TradingPair instrument}) {
    if (!_matchesVerifiedInstrument(instrument)) return null;
    var amount = Decimal.zero;
    var quoteNotional = Decimal.zero;
    var inverseBase = Decimal.zero;
    for (final child in children) {
      final trade = child.trade;
      if (!trade.amount.isFinite ||
          trade.amount <= 0 ||
          !trade.price.isFinite ||
          trade.price <= 0) {
        continue;
      }
      final tradeAmount = dFrom(trade.amount);
      amount += tradeAmount;
      quoteNotional += tradeQuoteNotional(pair: instrument, trade: trade);
      if (instrument.isInverseFuture) {
        inverseBase += (tradeAmount / dFrom(trade.price)).toDecimal(
          scaleOnInfinitePrecision: 24,
        );
      }
    }
    final denominator = instrument.isInverseFuture ? inverseBase : amount;
    if (amount <= Decimal.zero || denominator <= Decimal.zero) return null;
    return dToDouble(
      (quoteNotional / denominator).toDecimal(scaleOnInfinitePrecision: 24),
    );
  }

  bool _matchesVerifiedInstrument(TradingPair instrument) {
    if (!instrument.isVerified) return false;
    final symbol = TradingPair.canonicalSymbol(instrument.symbol);
    return symbol.isNotEmpty &&
        children.every(
          (child) => child.trade.instrumentName.trim().toUpperCase() == symbol,
        );
  }

  ({double min, double max}) get priceRange {
    var min = children.first.trade.price;
    var max = children.first.trade.price;
    for (final child in children.skip(1)) {
      final price = child.trade.price;
      if (price < min) min = price;
      if (price > max) max = price;
    }
    return (min: min, max: max);
  }

  bool get hasMixedPrices {
    final first = children.first.trade.price;
    return children.any((child) => child.trade.price != first);
  }

  List<TradeHistoryFeeAmount> get feeAmounts =>
      summarizeTradeHistoryFees(children.map((child) => child.trade));

  void setAll(bool selected) {
    for (final child in children) {
      child.isSelected = selected;
    }
  }

  void toggleSelectionFromCheckbox(bool? value) {
    if (value == true) {
      setAll(true);
    } else if (value == false) {
      setAll(false);
    } else {
      setAll(triState != true);
    }
  }

  static String _shortOrderId(String id) {
    final trimmed = id.trim();
    if (trimmed.length <= 8) return trimmed;
    return '${trimmed.substring(0, 8)}…';
  }
}

class TradeHistoryDayGroupVM {
  final DateTime day; // local date (yyyy-mm-dd 00:00)
  final List<TradeHistoryRowVM> rows;
  TradeHistoryDayGroupVM(this.day, this.rows);

  // Backward-compatible alias for existing callers/tests during migration.
  List<TradeHistoryRowVM> get trades => rows;

  Iterable<TradeHistoryEntryVM> get leafEntries =>
      rows.expand((row) => row.leafEntries);

  bool? get triState {
    final leaves = leafEntries.toList();
    final total = leaves.length;
    final selected = leaves.where((t) => t.isSelected).length;
    if (selected == 0) return false;
    if (selected == total) return true;
    return null;
  }

  void setAll(bool selected) {
    for (final t in leafEntries) {
      t.isSelected = selected;
    }
  }

  void invert() {
    for (final t in leafEntries) {
      t.isSelected = !t.isSelected;
    }
  }
}

List<TradeHistoryFeeAmount> summarizeTradeHistoryFees(
  Iterable<TradeHistory> trades,
) {
  final byCurrency = <String, double>{};
  for (final trade in trades) {
    final fee = trade.fee;
    if (!fee.isFinite) continue;
    final currency = trade.feeCurrency.trim().isEmpty
        ? (fee == 0 ? null : 'UNKNOWN')
        : trade.feeCurrency.trim();
    if (currency == null) continue;
    byCurrency[currency] = (byCurrency[currency] ?? 0.0) + fee;
  }
  final currencies = byCurrency.keys.toList()..sort();
  return [
    for (final currency in currencies)
      TradeHistoryFeeAmount(currency, byCurrency[currency]!),
  ];
}

String formatTradeHistoryFeeAmounts(List<TradeHistoryFeeAmount> fees) {
  if (fees.isEmpty) return '0.000000';
  return fees
      .map((fee) => '${fee.amount.toStringAsFixed(6)} ${fee.currency}')
      .join(' + ');
}

class _AccountMetricsCache {
  final double equity;
  final double maintenanceMargin;
  final double availableFunds;
  final DateTime fetchedAt;
  const _AccountMetricsCache(
    this.equity,
    this.maintenanceMargin,
    this.availableFunds,
    this.fetchedAt,
  );
  bool isExpired(Duration ttl) => DateTime.now().difference(fetchedAt) > ttl;
}

class _RateCache {
  final double rate;
  final DateTime fetchedAt;
  const _RateCache(this.rate, this.fetchedAt);
  bool isExpired(Duration ttl) => DateTime.now().difference(fetchedAt) > ttl;
}

class MainViewModel extends ChangeNotifier {
  final TradingService _service;
  final FiatRateService _fiatRateService = FiatRateService();

  // Connection/Auth state
  String statusMessage = 'Disconnected';
  bool isConnected = false;
  bool isAuthenticated = false;
  bool isTestnet = true;
  bool androidBackgroundKeepAlive = false;
  bool accountInfoFromCache = false;
  bool withdrawalsFromCache = false;
  Timer? _marketCacheSaveTimer;
  int _marketCacheLoadGeneration = 0;
  final Map<String, Future<double?>> _usdRateRequests = {};
  String clientId = '';
  String clientSecret = '';
  bool rememberCredentials = false;
  bool _connectionRequested = false;
  Future<void>? _authenticationFuture;
  bool _disposed = false;
  int _lifecycleGeneration = 0;
  int _connectionOperationGeneration = 0;
  int _authenticationOperationGeneration = 0;
  final Completer<void> _settingsReady = Completer<void>();
  Future<void>? _connectFuture;
  Future<bool>? _resumeConnectionFuture;

  bool get connectionRequested => _connectionRequested;
  bool get isConnecting => _connectFuture != null;
  bool get isAuthenticating => _authenticationFuture != null;

  // Settings
  double maxSpreadPercent = 0.8;
  bool hideZeroCurrencies = false;
  // Percent sizing buffer (fraction 0..1), used for futures % sizing
  double percentSizingBuffer = 0.99;

  // Collections
  final List<TradingPair> customTradingPairs = [];
  final List<TradingPairVM> tradingPairs = [];
  final List<OrderVM> activeOrders = [];
  final List<PositionVM> positions = [];
  final List<String> statusMessages = [];
  // Withdraw / Address book
  final List<AddressBookEntry> addressBook = [];
  bool loadingAddressBook = false;
  String? addressBookError;
  String? addressBookCurrency;
  int _addressBookRequestGeneration = 0;
  final List<Withdrawal> withdrawals = [];
  bool loadingWithdrawals = false;
  String? withdrawalsError;
  String? withdrawalsCurrency;
  bool hasMoreWithdrawals = false;
  int _withdrawalRequestGeneration = 0;
  int _withdrawalNextOffset = 0;
  static const int _withdrawalPageSize = 20;
  // Public announcement history and account-specific unread state.
  final List<Announcement> announcements = [];
  final Set<int> _unreadAnnouncementIds = {};
  bool loadingAnnouncements = false;
  String? announcementsError;
  bool loadingCustomInstrument = false;
  String? customInstrumentError;
  int _customPairLifecycleGeneration = 0;
  int _nextCustomInstrumentLoadOwner = 0;
  final Map<String, int> _customInstrumentLoads = {};
  Future<void> _customPairPersistenceQueue = Future<void>.value();

  /// 正在标已读的公告 id 集合（避免重复点击）
  final Set<int> markingAnnouncementIds = {};
  final List<TradeHistory> tradeHistory = [];
  final List<TradeHistoryDayGroupVM> tradeHistoryGroups = [];
  TradingPair? _tradeHistoryInstrument;
  String? _tradeHistoryRequestedInstrument;
  int _tradeHistoryRequestGeneration = 0;
  // Trade History position navigation
  // Each position is a contiguous range in chronological order where
  // there is at least one buy and one sell and the net native API amount == 0.
  final List<(int start, int end)> _tradeHistoryPositions = [];
  int? _currentTradeHistoryPositionIndex;

  // Account summaries
  AccountSummaries? accountSummaries;
  bool loadingAccountSummaries = false;
  String? accountSummariesError;
  Timer? _accountRefreshTimer;
  static const Duration _accountAutoRefreshInterval = Duration(seconds: 30);
  // Account totals
  bool loadingAccountTotals = false;
  double? accountTotalUsd;
  double? accountTotalBtc;
  final Map<String, _RateCache> _usdRates = {};
  final Map<String, _RateCache> _btcRates = {};
  final Map<String, Future<double?>> _btcRateRequests = {};
  static const Duration _usdRateTtl = Duration(seconds: 30);
  final Set<String> _usdRateLoading = {};
  // USD→CNY 法币汇率（Frankfurter 官方参考价，仅用于展示估值，不参与下单/结算）
  double? accountTotalCny;
  bool loadingAccountCny = false;
  double? _usdCnyRate;
  DateTime? _usdCnySourceDate; // ECB 发布日（数据实际日期）
  DateTime? _usdCnyFetchedAt; // 本地拉取时间（用于 TTL 判断）
  bool _usdCnyStale = false; // 请求失败、降级使用旧值时为 true
  bool _usdCnyLoadedFromDisk = false;
  static const Duration _usdCnyTtl = Duration(hours: 6);

  bool get usdCnyIsStale => _usdCnyStale;
  double? get usdCnyRate => _usdCnyRate;
  DateTime? get usdCnySourceDate => _usdCnySourceDate;

  /// CNY 行下方的标注文本（「参考价/参考价·离线」+ 源数据日期）。
  String? get usdCnyNote {
    if (accountTotalCny == null) return null;
    final prefix = _usdCnyStale ? '参考价·离线' : '参考价';
    final d = _usdCnySourceDate;
    if (d == null) return prefix;
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$prefix ${d.year}-$m-$day';
  }

  double? getCachedUsdRate(String currency) {
    final c = currency.toUpperCase();
    if (c == 'USD' || c == 'USDC' || c == 'USDT' || c == 'USDE') return 1.0;
    final cached = _usdRates[c];
    if (cached == null) return null;
    if (cached.isExpired(_usdRateTtl)) return null;
    return cached.rate;
  }

  Future<void> ensureUsdRate(String currency) async {
    final c = currency.toUpperCase();
    if (c == 'USD' || c == 'USDC' || c == 'USDT' || c == 'USDE') return;
    final cached = _usdRates[c];
    if (cached != null && !cached.isExpired(_usdRateTtl)) return;
    final generation = _accountStateGeneration;
    final requestKey = '$generation:$c';
    if (_usdRateLoading.contains(requestKey)) return;
    _usdRateLoading.add(requestKey);
    try {
      final r = await _getUsdRateForCurrency(c, generation: generation);
      if (r != null && r > 0 && _isCurrentRateGeneration(generation)) {
        notifyListeners();
      }
    } finally {
      _usdRateLoading.remove(requestKey);
    }
  }

  double? getCachedBtcRate(String currency) {
    final c = currency.toUpperCase();
    if (c == 'BTC') return 1.0;
    final cached = _btcRates[c];
    if (cached == null || cached.isExpired(_usdRateTtl)) return null;
    return cached.rate;
  }

  Future<void> ensureBtcRate(String currency) async {
    final c = currency.toUpperCase();
    if (getCachedBtcRate(c) != null) return;
    final generation = _accountStateGeneration;
    final rate = await _getBtcRateForCurrency(c, generation: generation);
    if (rate != null && rate > 0 && _isCurrentRateGeneration(generation)) {
      notifyListeners();
    }
  }

  // Orders refresh
  bool loadingOpenOrders = false;
  Timer? _ordersRefreshTimer;
  static const Duration _ordersAutoRefreshInterval = Duration(seconds: 30);
  bool? isAllTradeHistorySelected;
  int tradeHistorySelectedCount = 0;
  int tradeHistorySelectedExcludedInvalidCount = 0;
  double tradeHistorySelectedBuyAmount = 0;
  double tradeHistorySelectedSellAmount = 0;
  double tradeHistorySelectedBuyValue = 0;
  double tradeHistorySelectedSellValue = 0;
  double? tradeHistorySelectedAverageBuyPrice;
  double? tradeHistorySelectedAverageSellPrice;
  double? tradeHistorySelectedRealizedPnL;
  double? tradeHistorySelectedRealizedPnlQuoteEquivalent;
  double tradeHistorySelectedMatchedAmount = 0;
  double tradeHistorySelectedOpenAmount = 0;
  String? tradeHistorySelectedAmountCurrency;
  String? tradeHistorySelectedQuoteCurrency;
  String? tradeHistorySelectedSettlementCurrency;
  // Aggregated fee for selected trades. Keep total/currency for legacy single-currency
  // callers; use tradeHistorySelectedFeeSummary for display because fees may use
  // multiple currencies.
  double tradeHistorySelectedFeeTotal = 0;
  String? tradeHistorySelectedFeeCurrency;
  String tradeHistorySelectedFeeSummary = '0.000000';
  String? tradeHistorySelectionUnavailableReason;

  StreamSubscription<String>? _statusSub;
  StreamSubscription<OrderBookData>? _bookSub;
  StreamSubscription<TickerData>? _tickerSub;
  StreamSubscription<Order>? _orderSub;
  StreamSubscription<Position>? _posSub;
  StreamSubscription<AnnouncementEvent>? _announcementSub;
  StreamSubscription<TradingPair>? _instrumentSub;
  int _announcementStateGeneration = 0;
  int _accountStateGeneration = 0;
  int _nextSubscriptionIntentGeneration = 0;
  final Map<String, int> _subscriptionIntentGenerations = {};
  final Set<String> _desiredSubscribedSymbols = {};
  final Set<String> _orderSubscriptionSymbols = {};
  final Set<String> _positionSubscriptionSymbols = {};
  final Set<String> _sessionSubscribedSymbols = {};
  final Set<String> _sessionPublicSubscribedSymbols = {};
  final Set<String> _sessionPrivateSubscribedSymbols = {};
  int _nextSessionSubscriptionOwner = 0;
  final Map<String, int> _sessionSubscriptionOwners = {};
  final Map<String, Timer> _subscriptionRetryTimers = {};
  final Map<String, int> _subscriptionRetryAttempts = {};
  final Map<String, _AccountMetricsCache> _accountMetrics = {};
  final Map<String, int> _accountMetricLoadGenerations = {};
  static const Duration _accountMetricsTtl = Duration(seconds: 10);

  MainViewModel(TradingService service) : _service = service {
    _statusSub = _service.statusStream.listen(_onStatus);
    _bookSub = _service.orderBookStream.listen(_onOrderBook);
    _tickerSub = _service.tickerStream.listen(_onTicker);
    _orderSub = _service.orderStream.listen(_onOrder);
    _posSub = _service.positionStream.listen(_onPosition);
    _announcementSub = _service.announcementStream.listen(_onAnnouncementEvent);
    _instrumentSub = _service.instrumentStream.listen(_onInstrumentMetadata);

    // Load defaults
    for (final p in _service.getDefaultPairs()) {
      tradingPairs.add(TradingPairVM(p));
    }

    // Load persisted settings (async, fire-and-forget)
    () async {
      final lifecycleGeneration = _lifecycleGeneration;
      isTestnet = await SettingsStore.loadIsTestnet();
      tradingPairs.clear();
      tradingPairs.addAll(
        TradingPair.defaultPairs(paper: isTestnet).map(TradingPairVM.new),
      );
      androidBackgroundKeepAlive =
          await SettingsStore.loadAndroidBackgroundKeepAlive();
      rememberCredentials = await SettingsStore.loadRememberCredentials();
      maxSpreadPercent = await SettingsStore.loadMaxSpreadPercent();
      hideZeroCurrencies = await SettingsStore.loadHideZeroCurrencies();
      percentSizingBuffer = await SettingsStore.loadPercentSizingBuffer();
      if (rememberCredentials) {
        final creds = await SettingsStore.loadCredentials();
        clientId = creds.clientId;
        clientSecret = creds.clientSecret;
      }
      // load custom pairs
      final rawPairs = await SettingsStore.loadCustomTradingPairsRaw();
      for (final m in rawPairs) {
        _addCachedCustomPair(TradingPair.fromMap(m));
      }
      await _restoreMarketCache();
      // load per-pair options expanded state
      final opts = await SettingsStore.loadPairOptionsExpandedMap();
      for (final tp in tradingPairs) {
        final b = opts[tp.symbol];
        if (b != null) tp.optionsExpanded = b;
      }
      if (!_isAlive(lifecycleGeneration)) {
        _markSettingsReady();
        return;
      }
      await _persistCustomPairs();
      if (!_isAlive(lifecycleGeneration)) {
        _markSettingsReady();
        return;
      }
      _pushServiceSettings();
      if (_service.isConnected && customTradingPairs.isNotEmpty) {
        await _service.refreshInstrumentMetadata(
          symbols: customTradingPairs.map((pair) => pair.symbol),
        );
        if (!_isAlive(lifecycleGeneration)) {
          _markSettingsReady();
          return;
        }
      }
      notifyListeners();
      _markSettingsReady();

      // Auto-connect and authenticate if credentials available
      if (rememberCredentials &&
          clientId.isNotEmpty &&
          clientSecret.isNotEmpty) {
        try {
          await connect();
          if (isConnected) {
            await authenticate();
          }
        } catch (_) {}
      }
    }().catchError((Object error) {
      _onStatus('Settings load failed: $error');
      _markSettingsReady();
    });
  }

  Future<void> _restoreMarketCache() async {
    final generation = ++_marketCacheLoadGeneration;
    final paper = isTestnet;
    try {
      final cached = await LocalCacheStore.loadMarket(paper);
      if (_disposed ||
          paper != isTestnet ||
          generation != _marketCacheLoadGeneration) {
        return;
      }
      final bySymbol = {for (final p in cached) p.symbol: p};
      for (final vm in tradingPairs) {
        final metadata = bySymbol[vm.symbol];
        if (metadata == null || vm.pair.isVerified) continue;
        vm.pair = metadata.withMaxPriceDeviationPercent(
          vm.pair.maxPriceDeviationPercent,
        );
        if (vm.buyAmount == 0) vm.buyAmount = metadata.minTradeAmount;
        if (vm.sellAmount == 0) vm.sellAmount = metadata.minTradeAmount;
      }
      notifyListeners();
    } catch (e) {
      _onStatus('Market cache load failed: $e');
    }
  }

  void _saveMarketCacheSoon() {
    _marketCacheSaveTimer?.cancel();
    final paper = isTestnet;
    final snapshot = tradingPairs
        .map((vm) => vm.pair)
        .where((p) => p.isVerified)
        .toList();
    _marketCacheSaveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(
        LocalCacheStore.saveMarket(paper, snapshot).catchError((Object e) {
          _onStatus('Market cache save failed: $e');
        }),
      );
    });
  }

  Future<void> _restoreAccountIdentity() async {
    final generation = _accountStateGeneration;
    final key = clientId;
    final paper = isTestnet;
    try {
      final cached = await LocalCacheStore.loadIdentity(paper, key);
      if (!_isCurrentAccountState(generation) ||
          key != clientId ||
          paper != isTestnet ||
          cached == null) {
        return;
      }
      accountSummaries = cached.value;
      accountInfoFromCache = true;
      notifyListeners();
    } catch (e) {
      _onStatus('Account cache load failed: $e');
    }
  }

  bool _isAlive(int lifecycleGeneration) =>
      !_disposed && lifecycleGeneration == _lifecycleGeneration;

  void _markSettingsReady() {
    if (!_settingsReady.isCompleted) _settingsReady.complete();
  }

  Future<void> connect() {
    final pending = _connectFuture;
    if (pending != null) return pending;
    final future = _connect();
    _connectFuture = future;
    future.then<void>(
      (_) => _completeConnect(future),
      onError: (Object _, StackTrace __) => _completeConnect(future),
    );
    return future;
  }

  void _completeConnect(Future<void> future) {
    if (identical(_connectFuture, future)) {
      _connectFuture = null;
      notifyListeners();
    }
  }

  void _invalidateAuthenticationOperation() {
    _authenticationOperationGeneration++;
    _authenticationFuture = null;
    isAuthenticated = false;
  }

  Future<void> _connect() async {
    await _settingsReady.future;
    if (_disposed) return;
    _connectionRequested = true;
    final operationGeneration = ++_connectionOperationGeneration;
    final requestedIsTestnet = isTestnet;
    isConnected = false;
    _invalidateAuthenticationOperation();
    _clearTradingSessionState();
    _downgradeTradingPairMetadata();
    statusMessage = 'Connecting...';
    notifyListeners();
    try {
      await _service.connect(isTestnet: requestedIsTestnet);
      if (!_isCurrentConnectionOperation(
        operationGeneration,
        requestedIsTestnet,
      )) {
        return;
      }
      isConnected = _service.isConnected;
      if (isConnected) {
        if (androidBackgroundKeepAlive) {
          try {
            await MobileConnectionKeepAlive.start();
          } catch (e) {
            _onStatus('Android background keepalive failed: $e');
          }
        }
        if (!_isCurrentConnectionOperation(
          operationGeneration,
          requestedIsTestnet,
        )) {
          return;
        }
      }
      // Restore previous subscriptions
      await _resubscribeAll();

      notifyListeners();
    } catch (_) {
      if (_connectionOperationGeneration == operationGeneration && !_disposed) {
        _connectionRequested = false;
        isConnected = false;
        isAuthenticated = false;
        await MobileConnectionKeepAlive.stop();
      }
      rethrow;
    }
  }

  bool _isCurrentConnectionOperation(int generation, bool requestedIsTestnet) =>
      !_disposed &&
      _connectionRequested &&
      generation == _connectionOperationGeneration &&
      requestedIsTestnet == isTestnet;

  Future<void> disconnect() async {
    _connectionRequested = false;
    _connectionOperationGeneration++;
    _invalidateAuthenticationOperation();
    _connectFuture = null;
    _resumeConnectionFuture = null;
    isConnected = false;
    _clearTradingSessionState();
    statusMessage = 'Disconnecting...';
    notifyListeners();
    await MobileConnectionKeepAlive.stop();
    await _service.disconnect();
    _downgradeTradingPairMetadata();
    isConnected = _service.isConnected;
    isAuthenticated = _service.isAuthenticated;
    // Reset subscriptions and prices
    for (final tp in tradingPairs) {
      tp.isSubscribed = false;
      tp.bestBid = 0;
      tp.bestAsk = 0;
      tp.lastUpdate = null;
    }
    _clearAnnouncementState();
    notifyListeners();
  }

  Future<void> authenticate() {
    final future = _authenticate();
    _authenticationFuture = future;
    future.then<void>(
      (_) => _completeAuthentication(future),
      onError: (Object _, StackTrace __) => _completeAuthentication(future),
    );
    notifyListeners();
    return future;
  }

  void _completeAuthentication(Future<void> future) {
    if (identical(_authenticationFuture, future)) {
      _authenticationFuture = null;
      notifyListeners();
    }
  }

  Future<void> _authenticate() async {
    final operationGeneration = ++_authenticationOperationGeneration;
    final connectionGeneration = _connectionOperationGeneration;
    isAuthenticated = false;
    _clearPrivateTradingSessionState();
    statusMessage = 'Authenticating...';
    notifyListeners();
    final ok = await _service.authenticate(clientId, clientSecret);
    if (_disposed ||
        operationGeneration != _authenticationOperationGeneration ||
        connectionGeneration != _connectionOperationGeneration ||
        !isConnected ||
        !_service.isConnected) {
      return;
    }
    isAuthenticated = ok;
    if (ok) {
      _clearAnnouncementUnreadState(invalidateRequests: true);
      await _restoreAccountIdentity();
      await _persistCredentialsIfNeeded();
      if (operationGeneration != _authenticationOperationGeneration) return;
      await _subscribeUserChangesAll();
      if (operationGeneration != _authenticationOperationGeneration) return;
      // ignore: discarded_futures
      refreshAccountSummaries();
      _startAccountAutoRefresh();
      // ignore: discarded_futures
      refreshOpenOrders();
      _startOrdersAutoRefresh();
      // ignore: discarded_futures
    }
    notifyListeners();
  }

  Future<bool> resumeConnection() {
    if (!_connectionRequested) return Future.value(false);
    final pending = _resumeConnectionFuture;
    if (pending != null) return pending;
    final future = _resumeConnection();
    _resumeConnectionFuture = future;
    future.whenComplete(() {
      if (identical(_resumeConnectionFuture, future)) {
        _resumeConnectionFuture = null;
      }
    });
    return future;
  }

  Future<bool> _resumeConnection() async {
    final operationGeneration = _connectionOperationGeneration;
    statusMessage = 'Checking connection...';
    notifyListeners();
    try {
      final connected = await _service.ensureConnected();
      if (_disposed ||
          !_connectionRequested ||
          operationGeneration != _connectionOperationGeneration) {
        return false;
      }
      isConnected = connected;
      if (!connected) {
        _invalidateAuthenticationOperation();
        _clearTradingSessionState();
        _downgradeTradingPairMetadata();
      }
      if (connected) {
        statusMessage = 'Connected';
        if (androidBackgroundKeepAlive) {
          try {
            await MobileConnectionKeepAlive.start();
          } catch (e) {
            _onStatus('Android background keepalive failed: $e');
          }
        }
      } else {
        statusMessage = 'Connection recovery failed';
      }
      notifyListeners();
      return connected;
    } catch (e) {
      if (_disposed || operationGeneration != _connectionOperationGeneration) {
        return false;
      }
      isConnected = false;
      _invalidateAuthenticationOperation();
      _clearTradingSessionState();
      _downgradeTradingPairMetadata();
      statusMessage = 'Connection recovery failed: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> refreshAccountSummaries() async {
    if (!isAuthenticated) {
      accountSummariesError = 'Please authenticate first';
      notifyListeners();
      return;
    }
    if (loadingAccountSummaries) {
      return; // avoid overlapping loads
    }
    final generation = _accountStateGeneration;
    loadingAccountSummaries = true;
    accountSummariesError = null;
    notifyListeners();
    try {
      final res = await _service.getAccountSummaries(extended: true);
      if (!_isCurrentAccountState(generation)) return;
      if (res == null) {
        accountSummariesError = 'Account refresh failed; see logs';
        return;
      }
      accountSummaries = res;
      accountInfoFromCache = false;
      {
        unawaited(
          LocalCacheStore.saveIdentity(isTestnet, clientId, res).catchError((
            Object e,
          ) {
            _onStatus('Account cache save failed: $e');
          }),
        );
      }
      // Fire-and-forget compute account totals after summaries update
      // ignore: discarded_futures
      _refreshAccountTotals(generation);
    } catch (e) {
      if (_isCurrentAccountState(generation)) {
        accountSummariesError = 'Failed to load: $e';
      }
    } finally {
      if (_isCurrentAccountState(generation)) {
        loadingAccountSummaries = false;
        notifyListeners();
      }
    }
  }

  bool _isCurrentAccountState(int generation) =>
      !_disposed && isAuthenticated && generation == _accountStateGeneration;

  Future<void> _refreshAccountTotals([int? requestedGeneration]) async {
    final generation = requestedGeneration ?? _accountStateGeneration;
    final acc = accountSummaries;
    if (!_isCurrentAccountState(generation) || acc == null) {
      accountTotalUsd = null;
      accountTotalBtc = null;
      accountTotalCny = null;
      notifyListeners();
      return;
    }
    if (loadingAccountTotals) return;
    loadingAccountTotals = true;
    notifyListeners();
    try {
      final valuations = await Future.wait(
        acc.summaries.where((s) => s.hasValuationExposure).map((s) async {
          final rates = await Future.wait([
            _getUsdRateForCurrency(s.currency, generation: generation),
            _getBtcRateForCurrency(s.currency, generation: generation),
          ]);
          return (
            usd: rates[0] == null ? null : s.equity * rates[0]!,
            btc: rates[1] == null ? null : s.equity * rates[1]!,
          );
        }),
      );
      if (!_isCurrentAccountState(generation) ||
          !identical(accountSummaries, acc)) {
        return;
      }
      accountTotalUsd = valuations.every((v) => v.usd != null)
          ? valuations.fold<double>(0, (sum, v) => sum + v.usd!)
          : null;
      accountTotalBtc = valuations.every((v) => v.btc != null)
          ? valuations.fold<double>(0, (sum, v) => sum + v.btc!)
          : null;
    } catch (_) {
      // keep previous value if any
    } finally {
      if (_isCurrentAccountState(generation)) {
        loadingAccountTotals = false;
        notifyListeners();
      }
    }
    // CNY 走外部法币 API 换算，独立异步刷新，避免 Frankfurter 慢/超时阻塞
    // Total in USD/BTC 的展示。
    if (_isCurrentAccountState(generation) && accountTotalUsd != null) {
      unawaited(_refreshAccountCnyTotal(generation, accountTotalUsd!));
    }
  }

  /// 独立刷新 Total in CNY（= Total in USD × USD/CNY 官方参考价）。
  Future<void> _refreshAccountCnyTotal(int generation, double usd) async {
    if (!_isCurrentAccountState(generation)) {
      accountTotalCny = null;
      notifyListeners();
      return;
    }
    if (loadingAccountCny) return;
    loadingAccountCny = true;
    notifyListeners();
    try {
      final usdCny = await _getUsdCnyRate();
      // stale completion 校验：await 期间若已登出或 USD 总额被新一轮刷新改写，
      // 丢弃本轮结果，避免把旧 USD 对应的 CNY 写回（下一轮刷新会自愈）。
      if (!_isCurrentAccountState(generation) || accountTotalUsd != usd) return;
      accountTotalCny = (usdCny != null && usdCny > 0) ? usd * usdCny : null;
    } catch (_) {
      // 保留上一次 CNY 值
    } finally {
      if (_isCurrentAccountState(generation)) {
        loadingAccountCny = false;
        notifyListeners();
      }
    }
  }

  bool _isCurrentRateGeneration(int generation) =>
      !_disposed && generation == _accountStateGeneration;

  Future<double?> _getUsdRateForCurrency(String currency, {int? generation}) {
    final current = generation ?? _accountStateGeneration;
    final key = '$current:${currency.toUpperCase()}';
    final pending = _usdRateRequests[key];
    if (pending != null) return pending;
    late final Future<double?> request;
    request = _loadUsdRateForCurrency(currency, generation: current)
        .whenComplete(() {
          if (identical(_usdRateRequests[key], request)) {
            _usdRateRequests.remove(key);
          }
        });
    _usdRateRequests[key] = request;
    return request;
  }

  Future<double?> _loadUsdRateForCurrency(
    String currency, {
    int? generation,
  }) async {
    final requestGeneration = generation ?? _accountStateGeneration;
    final c = currency.toUpperCase();
    if (c == 'USD' || c == 'USDC' || c == 'USDT' || c == 'USDE') return 1.0;
    final cached = _usdRates[c];
    if (cached != null && !cached.isExpired(_usdRateTtl)) return cached.rate;

    // Try direct index e.g., btc_usd, eth_usd, etc.
    double? rate = await _service.getIndexPrice(base: c, quote: 'USD');
    if (!_isCurrentRateGeneration(requestGeneration)) return null;
    // Fallbacks: common aliases (e.g., EURR -> EUR)
    if ((rate == null || rate <= 0) && c == 'EURR') {
      rate = await _service.getIndexPrice(base: 'EUR', quote: 'USD');
      if (!_isCurrentRateGeneration(requestGeneration)) return null;
    }
    if (rate != null && rate > 0) {
      _usdRates[c] = _RateCache(rate, DateTime.now());
    }
    return rate;
  }

  Future<double?> _getBtcRateForCurrency(
    String currency, {
    int? generation,
  }) async {
    final requestGeneration = generation ?? _accountStateGeneration;
    final c = currency.toUpperCase();
    if (c == 'BTC') return 1.0;

    final cached = _btcRates[c];
    if (cached != null && !cached.isExpired(_usdRateTtl)) {
      return cached.rate;
    }

    final requestKey = '$requestGeneration:$c';
    final inFlight = _btcRateRequests[requestKey];
    if (inFlight != null) return inFlight;

    final request = _loadBtcRateForCurrency(c, requestGeneration);
    _btcRateRequests[requestKey] = request;
    try {
      return await request;
    } finally {
      if (identical(_btcRateRequests[requestKey], request)) {
        _btcRateRequests.remove(requestKey);
      }
    }
  }

  Future<double?> _loadBtcRateForCurrency(
    String currency,
    int generation,
  ) async {
    final c = currency.toUpperCase();

    final btcUsd = await _getUsdRateForCurrency('BTC', generation: generation);
    if (!_isCurrentRateGeneration(generation)) return null;
    if (btcUsd == null || btcUsd <= 0) return null;

    if (c == 'USD' || c == 'USDC' || c == 'USDT' || c == 'USDE') {
      final rate = 1.0 / btcUsd;
      _btcRates[c] = _RateCache(rate, DateTime.now());
      return rate;
    }

    double? rate = await _service.getIndexPrice(base: c, quote: 'BTC');
    if (!_isCurrentRateGeneration(generation)) return null;
    if ((rate == null || rate <= 0) && c == 'EURR') {
      rate = await _service.getIndexPrice(base: 'EUR', quote: 'BTC');
      if (!_isCurrentRateGeneration(generation)) return null;
    }
    if (rate != null && rate > 0) {
      _btcRates[c] = _RateCache(rate, DateTime.now());
      return rate;
    }

    final usdRate = await _getUsdRateForCurrency(c, generation: generation);
    if (!_isCurrentRateGeneration(generation)) return null;
    if (usdRate == null || usdRate <= 0) return null;
    rate = usdRate / btcUsd;
    _btcRates[c] = _RateCache(rate, DateTime.now());
    return rate;
  }

  /// 获取 USD→CNY 参考汇率（Frankfurter v2 官方中间价）。
  ///
  /// 策略：冷启动先读持久化值；内存缓存 6h（按 fetchedAt 判定）内直接返回；
  /// 过期则请求 Frankfurter，成功则刷新内存 + 持久化（持久化失败不影响本轮展示）；
  /// 请求失败则降级使用旧值并标记 stale；无任何值时返回 null。
  Future<double?> _getUsdCnyRate() async {
    if (!_usdCnyLoadedFromDisk) {
      _usdCnyLoadedFromDisk = true;
      final saved = await SettingsStore.loadUsdCnyRate();
      if (saved != null) {
        _usdCnyRate = saved.rate;
        _usdCnySourceDate = saved.sourceDate;
        _usdCnyFetchedAt = saved.fetchedAt;
      }
    }
    final fetchedAt = _usdCnyFetchedAt;
    if (_usdCnyRate != null &&
        fetchedAt != null &&
        DateTime.now().difference(fetchedAt) <= _usdCnyTtl) {
      _usdCnyStale = false;
      return _usdCnyRate;
    }
    final fresh = await _fiatRateService.getUsdCnyRate();
    if (fresh != null && fresh.rate > 0) {
      _usdCnyRate = fresh.rate;
      _usdCnySourceDate = fresh.sourceDate;
      _usdCnyFetchedAt = DateTime.now();
      _usdCnyStale = false;
      try {
        await SettingsStore.saveUsdCnyRate(
          fresh.rate,
          fresh.sourceDate,
          _usdCnyFetchedAt!,
        );
      } catch (_) {
        // 持久化失败不影响本轮内存展示
      }
      return fresh.rate;
    }
    // 请求失败：降级使用旧值（可能已过期），标记 stale
    if (_usdCnyRate != null) {
      _usdCnyStale = true;
      return _usdCnyRate;
    }
    return null;
  }

  Future<void> loadAddressBook({required String currency}) async {
    if (!isAuthenticated) {
      addressBookError = '请先完成认证';
      notifyListeners();
      return;
    }
    final normalizedCurrency = currency.trim().toUpperCase();
    if (normalizedCurrency.isEmpty) {
      addressBookError = '提款币种不能为空';
      notifyListeners();
      return;
    }
    final authenticationGeneration = _authenticationOperationGeneration;
    final requestGeneration = ++_addressBookRequestGeneration;
    if (addressBookCurrency != normalizedCurrency) {
      addressBook.clear();
      addressBookCurrency = null;
    }
    loadingAddressBook = true;
    addressBookError = null;
    notifyListeners();
    try {
      final list = await _service.getAddressBook(currency: normalizedCurrency);
      if (requestGeneration != _addressBookRequestGeneration ||
          authenticationGeneration != _authenticationOperationGeneration ||
          !isAuthenticated) {
        return;
      }
      addressBook
        ..clear()
        ..addAll(
          list.where(
            (entry) =>
                entry.currency.trim().toUpperCase() == normalizedCurrency,
          ),
        );
      addressBookCurrency = normalizedCurrency;
    } catch (e) {
      if (requestGeneration == _addressBookRequestGeneration &&
          authenticationGeneration == _authenticationOperationGeneration &&
          isAuthenticated) {
        addressBookError = '获取地址簿失败: $e';
      }
    } finally {
      if (requestGeneration == _addressBookRequestGeneration &&
          authenticationGeneration == _authenticationOperationGeneration) {
        loadingAddressBook = false;
        notifyListeners();
      }
    }
  }

  List<AddressBookEntry> addressBookForCurrency(String currency) {
    final normalizedCurrency = currency.trim().toUpperCase();
    if (addressBookCurrency != normalizedCurrency) return const [];
    return addressBook
        .where(
          (entry) => entry.currency.trim().toUpperCase() == normalizedCurrency,
        )
        .toList(growable: false);
  }

  Future<void> loadWithdrawals({
    required String currency,
    bool loadMore = false,
  }) async {
    if (!isAuthenticated) {
      withdrawalsError = '请先完成认证';
      notifyListeners();
      return;
    }
    final normalizedCurrency = currency.trim().toUpperCase();
    if (normalizedCurrency.isEmpty) {
      withdrawalsError = '提款币种不能为空';
      notifyListeners();
      return;
    }
    final append = loadMore && withdrawalsCurrency == normalizedCurrency;
    if (loadMore && (loadingWithdrawals || !append || !hasMoreWithdrawals)) {
      return;
    }
    final cacheKey = clientId;
    final paper = isTestnet;
    final authenticationGeneration = _authenticationOperationGeneration;
    final requestGeneration = ++_withdrawalRequestGeneration;
    final offset = append ? _withdrawalNextOffset : 0;
    if (!append && withdrawalsCurrency != normalizedCurrency) {
      withdrawals.clear();
      withdrawalsCurrency = normalizedCurrency;
      withdrawalsFromCache = false;
      hasMoreWithdrawals = false;
      _withdrawalNextOffset = 0;
    }
    loadingWithdrawals = true;
    withdrawalsError = null;
    notifyListeners();
    try {
      if (!append && withdrawals.isEmpty) {
        try {
          final cached = await LocalCacheStore.loadWithdrawals(
            paper,
            cacheKey,
            normalizedCurrency,
            offset,
          );
          if (requestGeneration != _withdrawalRequestGeneration ||
              authenticationGeneration != _authenticationOperationGeneration ||
              !isAuthenticated) {
            return;
          }
          if (cached != null) {
            withdrawals.addAll(cached.value);
            withdrawalsFromCache = true;
            notifyListeners();
          }
        } catch (e) {
          _onStatus('Withdrawal cache load failed: $e');
        }
      }
      final list = await _service.getWithdrawals(
        currency: normalizedCurrency,
        count: _withdrawalPageSize,
        offset: offset,
      );
      if (requestGeneration != _withdrawalRequestGeneration ||
          authenticationGeneration != _authenticationOperationGeneration ||
          !isAuthenticated) {
        return;
      }
      withdrawalsFromCache = false;
      unawaited(
        LocalCacheStore.saveWithdrawals(
          paper,
          cacheKey,
          normalizedCurrency,
          offset,
          list,
        ).catchError((Object e) {
          _onStatus('Withdrawal cache save failed: $e');
        }),
      );
      if (append) {
        final loadedIds = withdrawals
            .map((withdrawal) => withdrawal.id)
            .toSet();
        withdrawals.addAll(
          list.where((withdrawal) => loadedIds.add(withdrawal.id)),
        );
        _withdrawalNextOffset += list.length;
      } else {
        withdrawals
          ..clear()
          ..addAll(list);
        withdrawalsCurrency = normalizedCurrency;
        _withdrawalNextOffset = list.length;
      }
      hasMoreWithdrawals = list.length == _withdrawalPageSize;
    } catch (e) {
      if (requestGeneration == _withdrawalRequestGeneration &&
          authenticationGeneration == _authenticationOperationGeneration &&
          isAuthenticated) {
        withdrawalsError = '获取提款历史失败: $e';
      }
    } finally {
      if (requestGeneration == _withdrawalRequestGeneration &&
          authenticationGeneration == _authenticationOperationGeneration) {
        loadingWithdrawals = false;
        notifyListeners();
      }
    }
  }

  List<Announcement> get unreadAnnouncements => announcements
      .where((announcement) => _unreadAnnouncementIds.contains(announcement.id))
      .toList(growable: false);

  int get unreadAnnouncementCount => _unreadAnnouncementIds.length;

  bool isAnnouncementUnread(int announcementId) =>
      _unreadAnnouncementIds.contains(announcementId);

  /// Refresh public history, then derive unread state when authenticated.
  Future<void> refreshAnnouncements() async {
    if (!isConnected || loadingAnnouncements) return;
    final generation = _announcementStateGeneration;
    loadingAnnouncements = true;
    announcementsError = null;
    notifyListeners();

    try {
      final publicAnnouncements = await _service.getAnnouncements();
      if (generation != _announcementStateGeneration || !isConnected) return;

      _replaceAnnouncements(publicAnnouncements, _unreadAnnouncementIds);
      if (isAuthenticated) {
        try {
          final unread = await _service.getNewAnnouncements();
          if (generation != _announcementStateGeneration ||
              !isConnected ||
              !isAuthenticated) {
            return;
          }
          _applyUnreadIds(unread.map((announcement) => announcement.id));
        } catch (e) {
          announcementsError = '获取未读公告失败: $e';
        }
      } else {
        _applyUnreadIds(const <int>[]);
      }
    } catch (e) {
      if (generation == _announcementStateGeneration) {
        announcementsError = '获取公告失败: $e';
      }
    } finally {
      if (generation == _announcementStateGeneration) {
        loadingAnnouncements = false;
        notifyListeners();
      }
    }
  }

  /// Backwards-compatible refresh entry point used by older callers.
  Future<void> refreshUnreadAnnouncements() => refreshAnnouncements();

  Future<void> _refreshAnnouncementUnreadState() async {
    if (!isAuthenticated) {
      _applyUnreadIds(const <int>[]);
      notifyListeners();
      return;
    }
    final generation = _announcementStateGeneration;
    try {
      final unread = await _service.getNewAnnouncements();
      if (generation != _announcementStateGeneration || !isAuthenticated) {
        return;
      }
      _applyUnreadIds(unread.map((announcement) => announcement.id));
      announcementsError = null;
      notifyListeners();
    } catch (e) {
      if (generation == _announcementStateGeneration) {
        announcementsError = '获取未读公告失败: $e';
        notifyListeners();
      }
    }
  }

  /// Mark one item as read while retaining it in public history.
  Future<bool> markAnnouncementAsRead(int announcementId) async {
    if (!isAuthenticated) {
      announcementsError = '请先完成认证';
      notifyListeners();
      return false;
    }
    if (markingAnnouncementIds.contains(announcementId)) return false;
    markingAnnouncementIds.add(announcementId);
    notifyListeners();
    try {
      final ok = await _service.setAnnouncementAsRead(announcementId);
      if (ok) {
        _unreadAnnouncementIds.remove(announcementId);
        _syncAnnouncementUnreadFlags();
      } else {
        announcementsError = '标记已读失败';
      }
      return ok;
    } catch (e) {
      announcementsError = '标记已读失败: $e';
      return false;
    } finally {
      markingAnnouncementIds.remove(announcementId);
      notifyListeners();
    }
  }

  /// 全部标为已读
  Future<void> markAllAnnouncementsAsRead() async {
    if (!isAuthenticated || _unreadAnnouncementIds.isEmpty) return;
    final ids = _unreadAnnouncementIds.toList();
    for (final id in ids) {
      await markAnnouncementAsRead(id);
    }
  }

  void _replaceAnnouncements(
    Iterable<Announcement> values,
    Set<int> unreadIds,
  ) {
    announcements
      ..clear()
      ..addAll(
        values.map(
          (announcement) => announcement.copyWith(
            unread: unreadIds.contains(announcement.id),
          ),
        ),
      );
    announcements.sort(
      (a, b) => b.publicationTimestamp.compareTo(a.publicationTimestamp),
    );
  }

  void _applyUnreadIds(Iterable<int> ids) {
    _unreadAnnouncementIds
      ..clear()
      ..addAll(ids.where((id) => id != 0));
    _syncAnnouncementUnreadFlags();
  }

  void _syncAnnouncementUnreadFlags() {
    for (var i = 0; i < announcements.length; i++) {
      final announcement = announcements[i];
      announcements[i] = announcement.copyWith(
        unread: _unreadAnnouncementIds.contains(announcement.id),
      );
    }
  }

  void _clearAnnouncementUnreadState({bool invalidateRequests = false}) {
    if (invalidateRequests) {
      _announcementStateGeneration++;
      loadingAnnouncements = false;
    }
    _unreadAnnouncementIds.clear();
    markingAnnouncementIds.clear();
    _syncAnnouncementUnreadFlags();
  }

  void _clearAnnouncementState() {
    _announcementStateGeneration++;
    announcements.clear();
    _unreadAnnouncementIds.clear();
    markingAnnouncementIds.clear();
    announcementsError = null;
    loadingAnnouncements = false;
  }

  void _onAnnouncementEvent(AnnouncementEvent event) {
    if (!isConnected) return;
    if (event.isDeleted) {
      announcements.removeWhere((announcement) => announcement.id == event.id);
      _unreadAnnouncementIds.remove(event.id);
      notifyListeners();
      return;
    }

    final incoming = event.announcement;
    if (!event.isNew || incoming == null) return;
    final index = announcements.indexWhere(
      (announcement) => announcement.id == incoming.id,
    );
    final value = incoming.copyWith(
      unread: _unreadAnnouncementIds.contains(incoming.id),
    );
    if (index >= 0) {
      announcements[index] = value;
    } else {
      announcements.add(value);
    }
    announcements.sort(
      (a, b) => b.publicationTimestamp.compareTo(a.publicationTimestamp),
    );
    notifyListeners();
    if (isAuthenticated) {
      // The private endpoint remains the source of truth for unread IDs.
      // ignore: discarded_futures
      _refreshAnnouncementUnreadState();
    }
  }

  Future<bool> withdraw({
    required String currency,
    required String address,
    required double amount,
    required String method,
    String? destinationTag,
  }) async {
    final ok = await _service.withdraw(
      currency: currency,
      address: address,
      amount: amount,
      method: method,
      destinationTag: destinationTag,
    );
    if (ok) {
      // Optionally refresh account summaries after a short delay
      // ignore: discarded_futures
      refreshAccountSummaries();
      // ignore: discarded_futures
      loadWithdrawals(currency: currency);
    }
    return ok;
  }

  void _startAccountAutoRefresh() {
    _accountRefreshTimer?.cancel();
    if (!isAuthenticated) return;
    _accountRefreshTimer = Timer.periodic(
      _accountAutoRefreshInterval,
      (_) => refreshAccountSummaries(),
    );
  }

  void _stopAccountAutoRefresh() {
    _accountRefreshTimer?.cancel();
    _accountRefreshTimer = null;
  }

  void _startOrdersAutoRefresh() {
    _ordersRefreshTimer?.cancel();
    if (!isAuthenticated) return;
    _ordersRefreshTimer = Timer.periodic(
      _ordersAutoRefreshInterval,
      (_) => refreshOpenOrders(),
    );
  }

  void _stopOrdersAutoRefresh() {
    _ordersRefreshTimer?.cancel();
    _ordersRefreshTimer = null;
  }

  Future<void> setHideZeroCurrencies(bool v) async {
    hideZeroCurrencies = v;
    notifyListeners();
    await SettingsStore.saveHideZeroCurrencies(v);
  }

  Future<void> subscribeToInstrument(TradingPairVM tp) async {
    final symbol = _normalizeSymbol(tp.symbol);
    if (symbol.isEmpty) return;
    _setManualSubscriptionDesired(symbol, true);
    await _ensureInstrumentSubscribed(symbol, addToDesired: false);
  }

  Future<void> unsubscribeFromInstrument(TradingPairVM tp) async {
    await _unsubscribeSymbol(tp.symbol);
  }

  Future<void> _unsubscribeSymbol(String rawSymbol) async {
    final symbol = _normalizeSymbol(rawSymbol);
    if (symbol.isEmpty) return;
    _setManualSubscriptionDesired(symbol, false);
    if (_wantsSubscription(symbol)) return;
    await _unsubscribeCurrentSymbol(symbol);
  }

  Future<void> _unsubscribeCurrentSymbol(String symbol) async {
    await _runSessionSubscriptionReconcile(symbol);
  }

  Future<void> placeOrder(
    TradingPairVM tp,
    String direction,
    double amount, {
    double? customPrice,
    bool enableChasing = false,
    bool postOnly = true,
    bool reduceOnly = false,
  }) async {
    await _service.placeLimitOrder(
      tp.symbol,
      direction,
      amount,
      customPrice: customPrice,
      enableChasing: enableChasing,
      postOnly: postOnly,
      reduceOnly: reduceOnly,
      leverage: tp.leverage,
    );
  }

  Future<void> placeMarketOrder(
    TradingPairVM tp,
    String direction,
    double amount, {
    bool reduceOnly = false,
  }) async {
    await _service.placeMarketOrder(
      tp.symbol,
      direction,
      amount,
      leverage: tp.leverage,
      reduceOnly: reduceOnly,
    );
  }

  Future<void> modifyOrder(OrderVM o) async {
    await modifyOrderValues(
      o,
      newPrice: o.editablePrice,
      newAmount: o.editableAmount,
    );
  }

  Future<void> modifyOrderValues(
    OrderVM o, {
    required double newPrice,
    double? newAmount,
  }) async {
    o.isModifying = true;
    o.editablePrice = newPrice;
    if (newAmount != null) o.editableAmount = newAmount;
    notifyListeners();
    try {
      final updated = await _service.modifyOrder(
        o.order.orderId,
        newPrice,
        newAmount: newAmount,
      );
      if (updated != null) {
        o.order = updated;
      }
    } finally {
      o.isModifying = false;
      notifyListeners();
    }
  }

  Future<void> cancelOrder(OrderVM o) async {
    await _service.cancelOrder(o.order.orderId);
  }

  // Per-order chasing helpers
  bool isOrderChased(OrderVM o) => _service.isChasing(o.order.orderId);

  void setOrderChasing(OrderVM o, bool enable) {
    _service.setChasingForOrder(o.order.orderId, enable);
    notifyListeners();
  }

  Future<Order?> increasePosition(
    PositionVM position, {
    required double amount,
    bool market = false,
    double? price,
    bool postOnly = true,
    bool enableChasing = false,
    int leverage = 1,
  }) => _service.increasePosition(
    position.position.instrumentName,
    expectedDirection: position.position.direction,
    amount: amount,
    market: market,
    price: price,
    postOnly: postOnly,
    enableChasing: enableChasing,
    leverage: leverage,
  );

  Future<void> closePosition(
    PositionVM p, {
    double? percentage,
    double? amount,
    double? nativeApiAmount,
    bool isQuoteCurrency = false,
    double? customPrice,
  }) async {
    await _service.closePosition(
      p.position.instrumentName,
      percentage: percentage,
      amount: amount,
      nativeApiAmount: nativeApiAmount,
      isQuoteCurrency: isQuoteCurrency,
      customPrice: customPrice,
    );
  }

  Future<void> closePositionMarket(
    PositionVM p, {
    double? percentage,
    double? amount,
    double? nativeApiAmount,
    bool isQuoteCurrency = false,
  }) async {
    await _service.closePositionMarket(
      p.position.instrumentName,
      percentage: percentage,
      amount: amount,
      nativeApiAmount: nativeApiAmount,
      isQuoteCurrency: isQuoteCurrency,
    );
  }

  Future<void> closeAllPositions({
    double? percentage,
    bool market = false,
  }) async {
    // Work on a snapshot to avoid concurrent modification as positions update
    final list = positions.map((e) => e).toList();
    final failures = <String>[];
    for (final p in list) {
      try {
        if (market) {
          await _service.closePositionMarket(
            p.position.instrumentName,
            percentage: percentage,
          );
        } else {
          await _service.closePosition(
            p.position.instrumentName,
            percentage: percentage,
          );
        }
      } catch (e) {
        failures.add("${p.position.instrumentName}: $e");
      }
    }
    if (failures.isNotEmpty) {
      throw StateError("Close all failed: ${failures.join('; ')}");
    }
  }

  Future<void> reversePosition(
    PositionVM p, {
    double? percentage,
    bool market = false,
  }) async {
    await _service.reversePosition(
      p.position.instrumentName,
      percentage: percentage,
      market: market,
    );
  }

  Future<void> loadTradeHistory(
    String instrument,
    DateTime from,
    DateTime to,
  ) async {
    final requestGeneration = ++_tradeHistoryRequestGeneration;
    final list = await _service.getTradeHistory(instrument, from, to);
    if (_disposed || requestGeneration != _tradeHistoryRequestGeneration) {
      return;
    }
    final normalizedInstrument = _normalizeSymbol(instrument);
    _tradeHistoryRequestedInstrument = normalizedInstrument;
    final metadata = _service.getTradingPairBySymbol(
      normalizedInstrument,
      customTradingPairs,
    );
    _tradeHistoryInstrument =
        metadata != null &&
            metadata.isVerified &&
            _normalizeSymbol(metadata.symbol) == normalizedInstrument
        ? metadata
        : null;
    tradeHistory
      ..clear()
      ..addAll(list);

    tradeHistoryGroups.clear();
    // group by local day
    final map = <DateTime, List<TradeHistoryEntryVM>>{};
    for (var sourceOrder = 0; sourceOrder < list.length; sourceOrder++) {
      final t = list[sourceOrder];
      final dt = DateTime.fromMillisecondsSinceEpoch(t.timestamp).toLocal();
      final day = DateTime(dt.year, dt.month, dt.day);
      map.putIfAbsent(day, () => []);
      map[day]!.add(TradeHistoryEntryVM(t, sourceOrder: sourceOrder));
    }
    final days = map.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final d in days) {
      final entries = map[d]!..sort((a, b) => compareTradeHistoryEntries(b, a));
      tradeHistoryGroups.add(
        TradeHistoryDayGroupVM(d, _buildTradeHistoryRowsForDay(entries)),
      );
    }
    // Recompute positions upon loading
    _computeTradeHistoryPositions();
    _currentTradeHistoryPositionIndex = null;
    _refreshTradeHistorySelectionSummary();
    notifyListeners();
  }

  void setAllTradeHistorySelection(bool selected) {
    for (final g in tradeHistoryGroups) {
      g.setAll(selected);
    }
    _refreshTradeHistorySelectionSummary();
    notifyListeners();
  }

  void invertAllTradeHistorySelection() {
    for (final g in tradeHistoryGroups) {
      g.invert();
    }
    _refreshTradeHistorySelectionSummary();
    notifyListeners();
  }

  void onGroupSelectionChanged(TradeHistoryDayGroupVM g, bool? value) {
    if (value == true) {
      g.setAll(true);
    } else if (value == false) {
      g.setAll(false);
    } else {
      g.invert();
    }
    _refreshTradeHistorySelectionSummary();
    notifyListeners();
  }

  void onEntrySelectionChanged(TradeHistoryEntryVM e, bool selected) {
    e.isSelected = selected;
    _refreshTradeHistorySelectionSummary();
    notifyListeners();
  }

  void onTradeHistoryRowSelectionChanged(TradeHistoryRowVM row, bool? value) {
    if (row.triState == null) {
      row.setAll(true);
    } else {
      row.setAll(value ?? false);
    }
    _refreshTradeHistorySelectionSummary();
    notifyListeners();
  }

  void toggleTradeHistoryRowExpanded(TradeHistoryRowVM row) {
    if (!row.isMerged) return;
    row.isExpanded = !row.isExpanded;
    notifyListeners();
  }

  List<TradeHistoryRowVM> _buildTradeHistoryRowsForDay(
    List<TradeHistoryEntryVM> entries,
  ) {
    final buckets = <String, List<TradeHistoryEntryVM>>{};
    final ungrouped = <TradeHistoryEntryVM>[];

    for (final entry in entries) {
      final orderId = entry.trade.orderId.trim();
      if (orderId.isEmpty) {
        ungrouped.add(entry);
        continue;
      }
      final key = '${entry.trade.instrumentName}\u0000$orderId';
      buckets.putIfAbsent(key, () => []).add(entry);
    }

    final rows = <TradeHistoryRowVM>[
      for (final entry in ungrouped) TradeHistoryRowVM([entry]),
      for (final group in buckets.values)
        if (group.length >= 2)
          TradeHistoryRowVM(group)
        else
          TradeHistoryRowVM(group),
    ];
    rows.sort(
      (a, b) => compareTradeHistoryEntries(b.primaryEntry, a.primaryEntry),
    );
    return rows;
  }

  String get tradeHistorySelectionSummary {
    final avgBuy = tradeHistorySelectedAverageBuyPrice;
    final avgSell = tradeHistorySelectedAverageSellPrice;
    final parts = <String>[
      'Selected: $tradeHistorySelectedCount',
      if (tradeHistorySelectedExcludedInvalidCount > 0)
        'Excluded invalid: $tradeHistorySelectedExcludedInvalidCount',
      'Buy Amt: ${tradeHistorySelectedBuyAmount.toStringAsFixed(4)}',
      'Sell Amt: ${tradeHistorySelectedSellAmount.toStringAsFixed(4)}',
      'Net Amt: ${(tradeHistorySelectedBuyAmount - tradeHistorySelectedSellAmount).toStringAsFixed(4)}',
      'Buy Val: ${tradeHistorySelectedBuyValue.toStringAsFixed(2)}',
      'Sell Val: ${tradeHistorySelectedSellValue.toStringAsFixed(2)}',
      'Avg(B): ${avgBuy != null ? avgBuy.toStringAsFixed(2) : '-'}',
      'Avg(S): ${avgSell != null ? avgSell.toStringAsFixed(2) : '-'}',
    ];
    return parts.join('  |  ');
  }

  void _refreshTradeHistorySelectionSummary() {
    final selected = tradeHistoryGroups
        .expand((g) => g.leafEntries.where((t) => t.isSelected))
        .toList();
    final pair = _tradeHistoryInstrument;
    final hasVerifiedContext = pair != null && pair.isVerified;
    final structurallyValid = selected
        .where(isTradeHistoryEntryStructurallyValid)
        .toList(growable: false);
    final hasCompletePnlCoverage =
        hasVerifiedContext &&
        structurallyValid.every(
          (entry) => _isTradeHistoryEntryPnlEligible(entry, pair),
        );
    final pnlEntries = hasCompletePnlCoverage
        ? structurallyValid
        : const <TradeHistoryEntryVM>[];
    tradeHistorySelectedCount = structurallyValid.length;
    tradeHistorySelectedExcludedInvalidCount =
        selected.length - structurallyValid.length;
    tradeHistorySelectionUnavailableReason = structurallyValid.isEmpty
        ? null
        : !hasVerifiedContext
        ? 'Verified instrument metadata unavailable'
        : !hasCompletePnlCoverage
        ? 'Selected trade instrument does not match verified metadata'
        : null;
    final verifiedPair = hasVerifiedContext ? pair : null;

    var buyAmount = Decimal.zero, sellAmount = Decimal.zero;
    var buyQuote = Decimal.zero, sellQuote = Decimal.zero;
    var buyPriceDenominator = Decimal.zero;
    var sellPriceDenominator = Decimal.zero;
    for (final e in pnlEntries) {
      final amt = e.trade.amount;
      final px = e.trade.price;
      final dir = e.trade.direction.trim().toLowerCase();
      final amount = dFrom(amt);
      final quote = tradeQuoteNotional(pair: verifiedPair!, trade: e.trade);
      if (dir == 'buy') {
        buyAmount += amount;
        buyQuote += quote;
        buyPriceDenominator += verifiedPair.isInverseFuture
            ? (amount / dFrom(px)).toDecimal(scaleOnInfinitePrecision: 24)
            : amount;
      } else if (dir == 'sell') {
        sellAmount += amount;
        sellQuote += quote;
        sellPriceDenominator += verifiedPair.isInverseFuture
            ? (amount / dFrom(px)).toDecimal(scaleOnInfinitePrecision: 24)
            : amount;
      }
    }
    tradeHistorySelectedBuyAmount = hasCompletePnlCoverage
        ? dToDouble(buyAmount)
        : 0;
    tradeHistorySelectedSellAmount = hasCompletePnlCoverage
        ? dToDouble(sellAmount)
        : 0;
    tradeHistorySelectedBuyValue = hasCompletePnlCoverage
        ? dToDouble(buyQuote)
        : 0;
    tradeHistorySelectedSellValue = hasCompletePnlCoverage
        ? dToDouble(sellQuote)
        : 0;
    tradeHistorySelectedAverageBuyPrice =
        hasCompletePnlCoverage &&
            buyAmount > Decimal.zero &&
            buyPriceDenominator > Decimal.zero
        ? dToDouble(
            (verifiedPair!.isInverseFuture
                    ? buyAmount / buyPriceDenominator
                    : buyQuote / buyAmount)
                .toDecimal(scaleOnInfinitePrecision: 24),
          )
        : null;
    tradeHistorySelectedAverageSellPrice =
        hasCompletePnlCoverage &&
            sellAmount > Decimal.zero &&
            sellPriceDenominator > Decimal.zero
        ? dToDouble(
            (verifiedPair!.isInverseFuture
                    ? sellAmount / sellPriceDenominator
                    : sellQuote / sellAmount)
                .toDecimal(scaleOnInfinitePrecision: 24),
          )
        : null;
    tradeHistorySelectedAmountCurrency = hasCompletePnlCoverage
        ? verifiedPair!.apiAmountCurrency
        : null;
    tradeHistorySelectedQuoteCurrency = hasCompletePnlCoverage
        ? verifiedPair!.quoteCurrency
        : null;
    tradeHistorySelectedSettlementCurrency = hasCompletePnlCoverage
        ? (verifiedPair!.settlementCurrency.isNotEmpty
              ? verifiedPair.settlementCurrency
              : verifiedPair.quoteCurrency)
        : null;
    final feeAmounts = summarizeTradeHistoryFees(
      structurallyValid.map((e) => e.trade),
    );
    final feeTotal = structurallyValid.fold<double>(
      0,
      (sum, entry) => entry.trade.fee.isFinite ? sum + entry.trade.fee : sum,
    );
    tradeHistorySelectedFeeTotal = feeAmounts.length == 1
        ? feeAmounts.first.amount
        : feeTotal;
    tradeHistorySelectedFeeCurrency = feeAmounts.length == 1
        ? feeAmounts.first.currency
        : null;
    tradeHistorySelectedFeeSummary = formatTradeHistoryFeeAmounts(feeAmounts);

    final pnl = hasCompletePnlCoverage
        ? _matchSelectedTradeHistoryLots(pnlEntries, verifiedPair!)
        : null;
    tradeHistorySelectedMatchedAmount = pnl == null
        ? 0
        : dToDouble(pnl.matchedAmount);
    tradeHistorySelectedOpenAmount = pnl == null
        ? 0
        : dToDouble(pnl.openAmount);
    tradeHistorySelectedRealizedPnL =
        pnl != null && pnl.matchedAmount > Decimal.zero
        ? dToDouble(pnl.realizedPnl)
        : null;
    tradeHistorySelectedRealizedPnlQuoteEquivalent = null;
    if (pair != null &&
        pair.isInverseFuture &&
        tradeHistorySelectedRealizedPnL != null) {
      final latestSelectedPrice = pnlEntries
          .fold<TradeHistoryEntryVM?>(
            null,
            (latest, entry) =>
                latest == null || compareTradeHistoryEntries(entry, latest) > 0
                ? entry
                : latest,
          )
          ?.trade
          .price;
      final referencePrice =
          _latestMarkPrice[_normalizeSymbol(pair.symbol)] ??
          latestSelectedPrice;
      if (referencePrice != null &&
          referencePrice.isFinite &&
          referencePrice > 0) {
        tradeHistorySelectedRealizedPnlQuoteEquivalent = dToDouble(
          pnl!.realizedPnl * dFrom(referencePrice),
        );
      }
    }

    // update global tri-state
    final totalTrades = tradeHistoryGroups.fold<int>(
      0,
      (a, g) => a + g.leafEntries.length,
    );
    final selectedTrades = selected.length;
    if (totalTrades == 0) {
      isAllTradeHistorySelected = false;
    } else if (selectedTrades == 0) {
      isAllTradeHistorySelected = false;
    } else if (selectedTrades == totalTrades) {
      isAllTradeHistorySelected = true;
    } else {
      isAllTradeHistorySelected = null;
    }
  }

  // ---- Trade History Position Grouping & Navigation ----

  int get tradeHistoryPositionCount => _tradeHistoryPositions.length;
  int? get currentTradeHistoryPositionIndex =>
      _currentTradeHistoryPositionIndex;

  List<TradeHistoryEntryVM> _chronologicalTradeHistoryEntries({
    bool pnlEligibleOnly = false,
  }) {
    final entries = tradeHistoryGroups
        .expand((group) => group.leafEntries)
        .where(
          (entry) =>
              !pnlEligibleOnly ||
              _isTradeHistoryEntryPnlEligible(entry, _tradeHistoryInstrument),
        )
        .toList();
    entries.sort(compareTradeHistoryEntries);
    return entries;
  }

  void _computeTradeHistoryPositions() {
    _tradeHistoryPositions.clear();
    _currentTradeHistoryPositionIndex = null;
    final flat = _chronologicalTradeHistoryEntries(pnlEligibleOnly: true);
    if (flat.isEmpty) return;

    final pair = _tradeHistoryInstrument;
    if (pair == null) return;

    int start = 0;
    while (start < flat.length) {
      var netApiAmount = Decimal.zero;
      bool hasBuy = false;
      bool hasSell = false;
      bool found = false;
      for (int k = start; k < flat.length; k++) {
        final t = flat[k].trade;
        final amt = t.amount;
        final amount = dFrom(amt);
        if (t.direction.trim().toLowerCase() == 'buy') {
          netApiAmount += amount;
          hasBuy = true;
        } else {
          netApiAmount -= amount;
          hasSell = true;
        }
        if (hasBuy && hasSell && netApiAmount == Decimal.zero) {
          _tradeHistoryPositions.add((start, k));
          start = k + 1;
          found = true;
          break;
        }
      }
      if (!found) {
        // No closure from this start within range; try next start to
        // allow recognizing later closed positions in the window.
        start += 1;
      }
    }
    // Order positions from most recent to oldest
    if (_tradeHistoryPositions.isNotEmpty) {
      final reversed = _tradeHistoryPositions.reversed.toList();
      _tradeHistoryPositions
        ..clear()
        ..addAll(reversed);
    }
  }

  void selectTradeHistoryPosition(int index) {
    if (_tradeHistoryPositions.isEmpty) {
      _computeTradeHistoryPositions();
    }
    if (_tradeHistoryPositions.isEmpty) return;
    final clamped = index.clamp(0, _tradeHistoryPositions.length - 1);
    final (start, end) = _tradeHistoryPositions[clamped];
    _currentTradeHistoryPositionIndex = clamped;

    // First, deselect all
    for (final g in tradeHistoryGroups) {
      for (final e in g.leafEntries) {
        e.isSelected = false;
      }
    }

    final flat = _chronologicalTradeHistoryEntries(pnlEligibleOnly: true);
    for (int i = start; i <= end && i < flat.length; i++) {
      flat[i].isSelected = true;
    }
    _refreshTradeHistorySelectionSummary();
    notifyListeners();
  }

  void selectNextTradeHistoryPosition() {
    if (_tradeHistoryPositions.isEmpty) {
      _computeTradeHistoryPositions();
    }
    if (_tradeHistoryPositions.isEmpty) return;
    final nextIndex = (_currentTradeHistoryPositionIndex ?? -1) + 1;
    if (nextIndex >= _tradeHistoryPositions.length) {
      selectTradeHistoryPosition(0);
    } else {
      selectTradeHistoryPosition(nextIndex);
    }
  }

  void selectPrevTradeHistoryPosition() {
    if (_tradeHistoryPositions.isEmpty) {
      _computeTradeHistoryPositions();
    }
    if (_tradeHistoryPositions.isEmpty) return;
    final prevIndex = (_currentTradeHistoryPositionIndex ?? 0) - 1;
    if (prevIndex < 0) {
      selectTradeHistoryPosition(_tradeHistoryPositions.length - 1);
    } else {
      selectTradeHistoryPosition(prevIndex);
    }
  }

  double? getEstimatedPrice(String instrumentName, String direction) {
    final symbol = _normalizeSymbol(instrumentName);
    // First try current trading pairs values (best bid/ask)
    final tp =
        findTradingPairVm(symbol) ??
        TradingPairVM(TradingPair.unverified(symbol));
    final bid = tp.bestBid;
    final ask = tp.bestAsk;
    if (direction.toLowerCase() == 'buy') {
      return ask > 0 ? ask : null;
    } else if (direction.toLowerCase() == 'sell') {
      return bid > 0 ? bid : null;
    } else {
      if (bid > 0 && ask > 0) return (bid + ask) / 2;
    }
    return null;
  }

  double? computeLimitPrice(
    TradingPairVM tp,
    String direction, {
    double? custom,
  }) {
    final reference = custom ?? (direction == 'buy' ? tp.bestAsk : tp.bestBid);
    if (!reference.isFinite || reference <= 0) return null;
    final tickD = dFrom(tp.pair.tickSizeAt(reference));
    if (tickD <= Decimal.zero) return null;
    if (custom != null && custom.isFinite && custom > 0) {
      return dToDouble(roundToTick(dFrom(custom), tickD));
    }
    final bidD = dFrom(tp.bestBid);
    final askD = dFrom(tp.bestAsk);
    Decimal? base;
    int offsetTicks = 0;
    if (direction.toLowerCase() == 'buy') {
      if (askD <= Decimal.zero || tickD <= Decimal.zero) return null;
      base = askD - tickD;
      offsetTicks = tp.buyOffsetTicks;
    } else if (direction.toLowerCase() == 'sell') {
      if (bidD <= Decimal.zero || tickD <= Decimal.zero) return null;
      base = bidD + tickD;
      offsetTicks = tp.sellOffsetTicks;
    } else {
      if (bidD > Decimal.zero && askD > Decimal.zero) {
        base = Decimal.parse(((bidD + askD) / Decimal.fromInt(2)).toString());
      }
    }
    if (base == null) return null;
    final price = base + (tickD * Decimal.fromInt(offsetTicks));
    final rounded = roundToTick(price, tickD);
    return dToDouble(rounded);
  }

  // Same as computePercentOrderAmount but returns meta info for UI
  (double? amount, bool usedAvailableFunds, double bufferFactor)
  computePercentOrderAmountWithMeta(
    TradingPairVM tp,
    String direction, {
    double? atPrice,
  }) {
    if (!tp.pair.isVerified || tp.pair.type != TradingPairType.future) {
      return (null, false, 1.0);
    }
    final lev = tp.leverage.clamp(1, tp.pair.maxLeverage);
    if (lev <= 0) return (null, false, percentSizingBuffer);

    final pct = (direction.toLowerCase() == 'buy')
        ? tp.buyPercent
        : tp.sellPercent;
    if (pct <= 0) return (0.0, false, percentSizingBuffer);
    final price = atPrice ?? computeLimitPrice(tp, direction);
    if (price == null || price <= 0) return (null, false, percentSizingBuffer);

    final isInverse = tp.pair.amountUnit == AmountUnit.usd;
    final marginCurrency = tp.pair.marginCurrency;
    final metrics = _accountMetrics[marginCurrency.trim().toUpperCase()];
    if (metrics == null) {
      // ignore: discarded_futures
      ensureAccountMetricsForCurrency(marginCurrency);
      return (null, false, percentSizingBuffer);
    }
    const usedAvailable = true;
    final baseFunds = metrics.availableFunds;
    if (baseFunds <= 0) return (null, usedAvailable, percentSizingBuffer);
    final safeFunds = baseFunds * percentSizingBuffer;

    double notionalQuote;
    if (isInverse) {
      notionalQuote = safeFunds * price * (lev / 1.0) * (pct / 100.0);
    } else {
      notionalQuote = safeFunds * (lev / 1.0) * (pct / 100.0);
    }
    final amount = isInverse ? notionalQuote : (notionalQuote / price);
    return (amount, usedAvailable, percentSizingBuffer);
  }

  Future<void> setPercentSizingBuffer(double v) async {
    final clamped = v.clamp(0.1, 1.0);
    percentSizingBuffer = clamped;
    notifyListeners();
    await SettingsStore.savePercentSizingBuffer(clamped);
  }

  final Map<String, double> _latestMarkPrice = {};

  void _onTicker(TickerData t) {
    final symbol = _normalizeSymbol(t.instrumentName);
    final vm = findTradingPairVm(symbol);
    if (vm == null && !_allowsRuntimeSymbol(symbol)) return;
    if (t.markPrice > 0) {
      _latestMarkPrice[symbol] = t.markPrice;
      if (_tradeHistoryRequestedInstrument == symbol) {
        _refreshTradeHistorySelectionSummary();
      }
    }
    // Optional: also refresh bid/ask if missing
    final target = vm ?? _ensureTradingPairVm(symbol);
    if (target == null) return;
    if (t.bestBid != null && t.bestBid! > 0) target.bestBid = t.bestBid!;
    if (t.bestAsk != null && t.bestAsk! > 0) target.bestAsk = t.bestAsk!;
    notifyListeners();
  }

  double? getLatestMarkPrice(String instrument) =>
      _latestMarkPrice[_normalizeSymbol(instrument)];

  Future<void> ensureAccountMetricsForCurrency(String currency) async {
    final normalizedCurrency = currency.trim().toUpperCase();
    if (normalizedCurrency.isEmpty) return;
    final cached = _accountMetrics[normalizedCurrency];
    if (cached != null && !cached.isExpired(_accountMetricsTtl)) return;
    final generation = _accountStateGeneration;
    if (_accountMetricLoadGenerations[normalizedCurrency] == generation) return;
    _accountMetricLoadGenerations[normalizedCurrency] = generation;
    try {
      final res = await _service.getAccountMetrics(normalizedCurrency);
      if (res != null && _isCurrentAccountState(generation)) {
        _accountMetrics[normalizedCurrency] = _AccountMetricsCache(
          res.$1,
          res.$2,
          res.$3,
          DateTime.now(),
        );
        notifyListeners();
      }
    } finally {
      if (_accountMetricLoadGenerations[normalizedCurrency] == generation) {
        _accountMetricLoadGenerations.remove(normalizedCurrency);
      }
    }
  }

  double? getEstimatedLiquidationPrice(Position pos) {
    // 1) Prefer value provided by Position
    final est = pos.estimatedLiquidationPrice;
    if (est != null && est > 0) return est;

    // 2) Fallback: mark_price * estimated_liquidation_ratio_map[pairKey]
    final mark =
        _latestMarkPrice[_normalizeSymbol(pos.instrumentName)] ?? pos.markPrice;
    if (mark <= 0) return null;

    // Ratio keys describe the base/quote pair, while account summaries are
    // partitioned by the instrument's margin currency.
    final tp = _service.getTradingPairBySymbol(
      pos.instrumentName,
      customTradingPairs,
    );
    if (tp == null ||
        !tp.isVerified ||
        tp.baseCurrency.isEmpty ||
        tp.quoteCurrency.isEmpty ||
        tp.marginCurrency.isEmpty) {
      return null;
    }
    final baseKey = tp.baseCurrency.toLowerCase();
    final quoteKey = tp.quoteCurrency.toLowerCase();
    final marginKey = tp.marginCurrency.toLowerCase();
    final ratioKey = '${baseKey}_$quoteKey';

    final acc = accountSummaries;
    if (acc == null) return null;
    for (final s in acc.summaries) {
      if (s.currency.toLowerCase() != marginKey) continue;
      final map = s.estimatedLiquidationRatioMap;
      if (map == null || map.isEmpty) continue;
      final ratio = map[ratioKey];
      if (ratio != null && ratio > 0) {
        return mark * ratio;
      }
    }
    return null;
  }

  Future<void> _resubscribeAll() async {
    final connectionGeneration = _connectionOperationGeneration;
    for (final symbol in _desiredSubscribedSymbols.toList()) {
      if (connectionGeneration != _connectionOperationGeneration ||
          !isConnected) {
        return;
      }
      await _ensureInstrumentSubscribed(symbol, addToDesired: false);
    }
  }

  Future<void> _subscribeUserChangesAll() async {
    if (!isAuthenticated) return;
    final authenticationGeneration = _authenticationOperationGeneration;
    final connectionGeneration = _connectionOperationGeneration;
    for (final symbol in _sessionPublicSubscribedSymbols.toList()) {
      if (!isAuthenticated ||
          authenticationGeneration != _authenticationOperationGeneration ||
          connectionGeneration != _connectionOperationGeneration) {
        return;
      }
      _syncSessionSubscriptionPresentation(symbol);
      await _runSessionSubscriptionReconcile(symbol);
    }
  }

  Future<void> setIsTestnet(bool v) async {
    if (isConnecting) return;
    if (isTestnet == v) return;
    if (isConnected) await disconnect();
    _marketCacheSaveTimer?.cancel();
    isTestnet = v;
    tradingPairs.removeWhere(
      (tp) => !customTradingPairs.any((p) => p.symbol == tp.pair.symbol),
    );
    for (final pair in TradingPair.defaultPairs(paper: v)) {
      if (!tradingPairs.any((tp) => tp.pair.symbol == pair.symbol)) {
        tradingPairs.add(TradingPairVM(pair));
      }
    }
    notifyListeners();
    await SettingsStore.saveIsTestnet(v);
    await _restoreMarketCache();
  }

  Future<void> setAndroidBackgroundKeepAlive(bool enabled) async {
    if (enabled == androidBackgroundKeepAlive) return;
    try {
      if (enabled && isConnected) {
        await MobileConnectionKeepAlive.start();
      } else if (!enabled) {
        await MobileConnectionKeepAlive.stop();
      }
      await SettingsStore.saveAndroidBackgroundKeepAlive(enabled);
      androidBackgroundKeepAlive = enabled;
      notifyListeners();
    } catch (e) {
      _onStatus('Android background keepalive failed: $e');
      rethrow;
    }
  }

  Future<void> setRememberCredentials(bool v) async {
    rememberCredentials = v;
    notifyListeners();
    await SettingsStore.saveRememberCredentials(v);
    if (v) {
      await SettingsStore.saveCredentials(clientId, clientSecret);
    } else {
      await SettingsStore.clearCredentials();
    }
  }

  Future<void> _persistCredentialsIfNeeded() async {
    if (rememberCredentials) {
      await SettingsStore.saveCredentials(clientId, clientSecret);
    }
  }

  void updateClientId(String v) {
    clientId = v;
    if (rememberCredentials) {
      // fire-and-forget; do not await to keep UI snappy
      // ignore: discarded_futures
      SettingsStore.saveCredentials(clientId, clientSecret);
    }
    notifyListeners();
  }

  void updateClientSecret(String v) {
    clientSecret = v;
    if (rememberCredentials) {
      // ignore: discarded_futures
      SettingsStore.saveCredentials(clientId, clientSecret);
    }
    notifyListeners();
  }

  Future<void> setMaxSpreadPercent(double v) async {
    maxSpreadPercent = v;
    notifyListeners();
    await SettingsStore.saveMaxSpreadPercent(v);
    _pushServiceSettings();
  }

  Future<void> addCustomTradingPair({
    required String symbol,
    double maxPriceDeviationPercent = 0.3,
  }) async {
    final normalized = TradingPair.canonicalSymbol(symbol);
    customInstrumentError = null;
    if (normalized.isEmpty) {
      customInstrumentError = 'Symbol is required';
      notifyListeners();
      return;
    }
    if (!maxPriceDeviationPercent.isFinite || maxPriceDeviationPercent <= 0) {
      customInstrumentError = 'Max price deviation must be greater than zero';
      notifyListeners();
      return;
    }
    if (_hasConfiguredSymbol(normalized) ||
        _customInstrumentLoads.containsKey(normalized)) {
      customInstrumentError = '$normalized is already configured';
      notifyListeners();
      return;
    }
    final lifecycleGeneration = _customPairLifecycleGeneration;
    final owner = ++_nextCustomInstrumentLoadOwner;
    _customInstrumentLoads[normalized] = owner;
    loadingCustomInstrument = true;
    notifyListeners();
    try {
      final tp = await _service.loadInstrument(
        normalized,
        maxPriceDeviationPercent: maxPriceDeviationPercent,
      );
      if (_disposed ||
          lifecycleGeneration != _customPairLifecycleGeneration ||
          _customInstrumentLoads[normalized] != owner) {
        return;
      }
      if (tp == null) {
        customInstrumentError = 'Unable to load active instrument $normalized';
        return;
      }
      if (_hasConfiguredSymbol(normalized)) {
        customInstrumentError = '$normalized is already configured';
        return;
      }
      final normalizedPair = tp.symbol == normalized
          ? tp
          : TradingPair.fromMap({...tp.toMap(), 'symbol': normalized});
      customTradingPairs.add(normalizedPair);
      tradingPairs.add(TradingPairVM(normalizedPair));
      customInstrumentError = null;
      _pushServiceSettings();
      await _persistCustomPairs();
    } catch (e) {
      if (!_disposed &&
          lifecycleGeneration == _customPairLifecycleGeneration &&
          _customInstrumentLoads[normalized] == owner) {
        customInstrumentError = 'Unable to load $normalized: $e';
      }
    } finally {
      if (_customInstrumentLoads[normalized] == owner) {
        _customInstrumentLoads.remove(normalized);
      }
      loadingCustomInstrument = _customInstrumentLoads.isNotEmpty;
      notifyListeners();
    }
  }

  Future<void> addImportedCustomTradingPair(TradingPair cached) async {
    final lifecycleGeneration = _customPairLifecycleGeneration;
    final unverified = _addCachedCustomPair(cached);
    if (unverified == null) return;
    _pushServiceSettings();
    notifyListeners();
    await _persistCustomPairs();
    if (isConnected &&
        lifecycleGeneration == _customPairLifecycleGeneration &&
        _hasConfiguredSymbol(unverified.symbol)) {
      await _service.refreshInstrumentMetadata(symbols: [unverified.symbol]);
    }
  }

  Future<void> replaceImportedCustomTradingPairs(
    Iterable<TradingPair> imported,
  ) async {
    _customPairLifecycleGeneration++;
    final pendingSymbols = _customInstrumentLoads.keys.toSet();
    _customInstrumentLoads.clear();
    loadingCustomInstrument = false;
    final defaults = TradingPair.defaultPairs(
      paper: isTestnet,
    ).map((pair) => _normalizeSymbol(pair.symbol)).toSet();
    final canonical = <String, TradingPair>{};
    for (final cached in imported) {
      final symbol = _normalizeSymbol(cached.symbol);
      if (symbol.isEmpty || defaults.contains(symbol)) continue;
      canonical.putIfAbsent(
        symbol,
        () => TradingPair.fromMap({...cached.toMap(), 'symbol': symbol}),
      );
    }
    final oldCustomSymbols = customTradingPairs
        .map((pair) => _normalizeSymbol(pair.symbol))
        .toSet();
    final oldCustomBySymbol = {
      for (final pair in customTradingPairs)
        _normalizeSymbol(pair.symbol): pair,
    };
    final oldCustomPairs = List<TradingPair>.of(customTradingPairs);
    final failedRetirements = <String>{};
    final retiredSymbols = <String>{};
    for (final symbol in oldCustomSymbols.difference(canonical.keys.toSet())) {
      if (!await _service.retireInstrumentIfSafe(symbol)) {
        failedRetirements.add(symbol);
        canonical[symbol] = oldCustomBySymbol[symbol]!;
      } else {
        retiredSymbols.add(symbol);
      }
    }
    final proposedCustomPairs = canonical.values.toList(growable: false);
    try {
      await _persistCustomPairSnapshot(proposedCustomPairs);
      _service.updateSettings(
        maxSpreadPercent: maxSpreadPercent,
        customPairs: proposedCustomPairs,
      );
    } catch (error) {
      await _restoreCustomPairMutation(oldCustomPairs, retiredSymbols);
      customInstrumentError =
          'Import failed; previous custom configuration was restored: $error';
      notifyListeners();
      return;
    }
    customInstrumentError = failedRetirements.isEmpty
        ? null
        : 'Kept ${failedRetirements.join(', ')} because safe retirement could not be verified';
    final newCustomSymbols = canonical.keys.toSet();
    final retainedVms = <String, TradingPairVM>{
      for (final vm in tradingPairs)
        if (oldCustomSymbols.contains(_normalizeSymbol(vm.symbol)))
          _normalizeSymbol(vm.symbol): vm,
    };
    for (final symbol in pendingSymbols) {
      _service.removeInstrument(symbol);
    }
    customTradingPairs.clear();
    customTradingPairs.addAll(proposedCustomPairs);
    for (final entry in canonical.entries) {
      final symbol = entry.key;
      final pair = entry.value;
      final retained = retainedVms[symbol];
      if (retained != null) {
        retained.pair = pair;
      } else {
        tradingPairs.add(TradingPairVM(pair));
      }
    }
    final cleanup = <Future<void>>[];
    for (final symbol in oldCustomSymbols.difference(newCustomSymbols)) {
      cleanup.add(_removeSymbolRuntimeState(symbol));
    }
    notifyListeners();
    await Future.wait(cleanup);
    if (_disposed) return;
    if (isConnected && customTradingPairs.isNotEmpty) {
      await _service.refreshInstrumentMetadata(
        symbols: customTradingPairs.map((pair) => pair.symbol),
      );
    }
  }

  TradingPair? _addCachedCustomPair(TradingPair cached) {
    final symbol = _normalizeSymbol(cached.symbol);
    if (symbol.isEmpty || _hasConfiguredSymbol(symbol)) return null;
    final unverified = TradingPair.fromMap({
      ...cached.toMap(),
      'symbol': symbol,
    });
    customTradingPairs.add(unverified);
    tradingPairs.add(TradingPairVM(unverified));
    return unverified;
  }

  String _normalizeSymbol(String symbol) => TradingPair.canonicalSymbol(symbol);

  String canonicalSymbol(String symbol) => _normalizeSymbol(symbol);

  TradingPairVM? findTradingPairVm(String symbol) {
    final normalized = _normalizeSymbol(symbol);
    for (final pair in tradingPairs) {
      if (_normalizeSymbol(pair.symbol) == normalized) return pair;
    }
    return null;
  }

  bool _hasConfiguredSymbol(String symbol) {
    final normalized = _normalizeSymbol(symbol);
    return TradingPair.defaultPairs(
          paper: isTestnet,
        ).any((pair) => _normalizeSymbol(pair.symbol) == normalized) ||
        customTradingPairs.any(
          (pair) => _normalizeSymbol(pair.symbol) == normalized,
        );
  }

  bool _allowsRuntimeSymbol(String symbol) {
    final normalized = _normalizeSymbol(symbol);
    return _hasConfiguredSymbol(normalized) ||
        _wantsSubscription(normalized) ||
        _hasRuntimeRisk(normalized);
  }

  bool _hasRuntimeRisk(String symbol) {
    final normalized = _normalizeSymbol(symbol);
    return activeOrders.any(
          (item) =>
              item.order.isActive &&
              _normalizeSymbol(item.order.instrumentName) == normalized,
        ) ||
        positions.any(
          (item) =>
              item.position.size != 0 &&
              _normalizeSymbol(item.position.instrumentName) == normalized,
        ) ||
        _service.hasActiveRiskForInstrument(normalized);
  }

  Future<bool> removeCustomTradingPair(String symbol) async {
    final normalized = _normalizeSymbol(symbol);
    if (!customTradingPairs.any(
      (pair) => _normalizeSymbol(pair.symbol) == normalized,
    )) {
      customInstrumentError =
          'Cannot remove $normalized: it is not a configured custom instrument';
      notifyListeners();
      return false;
    }
    if (!await _service.retireInstrumentIfSafe(normalized)) {
      customInstrumentError =
          'Cannot remove $normalized: safe retirement could not be verified';
      notifyListeners();
      return false;
    }
    final oldCustomPairs = List<TradingPair>.of(customTradingPairs);
    final proposedCustomPairs = oldCustomPairs
        .where((pair) => _normalizeSymbol(pair.symbol) != normalized)
        .toList(growable: false);
    customTradingPairs
      ..clear()
      ..addAll(proposedCustomPairs);
    try {
      _service.updateSettings(
        maxSpreadPercent: maxSpreadPercent,
        customPairs: proposedCustomPairs,
      );
      await _persistCustomPairSnapshot(proposedCustomPairs);
    } catch (error) {
      customTradingPairs
        ..clear()
        ..addAll(oldCustomPairs);
      await _restoreCustomPairMutation(oldCustomPairs, {normalized});
      customInstrumentError =
          'Cannot remove $normalized; previous custom configuration was restored: $error';
      notifyListeners();
      return false;
    }
    customInstrumentError = null;
    _customInstrumentLoads.remove(normalized);
    final cleanup = _removeSymbolRuntimeState(normalized);
    notifyListeners();
    await cleanup;
    return true;
  }

  Future<void> _restoreCustomPairMutation(
    List<TradingPair> oldCustomPairs,
    Set<String> retiredSymbols,
  ) async {
    try {
      await _persistCustomPairSnapshot(oldCustomPairs);
    } catch (_) {}
    try {
      _service.updateSettings(
        maxSpreadPercent: maxSpreadPercent,
        customPairs: oldCustomPairs,
      );
    } catch (_) {}
    if (_disposed || !isConnected || retiredSymbols.isEmpty) return;
    try {
      await _service.refreshInstrumentMetadata(symbols: retiredSymbols);
    } catch (_) {}
    for (final symbol in retiredSymbols) {
      _sessionPublicSubscribedSymbols.remove(symbol);
      _sessionPrivateSubscribedSymbols.remove(symbol);
      _syncSessionSubscriptionPresentation(symbol);
      if (_wantsSubscription(symbol)) {
        await _runSessionSubscriptionReconcile(symbol);
      }
    }
  }

  Future<void> _removeSymbolRuntimeState(String symbol) async {
    final normalized = _normalizeSymbol(symbol);
    _desiredSubscribedSymbols.remove(normalized);
    _orderSubscriptionSymbols.remove(normalized);
    _positionSubscriptionSymbols.remove(normalized);
    _bumpSubscriptionIntent(normalized);
    _service.removeInstrument(normalized);
    tradingPairs.removeWhere(
      (pair) => _normalizeSymbol(pair.symbol) == normalized,
    );
    _latestMarkPrice.remove(normalized);
    if (_sessionSubscribedSymbols.contains(normalized) ||
        _sessionSubscriptionOwners.containsKey(normalized)) {
      await _unsubscribeCurrentSymbol(normalized);
    } else {
      _subscriptionIntentGenerations.remove(normalized);
    }
  }

  void _cleanupRuntimeRiskSymbol(String symbol) {
    final normalized = _normalizeSymbol(symbol);
    if (_hasConfiguredSymbol(normalized) || _hasRuntimeRisk(normalized)) return;
    _orderSubscriptionSymbols.remove(normalized);
    _positionSubscriptionSymbols.remove(normalized);
    if (_desiredSubscribedSymbols.contains(normalized)) return;
    tradingPairs.removeWhere(
      (pair) => _normalizeSymbol(pair.symbol) == normalized,
    );
    _latestMarkPrice.remove(normalized);
  }

  Future<void> _persistCustomPairs() {
    return _persistCustomPairSnapshot(customTradingPairs);
  }

  Future<void> _persistCustomPairSnapshot(Iterable<TradingPair> pairs) {
    final raw = pairs.map((p) => p.toMap()).toList();
    final request = _customPairPersistenceQueue.then(
      (_) => SettingsStore.saveCustomTradingPairsRaw(raw),
    );
    _customPairPersistenceQueue = request.catchError((_) {});
    return request;
  }

  void _pushServiceSettings() {
    _service.updateSettings(
      maxSpreadPercent: maxSpreadPercent,
      customPairs: customTradingPairs,
    );
  }

  Future<void> setPairOptionsExpanded(TradingPairVM tp, bool expanded) async {
    tp.optionsExpanded = expanded;
    notifyListeners();
    final map = await SettingsStore.loadPairOptionsExpandedMap();
    map[tp.symbol] = expanded;
    await SettingsStore.savePairOptionsExpandedMap(map);
  }

  void _onStatus(String message) {
    if (_disposed) return;
    statusMessage = message;
    statusMessages.insert(
      0,
      '${DateTime.now().toIso8601String().substring(11, 19)} - $message',
    );
    if (statusMessages.length > 1000) {
      statusMessages.removeLast();
    }
    if (message.startsWith('Disconnected')) {
      _connectionOperationGeneration++;
      _invalidateAuthenticationOperation();
      isConnected = false;
      _clearTradingSessionState();
      _clearAnnouncementState();
      _stopAccountAutoRefresh();
      _stopOrdersAutoRefresh();
      _downgradeTradingPairMetadata();
      for (final tp in tradingPairs) {
        tp.isSubscribed = false;
        tp.bestBid = 0;
        tp.bestAsk = 0;
        tp.lastUpdate = null;
      }
    } else if (message.startsWith('Connected')) {
      if (isConnecting) {
        notifyListeners();
        return;
      }
      _invalidateAuthenticationOperation();
      isConnected = true;
      _clearTradingSessionState();
      _downgradeTradingPairMetadata();
      // Reconcile any announcement changes missed while disconnected.
      // ignore: discarded_futures

      // After reconnect, resubscribe public channels and re-auth if possible
      // ignore: discarded_futures
      _resubscribeAll();
      if (clientId.isNotEmpty && clientSecret.isNotEmpty) {
        // ignore: discarded_futures
        authenticate();
      }
    }
    notifyListeners();
  }

  void _onInstrumentMetadata(TradingPair pair) {
    if (_disposed) return;
    final normalized = _normalizeSymbol(pair.symbol);
    if (!_allowsRuntimeSymbol(normalized)) return;
    final index = tradingPairs.indexWhere(
      (vm) => _normalizeSymbol(vm.symbol) == normalized,
    );
    if (index >= 0) {
      final vm = tradingPairs[index];
      vm.pair = pair;
      if (vm.buyAmount == 0) vm.buyAmount = pair.minTradeAmount;
      if (vm.sellAmount == 0) vm.sellAmount = pair.minTradeAmount;
      vm.leverage = vm.leverage.clamp(1, pair.maxLeverage);
    }
    final customIndex = customTradingPairs.indexWhere(
      (item) => _normalizeSymbol(item.symbol) == normalized,
    );
    if (customIndex >= 0) {
      customTradingPairs[customIndex] = pair;
      // ignore: discarded_futures
      _persistCustomPairs();
    }
    if (_tradeHistoryRequestedInstrument == normalized) {
      _tradeHistoryInstrument = pair.isVerified ? pair : null;
      _computeTradeHistoryPositions();
      _refreshTradeHistorySelectionSummary();
    }
    if (pair.isVerified) _saveMarketCacheSoon();
    notifyListeners();
  }

  void _downgradeTradingPairMetadata() {
    for (final vm in tradingPairs) {
      if (vm.pair.isVerified) vm.pair = TradingPair.fromMap(vm.pair.toMap());
    }
    for (var i = 0; i < customTradingPairs.length; i++) {
      final pair = customTradingPairs[i];
      if (pair.isVerified) {
        customTradingPairs[i] = TradingPair.fromMap(pair.toMap());
      }
    }
  }

  bool canTradeSymbol(String symbol) =>
      isAuthenticated && _service.isInstrumentVerified(symbol);

  void _clearTradingSessionState() {
    _clearAccountState();
    _clearTradeHistoryState();
    activeOrders.clear();
    positions.clear();
    _latestMarkPrice.clear();
    _orderSubscriptionSymbols.clear();
    _positionSubscriptionSymbols.clear();
    _sessionSubscribedSymbols.clear();
    _sessionPublicSubscribedSymbols.clear();
    _sessionPrivateSubscribedSymbols.clear();
    _sessionSubscriptionOwners.clear();
    for (final timer in _subscriptionRetryTimers.values) {
      timer.cancel();
    }
    _subscriptionRetryTimers.clear();
    _subscriptionRetryAttempts.clear();
    _subscriptionIntentGenerations.clear();
    for (final symbol in _desiredSubscribedSymbols) {
      _subscriptionIntentGenerations[symbol] =
          ++_nextSubscriptionIntentGeneration;
    }
    for (final tp in tradingPairs) {
      tp.isSubscribed = false;
      tp.bestBid = 0;
      tp.bestAsk = 0;
      tp.lastUpdate = null;
    }
    _stopAccountAutoRefresh();
    _stopOrdersAutoRefresh();
  }

  void _clearPrivateTradingSessionState() {
    _clearAccountState();
    _clearTradeHistoryState();
    _clearAnnouncementUnreadState(invalidateRequests: true);
    addressBook.clear();
    addressBookError = null;
    loadingAddressBook = false;
    addressBookCurrency = null;
    _addressBookRequestGeneration++;
    withdrawals.clear();
    withdrawalsError = null;
    loadingWithdrawals = false;
    withdrawalsCurrency = null;
    hasMoreWithdrawals = false;
    _withdrawalNextOffset = 0;
    _withdrawalRequestGeneration++;
    loadingOpenOrders = false;
    activeOrders.clear();
    positions.clear();
    final affectedSubscriptions = <String>{
      ..._sessionSubscribedSymbols,
      ..._sessionPrivateSubscribedSymbols,
      ..._sessionPublicSubscribedSymbols,
    };
    _orderSubscriptionSymbols.clear();
    _positionSubscriptionSymbols.clear();
    _sessionPrivateSubscribedSymbols.clear();
    for (final symbol in affectedSubscriptions) {
      _syncSessionSubscriptionPresentation(symbol);
    }
    _stopAccountAutoRefresh();
    _stopOrdersAutoRefresh();
  }

  void _clearTradeHistoryState() {
    _tradeHistoryRequestGeneration++;
    _tradeHistoryInstrument = null;
    _tradeHistoryRequestedInstrument = null;
    tradeHistory.clear();
    tradeHistoryGroups.clear();
    _tradeHistoryPositions.clear();
    _currentTradeHistoryPositionIndex = null;
    _refreshTradeHistorySelectionSummary();
  }

  void _clearAccountState() {
    _accountStateGeneration++;
    accountSummaries = null;
    accountInfoFromCache = false;
    accountSummariesError = null;
    accountTotalUsd = null;
    accountTotalBtc = null;
    accountTotalCny = null;
    loadingAccountSummaries = false;
    loadingAccountTotals = false;
    loadingAccountCny = false;
    _accountMetrics.clear();
    _accountMetricLoadGenerations.clear();
    _usdRates.clear();
    _usdRateRequests.clear();
    _btcRates.clear();
    _btcRateRequests.clear();
    _usdRateLoading.clear();
  }

  void _onOrderBook(OrderBookData book) {
    final symbol = _normalizeSymbol(book.instrumentName);
    final tp = findTradingPairVm(symbol) ?? _ensureTradingPairVm(symbol);
    if (tp == null) return;
    tp.bestBid = book.bestBid;
    tp.bestAsk = book.bestAsk;
    tp.lastUpdate = DateTime.fromMillisecondsSinceEpoch(book.timestamp);
    notifyListeners();
  }

  void _onOrder(Order order) {
    final symbol = _normalizeSymbol(order.instrumentName);
    final existing = activeOrders
        .where((o) => o.order.orderId == order.orderId)
        .toList();
    if (order.isActive) {
      if (existing.isNotEmpty) {
        existing.first.order = order;
      } else {
        activeOrders.add(OrderVM(order));
      }
      // Restored/open orders need live public feeds for pair prices and Chase.
      // Position updates can carry mark prices through private streams, but
      // pair bid/ask and chasing require order book/ticker subscriptions.
      // ignore: discarded_futures
      _setOrderSubscriptionRequired(symbol, true);
      final vm = _ensureTradingPairVm(symbol);
      if (vm != null && !_hasConfiguredSymbol(symbol)) {
        vm.pair = TradingPair.fromMap(vm.pair.toMap());
      }
    } else if (existing.isNotEmpty) {
      activeOrders.remove(existing.first);
      final stillRequired = activeOrders.any(
        (item) => _normalizeSymbol(item.order.instrumentName) == symbol,
      );
      _setOrderSubscriptionRequired(symbol, stillRequired);
      _cleanupRuntimeRiskSymbol(symbol);
    }
    _sortActiveOrders();
    notifyListeners();
  }

  // 按最近更新时间倒序排列订单（最新更新的排在最前）
  void _sortActiveOrders() {
    activeOrders.sort(
      (a, b) =>
          b.order.lastUpdateTimestamp.compareTo(a.order.lastUpdateTimestamp),
    );
  }

  TradingPairVM? _ensureTradingPairVm(String instrumentName) {
    final symbol = _normalizeSymbol(instrumentName);
    final existingIdx = tradingPairs.indexWhere(
      (e) => _normalizeSymbol(e.symbol) == symbol,
    );
    if (existingIdx >= 0) return tradingPairs[existingIdx];
    if (!_allowsRuntimeSymbol(symbol)) return null;
    final meta =
        _service.getTradingPairBySymbol(symbol, customTradingPairs) ??
        TradingPair.unverified(symbol);
    final vm = TradingPairVM(meta);
    tradingPairs.add(vm);
    return vm;
  }

  Future<void> _ensureInstrumentSubscribed(
    String instrumentName, {
    bool addToDesired = true,
  }) async {
    final symbol = _normalizeSymbol(instrumentName);
    if (symbol.isEmpty) return;
    if (addToDesired && _desiredSubscribedSymbols.add(symbol)) {
      _bumpSubscriptionIntent(symbol);
    }
    await _runSessionSubscriptionReconcile(symbol);
  }

  Future<void> _runSessionSubscriptionReconcile(String symbol) async {
    if (_disposed ||
        !isConnected ||
        !_service.isConnected ||
        _sessionSubscriptionOwners.containsKey(symbol)) {
      return;
    }
    _subscriptionRetryTimers.remove(symbol)?.cancel();
    final connectionGeneration = _connectionOperationGeneration;
    final authenticationGeneration = _authenticationOperationGeneration;
    final owner = ++_nextSessionSubscriptionOwner;
    _sessionSubscriptionOwners[symbol] = owner;
    var failed = false;
    try {
      while (_ownsSessionSubscriptionTransport(
        connectionGeneration,
        symbol,
        owner,
      )) {
        final desired = _wantsSubscription(symbol);
        final publicActual = _sessionPublicSubscribedSymbols.contains(symbol);
        final privateActual = _sessionPrivateSubscribedSymbols.contains(symbol);
        if (desired && !publicActual) {
          if (_ensureTradingPairVm(symbol) == null) return;
          await _service.subscribeToInstrument(symbol);
          if (!_ownsSessionSubscriptionTransport(
            connectionGeneration,
            symbol,
            owner,
          )) {
            return;
          }
          _sessionPublicSubscribedSymbols.add(symbol);
          _syncSessionSubscriptionPresentation(symbol);
          continue;
        }
        if (desired && isAuthenticated && !privateActual) {
          await _service.subscribeToUserChanges(symbol);
          if (!_ownsSessionSubscriptionTransport(
                connectionGeneration,
                symbol,
                owner,
              ) ||
              authenticationGeneration != _authenticationOperationGeneration ||
              !isAuthenticated) {
            return;
          }
          _sessionPrivateSubscribedSymbols.add(symbol);
          _syncSessionSubscriptionPresentation(symbol);
          continue;
        }
        if ((!desired || !isAuthenticated) && privateActual) {
          if (isAuthenticated) {
            await _service.unsubscribeUserChanges(symbol);
            if (!_ownsSessionSubscriptionTransport(
                  connectionGeneration,
                  symbol,
                  owner,
                ) ||
                authenticationGeneration !=
                    _authenticationOperationGeneration) {
              return;
            }
          }
          _sessionPrivateSubscribedSymbols.remove(symbol);
          _syncSessionSubscriptionPresentation(symbol);
          continue;
        }
        if (!desired && publicActual) {
          await _service.unsubscribeFromInstrument(symbol);
          if (!_ownsSessionSubscriptionTransport(
            connectionGeneration,
            symbol,
            owner,
          )) {
            return;
          }
          _sessionPublicSubscribedSymbols.remove(symbol);
          _syncSessionSubscriptionPresentation(symbol);
          continue;
        }
        break;
      }
    } catch (_) {
      failed = true;
    } finally {
      if (_sessionSubscriptionOwners[symbol] == owner) {
        _sessionSubscriptionOwners.remove(symbol);
        _syncSessionSubscriptionPresentation(symbol);
        if (!_wantsSubscription(symbol) &&
            !_sessionPublicSubscribedSymbols.contains(symbol) &&
            !_sessionPrivateSubscribedSymbols.contains(symbol)) {
          _subscriptionIntentGenerations.remove(symbol);
        }
        final settled = _isSessionSubscriptionSettled(symbol);
        if (settled) {
          _subscriptionRetryAttempts.remove(symbol);
        } else if ((failed || !settled) &&
            !_disposed &&
            isConnected &&
            _service.isConnected) {
          _scheduleSubscriptionRetry(symbol);
        }
      }
    }
  }

  bool _isSessionSubscriptionSettled(String symbol) {
    final desired = _wantsSubscription(symbol);
    final desiredPrivate = desired && isAuthenticated;
    return _sessionPublicSubscribedSymbols.contains(symbol) == desired &&
        _sessionPrivateSubscribedSymbols.contains(symbol) == desiredPrivate;
  }

  void _syncSessionSubscriptionPresentation(String symbol) {
    final desired = _wantsSubscription(symbol);
    final publicActual = _sessionPublicSubscribedSymbols.contains(symbol);
    final privateActual = _sessionPrivateSubscribedSymbols.contains(symbol);
    final subscribed = desired
        ? publicActual && (!isAuthenticated || privateActual)
        : publicActual || privateActual;
    if (subscribed) {
      _sessionSubscribedSymbols.add(symbol);
    } else {
      _sessionSubscribedSymbols.remove(symbol);
    }
    final vm = findTradingPairVm(symbol);
    if (vm != null) vm.isSubscribed = subscribed;
    notifyListeners();
  }

  void _scheduleSubscriptionRetry(String symbol) {
    if (_subscriptionRetryTimers.containsKey(symbol)) return;
    final attempt = _subscriptionRetryAttempts[symbol] ?? 0;
    final multiplier = 1 << (attempt > 7 ? 7 : attempt);
    final exponentialDelayMs = 20 * multiplier;
    final delayMs = exponentialDelayMs > 2000 ? 2000 : exponentialDelayMs;
    _subscriptionRetryAttempts[symbol] = attempt + 1;
    _subscriptionRetryTimers[symbol] = Timer(
      Duration(milliseconds: delayMs),
      () {
        _subscriptionRetryTimers.remove(symbol);
        // ignore: discarded_futures
        _runSessionSubscriptionReconcile(symbol);
      },
    );
  }

  bool _ownsSessionSubscriptionTransport(
    int connectionGeneration,
    String symbol,
    int owner,
  ) =>
      !_disposed &&
      isConnected &&
      _service.isConnected &&
      connectionGeneration == _connectionOperationGeneration &&
      _sessionSubscriptionOwners[symbol] == owner;

  void _onPosition(Position p) {
    final symbol = _normalizeSymbol(p.instrumentName);
    final idx = positions.indexWhere(
      (x) => _normalizeSymbol(x.position.instrumentName) == symbol,
    );
    if (p.size != 0) {
      if (idx >= 0) {
        positions[idx] = PositionVM(p);
      } else {
        positions.add(PositionVM(p));
      }

      // Auto-subscribe the pair if not already subscribed when a non-zero position is observed
      _setPositionSubscriptionRequired(symbol, true);
      final vm = _ensureTradingPairVm(symbol);
      if (vm != null && !_hasConfiguredSymbol(symbol)) {
        vm.pair = TradingPair.fromMap(vm.pair.toMap());
      }
    } else if (idx >= 0) {
      positions.removeAt(idx);
      _setPositionSubscriptionRequired(symbol, false);
      _cleanupRuntimeRiskSymbol(symbol);
    }
    notifyListeners();
  }

  bool _wantsSubscription(String symbol) =>
      _desiredSubscribedSymbols.contains(symbol) ||
      _orderSubscriptionSymbols.contains(symbol) ||
      _positionSubscriptionSymbols.contains(symbol);

  void _bumpSubscriptionIntent(String symbol) {
    _subscriptionRetryTimers.remove(symbol)?.cancel();
    _subscriptionRetryAttempts.remove(symbol);
    _subscriptionIntentGenerations[symbol] =
        ++_nextSubscriptionIntentGeneration;
  }

  void _setManualSubscriptionDesired(String symbol, bool desired) {
    final wantedBefore = _wantsSubscription(symbol);
    if (desired) {
      _desiredSubscribedSymbols.add(symbol);
    } else {
      _desiredSubscribedSymbols.remove(symbol);
    }
    if (wantedBefore != _wantsSubscription(symbol)) {
      _bumpSubscriptionIntent(symbol);
    }
  }

  void _setOrderSubscriptionRequired(String symbol, bool required) {
    _setAutoSubscriptionRequired(_orderSubscriptionSymbols, symbol, required);
  }

  void _setPositionSubscriptionRequired(String symbol, bool required) {
    _setAutoSubscriptionRequired(
      _positionSubscriptionSymbols,
      symbol,
      required,
    );
  }

  void _setAutoSubscriptionRequired(
    Set<String> requirements,
    String symbol,
    bool required,
  ) {
    final wantedBefore = _wantsSubscription(symbol);
    if (required) {
      requirements.add(symbol);
    } else {
      requirements.remove(symbol);
    }
    final wantedNow = _wantsSubscription(symbol);
    if (wantedBefore != wantedNow) _bumpSubscriptionIntent(symbol);
    if (wantedNow) {
      // ignore: discarded_futures
      _ensureInstrumentSubscribed(symbol, addToDesired: false);
    } else if (wantedBefore) {
      // ignore: discarded_futures
      _unsubscribeCurrentSymbol(symbol);
    }
  }

  Future<Order?> addProtectionOrder(
    PositionVM p, {
    required String type,
    double? triggerPrice,
    double? limitPrice,
    double? trailingOffset,
    double? percentage,
    double? amount,
    double? nativeApiAmount,
    bool isQuoteCurrency = false,
    String triggerSource = 'last_price',
  }) async {
    return _service.placeConditionalOrderForPosition(
      p.position.instrumentName,
      type: type,
      triggerPrice: triggerPrice,
      limitPrice: limitPrice,
      trailingOffset: trailingOffset,
      percentage: percentage,
      amount: amount,
      nativeApiAmount: nativeApiAmount,
      isQuoteCurrency: isQuoteCurrency,
      triggerSource: triggerSource,
    );
  }

  Future<Order?> placeBreakevenStop(PositionVM p) async {
    final pair = findTradingPairVm(p.position.instrumentName)?.pair;
    if (pair == null || !pair.isVerified) {
      throw StateError('Instrument metadata unavailable');
    }
    final entry = p.position.averagePrice;
    final triggerPrice = dToDouble(
      roundToTick(dFrom(entry), dFrom(pair.tickSizeAt(entry))),
    );
    // Round the volume-weighted entry to the exchange's accepted price precision.
    return addProtectionOrder(
      p,
      type: 'stop_market',
      triggerPrice: triggerPrice,
      percentage: 100.0,
      triggerSource: 'last_price',
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _marketCacheSaveTimer?.cancel();
    _lifecycleGeneration++;
    _connectionOperationGeneration++;
    _authenticationOperationGeneration++;
    _authenticationFuture = null;
    _accountStateGeneration++;
    _connectionRequested = false;
    _markSettingsReady();
    isConnected = false;
    isAuthenticated = false;
    _statusSub?.cancel();
    _bookSub?.cancel();
    _tickerSub?.cancel();
    _orderSub?.cancel();
    _posSub?.cancel();
    _announcementSub?.cancel();
    _instrumentSub?.cancel();
    _stopAccountAutoRefresh();
    _stopOrdersAutoRefresh();
    for (final timer in _subscriptionRetryTimers.values) {
      timer.cancel();
    }
    _subscriptionRetryTimers.clear();
    _subscriptionRetryAttempts.clear();
    // ignore: discarded_futures
    MobileConnectionKeepAlive.stop();
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void clearLogs() {
    statusMessages.clear();
    notifyListeners();
  }

  Future<void> refreshOpenOrders() async {
    if (!isAuthenticated) return;
    if (loadingOpenOrders) return;
    loadingOpenOrders = true;
    notifyListeners();
    try {
      await _service.refreshOpenOrders();
    } catch (_) {}
    loadingOpenOrders = false;
    notifyListeners();
  }

  double? getAccountEntityForCurrency(String currency) {
    final normalizedCurrency = currency.trim().toUpperCase();
    if (normalizedCurrency.isEmpty) return null;
    final metrics = _accountMetrics[normalizedCurrency];
    if (metrics == null) {
      // refresh in background and return null for now
      // ignore: discarded_futures
      ensureAccountMetricsForCurrency(normalizedCurrency);
      return null;
    }
    if (metrics.isExpired(_accountMetricsTtl)) {
      // refresh in background but keep using stale value for estimation
      // ignore: discarded_futures
      ensureAccountMetricsForCurrency(normalizedCurrency);
    }

    return metrics.equity;
  }
}
