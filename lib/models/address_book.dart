class AddressBookEntry {
  final String? label;
  final String currency;
  final String address;

  const AddressBookEntry({
    required this.currency,
    required this.address,
    this.label,
  });

  factory AddressBookEntry.fromMap(Map<String, dynamic> m) {
    return AddressBookEntry(
      currency: ((m['currency'] as String?) ?? '').trim().toUpperCase(),
      address: (m['address'] as String?) ?? '',
      label: m['label'] as String?,
    );
  }

  String get displayLabel {
    final parts = <String>[];
    if (label != null && label!.isNotEmpty) parts.add(label!);
    parts.add(currency);

    final prefix = parts.join(' / ');
    final addrShort = address.length > 16
        ? '${address.substring(0, 8)}…${address.substring(address.length - 6)}'
        : address;
    return '$prefix - $addrShort';
  }
}
