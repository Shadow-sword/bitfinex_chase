import 'dart:async';
import 'dart:io';
import 'package:bitfinex_chase/models/market_data.dart';
import 'package:bitfinex_chase/services/bitfinex_api_service.dart';
import 'package:bitfinex_chase/services/bitfinex_transport.dart';
import 'paper_smoke.dart' show readEnv, waitFor;

/// Real Paper acceptance: mode isolation, margin long/short and position safety.
Future<void> main() async {
  final credentials = readEnv();
  final transport = BitfinexTransport();
  final api = BitfinexApiService(transport: transport);
  final orders = <String, Order>{};
  final ownedOrders = <String>{};
  const symbol = 'TESTBTC:TESTUSD';
  var ownsPosition = false;
  var transferred = 0.0;
  var initialMarginAvailable = 0.0;
  final subscription = api.orderStream.listen((o) => orders[o.orderId] = o);
  Future<void> transfer(String from, String to, double amount) async {
    if (!api.isAuthenticated || !api.isPaper) {
      throw StateError('Paper authentication required');
    }
    final result = await transport.privatePost('v2/auth/w/transfer', {
      'from': from,
      'to': to,
      'currency': 'TESTUSD',
      'currency_to': 'TESTUSD',
      'amount': amount.toStringAsFixed(8),
    });
    if (result is! List || result.length < 8 || result[6] != 'SUCCESS') {
      throw StateError('Paper wallet transfer failed');
    }
  }

  try {
    await api.connect(isTestnet: true);
    await api.authenticate(credentials['API_KEY']!, credentials['API_SECRET']!);
    if ((await api.getOpenOrders()).isNotEmpty ||
        (await api.getPositions()).isNotEmpty) {
      throw StateError(
        'Scenario requires no pre-existing Paper orders or positions',
      );
    }
    final pair = (await api.getInstrument(symbol))!;
    if (!pair.supportsMargin) {
      throw StateError('Paper symbol not margin-enabled');
    }
    initialMarginAvailable = await marginAvailable(api);
    if (initialMarginAvailable < 25) {
      transferred = 25 - initialMarginAvailable;
      await transfer('exchange', 'margin', transferred);
    }
    stdout.writeln('PASS Paper Margin wallet prepared');
    final bookResult = api.orderBookStream.firstWhere(
      (b) => b.instrumentName == symbol && b.bestAsk > 0,
    );
    await api.subscribeOrderBook(symbol);
    await api.subscribeTicker(symbol);
    final book = await bookResult.timeout(const Duration(seconds: 20));
    final tick = pair.tickSizeAt(book.bestBid);
    final far = (book.bestBid * .8 / tick).floor() * tick;
    final quantity = pair.minTradeAmount * 2;
    ownsPosition = true;
    final marginOrder = (await api.placeOrder(
      instrumentName: symbol,
      direction: 'buy',
      amount: quantity,
      orderType: 'limit',
      price: far,
      postOnly: true,
      marginTrading: true,
    ))!;
    ownedOrders.add(marginOrder.orderId);
    final exchangeOrder = (await api.placeOrder(
      instrumentName: symbol,
      direction: 'buy',
      amount: quantity,
      orderType: 'limit',
      price: far - tick,
      postOnly: true,
    ))!;
    ownedOrders.add(exchangeOrder.orderId);
    if (marginOrder.isExchange || !exchangeOrder.isExchange) {
      throw StateError('Order modes conflated');
    }
    final edited = (await api.editOrder(marginOrder.orderId, far + tick))!;
    if (edited.isExchange || !edited.postOnly || edited.price != far + tick) {
      throw StateError('Margin edit lost mode');
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    final snapshot = (await api.getOpenOrders()).singleWhere(
      (o) => o.orderId == marginOrder.orderId,
    );
    if (!snapshot.postOnly || snapshot.isExchange) {
      throw StateError('Order snapshot lost Margin repricing policy');
    }
    for (final order in [marginOrder, exchangeOrder]) {
      if (!await api.cancelOrder(order.orderId)) {
        throw StateError('Cancellation failed');
      }
      ownedOrders.remove(order.orderId);
    }
    stdout.writeln(
      'PASS simultaneous Exchange/Margin orders, post-only edit and cancel',
    );
    final guarded = (await api.placeOrder(
      instrumentName: symbol,
      direction: 'buy',
      amount: pair.minTradeAmount,
      orderType: 'limit',
      price: far,
      postOnly: true,
      marginTrading: true,
    ))!;
    ownedOrders.add(guarded.orderId);
    await api.editOrder(
      guarded.orderId,
      (book.bestAsk * 1.1 / tick).ceil() * tick,
    );
    await waitFor(() => orders[guarded.orderId]?.isActive == false);
    if (orders[guarded.orderId]!.orderState != 'cancelled' ||
        (orders[guarded.orderId]!.filledAmount ?? 0) != 0) {
      throw StateError(
        'Post-only crossing edit was not canceled without fills',
      );
    }
    ownedOrders.remove(guarded.orderId);
    stdout.writeln('PASS exchange enforces Post-only on crossing edits');
    final opened = (await api.placeOrder(
      instrumentName: symbol,
      direction: 'buy',
      amount: quantity,
      orderType: 'market',
      marginTrading: true,
    ))!;
    ownsPosition = true;
    await waitFor(() => orders[opened.orderId]?.isFilled == true);
    await waitPosition(api, (p) => p != null && p.kind == 'margin' && p.isLong);
    stdout.writeln('PASS Margin buy opens a long position');
    final stop = (await api.placeOrder(
      instrumentName: symbol,
      direction: 'sell',
      amount: quantity,
      orderType: 'stop_market',
      stopPrice: far,
      trigger: 'last_price',
      reduceOnly: true,
      marginTrading: true,
    ))!;
    ownedOrders.add(stop.orderId);
    if (stop.isExchange || !stop.reduceOnly) {
      throw StateError('Margin protection flags incorrect');
    }
    await api.cancelOrder(stop.orderId);
    ownedOrders.remove(stop.orderId);
    stdout.writeln('PASS native Margin reduce-only protection');
    final increased = (await api.placeOrder(
      instrumentName: symbol,
      direction: 'buy',
      amount: pair.minTradeAmount,
      orderType: 'market',
      marginTrading: true,
    ))!;
    await waitFor(() => orders[increased.orderId]?.isFilled == true);
    await waitPosition(
      api,
      (p) => p != null && (p.size - 3 * pair.minTradeAmount).abs() < 1e-10,
    );
    final partial = (await api.placeOrder(
      instrumentName: symbol,
      direction: 'sell',
      amount: pair.minTradeAmount,
      orderType: 'market',
      reduceOnly: true,
      marginTrading: true,
    ))!;
    await waitFor(() => orders[partial.orderId]?.isFilled == true);
    await waitPosition(
      api,
      (p) => p != null && (p.size - quantity).abs() < 1e-10,
    );
    stdout.writeln('PASS Margin increase and partial reduce-only close');
    final reversed = (await api.placeOrder(
      instrumentName: symbol,
      direction: 'sell',
      amount: quantity * 2,
      orderType: 'market',
      marginTrading: true,
    ))!;
    await waitFor(() => orders[reversed.orderId]?.isFilled == true);
    await waitPosition(
      api,
      (p) =>
          p != null &&
          p.kind == 'margin' &&
          p.isShort &&
          (p.size - quantity).abs() < 1e-10,
    );
    stdout.writeln('PASS Margin sell/reversal opens a short position');
    final closed = (await api.placeOrder(
      instrumentName: symbol,
      direction: 'buy',
      amount: quantity,
      orderType: 'market',
      reduceOnly: true,
      marginTrading: true,
    ))!;
    await waitFor(() => orders[closed.orderId]?.isFilled == true);
    await waitPosition(api, (p) => p == null || p.size == 0);
    ownsPosition = false;
    final history = await api.getUserTradesByInstrument(
      instrumentName: symbol,
      from: DateTime.fromMillisecondsSinceEpoch(
        opened.creationTimestamp - 1000,
      ),
      to: DateTime.fromMillisecondsSinceEpoch(
        closed.lastUpdateTimestamp + 1000,
      ),
    );
    if (!history.any(
      (t) => t.orderId == opened.orderId && t.isExchange == false,
    )) {
      throw StateError('Margin history mode missing');
    }
    stdout.writeln('PASS full Margin close and history mode parsing');
  } catch (error, stack) {
    stderr.writeln('MARGIN_SCENARIO_FAILED: $error\n$stack');
    rethrow;
  } finally {
    if (api.isAuthenticated) {
      final active = await api.getOpenOrders();
      for (final id in ownedOrders) {
        if (active.any((o) => o.orderId == id)) await api.cancelOrder(id);
      }
      if (ownsPosition) {
        final position = await api.getPosition(symbol);
        if (position != null && position.size != 0) {
          await api.placeOrder(
            instrumentName: symbol,
            direction: position.isLong ? 'sell' : 'buy',
            amount: position.sizeCurrency,
            orderType: 'market',
            reduceOnly: true,
            marginTrading: true,
          );
          await waitPosition(api, (p) => p == null || p.size == 0);
        }
      }
      if (transferred > 0) {
        // Paper transfers immediately after fills can return "Momentary
        // balance check. Please wait few seconds". Allow settlement before
        // the single transfer attempt; never retry a funding write.
        await Future<void>.delayed(const Duration(seconds: 5));
        final available = await marginAvailable(api);
        final delta = available - initialMarginAvailable;
        final returnAmount = (delta.clamp(0, transferred) * 1e8).floor() / 1e8;
        if (returnAmount > 0) {
          await transfer('margin', 'exchange', returnAmount);
        }
      }
      stdout.writeln(
        'Paper scenario orders/positions cleaned; temporary collateral returned',
      );
    }
    await subscription.cancel();
    await api.disconnect();
    api.dispose();
  }
  stdout.writeln('MARGIN_SCENARIOS_PASS');
}

Future<double> marginAvailable(BitfinexApiService api) async {
  final rows = (await api.getWallets()).cast<List>().where(
    (w) => (w[0] == 'margin' || w[0] == 'trading') && w[1] == 'TESTUSD',
  );
  return rows.isEmpty ? 0 : (rows.single[4] as num).toDouble();
}

Future<void> waitPosition(
  BitfinexApiService api,
  bool Function(Position?) predicate,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!predicate(await api.getPosition('TESTBTC:TESTUSD'))) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Margin position did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}
