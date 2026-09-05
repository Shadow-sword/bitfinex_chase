import 'dart:convert';

import 'package:http/http.dart' as http;

/// USD→CNY 参考汇率结果：汇率 + 源数据日期（ECB 发布日，日频）。
class UsdCnyRate {
  final double rate;
  final DateTime sourceDate;
  const UsdCnyRate(this.rate, this.sourceDate);
}

/// 法币汇率服务：从 Frankfurter v2 获取官方参考汇率（数据源 ECB 中间价，日频更新）。
///
/// 仅用于账户估值展示，不用于下单/结算等关键计算。
class FiatRateService {
  static const String _rateEndpoint =
      'https://api.frankfurter.dev/v2/rate/USD/CNY';

  /// 获取 USD→CNY 官方参考汇率及其源数据日期。
  ///
  /// 成功返回 UsdCnyRate（rate>0）；任何失败（非 200、空 body、解析错、网络异常、
  /// 超时）均返回 null，不抛异常。
  Future<UsdCnyRate?> getUsdCnyRate() async {
    try {
      final resp = await http
          .get(Uri.parse(_rateEndpoint))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) return null;
      final rate = (decoded['rate'] as num?)?.toDouble();
      if (rate == null || rate <= 0) return null;
      final dateStr = decoded['date'];
      // date 解析失败视为异常响应，整体当失败处理（不伪造为今天），
      // 由上层降级使用旧值。
      final sourceDate = dateStr is String ? DateTime.tryParse(dateStr) : null;
      if (sourceDate == null) return null;
      return UsdCnyRate(rate, sourceDate);
    } catch (_) {
      return null;
    }
  }
}
