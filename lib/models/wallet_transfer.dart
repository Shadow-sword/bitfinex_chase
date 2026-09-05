import 'package:decimal/decimal.dart';

enum TransferWallet {
  exchange('Exchange', 'exchange'),
  margin('Margin', 'margin'),
  funding('Funding', 'funding'),
  capitalRaise('Capital Raise', 'contribution'),
  derivatives('Derivatives', 'margin');

  const TransferWallet(this.label, this.apiName);
  final String label;
  final String apiName;

  static TransferWallet? fromApi(String type, String currency) =>
      switch (type) {
        'exchange' => exchange,
        'margin' || 'trading' => currency.endsWith('F0') ? derivatives : margin,
        'funding' || 'deposit' => funding,
        'contribution' => capitalRaise,
        _ => null,
      };

  String currencyFor(String sourceCurrency) {
    final base = sourceCurrency.endsWith('F0')
        ? sourceCurrency.substring(0, sourceCurrency.length - 2)
        : sourceCurrency;
    return this == derivatives ? '${base}F0' : base;
  }
}

class TransferBalance {
  const TransferBalance({
    required this.wallet,
    required this.currency,
    required this.balance,
    required this.available,
  });

  final TransferWallet wallet;
  final String currency;
  final Decimal balance;
  // null means Bitfinex has not calculated spendable funds.
  final Decimal? available;
}

Decimal parseTransferAmount(String value) {
  final text = value.trim();
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(text)) {
    throw const FormatException('请输入有效的划转数量');
  }
  final amount = Decimal.parse(text);
  if (amount <= Decimal.zero) {
    throw const FormatException('划转数量必须大于 0');
  }
  return amount;
}
