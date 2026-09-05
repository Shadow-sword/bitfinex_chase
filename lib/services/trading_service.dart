import 'dart:async';
import 'dart:collection';

import '../models/market_data.dart';
import '../models/account.dart';
import '../models/announcement.dart';
import '../models/trading_pair.dart';
import 'bitfinex_api_service.dart';
import 'package:decimal/decimal.dart';
import '../utils/decimal_utils.dart';
import '../utils/order_amount_conversion.dart';
import '../models/address_book.dart';
import '../models/withdrawal.dart';
import 'notification_service.dart';

class TradingService {
  final BitfinexApiService _api;
  final Duration _chasingInterval;

  TradingService({
    BitfinexApiService? api,
    Duration chasingInterval = const Duration(seconds: 1),
  }) : _api = api ?? BitfinexApiService(),
       _chasingInterval = chasingInterval;

  bool _connected = false;
  bool _authenticated = false;
  bool _disposed = false;
  int _sessionGeneration = 0;
  int _connectionRequestGeneration = 0;
  Future<void> _connectionQueue = Future<void>.value();
  bool _requestedIsTestnet = true;
  bool get isConnected => _connected;
  bool get isAuthenticated => _authenticated;

  final Map<String, OrderBookData> _orderBooks = {};
  final Map<String, TickerData> _tickers = {};
  final Map<String, Order> _activeOrders = {};
  final Map<String, Position> _positions = {};
  final Map<String, double> _initialOrderPrices = {};
  final Map<String, TradingPair> _verifiedInstruments = {};
  int _instrumentTrustGeneration = 0;
  final Map<String, int> _instrumentRequestGenerations = {};
  int _nextInstrumentRequestOwner = 0;
  final Map<String, Set<int>> _instrumentRequestOwners = {};
  final Set<String> _loggedExecutions = {};
  double _maxSpreadPercent = 0.8;
  List<TradingPair> _customPairs = const [];

  final _statusController = StreamController<String>.broadcast();
  final _orderBookController = StreamController<OrderBookData>.broadcast();
  final _orderController = StreamController<Order>.broadcast();
  final _positionController = StreamController<Position>.broadcast();
  final _tickerController = StreamController<TickerData>.broadcast();
  final _announcementController =
      StreamController<AnnouncementEvent>.broadcast();
  final _instrumentController = StreamController<TradingPair>.broadcast();

  Stream<String> get statusStream => _statusController.stream;
  Stream<OrderBookData> get orderBookStream => _orderBookController.stream;
  Stream<Order> get orderStream => _orderController.stream;
  Stream<Position> get positionStream => _positionController.stream;
  Stream<TickerData> get tickerStream => _tickerController.stream;
  Stream<AnnouncementEvent> get announcementStream =>
      _announcementController.stream;
  Stream<TradingPair> get instrumentStream => _instrumentController.stream;
  bool isInstrumentVerified(String symbol) =>
      _connected && _verifiedInstruments.containsKey(_normalizeSymbol(symbol));
  bool hasActiveRiskForInstrument(String symbol) {
    final normalized = _normalizeSymbol(symbol);
    return _activeOrders.values.any(
          (order) =>
              order.isActive &&
              _normalizeSymbol(order.instrumentName) == normalized,
        ) ||
        (_positions[normalized]?.size ?? 0) != 0;
  }

  List<Order> get activeOrdersSnapshot =>
      List.unmodifiable(_activeOrders.values);
  List<Position> get positionsSnapshot => List.unmodifiable(_positions.values);
  bool isPublicFeedSubscribed(String symbol) =>
      _publicSubscriptions[_normalizeSymbol(symbol)]?.isSubscribed ?? false;
  int get subscriptionStateCount =>
      _publicSubscriptions.length + _privateSubscriptions.length;
  int get instrumentRequestStateCount => _instrumentRequestGenerations.length;
  int get trackedOrderLifecycleEntryCount =>
      _closedOrderIds.length +
      _orderUpdateTimestamps.length +
      _chasingIntentGenerations.length;

  StreamSubscription? _subBook;
  StreamSubscription? _subOrder;
  StreamSubscription? _subPos;
  StreamSubscription? _subTicker;
  StreamSubscription? _subUser;
  StreamSubscription? _subAnnouncement;
  StreamSubscription? _subConn;
  StreamSubscription? _subDisc;
  Timer? _chasingTimer;
  final Set<String> _chasedOrderIds = {};
  final Set<String> _chasingEditsInFlight = {};
  final Map<String, int> _chasingIntentGenerations = {};
  int _nextChasingIntentGeneration = 0;
  final Map<String, int> _orderUpdateTimestamps = {};
  final Set<String> _closedOrderIds = {};
  static const int maxClosedOrderTombstones = 2048;
  final ListQueue<(String, int)> _closedOrderTombstoneQueue = ListQueue();
  final Map<String, int> _closedOrderTombstoneTokens = {};
  int _nextClosedOrderTombstoneToken = 0;
  final Set<String> _autoPublicOrderFeedSymbols = {};
  final Set<String> _autoPrivateOrderFeedSymbols = {};
  final Map<String, _PublicSubscriptionState> _publicSubscriptions = {};
  final Map<String, _PrivateSubscriptionState> _privateSubscriptions = {};
  final Set<String> _retiringInstruments = {};
  final Map<String, int> _instrumentWritesInFlight = {};
  final Map<String, int> _riskGenerations = {};
  int _nextRiskGeneration = 0;
  final Set<String> _loggedTrades = {};

  Future<void> connect({bool isTestnet = true}) async {
    if (_disposed) return;
    final requestGeneration = ++_connectionRequestGeneration;
    _requestedIsTestnet = isTestnet;
    _invalidateInstrumentTrust('connection changed');
    _connected = false;
    _authenticated = false;
    final request = _connectionQueue.then((_) async {
      if (!_isCurrentConnectionRequest(requestGeneration, isTestnet)) {
        return;
      }
      await _performConnect(
        isTestnet: isTestnet,
        requestGeneration: requestGeneration,
      );
    });
    _connectionQueue = request.catchError((_) {});
    await request;
  }

  bool _isCurrentConnectionRequest(int requestGeneration, bool isTestnet) =>
      !_disposed &&
      requestGeneration == _connectionRequestGeneration &&
      isTestnet == _requestedIsTestnet;

  Future<void> _performConnect({
    required bool isTestnet,
    required int requestGeneration,
  }) async {
    await _subBook?.cancel();
    await _subOrder?.cancel();
    await _subPos?.cancel();
    await _subTicker?.cancel();
    await _subConn?.cancel();
    await _subDisc?.cancel();
    await _subUser?.cancel();
    await _subAnnouncement?.cancel();
    _autoPublicOrderFeedSymbols.clear();
    _autoPrivateOrderFeedSymbols.clear();
    _invalidateSubscriptionStates();

    await _api.connect(isTestnet: isTestnet);
    if (!_isCurrentConnectionRequest(requestGeneration, isTestnet)) {
      await _api.disconnect();
      return;
    }
    _connected = _api.isConnected;
    if (_connected) {
      _status('Connected (${isTestnet ? 'Paper' : 'Live'})');
    } else {
      _status('Disconnected: connection failed');
    }

    _subConn = _api.connected.listen((_) {
      if (_disposed || requestGeneration != _connectionRequestGeneration) {
        return;
      }
      _invalidateInstrumentTrust('reconnected');
      _connected = true;
      _authenticated = false;
      _status('Connected');
      // ignore: discarded_futures
      // No Bitfinex announcements channel.
      // ignore: discarded_futures
      refreshInstrumentMetadata();
    });
    _subDisc = _api.disconnected.listen((reason) {
      if (_disposed || requestGeneration != _connectionRequestGeneration) {
        return;
      }
      _connected = false;
      _authenticated = false;
      _autoPublicOrderFeedSymbols.clear();
      _autoPrivateOrderFeedSymbols.clear();
      _invalidateInstrumentTrust('disconnected');
      _status('Disconnected: $reason');
    });

    _subBook = _api.orderBookStream.listen((ob) {
      if (_disposed || !_connected) return;
      _orderBooks[_normalizeSymbol(ob.instrumentName)] = ob;
      _emit(_orderBookController, ob);
    });
    _subTicker = _api.tickerStream.listen((t) {
      if (_disposed || !_connected) return;
      _tickers[_normalizeSymbol(t.instrumentName)] = t;
      _emit(_tickerController, t);
    });
    _subOrder = _api.orderStream.listen((o) {
      if (_disposed || !_authenticated) return;
      if (o.isActive) {
        _trackActiveOrder(o);
      } else {
        _recordClosedOrder(o);
        _removeActiveOrder(o.orderId, instrumentName: o.instrumentName);
        _emit(_orderController, o);
      }

      // Log order executions to status/logs once
      if (o.orderState == 'filled' && !_loggedExecutions.contains(o.orderId)) {
        _loggedExecutions.add(o.orderId);
        final side = o.direction;
        final inst = o.instrumentName;
        final amt = o.amount
            .toStringAsFixed(8)
            .replaceFirst(RegExp(r'\.?0+$'), '');
        final px = (o.averageExecutedPrice ?? o.price)
            .toStringAsFixed(8)
            .replaceFirst(RegExp(r'\.?0+$'), '');
        _status('Order executed: $inst $side $amt @ $px');
        // Fire a cross-platform desktop notification
        // Note: initialization is done at app startup (main.dart)
        // ignore: discarded_futures
        AppNotificationService.instance.showOrderFilled(o);
      }
    });
    _subPos = _api.positionStream.listen((p) {
      if (_disposed || !_authenticated) return;
      final symbol = _normalizeSymbol(p.instrumentName);
      _updatePositionRisk(symbol, p);
      _emit(_positionController, p);
      // Ensure we receive live mark updates for any instrument with positions
      _ensureFeedsForRestoredOrder(symbol);
    });

    // Also listen to user changes to detect trade executions (fills)
    _subUser = _api.userChangesStream.listen((uc) {
      if (_disposed || !_authenticated) return;
      for (final t in uc.trades) {
        if (t.tradeId.isEmpty) continue;
        if (_loggedTrades.add(t.tradeId)) {
          final side = t.direction;
          final inst = t.instrumentName;
          final amt = t.amount
              .toStringAsFixed(8)
              .replaceFirst(RegExp(r'\.?0+$'), '');
          final px = t.price.toStringAsFixed(4);
          _status('Trade executed: $inst $side $amt @ $px');
        }
      }
    });
    _subAnnouncement = _api.announcementStream.listen(
      (event) => _emit(_announcementController, event),
    );
    if (_connected) {
      // No Bitfinex announcements channel.
      await refreshInstrumentMetadata();
    }
  }

  void _invalidateInstrumentTrust(String reason) {
    if (_disposed) return;
    _sessionGeneration++;
    _instrumentTrustGeneration++;
    final previouslyVerified = _verifiedInstruments.values.toList();
    _verifiedInstruments.clear();
    _instrumentRequestGenerations.clear();
    _instrumentRequestOwners.clear();
    _authenticated = false;
    _orderBooks.clear();
    _tickers.clear();
    _clearLocalRiskState();
    _initialOrderPrices.clear();
    _autoPublicOrderFeedSymbols.clear();
    _autoPrivateOrderFeedSymbols.clear();
    _invalidateSubscriptionStates();
    _closedOrderIds.clear();
    _orderUpdateTimestamps.clear();
    _closedOrderTombstoneQueue.clear();
    _closedOrderTombstoneTokens.clear();
    _loggedExecutions.clear();
    _loggedTrades.clear();
    _chasingEditsInFlight.clear();
    _chasingIntentGenerations.clear();
    if (_chasedOrderIds.isNotEmpty) {
      _chasedOrderIds.clear();
      _chasingTimer?.cancel();
      _chasingTimer = null;
      _status('Chasing stopped: instrument metadata is unverified ($reason)');
    }
    for (final pair in previouslyVerified) {
      _emitInstrumentDowngrade(pair.symbol, cached: pair);
    }
  }

  void _emit<T>(StreamController<T> controller, T event) {
    if (!_disposed && !controller.isClosed) controller.add(event);
  }

  void _emitInstrumentDowngrade(String symbol, {TradingPair? cached}) {
    final normalized = _normalizeSymbol(symbol);
    if (normalized.isEmpty) return;
    final source = cached ?? _configuredPair(normalized);
    final pair = source == null
        ? TradingPair.unverified(normalized)
        : TradingPair.fromMap({...source.toMap(), 'symbol': normalized});
    _emit(_instrumentController, pair);
  }

  String _normalizeSymbol(String symbol) => TradingPair.canonicalSymbol(symbol);

  Future<List<TradingPair>> refreshInstrumentMetadata({
    Iterable<String>? symbols,
  }) async {
    if (!_connected) return const [];
    final generation = _instrumentTrustGeneration;
    final configured =
        symbols ??
        [
          ...TradingPair.defaultPairs(
            paper: _requestedIsTestnet,
          ).map((pair) => pair.symbol),
          ..._customPairs.map((pair) => pair.symbol),
        ];
    final refreshed = <TradingPair>[];
    for (final rawSymbol in configured.toSet()) {
      final symbol = _normalizeSymbol(rawSymbol);
      if (symbol.isEmpty) continue;
      final requestGeneration =
          (_instrumentRequestGenerations[symbol] ?? 0) + 1;
      _instrumentRequestGenerations[symbol] = requestGeneration;
      final requestOwner = _beginInstrumentRequest(symbol);
      try {
        final official = await _api.getInstrument(symbol);
        if (!_isCurrentInstrumentRequest(
          symbol,
          generation,
          requestGeneration,
          requireConfigured: true,
        )) {
          continue;
        }
        if (official == null || !official.isVerified) {
          _downgradeInstrument(symbol, reason: 'metadata refresh failed');
          _status('Instrument metadata unavailable for $symbol');
          continue;
        }
        final cached = _configuredPair(symbol);
        final pair = official.withMaxPriceDeviationPercent(
          cached?.maxPriceDeviationPercent ?? official.maxPriceDeviationPercent,
        );
        _verifiedInstruments[symbol] = pair;
        refreshed.add(pair);
        _emit(_instrumentController, pair);
      } catch (e) {
        if (!_isCurrentInstrumentRequest(
          symbol,
          generation,
          requestGeneration,
          requireConfigured: true,
        )) {
          continue;
        }
        _downgradeInstrument(symbol, reason: 'metadata refresh failed');
        _status('Instrument metadata refresh failed for $symbol: $e');
      } finally {
        _endInstrumentRequest(symbol, requestOwner);
      }
    }
    return refreshed;
  }

  Future<TradingPair?> loadInstrument(
    String symbol, {
    double maxPriceDeviationPercent = 0.3,
  }) async {
    final normalized = _normalizeSymbol(symbol);
    if (!_connected) {
      _status('Connect before loading instrument metadata');
      return null;
    }
    final generation = _instrumentTrustGeneration;
    final requestGeneration =
        (_instrumentRequestGenerations[normalized] ?? 0) + 1;
    _instrumentRequestGenerations[normalized] = requestGeneration;
    final requestOwner = _beginInstrumentRequest(normalized);
    try {
      final official = await _api.getInstrument(normalized);
      if (!_isCurrentInstrumentRequest(
        normalized,
        generation,
        requestGeneration,
      )) {
        _status('Instrument metadata load cancelled for $normalized');
        return null;
      }
      if (official == null || !official.isVerified) {
        _downgradeInstrument(normalized, reason: 'metadata load failed');
        _status('Instrument metadata unavailable for $normalized');
        return null;
      }
      final pair = official.withMaxPriceDeviationPercent(
        maxPriceDeviationPercent,
      );
      _verifiedInstruments[normalized] = pair;
      _emit(_instrumentController, pair);
      return pair;
    } catch (e) {
      if (!_isCurrentInstrumentRequest(
        normalized,
        generation,
        requestGeneration,
      )) {
        return null;
      }
      _downgradeInstrument(normalized, reason: 'metadata load failed');
      _status('Instrument metadata refresh failed for $normalized: $e');
      return null;
    } finally {
      _endInstrumentRequest(normalized, requestOwner);
    }
  }

  int _beginInstrumentRequest(String symbol) {
    final owner = ++_nextInstrumentRequestOwner;
    _instrumentRequestOwners.putIfAbsent(symbol, () => <int>{}).add(owner);
    return owner;
  }

  void _endInstrumentRequest(String symbol, int owner) {
    final owners = _instrumentRequestOwners[symbol];
    if (owners == null || !owners.remove(owner)) return;
    if (owners.isNotEmpty) return;
    if (identical(_instrumentRequestOwners[symbol], owners)) {
      _instrumentRequestOwners.remove(symbol);
    }
    if (!_allowedInstrumentSymbols().contains(symbol) &&
        !_verifiedInstruments.containsKey(symbol) &&
        !_instrumentRequestOwners.containsKey(symbol)) {
      _instrumentRequestGenerations.remove(symbol);
    }
  }

  bool _isCurrentInstrumentRequest(
    String symbol,
    int trustGeneration,
    int requestGeneration, {
    bool requireConfigured = false,
  }) =>
      !_disposed &&
      _connected &&
      trustGeneration == _instrumentTrustGeneration &&
      _instrumentRequestGenerations[symbol] == requestGeneration &&
      (!requireConfigured || _allowedInstrumentSymbols().contains(symbol));

  Set<String> _allowedInstrumentSymbols() => {
    ...TradingPair.defaultPairs(
      paper: _requestedIsTestnet,
    ).map((pair) => _normalizeSymbol(pair.symbol)),
    ..._customPairs.map((pair) => _normalizeSymbol(pair.symbol)),
    ..._activeOrders.values.map(
      (order) => _normalizeSymbol(order.instrumentName),
    ),
    ..._positions.keys,
  };

  void removeInstrument(String symbol) {
    final normalized = _normalizeSymbol(symbol);
    if (normalized.isEmpty) return;
    _instrumentRequestGenerations[normalized] =
        (_instrumentRequestGenerations[normalized] ?? 0) + 1;
    _downgradeInstrument(
      normalized,
      reason: 'instrument removed from settings',
    );
    if (!_instrumentRequestOwners.containsKey(normalized)) {
      _instrumentRequestGenerations.remove(normalized);
    }
  }

  Future<bool> retireInstrumentIfSafe(String symbol) async {
    final normalized = _normalizeSymbol(symbol);
    if (!_connected ||
        !_authenticated ||
        !_allowedInstrumentSymbols().contains(normalized) ||
        (_instrumentWritesInFlight[normalized] ?? 0) > 0 ||
        !_retiringInstruments.add(normalized)) {
      return false;
    }
    final generation = _sessionGeneration;
    final riskGeneration = _riskGenerations[normalized] ?? 0;
    final pair = getTradingPairBySymbol(normalized, _customPairs);
    final requiresPositionCheck = pair?.type != TradingPairType.spot;
    try {
      final openOrders = await _api.getOpenOrdersByInstrument(normalized);
      if (!_isRetirementStillSafe(normalized, generation, riskGeneration) ||
          openOrders.any((order) => order.isActive)) {
        return false;
      }
      if (requiresPositionCheck) {
        final position = await _api.getPosition(normalized);
        if (!_isRetirementStillSafe(normalized, generation, riskGeneration) ||
            (position?.size ?? 0) != 0) {
          return false;
        }
      }

      // A second order query narrows the window in which an order can appear
      // between the first order query and the position query.
      final finalOpenOrders = await _api.getOpenOrdersByInstrument(normalized);
      if (finalOpenOrders.any((order) => order.isActive) ||
          !_isRetirementStillSafe(normalized, generation, riskGeneration)) {
        return false;
      }

      final publicState = _publicSubscriptions[normalized];
      final restorePublic =
          publicState?.desired == true ||
          publicState?.bookSubscribed == true ||
          publicState?.tickerSubscribed == true;
      final privateState = _privateSubscriptions[normalized];
      final restorePrivate =
          privateState?.desired == true || privateState?.subscribed == true;
      final privateInterval = privateState?.actualInterval.isNotEmpty == true
          ? privateState!.actualInterval
          : privateState?.desiredInterval ?? '100ms';
      try {
        await unsubscribeFromInstrument(normalized);
        await unsubscribeUserChanges(normalized, interval: privateInterval);
      } catch (error) {
        _status('Feed cleanup failed while retiring $normalized: $error');
        await _restoreRetirementSubscriptions(
          normalized,
          restorePublic: restorePublic,
          restorePrivate: restorePrivate,
          privateInterval: privateInterval,
        );
        return false;
      }

      if (!_isRetirementStillSafe(normalized, generation, riskGeneration)) {
        await _restoreRetirementSubscriptions(
          normalized,
          restorePublic: restorePublic,
          restorePrivate: restorePrivate,
          privateInterval: privateInterval,
        );
        return false;
      }

      // Keep this final commit path synchronous: no event can interleave after
      // the last risk validation and before the successful return.
      _commitRetiredInstrument(normalized);
      return true;
    } catch (error) {
      _status('Cannot retire $normalized safely: $error');
      return false;
    } finally {
      _retiringInstruments.remove(normalized);
    }
  }

  Future<void> _restoreRetirementSubscriptions(
    String symbol, {
    required bool restorePublic,
    required bool restorePrivate,
    required String privateInterval,
  }) async {
    if (restorePublic && _connected) {
      try {
        await subscribeToInstrument(symbol);
      } catch (error) {
        _status('Public feed restore failed for $symbol: $error');
      }
    }
    if (restorePrivate && _authenticated) {
      try {
        await subscribeToUserChanges(symbol, interval: privateInterval);
      } catch (error) {
        _status('Private feed restore failed for $symbol: $error');
      }
    }
  }

  void _commitRetiredInstrument(String symbol) {
    removeInstrument(symbol);
    final publicState = _publicSubscriptions.remove(symbol);
    if (publicState != null) {
      for (final waiter in publicState.waiters) {
        if (!waiter.isCompleted) waiter.complete();
      }
      publicState.waiters.clear();
    }
    final privateState = _privateSubscriptions.remove(symbol);
    if (privateState != null) {
      for (final waiter in privateState.waiters) {
        if (!waiter.isCompleted) waiter.complete();
      }
      privateState.waiters.clear();
    }
    _autoPublicOrderFeedSymbols.remove(symbol);
    _autoPrivateOrderFeedSymbols.remove(symbol);
  }

  bool _isRetirementStillSafe(
    String symbol,
    int sessionGeneration,
    int riskGeneration,
  ) =>
      _retiringInstruments.contains(symbol) &&
      _isCurrentPrivateOperation(sessionGeneration) &&
      (_instrumentWritesInFlight[symbol] ?? 0) == 0 &&
      (_riskGenerations[symbol] ?? 0) == riskGeneration &&
      !hasActiveRiskForInstrument(symbol);

  Future<T?> _runInstrumentWrite<T>(
    String instrumentName,
    Future<T?> Function() action,
  ) async {
    final symbol = _normalizeSymbol(instrumentName);
    if (_retiringInstruments.contains(symbol)) {
      _status('Cannot write $symbol while it is being retired');
      return null;
    }
    _instrumentWritesInFlight[symbol] =
        (_instrumentWritesInFlight[symbol] ?? 0) + 1;
    try {
      return await action();
    } catch (e) {
      _status('Trade request failed for $symbol: $e');
      rethrow;
    } finally {
      final remaining = (_instrumentWritesInFlight[symbol] ?? 1) - 1;
      if (remaining > 0) {
        _instrumentWritesInFlight[symbol] = remaining;
      } else {
        _instrumentWritesInFlight.remove(symbol);
      }
    }
  }

  void _downgradeInstrument(String symbol, {required String reason}) {
    final normalized = _normalizeSymbol(symbol);
    final previous = _verifiedInstruments.remove(normalized);
    _stopChasingForInstrument(normalized, reason: reason);
    _emitInstrumentDowngrade(normalized, cached: previous);
  }

  Future<void> disconnect() async {
    if (_disposed) return;
    _connectionRequestGeneration++;
    _invalidateInstrumentTrust('disconnected');
    _connected = false;
    _authenticated = false;
    await _api.disconnect();
    if (_disposed) return;
    _connected = false;
    _authenticated = false;
    _status('Disconnected');
    _chasingTimer?.cancel();
    _autoPublicOrderFeedSymbols.clear();
    _autoPrivateOrderFeedSymbols.clear();
  }

  Future<bool> ensureConnected() async {
    if (_disposed) return false;
    final generation = _sessionGeneration;
    final wasConnected = _connected;
    try {
      final connected = await _api.ensureConnected();
      if (_disposed || generation != _sessionGeneration) return false;
      _connected = connected;
      if (!connected) {
        _authenticated = false;
        _invalidateInstrumentTrust('connection check failed');
      } else if (!wasConnected) {
        _authenticated = false;
        _invalidateInstrumentTrust('connection restored');
        _connected = true;
        await refreshInstrumentMetadata();
      } else {
        // connected && wasConnected: reused an existing healthy socket (mobile
        // resume). Re-issue subscriptions so book/ticker/user.changes resume
        // streaming, without disturbing chase selections or instrument trust.
        await _resubscribeExistingFeeds();
      }
      return connected;
    } catch (_) {
      if (!_disposed && generation == _sessionGeneration) {
        _connected = false;
        _authenticated = false;
        _invalidateInstrumentTrust('connection check failed');
      }
      rethrow;
    }
  }

  Future<bool> authenticate(String clientId, String clientSecret) async {
    final generation = _beginPrivateSession();
    if (!_connected) {
      _status('Please connect first');
      return false;
    }
    final bool ok;
    try {
      ok = await _api.authenticate(clientId, clientSecret);
    } catch (e) {
      _status('Authentication failed: $e');
      return false;
    }
    if (_disposed ||
        generation != _sessionGeneration ||
        !_connected ||
        !_api.isConnected) {
      return false;
    }
    if (!ok) {
      _status('Authentication failed');
      return false;
    }
    _authenticated = true;
    _status('Authenticated successfully');
    await _loadOpenOrdersAndPositions(generation);
    return _isCurrentPrivateOperation(generation);
  }

  int _beginPrivateSession() {
    final generation = ++_sessionGeneration;
    _authenticated = false;
    _clearLocalRiskState();
    _initialOrderPrices.clear();
    _invalidatePrivateSubscriptionStates();
    _closedOrderIds.clear();
    _orderUpdateTimestamps.clear();
    _closedOrderTombstoneQueue.clear();
    _closedOrderTombstoneTokens.clear();
    _loggedExecutions.clear();
    _loggedTrades.clear();
    _chasingEditsInFlight.clear();
    _chasingIntentGenerations.clear();
    _chasedOrderIds.clear();
    _chasingTimer?.cancel();
    _chasingTimer = null;
    return generation;
  }

  void _status(String message) {
    _emit(_statusController, message);
  }

  TradingPair? _configuredPair(String symbol) {
    final normalized = _normalizeSymbol(symbol);
    for (final pair in [
      ...TradingPair.defaultPairs(paper: _requestedIsTestnet),
      ..._customPairs,
    ]) {
      if (_normalizeSymbol(pair.symbol) == normalized) return pair;
    }
    return null;
  }

  TradingPair? _requireVerifiedInstrument(String symbol, String action) {
    final normalized = _normalizeSymbol(symbol);
    final pair = _verifiedInstruments[normalized];
    if (!_connected ||
        !_authenticated ||
        pair == null ||
        _retiringInstruments.contains(normalized)) {
      _status(
        'Cannot $action $symbol: verified instrument metadata unavailable',
      );
      _stopChasingForInstrument(symbol, reason: 'metadata is unverified');
      return null;
    }
    return pair;
  }

  bool _isCurrentWrite(int generation, String symbol) =>
      _isCurrentPrivateOperation(generation) &&
      _verifiedInstruments.containsKey(_normalizeSymbol(symbol)) &&
      !_retiringInstruments.contains(_normalizeSymbol(symbol));

  bool _isCurrentPrivateOperation(int generation) =>
      !_disposed &&
      generation == _sessionGeneration &&
      _connected &&
      _authenticated;

  bool _isCurrentPublicOperation(int generation) =>
      !_disposed && generation == _connectionRequestGeneration && _connected;

  void _stopChasingForInstrument(String symbol, {required String reason}) {
    final normalized = _normalizeSymbol(symbol);
    final stopped = _chasedOrderIds.where((id) {
      return _normalizeSymbol(_activeOrders[id]?.instrumentName ?? '') ==
          normalized;
    }).toList();
    if (stopped.isEmpty) return;
    _chasedOrderIds.removeAll(stopped);
    for (final id in stopped) {
      _bumpChasingIntent(id);
      _chasingIntentGenerations.remove(id);
    }
    _status('Chasing stopped for $normalized: $reason');
    if (_chasedOrderIds.isEmpty) {
      _chasingTimer?.cancel();
      _chasingTimer = null;
    }
  }

  Future<void> subscribeToInstrument(String instrumentName) async {
    if (!_connected) {
      _status('Please connect first');
      return;
    }
    final symbol = _normalizeSymbol(instrumentName);
    await _setPublicSubscriptionDesired(symbol, true);
    _status('Subscribed to $symbol order book');
  }

  Future<void> subscribeToUserChanges(
    String instrumentName, {
    String interval = '100ms',
  }) async {
    if (!_authenticated) {
      _status('Please authenticate first');
      return;
    }
    final symbol = _normalizeSymbol(instrumentName);
    await _setPrivateSubscriptionDesired(symbol, true, interval: interval);
    _status('Subscribed to user changes for $symbol');
  }

  Future<void> unsubscribeFromInstrument(String instrumentName) async {
    if (!_connected) {
      _status('Please connect first');
      return;
    }
    final symbol = _normalizeSymbol(instrumentName);
    await _setPublicSubscriptionDesired(symbol, false);
    _status('Unsubscribed from $symbol');
  }

  Future<void> unsubscribeUserChanges(
    String instrumentName, {
    String interval = '100ms',
  }) async {
    if (!_authenticated) {
      _status('Please authenticate first');
      return;
    }
    final symbol = _normalizeSymbol(instrumentName);
    await _setPrivateSubscriptionDesired(symbol, false, interval: interval);
    _status('Unsubscribed user changes for $symbol');
  }

  Future<void> _setPublicSubscriptionDesired(String symbol, bool desired) {
    final state = _publicSubscriptions.putIfAbsent(
      symbol,
      _PublicSubscriptionState.new,
    );
    state.desired = desired;
    final waiter = Completer<void>();
    state.waiters.add(waiter);
    state.runner ??= _runPublicSubscription(
      symbol,
      state,
      _connectionRequestGeneration,
    );
    return waiter.future;
  }

  Future<void> _runPublicSubscription(
    String symbol,
    _PublicSubscriptionState state,
    int generation,
  ) async {
    Object? failure;
    StackTrace? failureStack;
    try {
      while (_isCurrentPublicSubscriptionState(symbol, state, generation)) {
        if (state.desired) {
          if (!state.bookSubscribed) {
            await _api.subscribeOrderBook(symbol);
            if (!_isCurrentPublicSubscriptionState(symbol, state, generation)) {
              break;
            }
            state.bookSubscribed = true;
            _syncPublicSubscription(symbol, state);
            continue;
          }
          if (!state.tickerSubscribed) {
            await _api.subscribeTicker(symbol);
            if (!_isCurrentPublicSubscriptionState(symbol, state, generation)) {
              break;
            }
            state.tickerSubscribed = true;
            _syncPublicSubscription(symbol, state);
            continue;
          }
        } else {
          if (state.tickerSubscribed) {
            await _api.unsubscribeTicker(symbol);
            if (!_isCurrentPublicSubscriptionState(symbol, state, generation)) {
              break;
            }
            state.tickerSubscribed = false;
            _syncPublicSubscription(symbol, state);
            continue;
          }
          if (state.bookSubscribed) {
            await _api.unsubscribeOrderBook(symbol);
            if (!_isCurrentPublicSubscriptionState(symbol, state, generation)) {
              break;
            }
            state.bookSubscribed = false;
            _syncPublicSubscription(symbol, state);
            continue;
          }
        }
        break;
      }
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
      _status('${state.desired ? 'Subscribe' : 'Unsubscribe'} failed: $error');
    } finally {
      state.runner = null;
      final waiters = List<Completer<void>>.of(state.waiters);
      state.waiters.clear();
      for (final waiter in waiters) {
        if (waiter.isCompleted) continue;
        if (failure == null) {
          waiter.complete();
        } else {
          waiter.completeError(failure, failureStack);
        }
      }
      _prunePublicSubscription(symbol, state);
    }
  }

  bool _isCurrentPublicSubscriptionState(
    String symbol,
    _PublicSubscriptionState state,
    int generation,
  ) =>
      _isCurrentPublicOperation(generation) &&
      identical(_publicSubscriptions[symbol], state);

  void _syncPublicSubscription(String symbol, _PublicSubscriptionState state) {
    if (state.isSubscribed) {
      _autoPublicOrderFeedSymbols.add(symbol);
    } else {
      _autoPublicOrderFeedSymbols.remove(symbol);
    }
  }

  void _prunePublicSubscription(String symbol, _PublicSubscriptionState state) {
    if (!identical(_publicSubscriptions[symbol], state)) return;
    _syncPublicSubscription(symbol, state);
    if (!state.desired &&
        !state.bookSubscribed &&
        !state.tickerSubscribed &&
        state.runner == null &&
        state.waiters.isEmpty) {
      if (identical(_publicSubscriptions[symbol], state)) {
        _publicSubscriptions.remove(symbol);
      }
    }
  }

  Future<void> _setPrivateSubscriptionDesired(
    String symbol,
    bool desired, {
    required String interval,
  }) {
    final state = _privateSubscriptions.putIfAbsent(
      symbol,
      _PrivateSubscriptionState.new,
    );
    state.desired = desired;
    state.desiredInterval = interval;
    final waiter = Completer<void>();
    state.waiters.add(waiter);
    state.runner ??= _runPrivateSubscription(symbol, state, _sessionGeneration);
    return waiter.future;
  }

  Future<void> _runPrivateSubscription(
    String symbol,
    _PrivateSubscriptionState state,
    int generation,
  ) async {
    Object? failure;
    StackTrace? failureStack;
    try {
      while (_isCurrentPrivateSubscriptionState(symbol, state, generation)) {
        if (state.subscribed &&
            (!state.desired || state.actualInterval != state.desiredInterval)) {
          await _api.unsubscribeUserChangesForInstrument(
            symbol,
            interval: state.actualInterval,
          );
          if (!_isCurrentPrivateSubscriptionState(symbol, state, generation)) {
            break;
          }
          state.subscribed = false;
          state.actualInterval = '';
          _autoPrivateOrderFeedSymbols.remove(symbol);
          continue;
        }
        if (state.desired && !state.subscribed) {
          final interval = state.desiredInterval;
          await _api.subscribeUserChangesForInstrument(
            symbol,
            interval: interval,
          );
          if (!_isCurrentPrivateSubscriptionState(symbol, state, generation)) {
            break;
          }
          state.subscribed = true;
          state.actualInterval = interval;
          _autoPrivateOrderFeedSymbols.add(symbol);
          continue;
        }
        break;
      }
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
      _status(
        '${state.desired ? 'Subscribe' : 'Unsubscribe'} user changes failed: $error',
      );
    } finally {
      state.runner = null;
      final waiters = List<Completer<void>>.of(state.waiters);
      state.waiters.clear();
      for (final waiter in waiters) {
        if (waiter.isCompleted) continue;
        if (failure == null) {
          waiter.complete();
        } else {
          waiter.completeError(failure, failureStack);
        }
      }
      if (identical(_privateSubscriptions[symbol], state) &&
          !state.desired &&
          !state.subscribed &&
          state.runner == null &&
          state.waiters.isEmpty) {
        if (identical(_privateSubscriptions[symbol], state)) {
          _privateSubscriptions.remove(symbol);
        }
      }
    }
  }

  bool _isCurrentPrivateSubscriptionState(
    String symbol,
    _PrivateSubscriptionState state,
    int generation,
  ) =>
      _isCurrentPrivateOperation(generation) &&
      identical(_privateSubscriptions[symbol], state);

  /// Re-issues every currently desired public (and, when authenticated,
  /// private) subscription on a reused live socket, without tearing down chase
  /// or instrument-trust state.
  ///
  /// Mobile resume can hand back a WebSocket that passed the health check but
  /// whose exchange-side channels stopped streaming while the app was
  /// suspended. The socket is alive, so no disconnect/reconnect fires and the
  /// per-channel `bookSubscribed`/`tickerSubscribed` flags stay `true`, which
  /// makes the runners skip re-subscribing. Dropping the stale subscription
  /// state and re-issuing `subscribeTo*` forces a fresh `public/subscribe`
  /// (and `private/subscribe`), restoring the `_orderBooks` data flow chasing
  /// depends on.
  ///
  /// Deliberately does NOT call [_invalidateInstrumentTrust]: that would clear
  /// `_chasedOrderIds` (dropping the user's Chase selections) and
  /// `_verifiedInstruments`. Resume must only refresh subscriptions.
  Future<void> _resubscribeExistingFeeds() async {
    if (_disposed || !_connected) return;

    // Snapshot the currently desired feeds before mutating the state maps.
    final publicSymbols = [
      for (final entry in _publicSubscriptions.entries)
        if (entry.value.desired) entry.key,
    ];
    final privateSymbols = _authenticated
        ? [
            for (final entry in _privateSubscriptions.entries)
              if (entry.value.desired) entry.key,
          ]
        : const <String>[];

    for (final symbol in publicSymbols) {
      // Drop the old subscription state so subscribeToInstrument starts a fresh
      // runner (bookSubscribed=false) that actually re-issues public/subscribe.
      // Any in-flight runner sees its state replaced and exits via its guard.
      _publicSubscriptions.remove(symbol);
      _autoPublicOrderFeedSymbols.remove(symbol);
      // Drop the stale snapshot so chasing skips (ob == null) until fresh data
      // arrives rather than repricing off a pre-suspension book.
      _orderBooks.remove(symbol);
      await subscribeToInstrument(symbol);
      if (_disposed || !_connected) return;
    }

    // Private (user.changes) only while already authenticated. Re-auth is not
    // triggered here to avoid racing an in-flight authenticate().
    for (final symbol in privateSymbols) {
      if (!_authenticated) break;
      _privateSubscriptions.remove(symbol);
      _autoPrivateOrderFeedSymbols.remove(symbol);
      await subscribeToUserChanges(symbol);
      if (_disposed || !_connected) return;
    }
  }

  void _invalidateSubscriptionStates() {
    for (final state in _publicSubscriptions.values) {
      for (final waiter in state.waiters) {
        if (!waiter.isCompleted) waiter.complete();
      }
      state.waiters.clear();
    }
    for (final state in _privateSubscriptions.values) {
      for (final waiter in state.waiters) {
        if (!waiter.isCompleted) waiter.complete();
      }
      state.waiters.clear();
    }
    _publicSubscriptions.clear();
    _privateSubscriptions.clear();
    _autoPublicOrderFeedSymbols.clear();
    _autoPrivateOrderFeedSymbols.clear();
  }

  void _invalidatePrivateSubscriptionStates() {
    for (final state in _privateSubscriptions.values) {
      for (final waiter in state.waiters) {
        if (!waiter.isCompleted) waiter.complete();
      }
      state.waiters.clear();
    }
    _privateSubscriptions.clear();
    _autoPrivateOrderFeedSymbols.clear();
  }

  void _trackActiveOrder(Order order, {bool emit = true}) {
    if (_disposed || !_authenticated || !order.isActive) return;
    final timestamp = order.lastUpdateTimestamp;
    final latestTimestamp = _orderUpdateTimestamps[order.orderId] ?? -1;
    if (_closedOrderIds.contains(order.orderId) ||
        (timestamp > 0 && timestamp < latestTimestamp)) {
      return;
    }
    _bumpRiskGeneration(order.instrumentName);
    _orderUpdateTimestamps[order.orderId] = timestamp;
    _activeOrders[order.orderId] = order;
    _initialOrderPrices[order.orderId] =
        _initialOrderPrices[order.orderId] ?? order.price;
    if (emit) _emit(_orderController, order);

    // Open orders restored after an app restart must have live book/user feeds;
    // otherwise enabling Chase can edit once and then lose the replacement order
    // event, making the Chase checkbox appear to cancel itself.
    // ignore: discarded_futures
    _ensureFeedsForRestoredOrder(order.instrumentName);
  }

  Order? _removeActiveOrder(String orderId, {String? instrumentName}) {
    final order = _activeOrders.remove(orderId);
    final riskSymbol = order?.instrumentName ?? instrumentName;
    if (riskSymbol != null) _bumpRiskGeneration(riskSymbol);
    _initialOrderPrices.remove(orderId);
    _chasedOrderIds.remove(orderId);
    _chasingEditsInFlight.remove(orderId);
    _bumpChasingIntent(orderId);
    _chasingIntentGenerations.remove(orderId);
    return order;
  }

  void _updatePositionRisk(String symbol, Position? position) {
    final normalized = _normalizeSymbol(symbol);
    if (normalized.isEmpty) return;
    _bumpRiskGeneration(normalized);
    if (position != null && position.size != 0) {
      _positions[normalized] = position;
    } else {
      _positions.remove(normalized);
    }
  }

  void _bumpRiskGeneration(String symbol) {
    final normalized = _normalizeSymbol(symbol);
    if (normalized.isEmpty) return;
    _riskGenerations[normalized] = ++_nextRiskGeneration;
  }

  void _clearLocalRiskState() {
    final symbols = <String>{
      ..._activeOrders.values.map(
        (order) => _normalizeSymbol(order.instrumentName),
      ),
      ..._positions.keys,
    }..remove('');
    for (final symbol in symbols) {
      _bumpRiskGeneration(symbol);
    }
    _activeOrders.clear();
    _positions.clear();
  }

  void _recordClosedOrder(Order order) {
    final token = ++_nextClosedOrderTombstoneToken;
    _closedOrderIds.add(order.orderId);
    _orderUpdateTimestamps[order.orderId] = order.lastUpdateTimestamp;
    _closedOrderTombstoneTokens[order.orderId] = token;
    _closedOrderTombstoneQueue.addLast((order.orderId, token));
    while (_closedOrderTombstoneQueue.length > maxClosedOrderTombstones) {
      final (orderId, queuedToken) = _closedOrderTombstoneQueue.removeFirst();
      if (_closedOrderTombstoneTokens[orderId] != queuedToken) continue;
      _closedOrderTombstoneTokens.remove(orderId);
      _closedOrderIds.remove(orderId);
      _orderUpdateTimestamps.remove(orderId);
    }
  }

  void _reopenOrder(String orderId) {
    _closedOrderIds.remove(orderId);
    _closedOrderTombstoneTokens.remove(orderId);
  }

  int _bumpChasingIntent(String orderId) =>
      _chasingIntentGenerations[orderId] = ++_nextChasingIntentGeneration;

  void _emitClosedOrder(Order order) {
    final closed = Order(
      orderId: order.orderId,
      instrumentName: order.instrumentName,
      direction: order.direction,
      amount: order.amount,
      price: order.price,
      orderState: 'closed',
      orderType: order.orderType,
      isExchange: order.isExchange,
      flags: order.flags,
      stopPrice: order.stopPrice,
      trigger: order.trigger,
      trailing: order.trailing,
      averageExecutedPrice: order.averageExecutedPrice,
      filledAmount: order.filledAmount,
      creationTimestamp: order.creationTimestamp,
      lastUpdateTimestamp: DateTime.now().millisecondsSinceEpoch,
    );
    _recordClosedOrder(closed);
    _emit(_orderController, closed);
  }

  Future<void> _ensureFeedsForRestoredOrder(
    String instrumentName, {
    bool force = false,
  }) async {
    final symbol = _normalizeSymbol(instrumentName);
    if (symbol.isEmpty || !_connected) return;
    if (!_verifiedInstruments.containsKey(symbol)) {
      await refreshInstrumentMetadata(symbols: [symbol]);
      if (!_connected || !_verifiedInstruments.containsKey(symbol)) return;
    }
    if (force) {
      _autoPublicOrderFeedSymbols.remove(symbol);
      _autoPrivateOrderFeedSymbols.remove(symbol);
    }
    if (!_autoPublicOrderFeedSymbols.contains(symbol)) {
      try {
        await subscribeToInstrument(symbol);
      } catch (e) {
        _status('Restore feed failed for $symbol: $e');
      }
    }
    if (_authenticated && !_autoPrivateOrderFeedSymbols.contains(symbol)) {
      try {
        await subscribeToUserChanges(symbol);
      } catch (e) {
        _status('Restore feed failed for $symbol: $e');
      }
    }
  }

  Future<void> refreshOpenOrders() async {
    if (!_authenticated) {
      _status('Please authenticate first');
      return;
    }
    final generation = _sessionGeneration;
    final before = Map<String, int>.of(_orderUpdateTimestamps);
    try {
      final open = await _api.getOpenOrders();
      if (!_isCurrentPrivateOperation(generation)) return;
      final ids = open.map((order) => order.orderId).toSet();
      for (final order in open) {
        _trackActiveOrder(order);
      }
      for (final id in _activeOrders.keys.toList()) {
        // An event/new order received while the snapshot was in flight wins.
        if (ids.contains(id) ||
            !before.containsKey(id) ||
            before[id] != _orderUpdateTimestamps[id]) {
          continue;
        }
        final removed = _removeActiveOrder(id);
        if (removed != null) _emitClosedOrder(removed);
      }
    } catch (e) {
      if (_isCurrentPrivateOperation(generation)) {
        _status('Refresh orders failed: $e');
      }
      rethrow;
    }
  }

  Future<Order?> placeLimitOrder(
    String instrumentName,
    String direction,
    double amount, {
    double? customPrice,
    bool enableChasing = false,
    bool postOnly = true,
    int leverage = 1,
    bool marginTrading = false,
    bool reduceOnly = false,
  }) async {
    if (enableChasing && !postOnly) {
      throw ArgumentError('Chasing requires post-only');
    }
    if (!_authenticated) {
      _status('Please authenticate first');
      return null;
    }
    final pair = _requireVerifiedInstrument(instrumentName, 'place order for');
    if (pair == null) return null;
    if (customPrice != null && (!customPrice.isFinite || customPrice <= 0)) {
      _status('Order price must be a finite number greater than 0');
      return null;
    }
    final generation = _sessionGeneration;
    final ob = _orderBooks[_normalizeSymbol(instrumentName)];
    if (ob == null) {
      _status('No order book data for $instrumentName');
      return null;
    }
    final tickD = dFrom(
      pair.tickSizeAt(ob.bestAsk > 0 ? ob.bestAsk : ob.bestBid),
    );
    final bidD = dFrom(ob.bestBid);
    final askD = dFrom(ob.bestAsk);
    final base = direction == 'buy' ? (askD - tickD) : (bidD + tickD);
    final target = customPrice != null
        ? Decimal.parse(customPrice.toString())
        : base;
    final priceD = roundToTick(target, tickD);
    final price = dToDouble(priceD);
    if (price <= 0) {
      _status('Invalid order price');
      return null;
    }
    final normalizedAmount = normalizeApiAmount(
      pair: pair,
      rawApiAmount: amount,
    );
    if (!normalizedAmount.canSubmit) {
      _status(normalizedAmount.errorMessage ?? 'Invalid order amount');
      return null;
    }

    if (!_isCurrentWrite(generation, instrumentName)) return null;
    final order = await _runInstrumentWrite(
      instrumentName,
      () => _api.placeOrder(
        instrumentName: instrumentName,
        leverage: leverage,
        marginTrading: marginTrading,
        direction: direction,
        amount: normalizedAmount.apiAmount,
        orderType: 'limit',
        price: price,
        postOnly: postOnly,
        reduceOnly: reduceOnly,
      ),
    );
    if (!_isCurrentWrite(generation, instrumentName)) return null;
    if (order != null) {
      _status(
        'Placed $direction order: ${normalizedAmount.apiAmount} @ $price',
      );
      // Immediately reflect in local state/UI
      _trackActiveOrder(order);
      if (enableChasing) {
        _enableChasingForOrder(order.orderId);
      }
    }
    return order;
  }

  Future<Order?> placeMarketOrder(
    String instrumentName,
    String direction,
    double amount, {
    int leverage = 1,
    bool marginTrading = false,
    bool reduceOnly = false,
  }) async {
    if (!_authenticated) {
      _status('Please authenticate first');
      return null;
    }
    final pair = _requireVerifiedInstrument(instrumentName, 'place order for');
    if (pair == null) return null;
    final generation = _sessionGeneration;
    final normalizedAmount = normalizeApiAmount(
      pair: pair,
      rawApiAmount: amount,
    );
    if (!normalizedAmount.canSubmit) {
      _status(normalizedAmount.errorMessage ?? 'Invalid order amount');
      return null;
    }
    final apiAmount = normalizedAmount.apiAmount;
    // For market orders, price/post_only are not used
    if (!_isCurrentWrite(generation, instrumentName)) return null;
    final order = await _runInstrumentWrite(
      instrumentName,
      () => _api.placeOrder(
        instrumentName: instrumentName,
        leverage: leverage,
        marginTrading: marginTrading,
        direction: direction,
        amount: apiAmount,
        orderType: 'market',
        postOnly: false,
        reduceOnly: reduceOnly,
      ),
    );
    if (!_isCurrentWrite(generation, instrumentName)) return null;
    if (order != null) {
      _status('Placed market $direction: $apiAmount');
      _trackActiveOrder(order);
    }
    return order;
  }

  Future<Order?> modifyOrder(
    String orderId,
    double newPrice, {
    double? newAmount,
  }) async {
    if (!_authenticated) {
      _status('Please authenticate first');
      return null;
    }
    final active = _activeOrders[orderId];
    if (active == null) {
      _status(
        'Cannot modify order $orderId: active order metadata unavailable',
      );
      return null;
    }
    final pair = _requireVerifiedInstrument(
      active.instrumentName,
      'modify order for',
    );
    if (pair == null) return null;
    if (!newPrice.isFinite || newPrice <= 0) {
      _status('Order price must be a finite number greater than 0');
      return null;
    }
    double? apiAmount;
    if (newAmount != null) {
      final normalizedAmount = normalizeApiAmount(
        pair: pair,
        rawApiAmount: newAmount,
      );
      if (!normalizedAmount.canSubmit) {
        _status(normalizedAmount.errorMessage ?? 'Invalid order amount');
        return null;
      }
      apiAmount = normalizedAmount.apiAmount;
    }
    final generation = _sessionGeneration;
    if (!_isCurrentWrite(generation, active.instrumentName)) return null;
    final order = await _runInstrumentWrite(
      active.instrumentName,
      () => _api.editOrder(orderId, newPrice, newAmount: apiAmount),
    );
    if (!_isCurrentWrite(generation, active.instrumentName) ||
        !identical(_activeOrders[orderId], active)) {
      return null;
    }
    if (order != null) _status('Modified order ${order.orderId}');
    return order;
  }

  bool _positionUsesMargin(TradingPair pair, Position position) {
    if (pair.type == TradingPairType.spot && position.kind == 'margin') {
      return true;
    }
    if (pair.type == TradingPairType.future && position.kind == 'future') {
      return false;
    }
    throw StateError(
      'Position market type does not match the verified instrument',
    );
  }

  Future<Order?> increasePosition(
    String instrumentName, {
    required String expectedDirection,
    required double amount,
    bool market = false,
    double? price,
    bool postOnly = true,
    bool enableChasing = false,
    int leverage = 1,
  }) async {
    final current = _positions[_normalizeSymbol(instrumentName)];
    if (current == null ||
        current.size == 0 ||
        current.direction != expectedDirection) {
      throw StateError(
        'Position has closed or changed direction; reopen the increase dialog',
      );
    }
    final pair = _requireVerifiedInstrument(
      instrumentName,
      'increase position for',
    );
    if (pair == null) return null;
    final isMargin = _positionUsesMargin(pair, current);
    return market
        ? placeMarketOrder(
            instrumentName,
            expectedDirection,
            amount,
            leverage: leverage,
            marginTrading: isMargin,
          )
        : placeLimitOrder(
            instrumentName,
            expectedDirection,
            amount,
            customPrice: price,
            postOnly: postOnly,
            enableChasing: enableChasing,
            leverage: leverage,
            marginTrading: isMargin,
          );
  }

  Future<Order?> reversePosition(
    String instrumentName, {
    double? percentage,
    bool market = false,
  }) async {
    if (!_authenticated) {
      _status('Please authenticate first');
      return null;
    }

    final pair = _requireVerifiedInstrument(
      instrumentName,
      'reverse position for',
    );
    if (pair == null) return null;
    final generation = _sessionGeneration;

    // Load latest position
    Position? pos = _positions[_normalizeSymbol(instrumentName)];
    pos ??= await _api.getPosition(instrumentName);
    if (!_isCurrentWrite(generation, instrumentName)) return null;
    if (pos == null || pos.size == 0) {
      _status('No position for $instrumentName');
      return null;
    }
    final isMargin = _positionUsesMargin(pair, pos);

    if (!isValidPositionPercentage(percentage)) {
      _status('Target percentage must be greater than 0 and at most 100');
      return null;
    }
    final normalizedAmount = reversePositionApiAmount(
      pair: pair,
      position: pos,
      targetPercentage: percentage!,
    );
    if (!normalizedAmount.canSubmit) {
      _status(normalizedAmount.errorMessage ?? 'Invalid reverse size');
      return null;
    }
    final apiAmount = normalizedAmount.apiAmount;
    // Opposite side
    final direction = pos.isLong ? 'sell' : 'buy';

    double? limitPrice;
    if (!market) {
      // Compute post-only limit price from order book
      final ob = _orderBooks[_normalizeSymbol(instrumentName)];
      if (ob == null) {
        _status('No order book data for $instrumentName');
        return null;
      }
      final tickD = dFrom(
        pair.tickSizeAt(ob.bestAsk > 0 ? ob.bestAsk : ob.bestBid),
      );
      final base = direction == 'buy'
          ? (dFrom(ob.bestAsk) - tickD)
          : (dFrom(ob.bestBid) + tickD);
      limitPrice = dToDouble(roundToTick(base, tickD));
      if (limitPrice <= 0) {
        _status('Invalid computed limit price');
        return null;
      }
    }

    // Place order
    if (market) {
      if (!_isCurrentWrite(generation, instrumentName)) return null;
      final order = await _runInstrumentWrite(
        instrumentName,
        () => _api.placeOrder(
          instrumentName: instrumentName,
          marginTrading: isMargin,
          direction: direction,
          amount: apiAmount,
          orderType: 'market',
          postOnly: false,
          reduceOnly: false,
        ),
      );
      if (!_isCurrentWrite(generation, instrumentName)) return null;
      if (order != null) {
        _status('Placed reverse market: $direction $apiAmount');
        _trackActiveOrder(order);
      }
      return order;
    } else {
      final price = limitPrice ?? 0;
      if (price <= 0) {
        _status('Invalid limit price');
        return null;
      }
      if (!_isCurrentWrite(generation, instrumentName)) return null;
      final order = await _runInstrumentWrite(
        instrumentName,
        () => _api.placeOrder(
          instrumentName: instrumentName,
          marginTrading: isMargin,
          direction: direction,
          amount: apiAmount,
          orderType: 'limit',
          price: price,
          postOnly: true,
          reduceOnly: false,
        ),
      );
      if (!_isCurrentWrite(generation, instrumentName)) return null;
      if (order != null) {
        _status('Placed reverse limit: $direction $apiAmount @ $price');
        _trackActiveOrder(order);
      }
      return order;
    }
  }

  Future<Order?> closePosition(
    String instrumentName, {
    double? percentage,
    double? amount,
    double? nativeApiAmount,
    bool isQuoteCurrency = false,
    double? customPrice,
  }) async {
    if (!_authenticated) {
      _status('Please authenticate first');
      return null;
    }

    final pair = _requireVerifiedInstrument(
      instrumentName,
      'close position for',
    );
    if (pair == null) return null;
    final sizeInputCount =
        (percentage == null ? 0 : 1) +
        (amount == null ? 0 : 1) +
        (nativeApiAmount == null ? 0 : 1);
    if (sizeInputCount != 1) {
      _status(
        'Provide exactly one close amount, native API amount, or percentage',
      );
      return null;
    }
    if (amount != null && (!amount.isFinite || amount <= 0)) {
      _status('Close amount must be a finite number greater than 0');
      return null;
    }
    if (nativeApiAmount != null &&
        (!nativeApiAmount.isFinite || nativeApiAmount <= 0)) {
      _status('Native API amount must be a finite number greater than 0');
      return null;
    }
    if (percentage != null && !isValidPositionPercentage(percentage)) {
      _status('Percentage must be greater than 0 and at most 100');
      return null;
    }
    if (customPrice != null && (!customPrice.isFinite || customPrice <= 0)) {
      _status('Close price must be a finite number greater than 0');
      return null;
    }
    final generation = _sessionGeneration;
    Position? pos = _positions[_normalizeSymbol(instrumentName)];
    pos ??= await _api.getPosition(instrumentName);
    if (!_isCurrentWrite(generation, instrumentName)) return null;
    if (pos == null || pos.size == 0) {
      _status('No position for $instrumentName');
      return null;
    }
    final isMargin = _positionUsesMargin(pair, pos);

    final ob = _orderBooks[_normalizeSymbol(instrumentName)];
    if (ob == null) {
      _status('No order book data for $instrumentName');
      return null;
    }

    final tickD = dFrom(
      pair.tickSizeAt(ob.bestAsk > 0 ? ob.bestAsk : ob.bestBid),
    );

    final closeDirection = pos.isLong ? 'sell' : 'buy';
    final base = pos.isLong
        ? (dFrom(ob.bestBid) + tickD)
        : (dFrom(ob.bestAsk) - tickD);
    final target = customPrice != null
        ? Decimal.parse(customPrice.toString())
        : base;
    final price = dToDouble(roundToTick(target, tickD));
    if (price <= 0) {
      _status('Invalid close price');
      return null;
    }

    ApiAmountNormalization normalizedAmount;
    if (nativeApiAmount != null) {
      normalizedAmount = normalizeApiAmount(
        pair: pair,
        rawApiAmount: nativeApiAmount,
      );
    } else if (amount != null) {
      final conversion = convertPositionAmountForApi(
        pair: pair,
        inputAmount: amount,
        inputUnit: isQuoteCurrency
            ? ManualOrderAmountUnit.quote
            : ManualOrderAmountUnit.base,
        orderType: ManualOrderType.limit,
        direction: closeDirection,
        reference: (price: price, label: 'Limit Price'),
      );
      normalizedAmount = ApiAmountNormalization(
        rawAmount: conversion.rawApiAmount,
        apiAmount: conversion.apiAmount,
        roundedDown: conversion.roundedDown,
        preservedExact: false,
        errorMessage: conversion.errorMessage,
      );
    } else {
      normalizedAmount = positionPercentageApiAmount(
        pair: pair,
        position: pos,
        percentage: percentage!,
        preserveFullPosition: true,
      );
    }
    if (!normalizedAmount.canSubmit) {
      _status(normalizedAmount.errorMessage ?? 'Invalid close size');
      return null;
    }
    final apiAmount = normalizedAmount.apiAmount;

    if (!_isCurrentWrite(generation, instrumentName)) return null;
    final order = await _runInstrumentWrite(
      instrumentName,
      () => _api.placeOrder(
        instrumentName: instrumentName,
        marginTrading: isMargin,
        direction: closeDirection,
        amount: apiAmount,
        orderType: 'limit',
        price: price,
        postOnly: true,
        reduceOnly: pair.type == TradingPairType.future || isMargin,
      ),
    );
    if (!_isCurrentWrite(generation, instrumentName)) return null;
    if (order != null) {
      _status('Placed close order: $apiAmount @ $price');
      _trackActiveOrder(order);
    }
    return order;
  }

  Future<Order?> closePositionMarket(
    String instrumentName, {
    double? percentage,
    double? amount,
    double? nativeApiAmount,
    bool isQuoteCurrency = false,
  }) async {
    if (!_authenticated) {
      _status('Please authenticate first');
      return null;
    }

    final pair = _requireVerifiedInstrument(
      instrumentName,
      'close position for',
    );
    if (pair == null) return null;
    final sizeInputCount =
        (percentage == null ? 0 : 1) +
        (amount == null ? 0 : 1) +
        (nativeApiAmount == null ? 0 : 1);
    if (sizeInputCount != 1) {
      _status(
        'Provide exactly one close amount, native API amount, or percentage',
      );
      return null;
    }
    if (amount != null && (!amount.isFinite || amount <= 0)) {
      _status('Close amount must be a finite number greater than 0');
      return null;
    }
    if (nativeApiAmount != null &&
        (!nativeApiAmount.isFinite || nativeApiAmount <= 0)) {
      _status('Native API amount must be a finite number greater than 0');
      return null;
    }
    if (percentage != null && !isValidPositionPercentage(percentage)) {
      _status('Percentage must be greater than 0 and at most 100');
      return null;
    }
    final generation = _sessionGeneration;
    Position? pos = _positions[_normalizeSymbol(instrumentName)];
    pos ??= await _api.getPosition(instrumentName);
    if (!_isCurrentWrite(generation, instrumentName)) return null;
    if (pos == null || pos.size == 0) {
      _status('No position for $instrumentName');
      return null;
    }
    final isMargin = _positionUsesMargin(pair, pos);
    final direction = pos.isLong ? 'sell' : 'buy';

    ApiAmountNormalization normalizedAmount;
    if (nativeApiAmount != null) {
      normalizedAmount = normalizeApiAmount(
        pair: pair,
        rawApiAmount: nativeApiAmount,
      );
    } else if (amount != null) {
      final ticker = _tickers[_normalizeSymbol(instrumentName)];
      final reference = resolvePositionAmountReference(
        position: pos,
        latestMarkPrice: ticker?.markPrice,
      );
      final conversion = convertPositionAmountForApi(
        pair: pair,
        inputAmount: amount,
        inputUnit: isQuoteCurrency
            ? ManualOrderAmountUnit.quote
            : ManualOrderAmountUnit.base,
        orderType: ManualOrderType.market,
        direction: direction,
        reference: reference,
      );
      normalizedAmount = ApiAmountNormalization(
        rawAmount: conversion.rawApiAmount,
        apiAmount: conversion.apiAmount,
        roundedDown: conversion.roundedDown,
        preservedExact: false,
        errorMessage: conversion.errorMessage,
      );
    } else {
      normalizedAmount = positionPercentageApiAmount(
        pair: pair,
        position: pos,
        percentage: percentage!,
        preserveFullPosition: true,
      );
    }
    if (!normalizedAmount.canSubmit) {
      _status(normalizedAmount.errorMessage ?? 'Invalid close size');
      return null;
    }
    final apiAmount = normalizedAmount.apiAmount;

    if (!_isCurrentWrite(generation, instrumentName)) return null;
    final order = await _runInstrumentWrite(
      instrumentName,
      () => _api.placeOrder(
        instrumentName: instrumentName,
        marginTrading: isMargin,
        direction: direction,
        amount: apiAmount,
        orderType: 'market',
        postOnly: false,
        reduceOnly: pair.type == TradingPairType.future || isMargin,
      ),
    );
    if (!_isCurrentWrite(generation, instrumentName)) return null;
    if (order != null) {
      _status('Placed market close: $apiAmount');
      _trackActiveOrder(order);
    }
    return order;
  }

  Future<Order?> placeConditionalOrderForPosition(
    String instrumentName, {
    required String
    type, // stop_market, take_market, trailing_stop, stop_limit, take_limit
    double? triggerPrice, // for stop/take
    double? limitPrice, // for *_limit
    double? trailingOffset, // for trailing_stop
    double? percentage,
    double? amount,
    double? nativeApiAmount,
    bool isQuoteCurrency = false,
    String triggerSource = 'last_price',
  }) async {
    if (!_authenticated) {
      _status('Please authenticate first');
      return null;
    }

    final pair = _requireVerifiedInstrument(
      instrumentName,
      'place protection order for',
    );
    if (pair == null) return null;
    final sizeInputCount =
        (percentage == null ? 0 : 1) +
        (amount == null ? 0 : 1) +
        (nativeApiAmount == null ? 0 : 1);
    if (sizeInputCount != 1) {
      _status(
        'Provide exactly one protection amount, native API amount, or percentage',
      );
      return null;
    }
    if (amount != null && (!amount.isFinite || amount <= 0)) {
      _status('Protection amount must be a finite number greater than 0');
      return null;
    }
    if (nativeApiAmount != null &&
        (!nativeApiAmount.isFinite || nativeApiAmount <= 0)) {
      _status('Native API amount must be a finite number greater than 0');
      return null;
    }
    if (percentage != null && !isValidPositionPercentage(percentage)) {
      _status('Percentage must be greater than 0 and at most 100');
      return null;
    }
    final generation = _sessionGeneration;
    Position? pos = _positions[_normalizeSymbol(instrumentName)];
    pos ??= await _api.getPosition(instrumentName);
    if (!_isCurrentWrite(generation, instrumentName)) return null;
    if (pos == null || pos.size == 0) {
      _status('No position for $instrumentName');
      return null;
    }
    final isMargin = _positionUsesMargin(pair, pos);
    ApiAmountNormalization normalizedAmount;
    if (nativeApiAmount != null) {
      normalizedAmount = normalizeApiAmount(
        pair: pair,
        rawApiAmount: nativeApiAmount,
      );
    } else if (amount != null) {
      final ticker = _tickers[_normalizeSymbol(instrumentName)];
      final reference = resolvePositionAmountReference(
        position: pos,
        latestMarkPrice: ticker?.markPrice,
        fallbackPrice: limitPrice ?? triggerPrice,
        fallbackLabel: limitPrice != null ? 'Limit Price' : 'Trigger Price',
      );
      final conversion = convertPositionAmountForApi(
        pair: pair,
        inputAmount: amount,
        inputUnit: isQuoteCurrency
            ? ManualOrderAmountUnit.quote
            : ManualOrderAmountUnit.base,
        orderType: type.endsWith('_market')
            ? ManualOrderType.market
            : ManualOrderType.limit,
        direction: pos.isLong ? 'sell' : 'buy',
        reference: reference,
      );
      normalizedAmount = ApiAmountNormalization(
        rawAmount: conversion.rawApiAmount,
        apiAmount: conversion.apiAmount,
        roundedDown: conversion.roundedDown,
        preservedExact: false,
        errorMessage: conversion.errorMessage,
      );
    } else {
      normalizedAmount = positionPercentageApiAmount(
        pair: pair,
        position: pos,
        percentage: percentage!,
      );
    }
    if (!normalizedAmount.canSubmit) {
      _status(normalizedAmount.errorMessage ?? 'Invalid protection size');
      return null;
    }
    final apiAmount = normalizedAmount.apiAmount;

    // Determine order direction to reduce position
    final direction = pos.isLong ? 'sell' : 'buy';

    // Validate params per type
    double? stopPx;
    double? price;
    double? trailing;
    if (type == 'trailing_stop') {
      trailing = trailingOffset;
      if (trailing == null || !trailing.isFinite || trailing <= 0) {
        _status('Trailing offset is required');
        return null;
      }
    } else if (type == 'stop_market' || type == 'take_market') {
      stopPx = triggerPrice;
      if (stopPx == null || !stopPx.isFinite || stopPx <= 0) {
        _status('Trigger price is required');
        return null;
      }
    } else if (type == 'stop_limit' || type == 'take_limit') {
      stopPx = triggerPrice;
      price = limitPrice;
      if (stopPx == null ||
          !stopPx.isFinite ||
          stopPx <= 0 ||
          price == null ||
          !price.isFinite ||
          price <= 0) {
        _status('Trigger and limit prices are required');
        return null;
      }
    }

    if (!_isCurrentWrite(generation, instrumentName)) return null;
    final order = await _runInstrumentWrite(
      instrumentName,
      () => _api.placeOrder(
        instrumentName: instrumentName,
        marginTrading: isMargin,
        direction: direction,
        amount: apiAmount,
        orderType: type,
        price: price,
        reduceOnly: pair.type == TradingPairType.future || isMargin,
        stopPrice: stopPx,
        trigger: triggerSource,
        trailing: trailing,
      ),
    );
    if (!_isCurrentWrite(generation, instrumentName)) return null;
    if (order != null) {
      _status('Placed $type protection for $instrumentName: $apiAmount');
      _trackActiveOrder(order);
    }
    return order;
  }

  Future<List<TradeHistory>> getTradeHistory(
    String instrumentName,
    DateTime from,
    DateTime to, {
    bool marginTrading = false,
  }) async {
    if (!_authenticated) {
      _status('Please authenticate first');
      return [];
    }
    final generation = _sessionGeneration;
    try {
      final pair = await _api.getInstrument(instrumentName);
      final trades = await _api.getUserTradesByInstrument(
        instrumentName: instrumentName,
        from: from,
        to: to,
      );
      if (!_isCurrentPrivateOperation(generation)) return const [];
      final List<TradeHistory> selected;
      if (pair?.type == TradingPairType.spot) {
        if (trades.any((t) => t.isExchange == null)) {
          throw StateError(
            'Some historical trades lack order mode; narrow the time range to separate Exchange and Margin safely',
          );
        }
        selected = trades.where((t) => t.isExchange == !marginTrading).toList();
      } else {
        selected = trades;
      }
      _status(
        'Loaded ${selected.length} trades (${pair == null
            ? 'Unverified market'
            : pair.type == TradingPairType.future
            ? 'Derivatives'
            : marginTrading
            ? 'Margin'
            : 'Exchange'})',
      );
      return selected;
    } catch (e) {
      _status('Load trade history failed: $e');
      rethrow;
    }
  }

  Future<(double equity, double maintenanceMargin, double availableFunds)?>
  getAccountMetrics(String currency) async {
    if (!_authenticated) {
      _status('Please authenticate first');
      return null;
    }
    final generation = _sessionGeneration;
    final normalizedCurrency = currency.trim().toUpperCase();
    try {
      final m = await _api.getAccountSummary(currency: normalizedCurrency);
      if (!_isCurrentPrivateOperation(generation)) return null;
      if (m == null) return null;
      final equity = (m['equity'] as num?)?.toDouble() ?? 0.0;
      final mm = (m['maintenance_margin'] as num?)?.toDouble() ?? 0.0;
      final af = (m['available_funds'] as num?)?.toDouble() ?? 0.0;
      return (equity, mm, af);
    } catch (e) {
      _status('Load account summary failed: $e');
      return null;
    }
  }

  Future<AccountSummaries?> getAccountSummaries({bool extended = true}) async {
    if (!_authenticated) {
      _status('Please authenticate first');
      return null;
    }
    final generation = _sessionGeneration;
    try {
      final m = await _api.getAccountSummaries(extended: extended);
      if (!_isCurrentPrivateOperation(generation)) return null;
      if (m == null) return null;
      return AccountSummaries.fromMap(m);
    } catch (e) {
      _status('Load account summaries failed: $e');
      return null;
    }
  }

  Future<double?> getIndexPrice({
    required String base,
    String quote = 'USD',
  }) async {
    try {
      return await _api.getIndexPrice(base: base, quote: quote);
    } catch (e) {
      _status('Get index price failed: $e');
      return null;
    }
  }

  Future<List<AddressBookEntry>> getAddressBook({String? currency}) async {
    if (!_authenticated) {
      _status('Please authenticate first');
      return const [];
    }
    final generation = _sessionGeneration;
    try {
      final list = await _api.getAddressBook(currency: currency);
      if (!_isCurrentPrivateOperation(generation)) return const [];
      _status(
        'Loaded ${list.length} address book entr${list.length == 1 ? 'y' : 'ies'}',
      );
      return list;
    } catch (e) {
      _status('Load address book failed: $e');
      return const [];
    }
  }

  Future<List<Withdrawal>> getWithdrawals({
    required String currency,
    int count = 20,
    int offset = 0,
  }) async {
    if (!_authenticated) {
      _status('Please authenticate first');
      return const [];
    }
    final generation = _sessionGeneration;
    try {
      final list = await _api.getWithdrawals(
        currency: currency,
        count: count,
        offset: offset,
      );
      if (!_isCurrentPrivateOperation(generation)) return const [];
      _status(
        'Loaded ${list.length} withdrawal${list.length == 1 ? '' : 's'} for $currency',
      );
      return list;
    } catch (e) {
      _status('Load withdrawals failed: $e');
      rethrow;
    }
  }

  /// 拉取公开公告历史（无需登录）
  Future<List<Announcement>> getAnnouncements({int count = 50}) async {
    if (!_connected) {
      _status('Please connect first');
      return const [];
    }
    try {
      final list = await _api.getAnnouncements(count: count);
      list.sort(
        (a, b) => b.publicationTimestamp.compareTo(a.publicationTimestamp),
      );
      _status(
        'Loaded ${list.length} announcement${list.length == 1 ? '' : 's'}',
      );
      return list;
    } catch (e) {
      _status('Load announcements failed: $e');
      rethrow;
    }
  }

  /// 拉取未读公告（需登录）
  Future<List<Announcement>> getNewAnnouncements() async {
    if (!_authenticated) {
      _status('Please authenticate first');
      return const [];
    }
    final generation = _sessionGeneration;
    try {
      final list = await _api.getNewAnnouncements();
      if (!_isCurrentPrivateOperation(generation)) return const [];
      // 按发布时间倒序
      list.sort(
        (a, b) => b.publicationTimestamp.compareTo(a.publicationTimestamp),
      );
      _status(
        'Loaded ${list.length} unread announcement${list.length == 1 ? '' : 's'}',
      );
      return list;
    } catch (e) {
      _status('Load announcements failed: $e');
      rethrow;
    }
  }

  /// 标记公告已读
  Future<bool> setAnnouncementAsRead(int announcementId) async {
    if (!_authenticated) {
      _status('Please authenticate first');
      return false;
    }
    final generation = _sessionGeneration;
    try {
      final ok = await _api.setAnnouncementAsRead(announcementId);
      if (!_isCurrentPrivateOperation(generation)) return false;
      _status(
        ok
            ? 'Marked announcement $announcementId as read'
            : 'Mark announcement as read failed',
      );
      return ok;
    } catch (e) {
      _status('Mark announcement as read failed: $e');
      return false;
    }
  }

  Future<Map<String, List<String>>> getWithdrawalMethods() =>
      _api.getWithdrawalMethods();

  Future<bool> withdraw({
    required String currency,
    required String address,
    required double amount,
    required String method,
    String? destinationTag,
  }) async {
    if (!_authenticated) {
      _status('Please authenticate first');
      return false;
    }
    final generation = _sessionGeneration;
    try {
      final res = await _api.withdraw(
        currency: currency,
        address: address,
        amount: amount,
        method: method,
        destinationTag: destinationTag,
      );
      if (!_isCurrentPrivateOperation(generation)) return false;
      if (res != null) {
        final id = res['withdrawal_id'] ?? res['id'] ?? res['result'];
        _status(
          'Withdrawal requested: $currency $amount → $address (${id ?? 'ok'})',
        );
        return true;
      }
      _status('Withdrawal request returned empty result');
      return false;
    } catch (e) {
      _status('Withdrawal failed: $e');
      return false;
    }
  }

  Future<bool> cancelOrder(String orderId) async {
    if (!_authenticated) {
      _status('Please authenticate first');
      return false;
    }
    final generation = _sessionGeneration;
    final ok = await _api.cancelOrder(orderId);
    if (_disposed ||
        generation != _sessionGeneration ||
        !_connected ||
        !_authenticated) {
      return false;
    }
    if (ok) {
      final order = _removeActiveOrder(orderId);
      if (order != null) _emitClosedOrder(order);
      _status('Cancelled order $orderId');
    }
    return ok;
  }

  List<TradingPair> getDefaultPairs() =>
      TradingPair.defaultPairs(paper: _requestedIsTestnet);

  OrderBookData? getOrderBook(String instrument) =>
      _orderBooks[_normalizeSymbol(instrument)];
  TickerData? getTicker(String instrument) =>
      _tickers[_normalizeSymbol(instrument)];

  TradingPair? getTradingPairBySymbol(String symbol, List<TradingPair> custom) {
    final normalized = _normalizeSymbol(symbol);
    final verified = _verifiedInstruments[normalized];
    if (verified != null) return verified;
    final all = [
      ...TradingPair.defaultPairs(paper: _requestedIsTestnet),
      ...custom,
    ];
    try {
      return all.firstWhere((p) => _normalizeSymbol(p.symbol) == normalized);
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadOpenOrdersAndPositions(int generation) async {
    _clearLocalRiskState();
    _initialOrderPrices.clear();
    _closedOrderIds.clear();
    _orderUpdateTimestamps.clear();
    _closedOrderTombstoneQueue.clear();
    _closedOrderTombstoneTokens.clear();
    final snapshots = await Future.wait<dynamic>([
      _api.getOpenOrders(),
      _api.getPositions(),
    ]);
    if (!_isCurrentPrivateOperation(generation)) return;
    for (final order in snapshots[0] as List<Order>) {
      _trackActiveOrder(order);
    }
    for (final position in snapshots[1] as List<Position>) {
      _updatePositionRisk(position.instrumentName, position);
      _emit(_positionController, position);
      unawaited(_ensureFeedsForRestoredOrder(position.instrumentName));
    }
  }

  void updateSettings({
    double? maxSpreadPercent,
    List<TradingPair>? customPairs,
  }) {
    if (maxSpreadPercent != null) _maxSpreadPercent = maxSpreadPercent;
    if (customPairs != null) {
      final normalized = <String, TradingPair>{};
      for (final pair in customPairs) {
        final symbol = _normalizeSymbol(pair.symbol);
        if (symbol.isEmpty) continue;
        normalized.putIfAbsent(
          symbol,
          () => TradingPair.fromMap({...pair.toMap(), 'symbol': symbol}),
        );
      }
      _customPairs = List.unmodifiable(normalized.values);
      final allowed = _allowedInstrumentSymbols();
      final removed = {
        ..._verifiedInstruments.keys,
        ..._instrumentRequestGenerations.keys,
      }.where((symbol) => !allowed.contains(symbol)).toList();
      for (final symbol in removed) {
        removeInstrument(symbol);
      }
    }
    // Timer lifecycle managed by per-order chasing set
  }

  void _startChasingTimer() {
    _chasingTimer?.cancel();
    _chasingTimer = Timer.periodic(_chasingInterval, (_) async {
      if (!_authenticated) return;
      // Copy to avoid modification during iteration
      final toCheck = _chasedOrderIds.toList();
      for (final orderId in toCheck) {
        if (!_chasingEditsInFlight.add(orderId)) continue;
        try {
          final order = _activeOrders[orderId];
          if (order == null || !order.isActive) {
            _removeActiveOrder(orderId);
            continue;
          }
          if (order.orderType.toLowerCase() != 'limit' || !order.postOnly) {
            // Only chase post-only limit orders
            _chasedOrderIds.remove(orderId);
            _bumpChasingIntent(orderId);
            _chasingIntentGenerations.remove(orderId);
            continue;
          }
          final ob = _orderBooks[_normalizeSymbol(order.instrumentName)];
          if (ob == null) continue; // keep chasing when data resumes
          final bestBid = ob.bestBid;
          final bestAsk = ob.bestAsk;
          if (bestBid <= 0 || bestAsk <= 0) {
            continue; // incomplete book (one side empty): wait for both sides
          }
          final mid = (bestAsk + bestBid) / 2;
          final spreadPercent = (bestAsk - bestBid) / mid * 100.0;
          if (spreadPercent > _maxSpreadPercent) {
            continue; // wait until spread narrows relative to mid price
          }
          final pair =
              _verifiedInstruments[_normalizeSymbol(order.instrumentName)];
          if (pair == null) {
            _stopChasingForInstrument(
              order.instrumentName,
              reason: 'metadata is unverified',
            );
            continue;
          }

          final init = _initialOrderPrices[order.orderId] ?? order.price;
          final refPrice = order.direction == 'buy' ? ob.bestAsk : ob.bestBid;
          final dev = (refPrice - init).abs() / (init == 0 ? 1 : init) * 100.0;
          if (dev > pair.maxPriceDeviationPercent) {
            _status(
              'Chase stopped for ${order.orderId}: deviation $dev% exceeds ${pair.maxPriceDeviationPercent}%',
            );
            // Stop chasing if deviation exceeds threshold
            _chasedOrderIds.remove(order.orderId);
            _bumpChasingIntent(order.orderId);
            _chasingIntentGenerations.remove(order.orderId);
            continue;
          }

          final optimal = _calculateOptimalPrice(pair, order.direction, ob);
          if ((order.price - optimal).abs() >= pair.tickSizeAt(optimal)) {
            final sessionGeneration = _sessionGeneration;
            final intentGeneration =
                _chasingIntentGenerations[order.orderId] ?? 0;
            // Omit amount when repricing, preserving the exchange's remaining quantity.
            final edited = await _runInstrumentWrite(
              order.instrumentName,
              () => _api.editOrder(order.orderId, optimal),
            );
            final intentStillCurrent =
                _isCurrentWrite(sessionGeneration, order.instrumentName) &&
                _chasedOrderIds.contains(order.orderId) &&
                _chasingIntentGenerations[order.orderId] == intentGeneration &&
                identical(_activeOrders[order.orderId], order);
            if (edited != null && intentStillCurrent) {
              final initialPrice =
                  _initialOrderPrices[order.orderId] ?? order.price;
              if (edited.orderId != order.orderId) {
                _removeActiveOrder(order.orderId);
                _emitClosedOrder(order);
                _trackActiveOrder(edited);
                if (_activeOrders[edited.orderId] != null) {
                  _reopenOrder(edited.orderId);
                  _initialOrderPrices[edited.orderId] = initialPrice;
                  _bumpChasingIntent(edited.orderId);
                  _chasedOrderIds.add(edited.orderId);
                }
              } else {
                _initialOrderPrices[edited.orderId] = initialPrice;
                _trackActiveOrder(edited);
              }
            }
          }
        } catch (e) {
          // Surface chase edit failures instead of silently swallowing them;
          // a silent catch here previously hid a rejected edit indefinitely.
          setChasingForOrder(orderId, false);
          _status('Chase stopped after edit failure for $orderId: $e');
        } finally {
          _chasingEditsInFlight.remove(orderId);
        }
      }
      if (_chasedOrderIds.isEmpty) {
        _chasingTimer?.cancel();
        _chasingTimer = null;
      }
    });
  }

  bool _enableChasingForOrder(String orderId) {
    final order = _activeOrders[orderId];
    if (order == null ||
        !order.isActive ||
        order.orderType.toLowerCase() != 'limit' ||
        !order.postOnly) {
      _status(
        'Cannot chase $orderId: active=${order?.isActive}, type=${order?.orderType}, postOnly=${order?.postOnly}',
      );
      return false;
    }
    if (_requireVerifiedInstrument(
          order.instrumentName,
          'enable chasing for',
        ) ==
        null) {
      return false;
    }
    // Anchor the deviation guard at the current book reference price, not the
    // order price: a resting order far from the book must still be chased
    // towards the book. The guard then only stops chasing when the market
    // runs further away from this anchor beyond maxPriceDeviationPercent.
    final anchorOb = _orderBooks[_normalizeSymbol(order.instrumentName)];
    final anchor = anchorOb == null
        ? 0.0
        : (order.direction == 'buy' ? anchorOb.bestAsk : anchorOb.bestBid);
    _initialOrderPrices[orderId] = anchor > 0 ? anchor : order.price;
    _bumpChasingIntent(orderId);
    _chasedOrderIds.add(orderId);
    _status(
      'Chase enabled for $orderId, anchor=${_initialOrderPrices[orderId]}',
    );
    // ignore: discarded_futures
    _ensureFeedsForRestoredOrder(order.instrumentName, force: true);
    if (_chasingTimer == null) {
      _startChasingTimer();
    }
    return true;
  }

  double _calculateOptimalPrice(
    TradingPair pair,
    String direction,
    OrderBookData ob,
  ) {
    final tickD = dFrom(
      pair.tickSizeAt(ob.bestAsk > 0 ? ob.bestAsk : ob.bestBid),
    );
    final base = direction == 'buy'
        ? (dFrom(ob.bestAsk) - tickD)
        : (dFrom(ob.bestBid) + tickD);
    return dToDouble(roundToTick(base, tickD));
  }

  // Public helpers for per-order chasing control
  bool isChasing(String orderId) => _chasedOrderIds.contains(orderId);

  bool setChasingForOrder(String orderId, bool enable) {
    if (enable) {
      return _enableChasingForOrder(orderId);
    } else {
      _chasedOrderIds.remove(orderId);
      _bumpChasingIntent(orderId);
      _chasingIntentGenerations.remove(orderId);
      if (_chasedOrderIds.isEmpty) {
        _chasingTimer?.cancel();
        _chasingTimer = null;
      }
      return true;
    }
  }

  void dispose() {
    if (_disposed) return;
    _connectionRequestGeneration++;
    _sessionGeneration++;
    _instrumentTrustGeneration++;
    _connected = false;
    _authenticated = false;
    _invalidateSubscriptionStates();
    _disposed = true;
    _subBook?.cancel();
    _subOrder?.cancel();
    _subPos?.cancel();
    _subTicker?.cancel();
    _subUser?.cancel();
    _subAnnouncement?.cancel();
    _subConn?.cancel();
    _subDisc?.cancel();
    _chasingTimer?.cancel();
    _chasedOrderIds.clear();
    _chasingEditsInFlight.clear();
    _chasingIntentGenerations.clear();
    _closedOrderIds.clear();
    _orderUpdateTimestamps.clear();
    _closedOrderTombstoneQueue.clear();
    _closedOrderTombstoneTokens.clear();
    _instrumentRequestGenerations.clear();
    _instrumentRequestOwners.clear();
    _verifiedInstruments.clear();
    _orderBooks.clear();
    _tickers.clear();
    _clearLocalRiskState();
    _riskGenerations.clear();
    _statusController.close();
    _orderBookController.close();
    _orderController.close();
    _positionController.close();
    _tickerController.close();
    _announcementController.close();
    _instrumentController.close();
    _api.dispose();
  }
}

class _PublicSubscriptionState {
  bool desired = false;
  bool bookSubscribed = false;
  bool tickerSubscribed = false;
  Future<void>? runner;
  final List<Completer<void>> waiters = [];

  bool get isSubscribed => bookSubscribed && tickerSubscribed;
}

class _PrivateSubscriptionState {
  bool desired = false;
  bool subscribed = false;
  String desiredInterval = '100ms';
  String actualInterval = '';
  Future<void>? runner;
  final List<Completer<void>> waiters = [];
}
