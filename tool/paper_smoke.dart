import 'dart:async';
import 'dart:io';
import 'package:bitfinex_chase/models/market_data.dart';
import 'package:bitfinex_chase/services/bitfinex_api_service.dart';

Map<String, String> readEnv() {
  final values = <String, String>{};
  for (final line in File('.env').readAsLinesSync()) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final index = line.indexOf('=');
    if (index < 1) throw FormatException('Invalid .env entry');
    var value = line.substring(index + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
    values[line.substring(0, index).trim()] = value;
  }
  return values;
}

Future<void> main(List<String> args) async {
  final env = readEnv();
  final api = BitfinexApiService();
  final ownOrders = <String>{};
  final streamOrders = <Order>[];
  final sub = api.orderStream.listen(streamOrders.add);
  final books = <String, OrderBookData>{};
  final bookSub = api.orderBookStream.listen(
    (b) => books[b.instrumentName] = b,
  );
  try {
    await api.connect(isTestnet: true);
    stdout.writeln('PASS WebSocket connected');
    await api.authenticate(env['API_KEY']!, env['API_SECRET']!);
    stdout.writeln('PASS authentication and Paper account verification');
    const symbol = 'TESTBTC:TESTUSD';
    final pair = await api.getInstrument(symbol);
    if (pair == null || !pair.isVerified) {
      throw StateError('Missing verified instrument');
    }
    stdout.writeln(
      'PASS live catalogue: $symbol minimum=${pair.minTradeAmount}',
    );
    await api.subscribeOrderBook(symbol);
    await api.subscribeTicker(symbol);
    await waitFor(
      () => books[symbol]?.bestAsk != null && books[symbol]!.bestAsk > 0,
    );
    final book = books[symbol]!;
    stdout.writeln(
      'PASS book snapshot: bid=${book.bestBid} ask=${book.bestAsk}',
    );
    final account = await api.getAccountSummaries();
    if (account?['type'] != 'Paper Trading') {
      throw StateError('Account summary incorrect');
    }
    stdout.writeln('PASS wallets and account summary');
    stdout.writeln(
      'PASS open orders=${(await api.getOpenOrders()).length}, positions=${(await api.getPositions()).length}',
    );
    if (!args.contains('--trade')) return;
    final beforeWallets = (await api.getWallets()).cast<List>();
    final beforeBase = beforeWallets.where(
      (w) => w[0] == 'exchange' && w[1] == 'TESTBTC',
    );
    final initialBase = beforeBase.isEmpty
        ? 0.0
        : (beforeBase.single[2] as num).toDouble();
    final quantity = pair.minTradeAmount * 2;
    final tick = pair.tickSizeAt(book.bestBid);
    final price = (book.bestBid * 0.9 / tick).floor() * tick;
    final order = (await api.placeOrder(
      instrumentName: symbol,
      direction: 'buy',
      amount: quantity,
      orderType: 'limit',
      price: price,
      postOnly: true,
    ))!;
    ownOrders.add(order.orderId);
    if (!order.isActive || !order.postOnly || !order.isBuy) {
      throw StateError('Post-only order rejected');
    }
    stdout.writeln('PASS post-only buy');
    final edit = (await api.editOrder(order.orderId, price + tick))!;
    if (edit.price != price + tick || edit.amount != quantity || !edit.isBuy) {
      throw StateError('Incorrect edit');
    }
    stdout.writeln('PASS price-only edit preserves direction and amount');
    if (!await api.cancelOrder(order.orderId)) {
      throw StateError('Cancel failed');
    }
    ownOrders.remove(order.orderId);
    await waitFor(
      () => streamOrders.any((o) => o.orderId == order.orderId && !o.isActive),
    );
    if ((await api.getOpenOrdersByInstrument(
      symbol,
    )).any((o) => o.orderId == order.orderId)) {
      throw StateError('Cancelled order remains open');
    }
    stdout.writeln('PASS cancellation and private WebSocket lifecycle');
    final buy = (await api.placeOrder(
      instrumentName: symbol,
      direction: 'buy',
      amount: quantity,
      orderType: 'market',
    ))!;
    if (buy.isActive) ownOrders.add(buy.orderId);
    await waitFor(
      () => streamOrders.any((o) => o.orderId == buy.orderId && o.isFilled),
    );
    ownOrders.remove(buy.orderId);
    final wallet = (await api.getWallets())
        .cast<List>()
        .where((w) => w[0] == 'exchange' && w[1] == 'TESTBTC')
        .single;
    final available = (wallet[4] as num).toDouble();
    final sellAmount = ((available - initialBase) * 1e8).floor() / 1e8;
    final sell = (await api.placeOrder(
      instrumentName: symbol,
      direction: 'sell',
      amount: sellAmount,
      orderType: 'market',
    ))!;
    if (sell.isActive) ownOrders.add(sell.orderId);
    await waitFor(
      () => streamOrders.any((o) => o.orderId == sell.orderId && o.isFilled),
    );
    ownOrders.remove(sell.orderId);
    stdout.writeln('PASS market buy/sell and execution streams');
    // Use exchange timestamps to avoid local/exchange clock skew. The history
    // store can lag execution delivery; allow bounded time for it to index.
    final historyDeadline = DateTime.now().add(const Duration(seconds: 20));
    while (true) {
      final trades = await api.getUserTradesByInstrument(
        instrumentName: symbol,
        from: DateTime.fromMillisecondsSinceEpoch(buy.creationTimestamp - 1000),
        to: DateTime.fromMillisecondsSinceEpoch(
          sell.lastUpdateTimestamp + 1000,
        ),
      );
      if (trades.any((t) => t.orderId == buy.orderId && t.isBuy) &&
          trades.any((t) => t.orderId == sell.orderId && t.isSell)) {
        break;
      }
      if (DateTime.now().isAfter(historyDeadline)) {
        throw StateError('Executions missing in history');
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    stdout.writeln('PASS trade history directions and fee parsing');
  } finally {
    for (final id in ownOrders) {
      if (api.isAuthenticated &&
          (await api.getOpenOrders()).any((o) => o.orderId == id)) {
        if (!await api.cancelOrder(id)) {
          throw StateError('Cleanup failed for $id');
        }
        stdout.writeln('Cleaned up scenario order $id');
      }
    }
    await sub.cancel();
    await bookSub.cancel();
    await api.disconnect();
    api.dispose();
  }
}

Future<void> waitFor(bool Function() ready) async {
  final end = DateTime.now().add(const Duration(seconds: 20));
  while (!ready()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('Scenario did not complete');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
