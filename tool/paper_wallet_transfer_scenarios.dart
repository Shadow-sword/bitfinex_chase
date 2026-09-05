import 'dart:async';
import 'dart:io';

import 'package:bitfinex_chase/models/wallet_transfer.dart';
import 'package:bitfinex_chase/services/bitfinex_api_service.dart';
import 'package:bitfinex_chase/services/bitfinex_transport.dart';
import 'package:decimal/decimal.dart';

import 'paper_smoke.dart' show readEnv;

/// Real Paper API acceptance. Each successful transfer is reversed exactly once.
/// No orders are placed, no writes are retried, and credentials are never logged.
Future<void> main(List<String> args) async {
  final api = BitfinexApiService();
  final quantity = Decimal.parse('0.01');
  var failed = 0;
  var passed = 0;
  final returns = <Future<void> Function()>[];
  var lastWrite = DateTime.now();
  final selectedRoutes = args.map((arg) {
    if (!arg.startsWith('--route=')) {
      throw ArgumentError('Unknown argument: $arg');
    }
    return arg.substring('--route='.length);
  }).toSet();
  final routes = [
    (TransferWallet.exchange, TransferWallet.margin, 'TESTUSD'),
    (TransferWallet.exchange, TransferWallet.funding, 'TESTUSD'),
    (TransferWallet.exchange, TransferWallet.capitalRaise, 'TESTUSD'),
    (TransferWallet.derivatives, TransferWallet.exchange, 'TESTUSDTF0'),
    (TransferWallet.derivatives, TransferWallet.margin, 'TESTUSDTF0'),
    (TransferWallet.derivatives, TransferWallet.funding, 'TESTUSDTF0'),
    (TransferWallet.derivatives, TransferWallet.capitalRaise, 'TESTUSDTF0'),
  ];
  final routeNames = routes.map((r) => '${r.$1.name}:${r.$2.name}').toSet();
  if (!routeNames.containsAll(selectedRoutes)) {
    throw ArgumentError('Unknown route');
  }

  Future<void> transfer(
    TransferWallet from,
    TransferWallet to,
    String currency,
  ) async {
    final remaining =
        const Duration(seconds: 30) - DateTime.now().difference(lastWrite);
    if (remaining > Duration.zero) {
      stdout.writeln(
        'Waiting for Paper settlement before ${from.label} → ${to.label}',
      );
      await Future<void>.delayed(remaining);
    }
    try {
      await api.transferBetweenWallets(
        from: from,
        to: to,
        currency: currency,
        amount: quantity.toString(),
      );
    } finally {
      lastWrite = DateTime.now();
    }
  }

  Decimal balanceOf(
    List<TransferBalance> balances,
    TransferWallet wallet,
    String currency,
  ) =>
      balances
          .where((b) => b.wallet == wallet && b.currency == currency)
          .firstOrNull
          ?.balance ??
      Decimal.zero;

  Future<void> verifyBalance(
    TransferWallet from,
    TransferWallet to,
    String currency,
    Decimal expectedFrom,
    Decimal expectedTo,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (true) {
      final balances = await api.getTransferBalances();
      final actualFrom = balanceOf(balances, from, currency);
      final actualTo = balanceOf(balances, to, to.currencyFor(currency));
      if (actualFrom == expectedFrom && actualTo == expectedTo) return;
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
          'Unexpected balances: ${from.label} $actualFrom '
          '(expected $expectedFrom), ${to.label} $actualTo (expected $expectedTo)',
        );
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  Future<void> roundTrip(
    TransferWallet from,
    TransferWallet to,
    String currency,
  ) async {
    final before = await api.getTransferBalances();
    final source = before
        .where((b) => b.wallet == from && b.currency == currency)
        .single;
    if (source.available == null || source.available! < quantity) {
      throw StateError(
        'Requires at least $quantity $currency in ${from.label}',
      );
    }
    final initialFrom = source.balance;
    final initialTo = balanceOf(before, to, to.currencyFor(currency));
    var accepted = false;
    try {
      await transfer(from, to, currency);
      accepted = true;
      returns.add(() async {
        await transfer(to, from, to.currencyFor(currency));
        await verifyBalance(from, to, currency, initialFrom, initialTo);
        passed++;
        stdout.writeln(
          'PASS return ${to.label} → ${from.label}: original balances restored',
        );
      });
      await verifyBalance(
        from,
        to,
        currency,
        initialFrom - quantity,
        initialTo + quantity,
      );
      stdout.writeln(
        'PASS $quantity $currency ${from.label} → ${to.label}: both balances verified',
      );
    } on BitfinexApiException catch (e) {
      // A definitive server rejection must leave both wallets unchanged.
      if (accepted) rethrow;
      await verifyBalance(from, to, currency, initialFrom, initialTo);
      failed++;
      stdout.writeln(
        'REJECTED ${from.label} → ${to.label}: $e; balances unchanged',
      );
      return;
    }
  }

  try {
    final env = readEnv();
    await api.connect(isTestnet: true);
    await api.authenticate(env['API_KEY']!, env['API_SECRET']!);
    if (!api.isAuthenticated || !api.isPaper) {
      throw StateError('Paper authentication required');
    }
    if ((await api.getOpenOrders()).isNotEmpty ||
        (await api.getPositions()).isNotEmpty) {
      throw StateError('Requires no existing Paper orders or positions');
    }
    stdout.writeln('PASS Paper account authenticated; no orders or positions');
    final before = await api.getTransferBalances();
    final available = before
        .singleWhere(
          (b) => b.wallet == TransferWallet.exchange && b.currency == 'TESTUSD',
        )
        .available;
    if (available == null) {
      throw StateError('TESTUSD balance must be calculated');
    }
    final invalidRequests = [
      (TransferWallet.exchange, TransferWallet.exchange, '0.01'),
      for (final amount in [
        '0',
        '-1',
        'NaN',
        'Infinity',
        '1e-2',
        (available + Decimal.one).toString(),
      ])
        (TransferWallet.exchange, TransferWallet.margin, amount),
      (TransferWallet.derivatives, TransferWallet.exchange, '0.01'),
    ];
    for (final request in invalidRequests) {
      var rejected = false;
      try {
        await api.transferBetweenWallets(
          from: request.$1,
          to: request.$2,
          currency: 'TESTUSD',
          amount: request.$3,
        );
      } on ArgumentError {
        rejected = true;
      } on FormatException {
        rejected = true;
      } on StateError {
        rejected = true;
      }
      if (!rejected) {
        throw StateError('Invalid transfer was accepted: $request');
      }
    }
    String snapshot(List<TransferBalance> balances) =>
        (balances
                .map((b) => '${b.wallet.name}:${b.currency}:${b.balance}')
                .toList()
              ..sort())
            .join('|');
    if (snapshot(before) != snapshot(await api.getTransferBalances())) {
      throw StateError('Invalid requests changed wallet balances');
    }
    stdout.writeln(
      'PASS same-wallet, invalid amount, insufficient funds and currency mismatch rejected; balances unchanged',
    );
    for (final route in routes) {
      if (selectedRoutes.isNotEmpty &&
          !selectedRoutes.contains('${route.$1.name}:${route.$2.name}')) {
        continue;
      }
      await roundTrip(route.$1, route.$2, route.$3);
    }
  } finally {
    try {
      if (returns.isNotEmpty) {
        stdout.writeln(
          'Restoring ${returns.length} accepted transfers in reverse order',
        );
        for (final restore in returns.reversed) {
          await restore();
        }
      }
    } finally {
      await api.disconnect();
      api.dispose();
    }
  }
  stdout.writeln(
    'RESULT $passed round trips passed; $failed routes rejected by Paper API',
  );
  if (failed > 0) exitCode = 1;
}
