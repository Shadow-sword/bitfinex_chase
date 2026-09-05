import 'dart:async';
import 'dart:io';
import 'package:bitfinex_chase/models/account.dart';
import 'package:bitfinex_chase/models/market_data.dart';
import 'package:bitfinex_chase/models/withdrawal.dart';
import 'package:bitfinex_chase/services/fiat_rate_service.dart';
import 'package:bitfinex_chase/services/bitfinex_api_service.dart';
import 'package:bitfinex_chase/services/bitfinex_transport.dart';

/// Real-account acceptance checks. All trading/funding writes are blocked at
/// the transport boundary. Never prints credentials or private account rows.
class ReadOnlyTransport extends BitfinexTransport {
  static final _readPaths = RegExp(
    r'^v2/auth/r/(info/user|wallets|orders(?:/t[^/]+)?|positions|trades(?:/t[^/]+)?/hist|movements(?:/[^/]+)?/hist)$',
  );
  int reads = 0;
  @override
  Future<dynamic> privatePost(
    String path, [
    Map<String, dynamic> body = const {},
  ]) {
    if (!_readPaths.hasMatch(path)) {
      throw StateError('Blocked non-read-only REST request');
    }
    reads++;
    return super.privatePost(path, body);
  }

  @override
  void send(Object data) {
    if (data is! Map ||
        !const {
          'auth',
          'ping',
          'subscribe',
          'unsubscribe',
        }.contains(data['event'])) {
      throw StateError('Blocked non-read-only WebSocket request');
    }
    if (data['event'] == 'auth' && data.containsKey('dms')) {
      throw StateError(
        'Dead-man switches are forbidden in read-only verification',
      );
    }
    super.send(data);
  }
}

Map<String, String> readLiveCredentials(String path) {
  final values = <String, String>{};
  for (final line in File(path).readAsLinesSync()) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final index = line.indexOf('=');
    if (index < 1) throw const FormatException('Invalid credential file');
    var value = line.substring(index + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
    values[line.substring(0, index).trim()] = value;
  }
  if (values['API_KEY']?.isNotEmpty != true ||
      values['API_SECRET']?.isNotEmpty != true) {
    throw const FormatException('API_KEY and API_SECRET are required');
  }
  return values;
}

Future<void> main(List<String> args) async {
  if (args.length > 1 || args.any((a) => a.startsWith('--'))) {
    throw ArgumentError(
      'Usage: dart run tool/live_readonly.dart [credential-file]',
    );
  }
  final env = readLiveCredentials(args.isEmpty ? '.env.live' : args.single);
  final transport = ReadOnlyTransport();
  final api = BitfinexApiService(transport: transport);
  var failed = false;
  final books = <String, OrderBookData>{};
  final tickers = <String, TickerData>{};
  final bookSub = api.orderBookStream.listen(
    (b) => books[b.instrumentName] = b,
  );
  final tickerSub = api.tickerStream.listen(
    (t) => tickers[t.instrumentName] = t,
  );
  Future<void> check(String name, Future<void> Function() action) async {
    try {
      await action();
      stdout.writeln('PASS $name');
    } catch (error, stack) {
      failed = true;
      // The error type and source frames identify the parser without printing
      // any value from the private response or the credential file.
      stderr.writeln('FAIL $name: ${error.runtimeType}');
      stderr.writeln(stack.toString().split('\n').take(5).join('\n'));
    }
  }

  try {
    await api.connect(isTestnet: false);
    await api.authenticate(env['API_KEY']!, env['API_SECRET']!);
    stdout.writeln('PASS real-account REST/WS authentication');
    await check('account summaries and UI model', () async {
      final raw = await api.getAccountSummaries();
      if (raw == null) throw StateError('No account response');
      final account = AccountSummaries.fromMap(raw);
      if (account.type != 'Live') throw StateError('Wrong account type');
    });
    final walletRows = (await api.getWallets()).cast<List>();
    final currencies = walletRows.map((w) => w[1] as String).toSet();
    await check('wallet-specific account metrics', () async {
      for (final currency in currencies) {
        await api.getAccountSummary(currency: currency);
      }
    });
    await check('active orders and positions', () async {
      final orders = await api.getOpenOrders();
      final positions = await api.getPositions();
      if (orders.isEmpty && positions.isEmpty) {
        stdout.writeln(
          'INFO no active account orders/positions; verified empty snapshots',
        );
      }
    });
    await check('live spot/derivative instrument catalogue', () async {
      for (final symbol in [
        'BTCUSD',
        'BTCUST',
        'ETHUSD',
        'AAVE:USD',
        'BTCF0:USTF0',
      ]) {
        final pair = await api.getInstrument(symbol);
        if (pair == null || !pair.isVerified) {
          throw StateError('Missing instrument');
        }
        if (['BTCUSD', 'BTCUST'].contains(symbol) && !pair.supportsMargin) {
          throw StateError('Expected verified Margin eligibility');
        }
        if (symbol == 'BTCF0:USTF0' && pair.supportsMargin) {
          throw StateError('Derivative incorrectly classified as spot Margin');
        }
      }
    });
    await check('public book/ticker subscriptions', () async {
      for (final symbol in ['BTCUSD', 'AAVE:USD', 'BTCF0:USTF0']) {
        await api.subscribeOrderBook(symbol);
        await api.subscribeTicker(symbol);
      }
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (![
        'BTCUSD',
        'AAVE:USD',
        'BTCF0:USTF0',
      ].every((s) => books.containsKey(s) && tickers.containsKey(s))) {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('Market feeds did not arrive');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      for (final symbol in ['BTCUSD', 'AAVE:USD', 'BTCF0:USTF0']) {
        await api.unsubscribeOrderBook(symbol);
        await api.unsubscribeTicker(symbol);
      }
    });
    await check('USD/BTC account valuation reads', () async {
      var missingRates = 0;
      for (final currency in currencies) {
        for (final quote in ['USD', 'BTC']) {
          final rate = await api.getIndexPrice(base: currency, quote: quote);
          if (rate != null && (!rate.isFinite || rate <= 0)) {
            throw StateError('Invalid valuation rate');
          }
        }
      }
      if (missingRates != 0) {
        stdout.writeln(
          'INFO $missingRates valuation routes unavailable; represented as unknown, not zero',
        );
      }
    });
    final recent =
        (await transport.privatePost('v2/auth/r/trades/hist', {
              'limit': 100,
              'sort': -1,
            }))
            as List;
    await check('trade history through application parser', () async {
      if (recent.isEmpty) {
        await api.getUserTradesByInstrument(
          instrumentName: 'BTCUSD',
          from: DateTime.now().subtract(const Duration(days: 30)),
          to: DateTime.now(),
        );
        stdout.writeln(
          'INFO no recent account executions; verified empty history response',
        );
      } else {
        final symbols = recent
            .cast<List>()
            .map((r) => r[1] as String)
            .toSet()
            .take(5);
        final timestamps =
            recent.cast<List>().map((r) => (r[2] as num).toInt()).toList()
              ..sort();
        for (final symbol in symbols) {
          await api.getUserTradesByInstrument(
            instrumentName: symbol,
            from: DateTime.fromMillisecondsSinceEpoch(timestamps.first - 1),
            to: DateTime.fromMillisecondsSinceEpoch(timestamps.last + 1),
          );
        }
      }
    });
    await check('withdrawal history reads', () async {
      for (final currency in currencies) {
        final history = await api.getWithdrawals(currency: currency);
        for (final entry in history) {
          Withdrawal.fromMap(entry.toMap());
        }
      }
    });
    await check('CNY valuation reference', () async {
      final rate = await FiatRateService().getUsdCnyRate();
      if (rate == null || !rate.rate.isFinite || rate.rate <= 0) {
        throw StateError('CNY reference unavailable');
      }
    });
    if (!api.isConnected || !api.isAuthenticated) {
      throw StateError('Read-only session disconnected unexpectedly');
    }
    stdout.writeln(
      'Read-only requests completed: ${transport.reads}; trading/funding writes blocked',
    );
  } finally {
    await bookSub.cancel();
    await tickerSub.cancel();
    await api.disconnect();
    api.dispose();
  }
  if (failed) exitCode = 1;
}
