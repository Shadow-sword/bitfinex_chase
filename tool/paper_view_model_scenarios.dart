import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:bitfinex_chase/services/bitfinex_transport.dart';
import 'package:bitfinex_chase/services/bitfinex_api_service.dart';
import 'package:bitfinex_chase/services/trading_service.dart';
import 'package:bitfinex_chase/services/local_cache_store.dart';
import 'package:bitfinex_chase/services/config_service.dart';
import 'package:bitfinex_chase/view_models/main_view_model.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final transport = BitfinexTransport();
  final api = BitfinexApiService(transport: transport);
  final service = TradingService(api: api);
  final vm = MainViewModel(service);
  final status = service.statusStream.listen(
    (s) => stdout.writeln('STATUS $s'),
  );
  var failed = false, ownsPosition = false;
  const symbol = 'TESTBTCF0:TESTUSDTF0';
  final ownOrders = <String>{};
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(child: Text('Bitfinex Paper business acceptance')),
      ),
    ),
  );
  try {
    await Future<void>.delayed(const Duration(seconds: 1));
    vm.updateClientId(Platform.environment['API_KEY']!);
    vm.updateClientSecret(Platform.environment['API_SECRET']!);
    await vm.setIsTestnet(true);
    await vm.connect();
    await vm.authenticate();
    if (!vm.isConnected || !vm.isAuthenticated) {
      throw StateError('View model did not authenticate');
    }
    if ((await api.getPositions()).isNotEmpty) {
      throw StateError('Scenario requires no existing positions');
    }
    final pair = vm.findTradingPairVm(symbol)!;
    await vm.subscribeToInstrument(pair);
    await until(() => pair.bestAsk > 0 && pair.pair.isVerified);
    pair.leverage = 2;
    pair.buyPercent = 10;
    await vm.ensureAccountMetricsForCurrency('TESTUSDTF0');
    await until(
      () => vm.computePercentOrderAmountWithMeta(pair, 'buy').$1 != null,
    );
    final sizing = vm.computePercentOrderAmountWithMeta(pair, 'buy');
    if (sizing.$1! <= 0 || !sizing.$2) {
      throw StateError('Percent sizing did not use available funds');
    }
    stdout.writeln(
      'PASS view-model auth, instrument verification and leveraged percent sizing',
    );
    final amount = pair.pair.minTradeAmount * 2;
    await vm.placeMarketOrder(pair, 'buy', amount);
    ownsPosition = true;
    await until(
      () => vm.positions.any(
        (p) => p.position.instrumentName == symbol && p.position.isLong,
      ),
    );
    final position = vm.positions.singleWhere(
      (p) => p.position.instrumentName == symbol,
    );
    final increased = await vm.increasePosition(
      position,
      amount: pair.pair.minTradeAmount,
      market: true,
      leverage: pair.leverage,
    );
    if (increased == null) throw StateError('Increase order was not placed');
    await until(
      () => vm.positions.any(
        (p) =>
            p.position.instrumentName == symbol &&
            (p.position.size - pair.pair.minTradeAmount * 3).abs() < 1e-10,
      ),
    );
    stdout.writeln(
      'PASS same-direction increase adds exposure without reduce-only',
    );
    // Restore the original scenario size before the existing partial/reversal checks.
    await vm.closePositionMarket(
      vm.positions.singleWhere((p) => p.position.instrumentName == symbol),
      nativeApiAmount: pair.pair.minTradeAmount,
    );
    await until(
      () => vm.positions.any(
        (p) =>
            p.position.instrumentName == symbol &&
            (p.position.size - amount).abs() < 1e-10,
      ),
    );
    final wasKeepAlive = vm.androidBackgroundKeepAlive;
    await vm.setAndroidBackgroundKeepAlive(!wasKeepAlive);
    final config = await ConfigService.buildPlainSettings();
    if ((config['app'] as Map)['androidBackgroundKeepAlive'] != !wasKeepAlive) {
      throw StateError('Keepalive config export mismatch');
    }
    await vm.setAndroidBackgroundKeepAlive(wasKeepAlive);
    stdout.writeln('PASS optional keepalive setting persists and exports');
    final tick = pair.pair.tickSizeAt(pair.bestBid);
    final stop = await vm.addProtectionOrder(
      position,
      type: 'stop_market',
      percentage: 100,
      triggerPrice: (pair.bestBid * 0.8 / tick).floor() * tick,
    );
    if (stop == null || !stop.reduceOnly) {
      throw StateError('Protection order failed');
    }
    ownOrders.add(stop.orderId);
    await vm.cancelOrder(OrderVM(stop));
    ownOrders.remove(stop.orderId);
    stdout.writeln('PASS view-model market entry and percentage protection');
    await vm.closePositionMarket(position, percentage: 50);
    await until(
      () => vm.positions.any(
        (p) =>
            p.position.instrumentName == symbol &&
            (p.position.size - pair.pair.minTradeAmount).abs() < 1e-10,
      ),
    );
    await vm.reversePosition(
      vm.positions.singleWhere((p) => p.position.instrumentName == symbol),
      percentage: 100,
      market: true,
    );
    await until(
      () => vm.positions.any(
        (p) => p.position.instrumentName == symbol && p.position.isShort,
      ),
    );
    if (vm.positions.length != 1) {
      throw StateError('Unexpected external position; refusing close-all');
    }
    await vm.closeAllPositions(percentage: 100, market: true);
    await until(() => vm.positions.isEmpty);
    ownsPosition = false;
    stdout.writeln('PASS view-model partial close, reversal and close-all');
    await vm.loadTradeHistory(
      symbol,
      DateTime.now().subtract(const Duration(hours: 1)),
      DateTime.now().add(const Duration(minutes: 1)),
    );
    await vm.refreshAccountSummaries();
    if (vm.accountSummaries?.type != 'Paper Trading') {
      throw StateError('Account view did not load');
    }
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final cachedPairs = await LocalCacheStore.loadMarket(true);
    if (!cachedPairs.any((p) => p.symbol == symbol) ||
        cachedPairs.any((p) => p.isVerified)) {
      throw StateError('Cached metadata must remain unverified');
    }
    final identity = await LocalCacheStore.loadIdentity(true, vm.clientId);
    if (identity == null ||
        identity.value.id != vm.accountSummaries!.id ||
        identity.value.summaries.isNotEmpty) {
      throw StateError('Identity cache must exclude balances');
    }
    await vm.loadWithdrawals(currency: 'TESTUSD');
    final cachedWithdrawals = await LocalCacheStore.loadWithdrawals(
      true,
      vm.clientId,
      'TESTUSD',
      0,
    );
    if (cachedWithdrawals == null) {
      throw StateError('Withdrawal history was not cached');
    }
    stdout.writeln('PASS metadata, identity-only and withdrawal caches');
    await vm.disconnect();
    if (vm.isAuthenticated || vm.positions.isNotEmpty) {
      throw StateError('View model retained private state');
    }
    await vm.connect();
    await vm.authenticate();
    transport.fail('Simulated network loss for acceptance');
    await until(() => !vm.isAuthenticated);
    await until(() => vm.isAuthenticated && vm.isConnected);
    stdout.writeln('PASS automatic network recovery and reauthentication');
    await vm.disconnect();
    stdout.writeln('VIEW_MODEL_SCENARIOS_PASS');
  } catch (e, stack) {
    failed = true;
    stderr.writeln('VIEW_MODEL_SCENARIOS_FAILED: $e\n$stack');
  } finally {
    for (final id in ownOrders) {
      if (api.isAuthenticated &&
          (await api.getOpenOrders()).any((o) => o.orderId == id)) {
        await api.cancelOrder(id);
      }
    }
    if (ownsPosition && api.isAuthenticated) {
      final p = await api.getPosition(symbol);
      if (p != null && p.size != 0) {
        await api.placeOrder(
          instrumentName: symbol,
          direction: p.isLong ? 'sell' : 'buy',
          amount: p.size,
          orderType: 'market',
          reduceOnly: true,
        );
      }
    }
    await vm.disconnect();
    await status.cancel();
    vm.dispose();
    service.dispose();
    exit(failed ? 1 : 0);
  }
}

Future<void> until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('View-model scenario did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
