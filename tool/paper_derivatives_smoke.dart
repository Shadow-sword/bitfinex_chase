import 'dart:async';
import 'dart:io';
import 'package:bitfinex_chase/models/market_data.dart';
import 'package:bitfinex_chase/services/bitfinex_api_service.dart';
import 'package:bitfinex_chase/services/bitfinex_transport.dart';
import 'paper_smoke.dart' show readEnv, waitFor;

Future<void> main(List<String> args) async {
  final env = readEnv();
  final transport = BitfinexTransport();
  final api = BitfinexApiService(transport: transport);
  final orders = <String, Order>{};
  final own = <String>{};
  var openedPosition = false;
  final sub = api.orderStream.listen((o) => orders[o.orderId] = o);
  const symbol = 'TESTBTCF0:TESTUSDTF0';
  try {
    await api.connect(isTestnet: true);
    await api.authenticate(env['API_KEY']!, env['API_SECRET']!);
    final before = await api.getPosition(symbol);
    if (before != null && before.size != 0) {
      throw StateError('Scenario requires no existing position in $symbol');
    }
    var available = await walletBalance(api, 'margin', 'TESTUSDTF0');
    if (available < 10 && args.contains('--fund')) {
      // Buy only a small amount of Paper BTC with Paper USD, sell that amount
      // for Paper USDT, then use the documented derivative-wallet conversion.
      final btcBefore = await walletBalance(api, 'exchange', 'TESTBTC');
      final usdtBefore = await walletBalance(api, 'exchange', 'TESTUSDT');
      final buy = (await api.placeOrder(
        instrumentName: 'TESTBTC:TESTUSD',
        direction: 'buy',
        amount: 0.0004,
        orderType: 'market',
      ))!;
      await waitFor(() => orders[buy.orderId]?.isFilled == true);
      final acquired =
          await walletBalance(api, 'exchange', 'TESTBTC') - btcBefore;
      final sell = (await api.placeOrder(
        instrumentName: 'TESTBTC:TESTUSDT',
        direction: 'sell',
        amount: (acquired * 1e8).floor() / 1e8,
        orderType: 'market',
      ))!;
      await waitFor(() => orders[sell.orderId]?.isFilled == true);
      final funds =
          await walletBalance(api, 'exchange', 'TESTUSDT') - usdtBefore;
      final result = await transport.privatePost('v2/auth/w/transfer', {
        'from': 'exchange',
        'to': 'margin',
        'currency': 'TESTUSDT',
        'currency_to': 'TESTUSDTF0',
        'amount': funds.toStringAsFixed(8),
      });
      if (result is! List || result[6] != 'SUCCESS') {
        throw StateError('Paper collateral transfer failed: $result');
      }
      available = await walletBalance(api, 'margin', 'TESTUSDTF0');
      stdout.writeln('PASS Paper collateral conversion: $available TESTUSDTF0');
    }
    if (available < 10) {
      throw StateError(
        'At least 10 TESTUSDTF0 required; refill Paper balance or use --fund',
      );
    }
    final pair = (await api.getInstrument(symbol))!;
    final bookFuture = api.orderBookStream.firstWhere(
      (b) => b.instrumentName == symbol && b.bestAsk > 0,
    );
    await api.subscribeOrderBook(symbol);
    final book = await bookFuture.timeout(const Duration(seconds: 20));
    final tick = pair.tickSizeAt(book.bestAsk);
    final far = (book.bestBid * 0.9 / tick).floor() * tick;
    final amount = pair.minTradeAmount * 2;
    final limit = (await api.placeOrder(
      instrumentName: symbol,
      direction: 'buy',
      amount: amount,
      orderType: 'limit',
      price: far,
      postOnly: true,
      leverage: 2,
    ))!;
    own.add(limit.orderId);
    final edited = await api.editOrder(limit.orderId, far + tick);
    if (edited == null || edited.price != far + tick) {
      throw StateError('Derivative edit failed');
    }
    if (!await api.cancelOrder(limit.orderId)) {
      throw StateError('Derivative cancel failed');
    }
    own.remove(limit.orderId);
    stdout.writeln(
      'PASS derivative post-only order, leverage-preserving edit, cancel',
    );
    final buy = (await api.placeOrder(
      instrumentName: symbol,
      direction: 'buy',
      amount: amount,
      orderType: 'market',
      leverage: 2,
    ))!;
    openedPosition = true;
    await waitFor(() => orders[buy.orderId]?.isFilled == true);
    await waitPosition(api, symbol, (p) => p != null && p.size > 0 && p.isLong);
    stdout.writeln('PASS derivative market open and position stream');
    final stopPrice = (book.bestBid * 0.8 / tick).floor() * tick;
    for (final type in ['stop_market', 'stop_limit', 'trailing_stop']) {
      final protection = (await api.placeOrder(
        instrumentName: symbol,
        direction: 'sell',
        amount: amount,
        orderType: type,
        stopPrice: type == 'trailing_stop' ? null : stopPrice,
        price: type == 'stop_limit' ? stopPrice - tick : null,
        trailing: type == 'trailing_stop' ? 10000 : null,
        trigger: 'last_price',
        reduceOnly: true,
        leverage: 2,
      ))!;
      own.add(protection.orderId);
      if (!protection.reduceOnly || protection.orderType != type) {
        throw StateError('Protection flags incorrect');
      }
      if (!await api.cancelOrder(protection.orderId)) {
        throw StateError('Protection cancellation failed');
      }
      own.remove(protection.orderId);
      stdout.writeln(
        'PASS native $type reduce-only placement and cancellation',
      );
    }
    final closeHalf = (await api.placeOrder(
      instrumentName: symbol,
      direction: 'sell',
      amount: pair.minTradeAmount,
      orderType: 'market',
      reduceOnly: true,
      leverage: 2,
    ))!;
    await waitFor(() => orders[closeHalf.orderId]?.isFilled == true);
    await waitPosition(
      api,
      symbol,
      (p) => p != null && (p.size - pair.minTradeAmount).abs() < 1e-10,
    );
    stdout.writeln('PASS partial reduce-only close');
    final reverse = (await api.placeOrder(
      instrumentName: symbol,
      direction: 'sell',
      amount: pair.minTradeAmount * 2,
      orderType: 'market',
      leverage: 2,
    ))!;
    await waitFor(() => orders[reverse.orderId]?.isFilled == true);
    await waitPosition(api, symbol, (p) => p != null && p.isShort);
    stdout.writeln('PASS reversal from long to short');
    final close = (await api.placeOrder(
      instrumentName: symbol,
      direction: 'buy',
      amount: pair.minTradeAmount,
      orderType: 'market',
      reduceOnly: true,
      leverage: 2,
    ))!;
    await waitFor(() => orders[close.orderId]?.isFilled == true);
    await waitPosition(api, symbol, (p) => p == null || p.size == 0);
    openedPosition = false;
    stdout.writeln('PASS full close; no scenario position remains');
    stdout.writeln('DERIVATIVES_SCENARIOS_PASS');
  } finally {
    for (final id in own) {
      if (api.isAuthenticated &&
          (await api.getOpenOrders()).any((o) => o.orderId == id)) {
        await api.cancelOrder(id);
      }
    }
    if (openedPosition && api.isAuthenticated) {
      final p = await api.getPosition(symbol);
      if (p != null && p.size != 0) {
        await api.placeOrder(
          instrumentName: symbol,
          direction: p.isLong ? 'sell' : 'buy',
          amount: p.sizeCurrency,
          orderType: 'market',
          reduceOnly: true,
          leverage: 2,
        );
        await waitPosition(api, symbol, (p) => p == null || p.size == 0);
        stdout.writeln('Cleaned up derivative scenario position');
      }
    }
    await sub.cancel();
    await api.disconnect();
    api.dispose();
  }
}

Future<double> walletBalance(
  BitfinexApiService api,
  String wallet,
  String currency,
) async {
  final rows = (await api.getWallets()).cast<List>().where(
    (w) =>
        (w[0] == wallet || (wallet == 'margin' && w[0] == 'trading')) &&
        w[1] == currency,
  );
  return rows.isEmpty ? 0 : (rows.single[4] as num).toDouble();
}

Future<void> waitPosition(
  BitfinexApiService api,
  String symbol,
  bool Function(Position?) predicate,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!predicate(await api.getPosition(symbol))) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Position did not settle');
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
}
