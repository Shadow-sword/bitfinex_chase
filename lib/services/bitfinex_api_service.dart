import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import '../models/market_data.dart';
import '../models/address_book.dart';
import '../models/announcement.dart';
import '../models/trading_pair.dart';
import '../models/withdrawal.dart';
import '../models/wallet_transfer.dart';
import 'package:decimal/decimal.dart';
import 'bitfinex_transport.dart';

/// Native Bitfinex v2 REST and WebSocket adapter. Symbols in the application
/// omit the wire-only `t` prefix. Amounts in the application are unsigned base
/// units; the sign is applied only when writing to Bitfinex.
class BitfinexApiService {
  final BitfinexTransport _transport;
  BitfinexApiService({BitfinexTransport? transport})
    : _transport = transport ?? BitfinexTransport() {
    _messages = _transport.messages.stream.listen(_onMessage);
    _disconnects = _transport.disconnected.stream.listen((reason) {
      _clearSession();
      _emit(_disconnectedController, reason);
      _scheduleReconnect();
    });
  }

  int _clientOrderId = 0;
  final Set<String> _pendingOrderWrites = {};
  bool _paper = true;
  bool _connectionWanted = false;
  bool _opening = false;
  Future<void>? _socketOpening;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _authenticated = false;
  bool _disposed = false;
  int _generation = 0;
  List<dynamic>? _user;
  Future<void>? _catalogueRequest;
  final Map<String, TradingPair> _instruments = {};
  final Map<String, double> _maxAmounts = {};
  final Set<String> _exchangeSymbols = {};
  final Map<int, (String, String)> _channels = {};
  final Map<String, int> _channelIds = {};
  final Map<String, _Book> _books = {};
  final Map<String, TickerData> _tickers = {};
  final Map<String, Order> _orders = {};
  final Map<String, int> _orderLeverage = {};
  final Map<String, Position> _positions = {};
  Future<void> _subscriptionQueue = Future<void>.value();
  late final StreamSubscription<dynamic> _messages;
  late final StreamSubscription<String> _disconnects;

  final _orderBookController = StreamController<OrderBookData>.broadcast();
  final _orderController = StreamController<Order>.broadcast();
  final _positionController = StreamController<Position>.broadcast();
  final _tickerController = StreamController<TickerData>.broadcast();
  final _userChangesController = StreamController<UserChanges>.broadcast();
  final _announcementController =
      StreamController<AnnouncementEvent>.broadcast();
  final _connectedController = StreamController<void>.broadcast();
  final _disconnectedController = StreamController<String>.broadcast();
  Stream<OrderBookData> get orderBookStream => _orderBookController.stream;
  Stream<Order> get orderStream => _orderController.stream;
  Stream<Position> get positionStream => _positionController.stream;
  Stream<TickerData> get tickerStream => _tickerController.stream;
  Stream<UserChanges> get userChangesStream => _userChangesController.stream;
  Stream<AnnouncementEvent> get announcementStream =>
      _announcementController.stream;
  Stream<void> get connected => _connectedController.stream;
  Stream<String> get disconnected => _disconnectedController.stream;
  bool get isConnected => _transport.isConnected;
  bool get isAuthenticated => _authenticated && isConnected;
  bool get isPaper => _paper;

  void _emit<T>(StreamController<T> controller, T event) {
    if (!_disposed && !controller.isClosed) controller.add(event);
  }

  void _clearSession() {
    _generation++;
    _authenticated = false;
    _transport.clearCredentials();
    _user = null;
    _channels.clear();
    _channelIds.clear();
    _books.clear();
    _tickers.clear();
    _orders.clear();
    _positions.clear();
    _orderLeverage.clear();
    _pendingOrderWrites.clear();
    _instruments.clear();
    _maxAmounts.clear();
    _exchangeSymbols.clear();
    _catalogueRequest = null;
  }

  Future<void> connect({required bool isTestnet}) async {
    _reconnectTimer?.cancel();
    _connectionWanted = true;
    _opening = true;
    _clearSession();
    _paper = isTestnet;
    try {
      await _openSocket();
      _reconnectAttempts = 0;
      _emit(_connectedController, null);
    } catch (_) {
      _connectionWanted = false;
      rethrow;
    } finally {
      _opening = false;
    }
  }

  void _scheduleReconnect() {
    if (!_connectionWanted || _disposed || _opening) return;
    _reconnectTimer?.cancel();
    // Bitfinex permits 5 connections per 15 seconds. Network recovery starts
    // at five seconds and backs off; order writes are never replayed.
    final seconds = math
        .min(30, 5 * math.pow(2, _reconnectAttempts.clamp(0, 3)))
        .toInt();
    _reconnectAttempts++;
    _emit(_disconnectedController, 'reconnecting in ${seconds}s');
    _reconnectTimer = Timer(Duration(seconds: seconds), () async {
      if (!_connectionWanted || _disposed) return;
      _opening = true;
      _clearSession();
      try {
        await _openSocket();
        if (!_connectionWanted || _disposed) {
          await _transport.disconnect();
          return;
        }
        _reconnectAttempts = 0;
        _emit(_connectedController, null);
      } catch (e) {
        _emit(_disconnectedController, 'Reconnect failed: $e');
      } finally {
        _opening = false;
        if (!isConnected) _scheduleReconnect();
      }
    });
  }

  Future<void> disconnect() async {
    _connectionWanted = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _clearSession();
    await _transport.disconnect();
  }

  Future<void> _openSocket() {
    final pending = _socketOpening;
    if (pending != null) return pending;
    late final Future<void> request;
    request = _transport.connect().whenComplete(() {
      if (identical(_socketOpening, request)) _socketOpening = null;
    });
    _socketOpening = request;
    return request;
  }

  Future<bool> ensureConnected() async {
    if (isConnected) return true;
    final pending = _socketOpening;
    if (pending != null) {
      await pending;
      return isConnected;
    }
    await connect(isTestnet: _paper);
    return isConnected;
  }

  Future<bool> authenticate(String clientId, String clientSecret) async {
    if (!isConnected) throw StateError('Connect before authenticating');
    if (_authenticated) {
      throw StateError('Disconnect before changing API credentials');
    }
    if (clientId.trim().isEmpty || clientSecret.trim().isEmpty) {
      throw ArgumentError('API Key and Secret are required');
    }
    final generation = _generation;
    _transport.setCredentials(clientId.trim(), clientSecret.trim());
    try {
      final user = await _transport.privatePost('v2/auth/r/info/user');
      if (user is! List || user.length <= 21) {
        throw const FormatException('Cannot verify Paper/Live account type');
      }
      // The official Bitfinex model treats an unset PPT_ENABLED as false.
      // A present null flag is distinct from a missing/truncated user response.
      final accountIsPaper = switch (user[21]) {
        1 || true => true,
        0 || false || null => false,
        _ => throw const FormatException('Invalid PPT_ENABLED account flag'),
      };
      if (accountIsPaper != _paper) {
        throw StateError(
          'Account type mismatch: select ${accountIsPaper ? 'Paper' : 'Live'} before connecting',
        );
      }
      final nonce = _transport.nextNonce();
      final payload = 'AUTH$nonce';
      final result = await _transport.requestEvent({
        'event': 'auth',
        'apiKey': clientId.trim(),
        'authNonce': nonce,
        'authPayload': payload,
        'authSig': _transport.signature(payload),
        'filter': ['trading', 'wallet', 'balance', 'notify'],
      }, (event) => event['event'] == 'auth' || event['event'] == 'error');
      if (result['status'] != 'OK') {
        throw const BitfinexApiException('auth', 'Authentication rejected');
      }
      if (generation != _generation || !isConnected) {
        throw StateError('Session changed');
      }
      _user = List<dynamic>.of(user);
      _authenticated = true;
      return true;
    } catch (_) {
      // A failed/replaced WS authentication must not retain the old account.
      await disconnect();
      rethrow;
    }
  }

  Future<void> _loadCatalogue() {
    if (_instruments.isNotEmpty) return Future<void>.value();
    return _catalogueRequest ??= _fetchCatalogue().whenComplete(
      () => _catalogueRequest = null,
    );
  }

  Future<void> _fetchCatalogue() async {
    final generation = _generation;
    final info = _list(
      await _transport.publicGet('v2/conf/pub:info:pair,pub:info:pair:futures'),
    );
    final symbols = _list(
      await _transport.publicGet(
        'v2/conf/pub:list:pair:exchange,pub:list:pair:futures,pub:list:pair:margin',
      ),
    );
    if (info.length != 2 || symbols.length != 3) {
      throw const FormatException('Invalid catalogue');
    }
    final marginSymbols = _list(symbols[2]).cast<String>().toSet();
    final pairs = <String, TradingPair>{};
    final maxima = <String, double>{};
    for (var group = 0; group < 2; group++) {
      final active = _list(symbols[group]).cast<String>().toSet();
      for (final raw in _list(info[group])) {
        final row = _list(raw);
        final symbol = row[0] as String;
        if (!active.contains(symbol) || symbol.startsWith('TEST') != _paper) {
          continue;
        }
        final config = _list(row[1]);
        final pair = TradingPair.fromBitfinexConfig(
          symbol,
          config,
          isFuture: group == 1,
          supportsMargin: marginSymbols.contains(symbol),
        );
        pairs[pair.symbol] = pair;
        maxima[pair.symbol] = _number(config[4]);
      }
    }
    if (generation != _generation) {
      throw StateError('Catalogue session changed');
    }
    _exchangeSymbols.addAll(_list(symbols[0]).cast<String>());
    _instruments.addAll(pairs);
    _maxAmounts.addAll(maxima);
  }

  Future<TradingPair?> getInstrument(String instrumentName) async {
    await _loadCatalogue();
    return _instruments[TradingPair.canonicalSymbol(instrumentName)];
  }

  Future<void> subscribeOrderBook(String instrumentName) =>
      _subscribe('book', instrumentName);
  Future<void> subscribeTicker(String instrumentName) =>
      _subscribe('ticker', instrumentName);
  Future<void> unsubscribeOrderBook(String instrumentName) =>
      _unsubscribe('book', instrumentName);
  Future<void> unsubscribeTicker(String instrumentName) =>
      _unsubscribe('ticker', instrumentName);

  Future<void> _queueSubscription(Future<void> Function() action) {
    final generation = _generation;
    final result = _subscriptionQueue.then((_) async {
      if (generation != _generation) {
        throw StateError('Subscription session changed');
      }
      await action();
    });
    _subscriptionQueue = result.then<void>(
      (_) {},
      onError: (Object e, StackTrace s) {},
    );
    return result;
  }

  Future<void> _subscribe(
    String channel,
    String rawSymbol,
  ) => _queueSubscription(() async {
    final symbol = TradingPair.canonicalSymbol(rawSymbol);
    if (await getInstrument(symbol) == null) {
      throw ArgumentError('Unsupported symbol: $symbol');
    }
    final key = '$channel:$symbol';
    if (_channelIds.containsKey(key)) return;
    await _transport.requestEvent(
      {
        'event': 'subscribe',
        'channel': channel,
        'symbol': 't$symbol',
        if (channel == 'book') ...{'prec': 'P0', 'freq': 'F0', 'len': '25'},
      },
      (e) =>
          e['event'] == 'error' ||
          (e['event'] == 'subscribed' &&
              e['channel'] == channel &&
              e['symbol'] == 't$symbol'),
    );
    // The channel is registered synchronously in _onMessage, before snapshots.
  });

  Future<void> _unsubscribe(String channel, String rawSymbol) =>
      _queueSubscription(() async {
        final symbol = TradingPair.canonicalSymbol(rawSymbol);
        final id = _channelIds['$channel:$symbol'];
        if (id == null) return;
        final result = await _transport.requestEvent(
          {'event': 'unsubscribe', 'chanId': id},
          (e) =>
              e['event'] == 'error' ||
              (e['event'] == 'unsubscribed' && e['chanId'] == id),
        );
        if (result['status'] != 'OK') {
          throw const BitfinexApiException(
            'unsubscribe',
            'Unsubscribe rejected',
          );
        }
        _channelIds.remove('$channel:$symbol');
        _channels.remove(id);
        if (channel == 'book') _books.remove(symbol);
        if (channel == 'ticker') _tickers.remove(symbol);
      });

  // The authenticated channel already streams all account orders/positions.
  Future<void> subscribeUserChangesForInstrument(
    String instrumentName, {
    String interval = '100ms',
  }) async {
    _requireAuth();
  }

  Future<void> unsubscribeUserChangesForInstrument(
    String instrumentName, {
    String interval = '100ms',
  }) async {}

  void _onMessage(dynamic message) {
    if (_disposed) return;
    try {
      if (message is Map) {
        if (message['event'] == 'subscribed') {
          final channel = message['channel'] as String;
          final symbol = TradingPair.canonicalSymbol(
            message['symbol'] as String,
          );
          final id = message['chanId'] as int;
          _channels[id] = (channel, symbol);
          _channelIds['$channel:$symbol'] = id;
        }
        return;
      }
      final event = _list(message);
      if (event.length < 2 || event[1] == 'hb') return;
      if (event[0] == 0) {
        if (event.length < 3) return;
        final type = event[1];
        switch (type) {
          case 'os':
            for (final row in _list(event[2])) {
              _publishOrder(_parseOrder(_list(row)));
            }
          case 'on':
          case 'ou':
          case 'oc':
            _publishOrder(_parseOrder(_list(event[2])));
          case 'ps':
            for (final row in _list(event[2])) {
              _publishPosition(_parsePosition(_list(row)));
            }
          case 'pn':
          case 'pu':
          case 'pc':
            _publishPosition(_parsePosition(_list(event[2])));
          case 'tu':
            _emit(
              _userChangesController,
              UserChanges(trades: [_parseTrade(_list(event[2]))]),
            );
        }
        return;
      }
      final channel = _channels[event[0]];
      if (channel == null) return;
      final (type, symbol) = channel;
      final data = _list(event[1]);
      if (type == 'book') {
        final book = _books.putIfAbsent(symbol, _Book.new);
        if (data.isEmpty || data.first is List) {
          book.clear();
          for (final row in data) {
            book.update(_list(row));
          }
        } else {
          book.update(data);
        }
        final snapshot = book.snapshot(symbol);
        if (snapshot.bestAsk > 0 && snapshot.bestBid >= snapshot.bestAsk) {
          throw const FormatException('Crossed order book');
        }
        _emit(_orderBookController, snapshot);
      } else if (type == 'ticker') {
        final ticker = _parseTicker(symbol, data);
        _tickers[symbol] = ticker;
        _emit(_tickerController, ticker);
      }
    } catch (e) {
      _transport.fail('Stream parsing failed: $e');
    }
  }

  void _publishOrder(Order order) {
    final previous = _orders[order.orderId];
    if (previous != null &&
        (order.lastUpdateTimestamp < previous.lastUpdateTimestamp ||
            (!previous.isActive &&
                order.isActive &&
                order.lastUpdateTimestamp <= previous.lastUpdateTimestamp))) {
      return;
    }
    _orders[order.orderId] = order;
    _emit(_orderController, order);
  }

  void _publishPosition(Position position) {
    _positions[position.instrumentName] = position;
    _emit(_positionController, position);
  }

  void _requireAuth() {
    if (!isAuthenticated) throw StateError('Please authenticate first');
  }

  Future<Order?> placeOrder({
    required String instrumentName,
    required String direction,
    required double amount,
    required String orderType,
    double? price,
    bool postOnly = false,
    bool reduceOnly = false,
    double? stopPrice,
    String? trigger,
    double? trailing,
    int leverage = 1,
    bool marginTrading = false,
  }) async {
    _requireAuth();
    final pair = await getInstrument(instrumentName);
    if (pair == null) throw ArgumentError('Unsupported instrument');
    if (direction != 'buy' && direction != 'sell') {
      throw ArgumentError('Invalid direction');
    }
    if (!amount.isFinite ||
        amount < pair.minTradeAmount ||
        amount > _maxAmounts[pair.symbol]!) {
      throw ArgumentError('Amount is outside exchange limits');
    }
    if (postOnly && orderType != 'limit') {
      throw ArgumentError('Post-only requires a limit order');
    }
    if (marginTrading &&
        (pair.type != TradingPairType.spot || !pair.supportsMargin)) {
      throw ArgumentError(
        'Margin trading is not supported for this instrument',
      );
    }
    if (reduceOnly && pair.type == TradingPairType.spot && !marginTrading) {
      throw ArgumentError('Exchange orders do not support reduce-only');
    }
    if (leverage < 1 || leverage > pair.maxLeverage) {
      throw ArgumentError('Invalid leverage');
    }
    final nativeType = switch (orderType) {
      'limit' => 'LIMIT',
      'market' => 'MARKET',
      'stop_market' => 'STOP',
      'stop_limit' => 'STOP LIMIT',
      'trailing_stop' => 'TRAILING STOP',
      _ => throw UnsupportedError(
        'Bitfinex has no native $orderType order; use a limit take-profit order',
      ),
    };
    if (orderType.startsWith('stop_') || orderType == 'trailing_stop') {
      if (trigger != null && trigger != 'last_price') {
        throw UnsupportedError(
          'Bitfinex stop orders trigger on last traded price',
        );
      }
    }
    String positive(double? value, String name) {
      if (value == null || !value.isFinite || value <= 0) {
        throw ArgumentError('$name must be positive');
      }
      return _price(value);
    }

    final now = DateTime.now().microsecondsSinceEpoch % ((1 << 45) - 1);
    _clientOrderId = math.max(now, _clientOrderId + 1);
    final cid = _clientOrderId;
    final body = <String, dynamic>{
      'cid': cid,
      'type':
          '${pair.type == TradingPairType.spot && !marginTrading ? 'EXCHANGE ' : ''}$nativeType',
      'symbol': 't${pair.symbol}',
      'amount': _amount(direction == 'buy' ? amount : -amount),
      'price': switch (orderType) {
        'market' || 'trailing_stop' => '0',
        'stop_market' || 'stop_limit' => positive(stopPrice, 'Trigger price'),
        _ => positive(price, 'Price'),
      },
      'flags': (postOnly ? 4096 : 0) | (reduceOnly ? 1024 : 0),
      if (orderType == 'stop_limit')
        'price_aux_limit': positive(price, 'Limit price'),
      if (orderType == 'trailing_stop')
        'price_trailing': positive(trailing, 'Trailing distance'),
      // Carry the UI's selected leverage to the exchange.
      if (pair.type == TradingPairType.future) 'lev': leverage,
      'meta': {'protect_selfmatch': 1},
    };
    final row = await _writeOrder('on', body, cid: cid);
    final order = _parseOrder(_list(row));
    _publishOrder(order);
    return order;
  }

  Future<Order?> editOrder(
    String orderId,
    double newPrice, {
    double? newAmount,
  }) async {
    _requireAuth();
    var current = _orders[orderId];
    if (current == null) {
      for (final order in await getOpenOrders()) {
        if (order.orderId == orderId) current = order;
      }
    }
    if (current == null || !current.isActive) {
      throw StateError('Order is no longer active');
    }
    final order = current;
    final pair = await getInstrument(order.instrumentName);
    if (pair == null) throw StateError('Unverified instrument');
    final body = <String, dynamic>{
      'id': int.parse(orderId),
      'price': _price(newPrice),
      'flags': order.flags,
    };
    // Repricing must omit amount. Re-sending the original amount after a partial
    // fill would increase the remaining order on Bitfinex.
    if (newAmount != null && newAmount != order.amount) {
      final remaining = newAmount - (order.filledAmount ?? 0);
      if (!remaining.isFinite ||
          remaining < pair.minTradeAmount ||
          remaining > _maxAmounts[pair.symbol]!) {
        throw ArgumentError('New remaining amount is outside exchange limits');
      }
      body['amount'] = _amount(order.isBuy ? remaining : -remaining);
    }
    if (pair.type == TradingPairType.future) {
      final leverage = _orderLeverage[orderId];
      if (leverage == null) {
        throw StateError(
          'Derivative leverage missing; refresh order before editing',
        );
      }
      body['lev'] = leverage;
    }
    final updated = _parseOrder(
      _list(await _writeOrder('ou', body, id: orderId)),
    );
    _publishOrder(updated);
    return updated;
  }

  Future<bool> cancelOrder(String orderId) async {
    _requireAuth();
    final closed = Completer<Order>();
    final subscription = orderStream.listen((order) {
      if (order.orderId == orderId && !order.isActive && !closed.isCompleted) {
        closed.complete(order);
      }
    });
    try {
      final order = _parseOrder(
        _list(await _writeOrder('oc', {'id': int.parse(orderId)}, id: orderId)),
      );
      // The request notification can contain the pre-cancellation ACTIVE order.
      // Only the terminal order event confirms that it actually left the book.
      _publishOrder(order);
      final known = _orders[orderId];
      if (known != null && !known.isActive) return true;
      await closed.future.timeout(const Duration(seconds: 15));
      return true;
    } finally {
      await subscription.cancel();
    }
  }

  Future<dynamic> _writeOrder(
    String operation,
    Map<String, dynamic> body, {
    int? cid,
    String? id,
  }) async {
    _requireAuth();
    final key = '$operation:${cid ?? id}';
    if (!_pendingOrderWrites.add(key)) {
      throw StateError(
        'An order request is pending or its outcome is unknown; reconnect and reconcile before retrying',
      );
    }
    var outcomeUnknown = false;
    try {
      final response = await _transport.requestMessage(
        [0, operation, null, body],
        (event) {
          if (event is! List ||
              event.length < 3 ||
              event[0] != 0 ||
              event[1] != 'n') {
            return false;
          }
          final notification = event[2];
          if (notification is! List ||
              notification.length < 8 ||
              notification[1] != '$operation-req') {
            return false;
          }
          final data = notification[4];
          if (data is List) {
            return cid != null
                ? data.length > 2 && data[2] == cid
                : data.isNotEmpty && data[0].toString() == id;
          }
          if (data is Map) {
            return cid != null
                ? data['cid'] == cid
                : data['id'].toString() == id;
          }
          return false;
        },
      );
      return _notification(_list(response)[2]);
    } on TimeoutException {
      outcomeUnknown = true;
      rethrow;
    } finally {
      if (!outcomeUnknown) _pendingOrderWrites.remove(key);
    }
  }

  Future<List<Order>> getOpenOrders() async {
    _requireAuth();
    final rows = _list(await _transport.privatePost('v2/auth/r/orders'));
    return rows.map((r) => _parseOrder(_list(r))).toList();
  }

  Future<List<Order>> getOpenOrdersByInstrument(String instrumentName) async {
    _requireAuth();
    final symbol = TradingPair.canonicalSymbol(instrumentName);
    final rows = _list(
      await _transport.privatePost('v2/auth/r/orders/t$symbol'),
    );
    final orders = rows.map((r) => _parseOrder(_list(r))).toList();
    for (final o in orders) {
      _orders[o.orderId] = o;
    }
    return orders;
  }

  Future<List<Position>> getPositions() async {
    _requireAuth();
    return _list(
      await _transport.privatePost('v2/auth/r/positions'),
    ).map((r) => _parsePosition(_list(r))).toList();
  }

  Future<Position?> getPosition(String instrumentName) async {
    final symbol = TradingPair.canonicalSymbol(instrumentName);
    for (final position in await getPositions()) {
      if (position.instrumentName == symbol) return position;
    }
    return null;
  }

  Future<List<TradeHistory>> getUserTradesByInstrument({
    required String instrumentName,
    required DateTime from,
    required DateTime to,
    bool historical = true,
  }) async {
    _requireAuth();
    final symbol = TradingPair.canonicalSymbol(instrumentName);
    final trades = <String, TradeHistory>{};
    var start = from.millisecondsSinceEpoch;
    final end = to.millisecondsSinceEpoch;
    if (start > end) throw ArgumentError('History start exceeds end');
    const limit = 2500;
    while (start <= end) {
      final rows = _list(
        await _transport.privatePost('v2/auth/r/trades/t$symbol/hist', {
          'start': start,
          'end': end,
          'sort': 1,
          'limit': limit,
        }),
      );
      for (final row in rows) {
        final trade = _parseTrade(_list(row));
        trades[trade.tradeId] = trade;
      }
      if (rows.length < limit) break;
      final lastTimestamp = (_list(rows.last)[2] as num).toInt();
      if (lastTimestamp <= start) {
        throw StateError(
          'History exceeds 2500 executions at one timestamp; narrow the query',
        );
      }
      // Overlap the boundary and deduplicate by trade ID, preserving fills
      // with identical timestamps across pages.
      start = lastTimestamp;
    }
    return trades.values.toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  Future<List<dynamic>> getWallets() async {
    _requireAuth();
    return _list(await _transport.privatePost('v2/auth/r/wallets'));
  }

  Future<List<TransferBalance>> getTransferBalances() async {
    final balances = <TransferBalance>[];
    for (final raw in await getWallets()) {
      final row = _list(raw);
      if (row.length < 5) {
        throw const FormatException('Invalid wallet balance');
      }
      final currency = row[1] as String;
      final wallet = TransferWallet.fromApi(row[0] as String, currency);
      if (wallet == null) continue;
      balances.add(
        TransferBalance(
          wallet: wallet,
          currency: currency,
          balance: Decimal.parse(row[2].toString()),
          available: row[4] == null ? null : Decimal.parse(row[4].toString()),
        ),
      );
    }
    return balances;
  }

  Future<void> transferBetweenWallets({
    required TransferWallet from,
    required TransferWallet to,
    required String currency,
    required String amount,
  }) async {
    _requireAuth();
    final generation = _generation;
    if (from == to) throw ArgumentError('请选择不同的转出和转入钱包');
    final quantity = parseTransferAmount(amount);
    if (currency != from.currencyFor(currency)) {
      throw ArgumentError('币种与转出钱包不匹配');
    }
    final destinationCurrency = to.currencyFor(currency);
    if (from == TransferWallet.derivatives || to == TransferWallet.derivatives) {
      final currencies = _list(
        _list(await _transport.publicGet('v2/conf/pub:list:currency')).single,
      );
      if (!currencies.contains(currency) ||
          !currencies.contains(destinationCurrency)) {
        throw ArgumentError('该币种不支持所选钱包间划转');
      }
    }
    final balances = await getTransferBalances();
    final source = balances.where(
      (b) => b.wallet == from && b.currency == currency,
    );
    if (source.length != 1) throw StateError('未找到唯一的转出钱包余额');
    final available = source.single.available;
    if (available == null) throw StateError('可用余额尚未计算，请刷新后再试');
    if (quantity > available) throw StateError('划转数量超过钱包可用余额');
    _requireAuth();
    if (generation != _generation) throw StateError('账号会话已变更，请重新操作');
    _notification(
      await _transport.privatePost('v2/auth/w/transfer', {
        'from': from.apiName,
        'to': to.apiName,
        'currency': currency,
        'currency_to': destinationCurrency,
        'amount': quantity.toString(),
      }),
    );
  }

  Future<Map<String, dynamic>?> getAccountSummary({
    String currency = 'USD',
  }) async {
    final name = currency.toUpperCase();
    final walletType = name.endsWith('F0') ? 'margin' : 'exchange';
    var balance = 0.0;
    var available = 0.0;
    for (final raw in await getWallets()) {
      final w = _list(raw);
      if (w[1] != name || !_walletMatches(w[0] as String, walletType)) continue;
      balance += _number(w[2]);
      // null means uncalculated; never substitute balance for spendable funds.
      if (w[4] == null) {
        throw StateError('Available wallet balance is not calculated');
      }
      available += _number(w[4]);
    }
    return {
      'currency': name,
      'equity': balance,
      'balance': balance,
      'available_funds': available,
      'maintenance_margin': 0.0,
    };
  }

  Future<Map<String, dynamic>?> getAccountSummaries({
    bool extended = true,
  }) async {
    _requireAuth();
    final wallets = await getWallets();
    final grouped = <String, Map<String, dynamic>>{};
    for (final raw in wallets) {
      final w = _list(raw);
      final currency = w[1] as String;
      final balance = _number(w[2]);
      if (w[4] == null) {
        throw StateError('Available balance for $currency is not calculated');
      }
      final available = _number(w[4]);
      final row = grouped.putIfAbsent(
        currency,
        () => {
          'currency': currency,
          'balance': 0.0,
          'equity': 0.0,
          'available_funds': 0.0,
          'available_withdrawal_funds': 0.0,
          'locked_balance': 0.0,
          'margin_balance': 0.0,
          'margin_model': 'Wallet balances',
        },
      );
      row['balance'] += balance;
      row['equity'] += balance;
      row['available_funds'] += available;
      if (w[0] == 'exchange') row['available_withdrawal_funds'] += available;
      row['locked_balance'] += balance - available;
      if (_walletMatches(w[0] as String, 'margin')) {
        row['margin_balance'] += balance;
      }
    }
    final positions = await getPositions();
    // Wallet/identity reads do not need the trading catalogue for flat accounts.
    if (positions.isNotEmpty) await _loadCatalogue();
    final valuations = await Future.wait(
      positions.map((position) async {
        final pair = _instruments[position.instrumentName];
        if (pair == null) return null;
        var pnl = position.floatingProfitLoss;
        if (position.kind == 'margin') {
          // Margin API P/L does not carry a currency. Calculate a quote-currency
          // estimate explicitly rather than adding that value to an arbitrary wallet.
          final quote = _parseTicker(
            pair.symbol,
            _list(await _transport.publicGet('v2/ticker/t${pair.symbol}')),
          );
          if (quote.markPrice <= 0 || position.averagePrice <= 0) {
            throw StateError(
              'Margin position valuation requires a valid reference price',
            );
          }
          pnl =
              (quote.markPrice - position.averagePrice) *
              position.sizeCurrency *
              (position.isLong ? 1 : -1);
        }
        return (currency: pair.settlementCurrency, pnl: pnl);
      }),
    );
    for (final valuation in valuations) {
      if (valuation == null) continue;
      final row = grouped.putIfAbsent(
        valuation.currency,
        () => {
          'currency': valuation.currency,
          'balance': 0.0,
          'equity': 0.0,
          'available_funds': 0.0,
          'available_withdrawal_funds': 0.0,
          'locked_balance': 0.0,
          'margin_balance': 0.0,
          'margin_model': 'Position P/L estimate',
        },
      );
      row['equity'] += valuation.pnl;
    }
    final user = _user!;
    return {
      'id': user[0],
      'username': user[2],
      'email': user[1],
      'type': _paper ? 'Paper Trading' : 'Live',
      'mandatory_tfa': user.length > 26 && _list(user[26]).isNotEmpty,
      'security_keys_enabled':
          user.length > 26 && _list(user[26]).contains('u2f'),
      'summaries': grouped.values.toList(),
    };
  }

  bool _walletMatches(String actual, String expected) =>
      actual == expected || (expected == 'margin' && actual == 'trading');

  Future<double?> getIndexPrice({
    required String base,
    String quote = 'USD',
  }) async {
    String underlying(String value) {
      var c = value.toUpperCase();
      if (c.startsWith('TEST')) c = c.substring(4);
      if (c.endsWith('F0')) c = c.substring(0, c.length - 2);
      return c == 'USDT' ? 'UST' : c;
    }

    final b = underlying(base), q = underlying(quote);
    if (b == q) return 1;
    await _loadCatalogue();
    final symbols = _exchangeSymbols;
    final direct = b.length == 3 && q.length == 3 ? '$b$q' : '$b:$q';
    final inverse = q.length == 3 && b.length == 3 ? '$q$b' : '$q:$b';
    if (!symbols.contains(direct) && !symbols.contains(inverse)) return null;
    final inverted = !symbols.contains(direct);
    final data = _list(
      await _transport.publicGet('v2/ticker/t${inverted ? inverse : direct}'),
    );
    final price = _number(data[6]);
    return price > 0 ? (inverted ? 1 / price : price) : null;
  }

  Future<List<AddressBookEntry>> getAddressBook({
    String? currency,
  }) async => throw UnsupportedError(
    'Bitfinex does not expose the Deribit withdrawal address book API; enter an address and network',
  );
  Future<List<Announcement>> getAnnouncements({
    int? startTimestamp,
    int count = 20,
  }) async => throw UnsupportedError(
    'Bitfinex does not expose a matching announcements API',
  );
  Future<List<Announcement>> getNewAnnouncements() async =>
      throw UnsupportedError(
        'Bitfinex does not expose account announcement read state',
      );
  Future<bool> setAnnouncementAsRead(int announcementId) async =>
      throw UnsupportedError(
        'Bitfinex does not expose account announcement read state',
      );
  Future<void> subscribeAnnouncements() async =>
      throw UnsupportedError('Bitfinex has no announcements WebSocket channel');
  Future<void> unsubscribeAnnouncements() async =>
      throw UnsupportedError('Bitfinex has no announcements WebSocket channel');

  Future<List<Withdrawal>> getWithdrawals({
    required String currency,
    int count = 20,
    int offset = 0,
  }) async {
    _requireAuth();
    if (currency.trim().isEmpty || count <= 0 || offset < 0) {
      throw ArgumentError('Invalid withdrawal history query');
    }
    final withdrawals = <int, Withdrawal>{};
    int? end;
    const limit = 100;
    while (withdrawals.length < offset + count) {
      final rows = _list(
        await _transport.privatePost(
          'v2/auth/r/movements/${currency.toUpperCase()}/hist',
          {'limit': limit, if (end != null) 'end': end},
        ),
      );
      for (final raw in rows) {
        final r = _list(raw);
        if (_number(r[12]) >= 0) continue;
        final withdrawal = Withdrawal(
          id: int.parse(r[0].toString()),
          currency: r[1] as String,
          amount: _number(r[12]).abs(),
          fee: _number(r[13]).abs(),
          address: r[16] as String? ?? '',
          state: (r[9] as String).toLowerCase(),
          transactionId: r[20] as String?,
          createdTimestamp: (r[5] as num).toInt(),
          updatedTimestamp: (r[6] as num).toInt(),
        );
        withdrawals[withdrawal.id] = withdrawal;
      }
      if (rows.length < limit) break;
      final boundary = (_list(rows.last)[6] as num).toInt();
      if (end != null && boundary >= end) {
        throw StateError(
          'Movement pagination cannot advance at this timestamp',
        );
      }
      end = boundary;
    }
    return withdrawals.values.skip(offset).take(count).toList();
  }

  Future<Map<String, List<String>>> getWithdrawalMethods() async {
    final response = _list(
      await _transport.publicGet('v2/conf/pub:map:tx:method'),
    );
    final methodsByCurrency = <String, Set<String>>{};
    for (final raw in _list(response.single)) {
      final row = _list(raw);
      // The API returns [method, currencies]; the form needs currency → methods.
      final method = (row[0] as String).toLowerCase();
      for (final rawCurrency in _list(row[1])) {
        final currency = (rawCurrency as String).toUpperCase();
        methodsByCurrency.putIfAbsent(currency, () => <String>{}).add(method);
      }
    }
    if (methodsByCurrency.isEmpty) {
      throw const FormatException('No withdrawal methods available');
    }
    return methodsByCurrency.map(
      (currency, methods) => MapEntry(currency, methods.toList()..sort()),
    );
  }

  Future<Map<String, dynamic>?> withdraw({
    required String currency,
    required String address,
    required double amount,
    required String method,
    String? destinationTag,
  }) async {
    _requireAuth();
    if (_paper) throw UnsupportedError('Paper tokens cannot be withdrawn');
    if (method.isEmpty) {
      throw ArgumentError('Select a Bitfinex withdrawal method/network');
    }
    if (!amount.isFinite || amount <= 0 || address.trim().isEmpty) {
      throw ArgumentError('Invalid withdrawal');
    }
    final methods = await getWithdrawalMethods();
    if (!(methods[currency.toUpperCase()]?.contains(method.toLowerCase()) ??
        false)) {
      throw ArgumentError('Withdrawal method does not match currency');
    }
    final data = _notification(
      await _transport.privatePost('v2/auth/w/withdraw', {
        'wallet': 'exchange',
        'method': method.toLowerCase(),
        'amount': _amount(amount),
        'address': address.trim(),
        if (destinationTag != null) 'payment_id': destinationTag,
      }),
    );
    return {'id': _list(data)[0]};
  }

  dynamic _notification(dynamic result) {
    final row = _list(result);
    if (row.length < 8) {
      throw const FormatException('Invalid operation notification');
    }
    if (row[6] != 'SUCCESS') {
      throw BitfinexApiException(row[5] ?? row[6], row[7].toString());
    }
    return row[4];
  }

  Order _parseOrder(List<dynamic> row) {
    if (row.length < 20) throw const FormatException('Invalid order');
    final remaining = _number(row[6]), original = _number(row[7]);
    final rawType = (row[8] as String).replaceFirst('EXCHANGE ', '');
    final status = row[13] as String;
    final type = switch (rawType) {
      'LIMIT' => 'limit',
      'MARKET' => 'market',
      'STOP' => 'stop_market',
      'STOP LIMIT' => 'stop_limit',
      'TRAILING STOP' => 'trailing_stop',
      _ => rawType.toLowerCase(),
    };
    final state =
        status.startsWith('ACTIVE') || status.startsWith('PARTIALLY FILLED')
        ? (rawType.contains('STOP') ? 'untriggered' : 'open')
        : status.startsWith('EXECUTED')
        ? 'filled'
        : status.contains('CANCELED')
        ? 'cancelled'
        : 'rejected';
    final flags = (row[12] as num).toInt();
    final id = row[0].toString();
    final meta = row.length > 31 && row[31] is Map ? row[31] as Map : null;
    final postMeta = meta?[r'$F7'];
    // Bitfinex consumes POST on a successful edit: later ou/REST snapshots can
    // omit both the flag and $F7. Keep the known repricing policy for this
    // session and explicitly send POST on every subsequent edit. An explicit
    // false metadata value still overrides that policy.
    final postOnly =
        flags & 4096 != 0 ||
        postMeta == 1 ||
        postMeta == true ||
        (postMeta == null && _orders[id]?.postOnly == true);
    if (row.length > 31 && row[31] is Map) {
      final leverage = (row[31] as Map)[r'$F33'];
      if (leverage is num) _orderLeverage[id] = leverage.toInt();
    }
    return Order(
      orderId: id,
      instrumentName: TradingPair.canonicalSymbol(row[3] as String),
      direction: original > 0 ? 'buy' : 'sell',
      amount: original.abs(),
      price: _number(type == 'stop_limit' ? row[19] : row[16]),
      orderState: state,
      orderType: type,
      isExchange: (row[8] as String).startsWith('EXCHANGE '),
      flags: flags | (postOnly ? 4096 : 0),
      stopPrice: type.startsWith('stop_') ? _number(row[16]) : null,
      trigger: rawType.contains('STOP') ? 'last_price' : null,
      trailing: type == 'trailing_stop' ? _number(row[18]) : null,
      averageExecutedPrice: _number(row[17]),
      filledAmount: math.max(0, original.abs() - remaining.abs()),
      creationTimestamp: (row[4] as num).toInt(),
      lastUpdateTimestamp: (row[5] as num).toInt(),
    );
  }

  Position _parsePosition(List<dynamic> r) {
    if (r.length < 16 || (r[15] != 0 && r[15] != 1)) {
      throw const FormatException('Missing or invalid position market type');
    }
    final symbol = TradingPair.canonicalSymbol(r[0] as String);
    final amount = r[1] == 'CLOSED' ? 0.0 : _number(r[2]);
    final average = _number(r[3]);
    final pnl = r[6] == null ? 0.0 : _number(r[6]);
    // Position messages have no mark/index fields. A mark implied by reported
    // UPL is valid for linear contracts; otherwise leave unavailable as zero.
    final isMargin = r[15] == 0;
    final mark = isMargin
        ? (_tickers[symbol]?.markPrice ?? 0.0)
        : amount != 0 && r[6] != null
        ? average + pnl / amount
        : 0.0;
    return Position(
      instrumentName: symbol,
      kind: isMargin ? 'margin' : 'future',
      size: amount.abs(),
      sizeCurrency: amount.abs(),
      direction: amount >= 0 ? 'buy' : 'sell',
      averagePrice: average,
      markPrice: mark,
      indexPrice: 0,
      settlementPrice: 0,
      leverage: r[9] == null ? 0 : _number(r[9]),
      maintenanceMargin: r.length > 18 && r[18] != null ? _number(r[18]) : 0,
      initialMargin: r.length > 17 && r[17] != null ? _number(r[17]) : 0,
      openOrdersMargin: 0,
      delta: amount,
      floatingProfitLoss: pnl,
      realizedProfitLoss: 0,
      totalProfitLoss: pnl,
      realizedFunding: 0,
      interestValue: _number(r[4]),
      estimatedLiquidationPrice: r[8] == null ? null : _number(r[8]),
    );
  }

  TradeHistory _parseTrade(List<dynamic> r) {
    if (r.length < 11) throw const FormatException('Invalid trade');
    final amount = _number(r[4]);
    return TradeHistory(
      tradeId: r[0].toString(),
      instrumentName: TradingPair.canonicalSymbol(r[1] as String),
      direction: amount > 0 ? 'buy' : 'sell',
      amount: amount.abs(),
      price: _number(r[5]),
      timestamp: (r[2] as num).toInt(),
      orderId: r[3].toString(),
      // Bitfinex fees are debits (negative); the UI subtracts positive costs.
      fee: -_number(r[9]),
      feeCurrency: r[10] as String,
      orderType: (r[6] as String? ?? '').toLowerCase(),
      markPrice: 0,
    );
  }

  TickerData _parseTicker(String symbol, List<dynamic> r) {
    if (r.length < 10) throw const FormatException('Invalid ticker');
    return TickerData(
      instrumentName: symbol,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      markPrice: _number(r[6]),
      indexPrice: 0,
      bestBid: _number(r[0]),
      bestAsk: _number(r[2]),
    );
  }

  String _price(double value) {
    if (!value.isFinite || value <= 0) {
      throw ArgumentError('Price must be positive');
    }
    final rounded = double.parse(value.toStringAsPrecision(5));
    if ((rounded - value).abs() > value.abs() * 1e-12 || value < 1e-8) {
      throw ArgumentError(
        'Price must use at most 5 significant digits and 8 decimals',
      );
    }
    final formatted = value.toStringAsFixed(8);
    if ((double.parse(formatted) - value).abs() > value.abs() * 1e-12) {
      throw ArgumentError('Price exceeds 8 decimal places');
    }
    return formatted;
  }

  String _amount(double value) {
    if (!value.isFinite || value == 0) {
      throw ArgumentError('Amount must be non-zero');
    }
    final formatted = value.toStringAsFixed(8);
    if ((double.parse(formatted) - value).abs() > 1e-12) {
      throw ArgumentError('Amount exceeds 8 decimal places');
    }
    return formatted;
  }

  static List<dynamic> _list(dynamic value) {
    if (value is! List) throw const FormatException('Expected an array');
    return List<dynamic>.of(value);
  }

  static double _number(dynamic value) {
    final number = value is num
        ? value.toDouble()
        : double.parse(value as String);
    if (!number.isFinite) throw const FormatException('Non-finite number');
    return number;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _connectionWanted = false;
    _reconnectTimer?.cancel();
    _clearSession();
    unawaited(_messages.cancel());
    unawaited(_disconnects.cancel());
    _transport.dispose();
    for (final c in <StreamController<dynamic>>[
      _orderBookController,
      _orderController,
      _positionController,
      _tickerController,
      _userChangesController,
      _announcementController,
      _connectedController,
      _disconnectedController,
    ]) {
      unawaited(c.close());
    }
  }
}

class _Book {
  final bids = SplayTreeMap<double, double>((a, b) => b.compareTo(a));
  final asks = SplayTreeMap<double, double>();
  void clear() {
    bids.clear();
    asks.clear();
  }

  void update(List<dynamic> row) {
    if (row.length != 3) {
      throw const FormatException('Invalid order book level');
    }
    final price = BitfinexApiService._number(row[0]);
    final count = row[1] as num;
    final amount = BitfinexApiService._number(row[2]);
    if (price <= 0 || amount == 0 || count < 0) {
      throw const FormatException('Invalid book level value');
    }
    final side = amount > 0 ? bids : asks;
    if (count == 0) {
      side.remove(price);
    } else {
      side[price] = amount.abs();
    }
  }

  OrderBookData snapshot(String symbol) => OrderBookData(
    instrumentName: symbol,
    timestamp: DateTime.now().millisecondsSinceEpoch,
    asks: asks.entries.map((e) => <dynamic>[e.key, e.value]).toList(),
    bids: bids.entries.map((e) => <dynamic>[e.key, e.value]).toList(),
  );
}
