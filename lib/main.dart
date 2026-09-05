import 'package:flutter/material.dart';
import 'views/main_screen.dart';
import 'services/desktop_window_initializer.dart';
import 'services/notification_service.dart';
import 'services/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDesktopWindowState();
  // Initialize local system notifications (desktop cross-platform)
  await AppNotificationService.instance.init();
  runApp(const BitfinexChaseApp());
}

class BitfinexChaseApp extends StatefulWidget {
  const BitfinexChaseApp({super.key});

  @override
  State<BitfinexChaseApp> createState() => _BitfinexChaseAppState();
}

class _BitfinexChaseAppState extends State<BitfinexChaseApp> {
  AppThemePreference _themePreference = AppThemePreference.system;

  @override
  void initState() {
    super.initState();
    () async {
      final preference = await SettingsStore.loadThemePreference();
      if (mounted) setState(() => _themePreference = preference);
    }();
  }

  Future<void> _setThemePreference(AppThemePreference preference) async {
    setState(() => _themePreference = preference);
    await SettingsStore.saveThemePreference(preference);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BitfinexChase',
      themeMode: _themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: MainScreen(
        themePreference: _themePreference,
        onThemePreferenceChanged: _setThemePreference,
      ),
    );
  }

  ThemeMode get _themeMode {
    switch (_themePreference) {
      case AppThemePreference.light:
        return ThemeMode.light;
      case AppThemePreference.dark:
        return ThemeMode.dark;
      case AppThemePreference.system:
        return ThemeMode.system;
    }
  }
}
