import 'package:decimal/decimal.dart';

Decimal dFrom(num v) => Decimal.parse(v.toString());
Decimal dParse(String v) => Decimal.parse(v);

double dToDouble(Decimal v) => double.parse(v.toString());

Decimal roundToTick(Decimal price, Decimal tick) {
  if (tick <= Decimal.zero) return price;
  // Use double for quotient rounding, then quantize back via Decimal.
  final s = price / tick;
  //final q = double.parse(s.toString()).round();
  final q = s.toBigInt().toInt();
  return tick * Decimal.fromInt(q);
}
