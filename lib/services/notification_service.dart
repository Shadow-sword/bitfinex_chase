import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/market_data.dart';

class AppNotificationService {
  AppNotificationService._();
  static final AppNotificationService instance = AppNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    // Android init (kept minimal even if desktop-first)
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');

    // macOS/iOS init
    const darwinInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: false,
      requestSoundPermission: true,
    );

    // Linux init (icon optional; leave null to use default)
    const linuxInit = LinuxInitializationSettings(defaultActionName: 'Open');

    // Windows init
    const windowsInit = WindowsInitializationSettings(
      appName: 'BitfinexChase',
      appUserModelId: 'BitfinexChase.App',
      guid: '12a45c24-1d34-d234-7294-1274661890ab',
    );

    final initSettings = InitializationSettings(
      android: androidInit,
      iOS: darwinInit,
      macOS: darwinInit,
      linux: linuxInit,
      windows: windowsInit,
    );

    await _plugin.initialize(initSettings);

    // Explicit macOS permission request (Darwin settings request above helps too)
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, sound: true, badge: false);
    } catch (_) {}

    _initialized = true;
  }

  Future<void> showOrderFilled(Order order) async {
    if (!_initialized) return;

    final sideZh = order.direction.toLowerCase() == 'buy' ? '买入' : '卖出';
    final avgPx =
        order.averageExecutedPrice ?? (order.price > 0 ? order.price : null);
    final avgStr = avgPx != null ? _fmt(avgPx) : '-';
    final qty = order.filledAmount ?? order.amount;
    final qtyStr = _fmt(qty);

    final title = '${order.instrumentName} 订单完全成交';
    final body =
        '${order.instrumentName}  方向: $sideZh   均价: $avgStr   数量: $qtyStr';

    const androidDetails = AndroidNotificationDetails(
      'order_filled_channel',
      'Order Filled',
      channelDescription: 'Notifications when orders are completely filled',
      importance: Importance.high,
      priority: Priority.high,
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
    );

    const linuxDetails = LinuxNotificationDetails(
      urgency: LinuxNotificationUrgency.normal,
    );

    const windowsDetails = WindowsNotificationDetails();

    final details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
      linux: linuxDetails,
      windows: windowsDetails,
    );

    // Simple unique id using current timestamp
    final id = DateTime.now().millisecondsSinceEpoch.remainder(0x7fffffff);
    await _plugin.show(id, title, body, details);
  }

  String _fmt(double v) {
    // Keep a sensible precision for price/quantity
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    if (v.abs() >= 1) return v.toStringAsFixed(4);
    return v.toStringAsFixed(6);
  }
}
