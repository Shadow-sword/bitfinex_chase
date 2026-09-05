import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:bitfinex_chase/models/market_data.dart';
import 'package:bitfinex_chase/services/bitfinex_api_service.dart';
import 'package:bitfinex_chase/services/settings_store.dart';
import 'package:bitfinex_chase/services/trading_service.dart';
import 'package:bitfinex_chase/views/main_screen.dart';

/// Runs business acceptance scenarios through the real Flutter trading service
/// and the real Paper API. This is deliberately not a unit-test target.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = BitfinexApiService();
  final service = TradingService(api: api);
  final orders = <String, Order>{};
  final owned = <String>{};
  final statusSub = service.statusStream.listen(
    (s) => stdout.writeln('STATUS $s'),
  );
  final orderSub = service.orderStream.listen((o) => orders[o.orderId] = o);
  runApp(
    MaterialApp(
      home: MainScreen(
        tradingService: service,
        themePreference: AppThemePreference.system,
        onThemePreferenceChanged: (_) {},
      ),
    ),
  );
  // Let the actual screen finish restoring its settings before scenarios.
  await Future<void>.delayed(const Duration(seconds: 1));
  var failed = false;
  try {
    await service.connect(isTestnet: true);
    if (!await service.authenticate(
      Platform.environment['API_KEY']!,
      Platform.environment['API_SECRET']!,
    )) {
      throw StateError('Authentication failed');
    }
    const symbol = 'TESTBTC:TESTUSD';
    await service.subscribeToInstrument(symbol);
    await until(() => service.getOrderBook(symbol)?.bestAsk != null);
    final pair = service.getTradingPairBySymbol(symbol, [])!;
    final book = service.getOrderBook(symbol)!;
    final before = await baseBalance(api);
    final tick = pair.tickSizeAt(book.bestBid);
    final farPrice = (book.bestBid * 0.9 / tick).floor() * tick;
    service.updateSettings(maxSpreadPercent: 0);
    final order = await service.placeLimitOrder(
      symbol,
      'buy',
      pair.minTradeAmount * 2,
      customPrice: farPrice,
      enableChasing: true,
    );
    if (order == null || !order.isActive) {
      throw StateError('Initial order not active');
    }
    stdout.writeln(
      'Initial order: ${order.orderId} ${order.orderType} postOnly=${order.postOnly} chasing=${service.isChasing(order.orderId)}',
    );
    owned.add(order.orderId);
    await Future<void>.delayed(const Duration(seconds: 3));
    final unchanged = (await api.getOpenOrders()).singleWhere(
      (o) => o.orderId == order.orderId,
    );
    if (unchanged.price != order.price) {
      throw StateError('Spread guard did not prevent repricing');
    }
    stdout.writeln('PASS spread guard holds the order price');
    stdout.writeln(
      'Chase active before repricing: ${service.isChasing(order.orderId)}; book=${service.getOrderBook(symbol)?.bestAsk}',
    );
    service.updateSettings(maxSpreadPercent: 5);
    await until(
      () =>
          orders[order.orderId]?.price != order.price ||
          orders[order.orderId]?.isFilled == true,
    );
    stdout.writeln('PASS real per-order chase repriced the order');
    service.setChasingForOrder(order.orderId, false);
    if (service.isChasing(order.orderId)) {
      throw StateError('Chase toggle did not stop');
    }
    final active = (await api.getOpenOrders()).where(
      (o) => o.orderId == order.orderId,
    );
    if (active.isNotEmpty && !await service.cancelOrder(order.orderId)) {
      throw StateError('Cancel failed');
    }
    owned.remove(order.orderId);
    // If the chased order filled in the moving market, close only scenario inventory.
    final acquired = (await baseBalance(api)) - before;
    if (acquired >= pair.minTradeAmount) {
      final sell = await service.placeMarketOrder(
        symbol,
        'sell',
        (acquired * 1e8).floor() / 1e8,
      );
      if (sell == null) throw StateError('Inventory cleanup failed');
      await until(() => orders[sell.orderId]?.isFilled == true);
    }
    stdout.writeln('PASS chase stop/cancel and inventory cleanup');
    await service.disconnect();
    if (service.isAuthenticated ||
        service.isConnected ||
        service.isChasing(order.orderId)) {
      throw StateError('Disconnect did not invalidate trading state');
    }
    stdout.writeln('PASS disconnect clears auth and chase state');
    await service.connect(isTestnet: true);
    if (!await service.authenticate(
      Platform.environment['API_KEY']!,
      Platform.environment['API_SECRET']!,
    )) {
      throw StateError('Reconnect authentication failed');
    }
    await service.subscribeToInstrument(symbol);
    await until(() => service.getOrderBook(symbol)?.bestAsk != null);
    stdout.writeln('PASS reconnect, authenticate, and resubscribe');
    stdout.writeln('DESKTOP_SCENARIOS_PASS');
  } catch (e, stack) {
    failed = true;
    stderr.writeln('DESKTOP_SCENARIOS_FAILED: $e\n$stack');
  } finally {
    for (final id in owned) {
      if (api.isAuthenticated &&
          (await api.getOpenOrders()).any((o) => o.orderId == id)) {
        await api.cancelOrder(id);
      }
    }
    await service.disconnect();
    await statusSub.cancel();
    await orderSub.cancel();
    service.dispose();
    exit(failed ? 1 : 0);
  }
}

Future<double> baseBalance(BitfinexApiService api) async {
  final rows = (await api.getWallets()).cast<List>().where(
    (w) => w[0] == 'exchange' && w[1] == 'TESTBTC',
  );
  return rows.isEmpty ? 0 : (rows.single[2] as num).toDouble();
}

Future<void> until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Business scenario did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
