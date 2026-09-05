class Withdrawal {
  final int id;
  final String currency;
  final double amount;
  final double fee;
  final String address;
  final String state;
  final String? transactionId;
  final int createdTimestamp;
  final int updatedTimestamp;

  const Withdrawal({
    required this.id,
    required this.currency,
    required this.amount,
    required this.fee,
    required this.address,
    required this.state,
    this.transactionId,
    required this.createdTimestamp,
    required this.updatedTimestamp,
  });

  factory Withdrawal.fromMap(Map<String, dynamic> map) {
    final id = (map['id'] as num?)?.toInt();
    final currency = (map['currency'] as String?)?.trim().toUpperCase();
    final amount = (map['amount'] as num?)?.toDouble();
    final fee = (map['fee'] as num?)?.toDouble();
    final address = (map['address'] as String?)?.trim();
    final state = (map['state'] as String?)?.trim().toLowerCase();
    final createdTimestamp = (map['created_timestamp'] as num?)?.toInt();
    final updatedTimestamp = (map['updated_timestamp'] as num?)?.toInt();
    if (id == null ||
        currency == null ||
        currency.isEmpty ||
        amount == null ||
        fee == null ||
        address == null ||
        address.isEmpty ||
        state == null ||
        state.isEmpty ||
        createdTimestamp == null ||
        updatedTimestamp == null) {
      throw const FormatException('Invalid withdrawal response');
    }

    return Withdrawal(
      id: id,
      currency: currency,
      amount: amount,
      fee: fee,
      address: address,
      state: state,
      transactionId: (map['transaction_id'] as String?)?.trim(),
      createdTimestamp: createdTimestamp,
      updatedTimestamp: updatedTimestamp,
    );
  }

  DateTime? get createdAt => createdTimestamp > 0
      ? DateTime.fromMillisecondsSinceEpoch(createdTimestamp).toLocal()
      : null;

  DateTime? get updatedAt => updatedTimestamp > 0
      ? DateTime.fromMillisecondsSinceEpoch(updatedTimestamp).toLocal()
      : null;
}
