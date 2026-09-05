import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:flutter/services.dart';

import '../services/trading_service.dart';
import '../view_models/main_view_model.dart';
import '../models/trading_pair.dart';
import '../models/withdrawal.dart';
import '../services/settings_store.dart';
import '../services/config_service.dart';
import '../utils/decimal_utils.dart';
import '../utils/instrument_pnl.dart';
import '../utils/order_amount_conversion.dart';
import 'package:decimal/decimal.dart';

class MainScreen extends StatefulWidget {
  final AppThemePreference themePreference;
  final ValueChanged<AppThemePreference> onThemePreferenceChanged;
  final TradingService? tradingService;

  const MainScreen({
    super.key,
    required this.themePreference,
    required this.onThemePreferenceChanged,
    this.tradingService,
  });

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final TradingService _service;
  late final MainViewModel _vm;
  late TabController _tabs;
  bool _mobileNavigation = false;
  List<int> get _tabOrder => _mobileNavigation
      ? const [2, 3, 4, 5, 1, 0, 6, 7]
      : const [0, 1, 2, 3, 4, 5, 6, 7];
  int get _currentTab => _tabOrder[_tabs.index];
  static const _tabLabels = ['首页', '账户', '行情', '订单', '持仓', '历史', '公告', '日志'];

  void _tabChanged() {
    if (mounted) setState(() {});
  }

  void _selectTab(int logicalTab) =>
      _tabs.animateTo(_tabOrder.indexOf(logicalTab));
  void _cycleTab(int delta) => _selectTab((_currentTab + delta + 8) % 8);
  String? _historySymbol;
  DateTime _historyFrom = DateTime.now().subtract(const Duration(days: 30));
  DateTime _historyTo = DateTime.now();
  String? _selectedQuickRange;
  // Custom pair form state
  final _newSymbolController = TextEditingController();
  final _newMaxDeviationController = TextEditingController(text: '0.3');
  bool _customPanelExpanded = false;
  bool _connPanelExpanded = true;
  bool _settingsPanelExpanded = true;
  bool _configPanelExpanded = false;
  bool _historyFiltersExpanded = true;
  bool _historyPositionsExpanded = false;
  bool _withdrawPanelExpanded = false;
  final TextEditingController _clientIdController = TextEditingController();
  final TextEditingController _clientSecretController = TextEditingController();
  bool _secretObscured = true;
  // Controllers and focus nodes for price inputs, keyed by field id
  final Map<String, TextEditingController> _priceControllers = {};
  final Map<String, FocusNode> _priceFocusNodes = {};
  // Controllers and focus nodes for amount inputs, keyed by field id
  final Map<String, TextEditingController> _amountControllers = {};
  final Map<String, FocusNode> _amountFocusNodes = {};
  final Map<String, ManualOrderAmountUnit> _manualAmountUnits = {};
  // Withdraw inputs
  final TextEditingController _withdrawAmountController =
      TextEditingController();
  String _withdrawCurrency = 'BTC';
  final _withdrawAddressController = TextEditingController();
  final _withdrawMethodController = TextEditingController();
  final _withdrawTagController = TextEditingController();
  // Percent sizing buffer input
  final TextEditingController _percentBufferController =
      TextEditingController();
  final FocusNode _percentBufferFocus = FocusNode();
  // Config import/export password
  final TextEditingController _configPasswordController =
      TextEditingController();
  bool _wasBackgrounded = false;

  TextEditingController _priceControllerFor(String id) =>
      _priceControllers.putIfAbsent(id, () => TextEditingController());
  FocusNode _priceFocusFor(String id) =>
      _priceFocusNodes.putIfAbsent(id, () => FocusNode());
  TextEditingController _amountControllerFor(String id) =>
      _amountControllers.putIfAbsent(id, () => TextEditingController());
  FocusNode _amountFocusFor(String id) =>
      _amountFocusNodes.putIfAbsent(id, () => FocusNode());

  Color get _panelColor => Theme.of(context).colorScheme.surfaceContainerHigh;
  Color get _sectionColor => Theme.of(context).colorScheme.surfaceContainerLow;
  Color get _subtleTextColor => Theme.of(context).colorScheme.onSurfaceVariant;
  Color get _borderColor => Theme.of(context).colorScheme.outlineVariant;

  String _themePreferenceLabel(AppThemePreference preference) {
    switch (preference) {
      case AppThemePreference.system:
        return 'System';
      case AppThemePreference.light:
        return 'Light';
      case AppThemePreference.dark:
        return 'Dark';
    }
  }

  @override
  void initState() {
    super.initState();
    _service = widget.tradingService ?? TradingService();
    _vm = MainViewModel(_service);
    WidgetsBinding.instance.addObserver(this);
    _tabs = TabController(length: 8, vsync: this)..addListener(_tabChanged);
    // Initialize percent buffer text and commit on focus loss
    _percentBufferController.text = (_vm.percentSizingBuffer * 100)
        .toStringAsFixed(0);
    _percentBufferFocus.addListener(() {
      if (!_percentBufferFocus.hasFocus) {
        _commitPercentBuffer();
      }
    });
    // Load History filters expanded state
    () async {
      final v = await SettingsStore.loadHistoryFiltersExpanded();
      if (mounted) setState(() => _historyFiltersExpanded = v);
    }();
    // Load History positions panel expanded state
    () async {
      final v = await SettingsStore.loadHistoryPositionsExpanded();
      if (mounted) setState(() => _historyPositionsExpanded = v);
    }();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabs.dispose();
    _vm.dispose();
    _service.dispose();
    _newSymbolController.dispose();
    _newMaxDeviationController.dispose();
    _clientIdController.dispose();
    _clientSecretController.dispose();
    for (final c in _priceControllers.values) {
      c.dispose();
    }
    for (final f in _priceFocusNodes.values) {
      f.dispose();
    }
    for (final c in _amountControllers.values) {
      c.dispose();
    }
    for (final f in _amountFocusNodes.values) {
      f.dispose();
    }
    _withdrawAmountController.dispose();
    _withdrawAddressController.dispose();
    _withdrawMethodController.dispose();
    _withdrawTagController.dispose();
    _percentBufferController.dispose();
    _percentBufferFocus.dispose();
    _configPasswordController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _wasBackgrounded = true;
        break;
      case AppLifecycleState.resumed:
        if (_wasBackgrounded) {
          _wasBackgrounded = false;
          unawaited(_vm.resumeConnection());
        }
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _vm,
      builder: (context, _) {
        _ensureTabController(MediaQuery.sizeOf(context).width <= 768);
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.tab, control: true): () =>
                _cycleTab(1),
            const SingleActivator(
              LogicalKeyboardKey.tab,
              control: true,
              shift: true,
            ): () =>
                _cycleTab(-1),
          },
          child: Focus(
            autofocus: true,
            debugLabel: 'Page shortcuts',
            child: Scaffold(
              appBar: AppBar(
                title: Text(
                  _mobileNavigation ? _tabLabels[_currentTab] : 'BitfinexChase',
                ),
                bottom: _mobileNavigation
                    ? null
                    : TabBar(
                        controller: _tabs,
                        isScrollable: true,
                        labelPadding: const EdgeInsets.symmetric(
                          horizontal: 30,
                        ),
                        tabs: [
                          const Tab(text: 'Home'),
                          const Tab(text: 'Account'),
                          Tab(text: 'Pairs (${_vm.tradingPairs.length})'),
                          Tab(text: 'Orders (${_vm.activeOrders.length})'),
                          Tab(text: 'Positions (${_vm.positions.length})'),
                          const Tab(text: 'Trade History'),
                          Tab(
                            text: _vm.unreadAnnouncementCount > 0
                                ? 'Announcement (${_vm.unreadAnnouncementCount})'
                                : 'Announcement',
                          ),
                          Tab(text: 'Logs (${_vm.statusMessages.length})'),
                        ],
                      ),
              ),
              body: Column(
                children: [
                  Expanded(
                    child: TabBarView(
                      controller: _tabs,
                      children: [
                        for (final tab in _tabOrder)
                          Builder(builder: (_) => _buildTab(tab)),
                      ],
                    ),
                  ),
                  if (!_mobileNavigation) _buildFooter(context),
                ],
              ),
              bottomNavigationBar: _mobileNavigation
                  ? _buildMobileNavigation()
                  : null,
            ),
          ),
        );
      },
    );
  }

  void _ensureTabController(bool mobile) {
    if (mobile == _mobileNavigation) return;
    final logicalTab = _currentTab;
    _tabs.removeListener(_tabChanged);
    _tabs.dispose();
    _mobileNavigation = mobile;
    _tabs = TabController(
      length: 8,
      vsync: this,
      initialIndex: _tabOrder.indexOf(logicalTab),
    )..addListener(_tabChanged);
  }

  Widget _buildTab(int tab) => switch (tab) {
    0 => _buildHomeTab(),
    1 => _buildAccountTab(),
    2 => _buildPairsTab(),
    3 => _buildOrdersTab(),
    4 => _buildPositionsTab(),
    5 => _buildHistoryTab(),
    6 => _buildAnnouncementTab(),
    7 => _buildLogsTab(),
    _ => throw StateError('Unknown tab'),
  };

  Widget _buildMobileNavigation() {
    const mainTabs = [2, 3, 4, 5, 1];
    final selected = mainTabs.indexOf(_currentTab);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildFooter(context),
        NavigationBar(
          height: 64,
          selectedIndex: selected < 0 ? 5 : selected,
          onDestinationSelected: (index) async {
            if (index < 5) {
              _selectTab(mainTabs[index]);
              return;
            }
            final tab = await showModalBottomSheet<int>(
              context: context,
              builder: (context) => SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final tab in const [0, 6, 7])
                      ListTile(
                        title: Text(_tabLabels[tab]),
                        onTap: () => Navigator.pop(context, tab),
                      ),
                  ],
                ),
              ),
            );
            if (mounted && tab != null) _selectTab(tab);
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.candlestick_chart),
              label: '行情',
            ),
            NavigationDestination(icon: Icon(Icons.list_alt), label: '订单'),
            NavigationDestination(
              icon: Icon(Icons.account_balance_wallet),
              label: '持仓',
            ),
            NavigationDestination(icon: Icon(Icons.history), label: '历史'),
            NavigationDestination(
              icon: Icon(Icons.account_balance),
              label: '账户',
            ),
            NavigationDestination(icon: Icon(Icons.more_horiz), label: '更多'),
          ],
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    // Sync controllers with VM (when loaded from prefs)
    if (_clientIdController.text != _vm.clientId) {
      _clientIdController.text = _vm.clientId;
    }
    if (_clientSecretController.text != _vm.clientSecret) {
      _clientSecretController.text = _vm.clientSecret;
    }
    final pctStr = (_vm.percentSizingBuffer * 100).toStringAsFixed(0);
    if (_percentBufferController.text != pctStr) {
      _percentBufferController.text = pctStr;
    }
    return Material(
      color: _panelColor,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _collapsibleHeader(
              title: 'Connection & Credentials',
              expanded: _connPanelExpanded,
              onToggle: () {
                setState(() => _connPanelExpanded = !_connPanelExpanded);
                // ignore: discarded_futures
                SettingsStore.saveConnPanelExpanded(_connPanelExpanded);
              },
            ),
            if (_connPanelExpanded) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: _vm.isConnected || _vm.isConnecting
                        ? null
                        : _vm.connect,
                    child: const Text('Connect'),
                  ),
                  ElevatedButton(
                    onPressed: _vm.isConnected ? _vm.disconnect : null,
                    child: const Text('Disconnect'),
                  ),
                  Row(
                    children: [
                      const Text('Paper Trading'),
                      Switch(
                        value: _vm.isTestnet,
                        onChanged: _vm.isConnected || _vm.isConnecting
                            ? null
                            : (v) => _vm.setIsTestnet(v),
                      ),
                    ],
                  ),
                  SizedBox(
                    width: 200,
                    child: TextField(
                      controller: _clientIdController,
                      enabled: !_vm.isAuthenticated,
                      decoration: const InputDecoration(labelText: 'API Key'),
                      onChanged: (v) => _vm.updateClientId(v),
                    ),
                  ),
                  SizedBox(
                    width: 220,
                    child: TextField(
                      controller: _clientSecretController,
                      enabled: !_vm.isAuthenticated,
                      obscureText: _secretObscured,
                      decoration: InputDecoration(
                        labelText: 'API Secret',
                        suffixIcon: IconButton(
                          onPressed: () => setState(
                            () => _secretObscured = !_secretObscured,
                          ),
                          icon: Icon(
                            _secretObscured
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                        ),
                      ),
                      onChanged: (v) => _vm.updateClientSecret(v),
                    ),
                  ),
                  ElevatedButton(
                    onPressed: _vm.isConnected && !_vm.isAuthenticating
                        ? _vm.authenticate
                        : null,
                    child: const Text('Authenticate'),
                  ),
                  OutlinedButton(
                    onPressed: _vm.isAuthenticated ? _vm.disconnect : null,
                    child: const Text('Logout'),
                  ),
                  if (!kIsWeb &&
                      defaultTargetPlatform == TargetPlatform.android)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: _vm.androidBackgroundKeepAlive,
                          onChanged: (value) {
                            if (value != null) {
                              _vm.setAndroidBackgroundKeepAlive(value);
                            }
                          },
                        ),
                        const Text('开启通知并保持后台连接'),
                      ],
                    ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: _vm.rememberCredentials,
                        onChanged: (v) =>
                            _vm.setRememberCredentials(v ?? false),
                      ),
                      const Text('Remember credentials'),
                    ],
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            _collapsibleHeader(
              title: 'Trading Settings',
              expanded: _settingsPanelExpanded,
              onToggle: () {
                setState(
                  () => _settingsPanelExpanded = !_settingsPanelExpanded,
                );
                // ignore: discarded_futures
                SettingsStore.saveSettingsPanelExpanded(_settingsPanelExpanded);
              },
            ),
            if (_settingsPanelExpanded) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Max Spread %'),
                  SizedBox(
                    width: 120,
                    child: TextFormField(
                      key: ValueKey(
                        'max-spread-percent-${_vm.maxSpreadPercent}',
                      ),
                      initialValue: _vm.maxSpreadPercent.toStringAsFixed(2),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onFieldSubmitted: (v) {
                        final d = double.tryParse(v);
                        if (d != null) _vm.setMaxSpreadPercent(d);
                      },
                    ),
                  ),
                  const Text('Percent Sizing Buffer (%)'),
                  SizedBox(
                    width: 120,
                    child: TextFormField(
                      controller: _percentBufferController,
                      focusNode: _percentBufferFocus,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onFieldSubmitted: (_) => _commitPercentBuffer(),
                      onEditingComplete: _commitPercentBuffer,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Theme'),
                      const SizedBox(width: 8),
                      DropdownButton<AppThemePreference>(
                        value: widget.themePreference,
                        items: AppThemePreference.values
                            .map(
                              (preference) =>
                                  DropdownMenuItem<AppThemePreference>(
                                    value: preference,
                                    child: Text(
                                      _themePreferenceLabel(preference),
                                    ),
                                  ),
                            )
                            .toList(),
                        onChanged: (preference) {
                          if (preference == null) return;
                          widget.onThemePreferenceChanged(preference);
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            _collapsibleHeader(
              title: 'Config',
              expanded: _configPanelExpanded,
              onToggle: () {
                setState(() => _configPanelExpanded = !_configPanelExpanded);
              },
            ),
            if (_configPanelExpanded) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 260,
                    child: TextField(
                      controller: _configPasswordController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Password (AES 可选) 密码',
                        hintText: '为空则明文导出',
                      ),
                    ),
                  ),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.upload),
                    onPressed: _exportConfigToClipboard,
                    label: const Text('Export -> Clipboard 导出'),
                  ),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.download),
                    onPressed: _importConfigFromClipboard,
                    label: const Text('Import <- Clipboard 导入'),
                  ),
                  Text(
                    '提示: 若加密导出，导入需相同密码',
                    style: TextStyle(color: _subtleTextColor, fontSize: 12),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAnnouncementTab() => const Padding(
    padding: EdgeInsets.all(24),
    child: SelectableText(
      'Bitfinex 未提供与原应用等价的公告列表、实时推送及已读状态 API。\n官方公告：https://www.bitfinex.com/posts',
    ),
  );

  Widget _buildLogsTab() {
    return Column(
      children: [
        Container(
          color: _sectionColor,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              const Text('Logs'),
              const Spacer(),
              TextButton(onPressed: _vm.clearLogs, child: const Text('Clear')),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: AnimatedBuilder(
            animation: _vm,
            builder: (context, _) {
              return ListView.builder(
                reverse: false,
                itemCount: _vm.statusMessages.length,
                itemBuilder: (context, index) {
                  final msg = _vm.statusMessages[index];
                  return Dismissible(
                    key: ValueKey('log-$index::$msg'),
                    direction: DismissDirection.startToEnd,
                    // 右滑复制该条日志:确认时复制后返回 false,让条目回弹
                    // 而非真正移除,便于把报错原文粘出来排查。
                    confirmDismiss: (_) async {
                      await _copyToClipboard(msg);
                      return false;
                    },
                    background: Container(
                      color: _sectionColor,
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: const Icon(Icons.copy, size: 18),
                    ),
                    child: ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      title: Text(msg, style: const TextStyle(fontSize: 12)),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  void _commitPercentBuffer() {
    final v = _percentBufferController.text.trim();
    final d = double.tryParse(v);
    if (d == null) return;
    final frac = (d / 100.0).clamp(0.1, 1.0);
    // Persist via VM; UI will reflect clamped value via AnimatedBuilder sync
    _vm.setPercentSizingBuffer(frac);
    final normalized = (frac * 100).toStringAsFixed(0);
    if (_percentBufferController.text != normalized) {
      _percentBufferController.text = normalized;
    }
    FocusScope.of(context).unfocus();
  }

  Future<void> _exportConfigToClipboard() async {
    final pwd = _configPasswordController.text.trim();
    try {
      final s = await ConfigService.exportConfig(
        password: pwd.isEmpty ? null : pwd,
      );
      await Clipboard.setData(ClipboardData(text: s));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('配置已导出到剪贴板${pwd.isEmpty ? ' (明文)' : ' (已加密)'}'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出失败: $e')));
    }
  }

  Future<void> _importConfigFromClipboard() async {
    try {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('剪贴板为空')));
        return;
      }
      final pwd = _configPasswordController.text.trim();
      final settings = await ConfigService.parseConfig(
        text,
        password: pwd.isEmpty ? null : pwd,
      );
      await ConfigService.applySettingsToPrefs(settings);
      await _applyImportedSettings(settings);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('配置导入成功')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导入失败: $e')));
    }
  }

  Future<void> _applyImportedSettings(Map<String, dynamic> settings) async {
    final app = (settings['app'] as Map?)?.cast<String, dynamic>() ?? {};
    final pairs = (settings['pairs'] as Map?)?.cast<String, dynamic>() ?? {};
    final ui = (settings['ui'] as Map?)?.cast<String, dynamic>() ?? {};

    // App settings -> ViewModel
    final keepAlive = app['androidBackgroundKeepAlive'];
    if (keepAlive is bool) await _vm.setAndroidBackgroundKeepAlive(keepAlive);
    final isTestnet = app['isTestnet'];
    if (isTestnet is bool) {
      await _vm.setIsTestnet(isTestnet);
    }

    final remember = app['rememberCredentials'];
    if (remember is bool) {
      await _vm.setRememberCredentials(remember);
    }
    final clientId = app['clientId'];
    if (clientId is String) {
      _vm.updateClientId(clientId);
      _clientIdController.text = clientId;
    }
    final clientSecret = app['clientSecret'];
    if (clientSecret is String) {
      _vm.updateClientSecret(clientSecret);
      _clientSecretController.text = clientSecret;
    }
    final maxSpreadPercent = app['maxSpreadPercent'];
    if (maxSpreadPercent is num) {
      await _vm.setMaxSpreadPercent(maxSpreadPercent.toDouble());
    }
    final percentSizingBuffer = app['percentSizingBuffer'];
    if (percentSizingBuffer is num) {
      await _vm.setPercentSizingBuffer(percentSizingBuffer.toDouble());
      _percentBufferController.text = (percentSizingBuffer.toDouble() * 100)
          .toStringAsFixed(0);
    }
    final hideZero = app['hideZeroCurrencies'];
    if (hideZero is bool) {
      await _vm.setHideZeroCurrencies(hideZero);
    }
    final themePreference = app['themePreference'];
    if (themePreference is String) {
      final preference = AppThemePreference.values.firstWhere(
        (v) => v.name == themePreference,
        orElse: () => AppThemePreference.system,
      );
      widget.onThemePreferenceChanged(preference);
    }

    // Custom trading pairs: replace current customs with imported
    final customTradingPairs = pairs['customTradingPairs'];
    if (customTradingPairs is List) {
      final imported = customTradingPairs.cast<Map>().map(
        (raw) => TradingPair.fromMap(raw.cast<String, dynamic>()),
      );
      await _vm.replaceImportedCustomTradingPairs(imported);
    }

    // UI panel states
    setState(() {
      final b = ui['connPanelExpanded'];
      if (b is bool) _connPanelExpanded = b;
      final s = ui['settingsPanelExpanded'];
      if (s is bool) _settingsPanelExpanded = s;
      final c = ui['customPanelExpanded'];
      if (c is bool) _customPanelExpanded = c;
      final hf = ui['historyFiltersExpanded'];
      if (hf is bool) _historyFiltersExpanded = hf;
      final hp = ui['historyPositionsExpanded'];
      if (hp is bool) _historyPositionsExpanded = hp;
    });

    // Pair options expanded map
    final pairOptionsMap = ui['pairOptionsExpandedMap'];
    if (pairOptionsMap is Map) {
      final typed = pairOptionsMap.cast<String, dynamic>();
      for (final tp in _vm.tradingPairs) {
        final b = typed[tp.symbol];
        if (b is bool) {
          // ignore: discarded_futures
          _vm.setPairOptionsExpanded(tp, b);
        }
      }
    }
  }

  Widget _buildHomeTab() {
    return ListView(
      padding: EdgeInsets.zero,
      children: [_buildHeader(context)],
    );
  }

  Widget _buildAccountTab() {
    final acc = _vm.accountSummaries;
    return Column(
      children: [
        Container(
          color: _sectionColor,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              const Text('Account'),
              if (_vm.accountInfoFromCache)
                const Text('  缓存账户信息，余额待刷新', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Hide zero'),
                  Switch(
                    value: _vm.hideZeroCurrencies,
                    onChanged: (v) => _vm.setHideZeroCurrencies(v),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              if (_vm.isAuthenticated)
                FilledButton.tonal(
                  onPressed: _vm.loadingAccountSummaries
                      ? null
                      : _vm.refreshAccountSummaries,
                  child: const Text('Refresh'),
                ),
              if (!_vm.isAuthenticated)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Text('Authenticate to view account'),
                ),
              const Spacer(),
              if (_vm.loadingAccountSummaries)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
        if (_vm.accountSummariesError != null)
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              _vm.accountSummariesError!,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        if (acc != null)
          Expanded(
            child: ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${acc.username} (${acc.email})',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'ID: ${acc.id}  Type: ${acc.type}  2FA: ${acc.mandatoryTfa ? 'On' : 'Off'}  Security Keys: ${acc.securityKeysEnabled ? 'On' : 'Off'}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text(
                            'Total in USD: ',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          if (_vm.loadingAccountTotals)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            Text(
                              _vm.accountTotalUsd != null
                                  ? _vm.accountTotalUsd!.toStringAsFixed(2)
                                  : '-',
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Text(
                            'Total in BTC: ',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          if (_vm.loadingAccountTotals)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            Text(
                              _vm.accountTotalBtc != null
                                  ? _vm.accountTotalBtc!.toStringAsFixed(8)
                                  : '-',
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Text(
                            'Total in CNY: ',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          if (_vm.loadingAccountCny)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            Text(
                              _vm.accountTotalCny != null
                                  ? _vm.accountTotalCny!.toStringAsFixed(2)
                                  : '-',
                            ),
                          if (!_vm.loadingAccountCny &&
                              _vm.usdCnyNote != null) ...[
                            const SizedBox(width: 6),
                            Text(
                              '(${_vm.usdCnyNote})',
                              style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(context).colorScheme.outline,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    'Currencies (${(_vm.hideZeroCurrencies ? acc.summaries.where((s) => !s.isDisplayZero).length : acc.summaries.length)})',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 6),
                ...acc.summaries.where((s) => !_vm.hideZeroCurrencies || !s.isDisplayZero).map((
                  s,
                ) {
                  final color = s.hasDisplayableEquity
                      ? Theme.of(context).colorScheme.onSurface
                      : _subtleTextColor;
                  return Column(
                    children: [
                      ListTile(
                        dense: true,
                        title: Row(
                          children: [
                            Text(
                              s.currency,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: color,
                              ),
                            ),
                            const SizedBox(width: 12),
                            // 点击整个 Equity 区块即可复制该 currency 的 equity 数量。
                            // 用 InkWell 包裹文本+图标扩大命中区域，避免原小图标按钮
                            // (24x24 + compact) 命中区过小导致点击不灵敏。
                            Tooltip(
                              message: 'Copy ${s.currency} Equity',
                              child: InkWell(
                                onTap: () => _copyToClipboard(
                                  s.equity.toStringAsFixed(6),
                                ),
                                borderRadius: BorderRadius.circular(4),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 6,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'Equity: ${s.equity.toStringAsFixed(6)}',
                                        style: TextStyle(color: color),
                                      ),
                                      const SizedBox(width: 6),
                                      Icon(Icons.copy, size: 14, color: color),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Flexible(
                              child: Builder(
                                builder: (_) {
                                  final usdRate = _vm.getCachedUsdRate(
                                    s.currency,
                                  );
                                  final btcRate = _vm.getCachedBtcRate(
                                    s.currency,
                                  );
                                  // Fire-and-forget: ensure rates are fetched if missing/expired
                                  // ignore: discarded_futures
                                  _vm.ensureUsdRate(s.currency);
                                  // ignore: discarded_futures
                                  _vm.ensureBtcRate(s.currency);
                                  final usdText =
                                      (usdRate != null && usdRate > 0)
                                      ? (s.equity * usdRate).toStringAsFixed(2)
                                      : '-';
                                  final btcText =
                                      (btcRate != null && btcRate > 0)
                                      ? (s.equity * btcRate).toStringAsFixed(8)
                                      : '-';
                                  return Wrap(
                                    spacing: 12,
                                    runSpacing: 2,
                                    children: [
                                      Text(
                                        '≈ $usdText USD',
                                        style: TextStyle(color: color),
                                      ),
                                      Text(
                                        '≈ $btcText BTC',
                                        key: ValueKey(
                                          '${s.currency}-equity-btc',
                                        ),
                                        style: TextStyle(color: color),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Bal: ${s.balance.toStringAsFixed(6)}  Avail: ${s.availableFunds.toStringAsFixed(6)}  Withdraw: ${s.availableWithdrawalFunds.toStringAsFixed(6)}',
                              style: TextStyle(color: color, fontSize: 12),
                            ),
                            Text(
                              'Locked: ${s.lockedBalance.toStringAsFixed(6)}  Margin wallet: ${s.marginBalance.toStringAsFixed(6)}',
                              style: TextStyle(color: color, fontSize: 12),
                            ),
                          ],
                        ),
                        trailing: s.depositAddress != null
                            ? IconButton(
                                icon: const Icon(Icons.copy, size: 18),
                                tooltip: 'Copy Deposit Address',
                                onPressed: () {
                                  Clipboard.setData(
                                    ClipboardData(text: s.depositAddress!),
                                  );
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Address copied'),
                                      duration: Duration(seconds: 1),
                                    ),
                                  );
                                },
                              )
                            : null,
                      ),
                      const Divider(height: 1),
                    ],
                  );
                }),
                const SizedBox(height: 12),
                _buildWithdrawalPanel(),
              ],
            ),
          )
        else
          Expanded(
            child: Center(
              child: Text(
                _vm.isAuthenticated
                    ? 'No data. Tap Refresh.'
                    : 'Authenticate to view account.',
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildWithdrawalPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _collapsibleHeader(
        title: 'Withdraw 提款',
        expanded: _withdrawPanelExpanded,
        onToggle: () {
          setState(() => _withdrawPanelExpanded = !_withdrawPanelExpanded);
          if (_withdrawPanelExpanded && _vm.isAuthenticated) {
            _vm.loadWithdrawals(currency: _withdrawCurrency);
          }
        },
      ),
      if (_withdrawPanelExpanded)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_vm.isTestnet) const Text('Paper 模拟资产不可提现。'),
              const Text('Bitfinex 不提供等价地址簿接口，请填写收款地址和对应网络。来源：Exchange 钱包。'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: 130,
                    child: TextFormField(
                      initialValue: _withdrawCurrency,
                      decoration: const InputDecoration(
                        labelText: 'Currency（如 BTC / UST）',
                      ),
                      onChanged: (v) =>
                          _withdrawCurrency = v.trim().toUpperCase(),
                    ),
                  ),
                  SizedBox(
                    width: 320,
                    child: TextField(
                      controller: _withdrawAddressController,
                      decoration: const InputDecoration(
                        labelText: 'Destination address',
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 230,
                    child: TextField(
                      controller: _withdrawMethodController,
                      decoration: const InputDecoration(
                        labelText: 'Method / network（如 bitcoin）',
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 220,
                    child: TextField(
                      controller: _withdrawTagController,
                      decoration: const InputDecoration(
                        labelText: 'Memo / Payment ID（选填）',
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 180,
                    child: TextField(
                      controller: _withdrawAmountController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(labelText: 'Amount'),
                    ),
                  ),
                  FilledButton(
                    onPressed: _vm.isAuthenticated && !_vm.isTestnet
                        ? _confirmAndWithdraw
                        : null,
                    child: const Text('Withdraw'),
                  ),
                ],
              ),
              const Divider(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _vm.withdrawalsFromCache
                          ? 'Withdrawal History 提款历史（缓存，等待刷新）'
                          : 'Withdrawal History 提款历史',
                    ),
                  ),
                  IconButton(
                    onPressed: _vm.isAuthenticated && !_vm.loadingWithdrawals
                        ? () => _vm.loadWithdrawals(currency: _withdrawCurrency)
                        : null,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              if (_vm.loadingWithdrawals) const LinearProgressIndicator(),
              if (_vm.withdrawalsError != null)
                Text(
                  _vm.withdrawalsError!,
                  style: const TextStyle(color: Colors.red),
                ),
              if (_vm.withdrawals.isEmpty && !_vm.loadingWithdrawals)
                const Text('暂无提款记录'),
              ..._vm.withdrawals.map(_buildWithdrawalHistoryRow),
              if (_vm.hasMoreWithdrawals)
                TextButton(
                  onPressed: _vm.loadingWithdrawals
                      ? null
                      : () => _vm.loadWithdrawals(
                          currency: _withdrawCurrency,
                          loadMore: true,
                        ),
                  child: const Text('Load more'),
                ),
            ],
          ),
        ),
    ],
  );

  Future<void> _confirmAndWithdraw() async {
    final addr = _withdrawAddressController.text.trim();
    final method = _withdrawMethodController.text.trim();
    final amount = double.tryParse(_withdrawAmountController.text.trim());
    if (addr.isEmpty || method.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请填写提款地址和网络')));
      return;
    }
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入有效的金额')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('确认提款'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Currency: $_withdrawCurrency'),
              Text('Amount: ${amount.toStringAsFixed(8)}'),
              Text('Address: $addr'),
              Text('Method: $method'),
              Text('Memo: ${_withdrawTagController.text.trim()}'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    final ok = await _vm.withdraw(
      currency: _withdrawCurrency,
      address: addr,
      amount: amount,
      method: method,
      destinationTag: _withdrawTagController.text.trim(),
    );
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('提款请求已提交，请检查确认邮件')));
      _withdrawAmountController.clear();
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('提款失败，请检查日志')));
    }
  }

  Widget _buildWithdrawalHistoryRow(Withdrawal withdrawal) {
    final timestamp = withdrawal.updatedAt ?? withdrawal.createdAt;
    final timeLabel = timestamp == null ? '时间未知' : _displayDateTime(timestamp);
    final transactionId = withdrawal.transactionId;
    final amount = withdrawal.amount
        .toStringAsFixed(8)
        .replaceFirst(RegExp(r'\.?0+$'), '');
    final fee = withdrawal.fee
        .toStringAsFixed(8)
        .replaceFirst(RegExp(r'\.?0+$'), '');
    final stateColor = _withdrawalStateColor(withdrawal.state);

    return Padding(
      key: ValueKey('withdrawal-${withdrawal.id}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _withdrawalStateIcon(withdrawal.state),
                size: 18,
                color: stateColor,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '$amount ${withdrawal.currency}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                withdrawal.state.toUpperCase(),
                style: TextStyle(
                  color: stateColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text('#${withdrawal.id} · $timeLabel'),
          Text(
            'Address: ${withdrawal.address}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (transactionId != null && transactionId.isNotEmpty)
            Text(
              'Transaction: $transactionId',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          if (withdrawal.fee > 0) Text('Fee: $fee ${withdrawal.currency}'),
          const Divider(height: 12),
        ],
      ),
    );
  }

  Color _withdrawalStateColor(String state) {
    return switch (state) {
      'completed' => Colors.green,
      'rejected' || 'cancelled' || 'interrupted' => Colors.red,
      'confirmed' => Colors.blue,
      _ => Colors.orange,
    };
  }

  IconData _withdrawalStateIcon(String state) {
    return switch (state) {
      'completed' => Icons.check_circle_outline,
      'rejected' || 'cancelled' || 'interrupted' => Icons.error_outline,
      'confirmed' => Icons.verified_outlined,
      _ => Icons.schedule,
    };
  }

  Widget _collapsibleHeader({
    required String title,
    required bool expanded,
    required VoidCallback onToggle,
  }) {
    return InkWell(
      onTap: onToggle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: _panelColor,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Icon(expanded ? Icons.expand_less : Icons.expand_more),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              expanded ? 'Hide' : 'Show',
              style: TextStyle(color: _subtleTextColor),
            ),
          ],
        ),
      ),
    );
  }

  String _pairTypeLabel(TradingPair pair) {
    if (pair.type != TradingPairType.future) return 'Spot';
    return pair.amountUnit == AmountUnit.usd
        ? 'Inverse (API ${pair.apiAmountCurrency})'
        : 'Linear (Base amt)';
  }

  Widget _buildPairsTab() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          Expanded(
            child: ListView.separated(
              itemCount: _vm.tradingPairs.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final tp = _vm.tradingPairs[index];
                final spread = (tp.bestAsk > 0 && tp.bestBid > 0)
                    ? (tp.bestAsk - tp.bestBid)
                    : 0.0;
                final last = tp.lastUpdate != null
                    ? _hhmmss(tp.lastUpdate!)
                    : '-';
                return Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 8.0,
                      horizontal: 8.0,
                    ),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final isCompact = constraints.maxWidth < 480;
                        if (isCompact) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Flexible(
                                          child: Text(
                                            tp.symbol,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        _chip(
                                          _pairTypeLabel(tp.pair),
                                          Colors.indigo,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Align(
                                alignment: Alignment.centerRight,
                                child: Text(
                                  'Updated: $last',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: _subtleTextColor,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Bid: ${tp.bestBid.toStringAsFixed(2)} · Ask: ${tp.bestAsk.toStringAsFixed(2)} · Spread: ${spread.toStringAsFixed(2)}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _subtleTextColor,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerRight,
                                child: Wrap(
                                  alignment: WrapAlignment.end,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 8,
                                  runSpacing: 6,
                                  children: [
                                    FilledButton.tonal(
                                      onPressed: () => tp.isSubscribed
                                          ? _vm.unsubscribeFromInstrument(tp)
                                          : _vm.subscribeToInstrument(tp),
                                      child: Text(
                                        tp.isSubscribed
                                            ? 'Unsubscribe'
                                            : 'Subscribe',
                                      ),
                                    ),
                                    TextButton.icon(
                                      onPressed: () =>
                                          _vm.setPairOptionsExpanded(
                                            tp,
                                            !(tp.optionsExpanded == true),
                                          ),
                                      icon: Icon(
                                        (tp.optionsExpanded == true)
                                            ? Icons.expand_less
                                            : Icons.expand_more,
                                      ),
                                      label: const Text('Options'),
                                    ),
                                  ],
                                ),
                              ),
                              if (tp.optionsExpanded == true) ...[
                                // Futures-only controls: leverage + input mode
                                if (tp.pair.type == TradingPairType.future)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 6.0),
                                    child: SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (tp.usePercentInput)
                                            _leverageSelector(tp),
                                          if (tp.usePercentInput)
                                            const SizedBox(width: 12),
                                          _inputModeToggle(tp),
                                          const SizedBox(width: 12),
                                          _orderTypeToggle(tp),
                                        ],
                                      ),
                                    ),
                                  ),
                                // Spot-only controls: order type toggle
                                if (tp.pair.type == TradingPairType.spot)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 6.0),
                                    child: SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [_orderTypeToggle(tp)],
                                      ),
                                    ),
                                  ),
                                const SizedBox(height: 6),
                                Wrap(
                                  alignment: WrapAlignment.end,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 8,
                                  runSpacing: 6,
                                  children: [
                                    if (!(tp.pair.type ==
                                            TradingPairType.future &&
                                        tp.usePercentInput)) ...[
                                      _manualAmountInput(tp, isBuy: true),
                                      _amountStepper(tp, isBuy: true),
                                    ] else ...[
                                      SizedBox(
                                        width: 240,
                                        child: _percentSlider(tp, isBuy: true),
                                      ),
                                    ],
                                    if (!tp.useMarketOrder)
                                      _priceBox(
                                        id: '${tp.symbol}-buy-px',
                                        label: 'Buy Px',
                                        initial:
                                            tp.buyLimitPrice ??
                                            (_vm.computeLimitPrice(tp, 'buy') ??
                                                0),
                                        tp: tp,
                                        isBuy: true,
                                        onChanged: (v) => setState(
                                          () => tp.buyLimitPrice = v > 0
                                              ? v
                                              : null,
                                        ),
                                      ),
                                    FilledButton(
                                      onPressed: _vm.canTradeSymbol(tp.symbol)
                                          ? () => _handleManualOrderButton(
                                              tp,
                                              'buy',
                                            )
                                          : null,
                                      child: const Text('Buy'),
                                    ),
                                    if (!tp.useMarketOrder)
                                      _tickAdjuster(tp, isBuy: true),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  alignment: WrapAlignment.end,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 8,
                                  runSpacing: 6,
                                  children: [
                                    if (!(tp.pair.type ==
                                            TradingPairType.future &&
                                        tp.usePercentInput)) ...[
                                      _manualAmountInput(tp, isBuy: false),
                                      _amountStepper(tp, isBuy: false),
                                    ] else ...[
                                      SizedBox(
                                        width: 240,
                                        child: _percentSlider(tp, isBuy: false),
                                      ),
                                    ],
                                    if (!tp.useMarketOrder)
                                      _priceBox(
                                        id: '${tp.symbol}-sell-px',
                                        label: 'Sell Px',
                                        initial:
                                            tp.sellLimitPrice ??
                                            (_vm.computeLimitPrice(
                                                  tp,
                                                  'sell',
                                                ) ??
                                                0),
                                        tp: tp,
                                        isBuy: false,
                                        onChanged: (v) => setState(
                                          () => tp.sellLimitPrice = v > 0
                                              ? v
                                              : null,
                                        ),
                                      ),
                                    FilledButton(
                                      style: FilledButton.styleFrom(
                                        backgroundColor: Colors.red,
                                      ),
                                      onPressed: _vm.canTradeSymbol(tp.symbol)
                                          ? () => _handleManualOrderButton(
                                              tp,
                                              'sell',
                                            )
                                          : null,
                                      child: const Text('Sell'),
                                    ),
                                    if (!tp.useMarketOrder)
                                      _tickAdjuster(tp, isBuy: false),
                                  ],
                                ),
                              ],
                            ],
                          );
                        }
                        // Regular (wider) layout: original two-column
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Flexible(
                                              child: Text(
                                                tp.symbol,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            _chip(
                                              _pairTypeLabel(tp.pair),
                                              Colors.indigo,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: Text(
                                      'Updated: $last',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: _subtleTextColor,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Bid: ${tp.bestBid.toStringAsFixed(2)}  Ask: ${tp.bestAsk.toStringAsFixed(2)}  Spread: ${spread.toStringAsFixed(2)}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: _subtleTextColor,
                                    ),
                                    softWrap: true,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Wrap(
                                    alignment: WrapAlignment.end,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    spacing: 8,
                                    runSpacing: 6,
                                    children: [
                                      FilledButton.tonal(
                                        onPressed: () => tp.isSubscribed
                                            ? _vm.unsubscribeFromInstrument(tp)
                                            : _vm.subscribeToInstrument(tp),
                                        child: Text(
                                          tp.isSubscribed
                                              ? 'Unsubscribe'
                                              : 'Subscribe',
                                        ),
                                      ),
                                      TextButton.icon(
                                        onPressed: () =>
                                            _vm.setPairOptionsExpanded(
                                              tp,
                                              !(tp.optionsExpanded == true),
                                            ),
                                        icon: Icon(
                                          (tp.optionsExpanded == true)
                                              ? Icons.expand_less
                                              : Icons.expand_more,
                                        ),
                                        label: Text(
                                          (tp.optionsExpanded == true)
                                              ? 'Hide Options'
                                              : 'Show Options',
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (tp.optionsExpanded == true) ...[
                                    if (tp.pair.type == TradingPairType.future)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          top: 6.0,
                                        ),
                                        child: Wrap(
                                          alignment: WrapAlignment.end,
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          spacing: 12,
                                          runSpacing: 6,
                                          children: [
                                            if (tp.usePercentInput)
                                              _leverageSelector(tp),
                                            _inputModeToggle(tp),
                                            _orderTypeToggle(tp),
                                          ],
                                        ),
                                      ),
                                    if (tp.pair.type == TradingPairType.spot)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          top: 6.0,
                                        ),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.end,
                                          children: [_orderTypeToggle(tp)],
                                        ),
                                      ),
                                    const SizedBox(height: 6),
                                    Wrap(
                                      alignment: WrapAlignment.end,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      spacing: 8,
                                      runSpacing: 6,
                                      children: [
                                        if (!(tp.pair.type ==
                                                TradingPairType.future &&
                                            tp.usePercentInput)) ...[
                                          _manualAmountInput(tp, isBuy: true),
                                          _amountStepper(tp, isBuy: true),
                                        ] else ...[
                                          SizedBox(
                                            width: 240,
                                            child: _percentSlider(
                                              tp,
                                              isBuy: true,
                                            ),
                                          ),
                                        ],
                                        if (!tp.useMarketOrder)
                                          _priceBox(
                                            id: '${tp.symbol}-buy-px',
                                            label: 'Buy Px',
                                            initial:
                                                tp.buyLimitPrice ??
                                                (_vm.computeLimitPrice(
                                                      tp,
                                                      'buy',
                                                    ) ??
                                                    0),
                                            tp: tp,
                                            isBuy: true,
                                            onChanged: (v) => setState(
                                              () => tp.buyLimitPrice = v > 0
                                                  ? v
                                                  : null,
                                            ),
                                          ),
                                        FilledButton(
                                          onPressed:
                                              _vm.canTradeSymbol(tp.symbol)
                                              ? () => _handleManualOrderButton(
                                                  tp,
                                                  'buy',
                                                )
                                              : null,
                                          child: const Text('Buy'),
                                        ),
                                        if (!tp.useMarketOrder)
                                          _tickAdjuster(tp, isBuy: true),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Wrap(
                                      alignment: WrapAlignment.end,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      spacing: 8,
                                      runSpacing: 6,
                                      children: [
                                        if (!(tp.pair.type ==
                                                TradingPairType.future &&
                                            tp.usePercentInput)) ...[
                                          _manualAmountInput(tp, isBuy: false),
                                          _amountStepper(tp, isBuy: false),
                                        ] else ...[
                                          SizedBox(
                                            width: 240,
                                            child: _percentSlider(
                                              tp,
                                              isBuy: false,
                                            ),
                                          ),
                                        ],
                                        if (!tp.useMarketOrder)
                                          _priceBox(
                                            id: '${tp.symbol}-sell-px',
                                            label: 'Sell Px',
                                            initial:
                                                tp.sellLimitPrice ??
                                                (_vm.computeLimitPrice(
                                                      tp,
                                                      'sell',
                                                    ) ??
                                                    0),
                                            tp: tp,
                                            isBuy: false,
                                            onChanged: (v) => setState(
                                              () => tp.sellLimitPrice = v > 0
                                                  ? v
                                                  : null,
                                            ),
                                          ),
                                        FilledButton(
                                          style: FilledButton.styleFrom(
                                            backgroundColor: Colors.red,
                                          ),
                                          onPressed:
                                              _vm.canTradeSymbol(tp.symbol)
                                              ? () => _handleManualOrderButton(
                                                  tp,
                                                  'sell',
                                                )
                                              : null,
                                          child: const Text('Sell'),
                                        ),
                                        if (!tp.useMarketOrder)
                                          _tickAdjuster(tp, isBuy: false),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          _buildCustomPairsSection(),
          _statusPanel(),
        ],
      ),
    );
  }

  Widget _buildCustomPairsSection() {
    final count = _vm.customTradingPairs.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () {
            setState(() => _customPanelExpanded = !_customPanelExpanded);
            // ignore: discarded_futures
            SettingsStore.saveCustomPanelExpanded(_customPanelExpanded);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            decoration: BoxDecoration(
              color: _panelColor,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Icon(
                  _customPanelExpanded ? Icons.expand_less : Icons.expand_more,
                ),
                const SizedBox(width: 6),
                const Text('Custom Trading Pairs'),
                const SizedBox(width: 8),
                if (count > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.indigo.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Colors.indigo.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Text(
                      '$count',
                      style: const TextStyle(color: Colors.indigo),
                    ),
                  ),
                const Spacer(),
                Text(
                  _customPanelExpanded ? 'Hide' : 'Show',
                  style: TextStyle(color: _subtleTextColor),
                ),
              ],
            ),
          ),
        ),
        if (_customPanelExpanded) ...[
          const SizedBox(height: 8),
          _buildCustomPairsPanel(),
        ],
      ],
    );
  }

  Widget _buildCustomPairsPanel() {
    return Card(
      color: _sectionColor,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Custom Trading Pairs',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _newSymbolController,
                    decoration: const InputDecoration(labelText: 'Symbol'),
                    textCapitalization: TextCapitalization.characters,
                  ),
                ),
                SizedBox(
                  width: 180,
                  child: TextField(
                    controller: _newMaxDeviationController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Max Price Deviation (%)',
                    ),
                  ),
                ),
                FilledButton(
                  onPressed: !_vm.isConnected || _vm.loadingCustomInstrument
                      ? null
                      : () async {
                          final symbol = _newSymbolController.text.trim();
                          final maxDeviation =
                              double.tryParse(
                                _newMaxDeviationController.text.trim(),
                              ) ??
                              0.3;
                          await _vm.addCustomTradingPair(
                            symbol: symbol,
                            maxPriceDeviationPercent: maxDeviation,
                          );
                          if (_vm.customInstrumentError == null) {
                            _newSymbolController.clear();
                          }
                        },
                  child: _vm.loadingCustomInstrument
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Add'),
                ),
              ],
            ),
            if (_vm.customInstrumentError != null) ...[
              const SizedBox(height: 6),
              Text(
                _vm.customInstrumentError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 8),
            if (_vm.customTradingPairs.isNotEmpty)
              Wrap(
                spacing: 6,
                children: _vm.customTradingPairs
                    .map(
                      (p) => Chip(
                        label: Text(
                          '${p.symbol} • '
                          '${_pairTypeLabel(p)}',
                        ),
                        onDeleted: () => _vm.removeCustomTradingPair(p.symbol),
                      ),
                    )
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrdersTab() {
    return Column(
      children: [
        Container(
          color: _sectionColor,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              const Text('Orders'),
              const Spacer(),
              FilledButton.tonal(
                onPressed: _vm.loadingOpenOrders
                    ? null
                    : () => _vm.refreshOpenOrders(),
                child: const Text('Refresh'),
              ),
              if (_vm.loadingOpenOrders)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: _vm.activeOrders.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final o = _vm.activeOrders[index];
              final sideColor = o.order.direction == 'buy'
                  ? Colors.green
                  : Colors.red;
              final state = o.order.orderState;
              // Resolve display unit for amount based on instrument
              final tp =
                  _vm.findTradingPairVm(o.order.instrumentName) ??
                  TradingPairVM(TradingPair.unverified(o.order.instrumentName));
              final amtUnitLabel = tp.pair.apiAmountCurrency;
              final isInverseOrder = isInverseFuturePair(tp.pair);
              final inverseOrderReferencePrice = o.order.price > 0
                  ? o.order.price
                  : (o.order.direction.toLowerCase() == 'buy'
                        ? tp.bestAsk
                        : tp.bestBid);
              final amountDisplay =
                  isInverseOrder && inverseOrderReferencePrice > 0
                  ? '${o.order.amount} ${tp.pair.apiAmountCurrency} (≈ ${(o.order.amount / inverseOrderReferencePrice).toStringAsFixed(8)} ${tp.pair.baseCurrency})'
                  : '${o.order.amount} $amtUnitLabel';
              String typeLabel() {
                final t = o.order.orderType.toLowerCase();
                switch (t) {
                  case 'limit':
                    return 'LIMIT';
                  case 'market':
                    return 'MARKET';
                  case 'stop_market':
                    return 'STOP MKT';
                  case 'stop_limit':
                    return 'STOP LMT';
                  case 'take_market':
                    return 'TAKE MKT';
                  case 'take_limit':
                    return 'TAKE LMT';
                  case 'trailing_stop':
                    return 'TRAIL';
                  default:
                    return o.order.orderType.toUpperCase();
                }
              }

              Color typeColor() {
                final t = o.order.orderType.toLowerCase();
                switch (t) {
                  case 'limit':
                    return Colors.grey;
                  case 'market':
                    return Colors.blueGrey;
                  case 'stop_market':
                  case 'stop_limit':
                    return Colors.orange;
                  case 'take_market':
                  case 'take_limit':
                    return Colors.teal;
                  case 'trailing_stop':
                    return Colors.purple;
                  default:
                    return _subtleTextColor;
                }
              }

              return LayoutBuilder(
                builder: (context, constraints) {
                  final isCompact = constraints.maxWidth < 420;
                  final labelStyle = TextStyle(
                    color: _subtleTextColor,
                    fontSize: isCompact ? 12 : 13,
                  );
                  final valueStyle = TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                    fontSize: isCompact ? 12 : 13,
                  );
                  Widget infoItem(String label, String value, {Color? color}) =>
                      RichText(
                        text: TextSpan(
                          children: [
                            TextSpan(
                              text: label,
                              style: color != null
                                  ? labelStyle.copyWith(color: color)
                                  : labelStyle,
                            ),
                            TextSpan(
                              text: value,
                              style: color != null
                                  ? valueStyle.copyWith(color: color)
                                  : valueStyle,
                            ),
                          ],
                        ),
                      );

                  // Determine colored labels for stop/take/trigger
                  final t = o.order.orderType.toLowerCase();
                  final isStop = t == 'stop_market' || t == 'stop_limit';
                  final isTake = t == 'take_market' || t == 'take_limit';
                  Color trigColor(String trig) {
                    switch (trig) {
                      case 'mark_price':
                        return Colors.indigo;
                      case 'index_price':
                        return Colors.blueGrey;
                      case 'last_price':
                        return Colors.brown;
                      default:
                        return Theme.of(context).colorScheme.onSurface;
                    }
                  }

                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    isThreeLine: true,
                    title: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          o.order.instrumentName,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: sideColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: sideColor.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Text(
                            o.order.direction.toUpperCase(),
                            style: TextStyle(
                              color: sideColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        _chip(typeLabel(), typeColor()),
                        if (o.order.postOnly) _chip('POST', Colors.indigo),
                        if (o.order.reduceOnly) _chip('REDUCE', Colors.brown),
                      ],
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 12,
                          runSpacing: 4,
                          children: [
                            infoItem(
                              isCompact ? 'Amt: ' : 'Amount: ',
                              amountDisplay,
                            ),
                            if (o.order.price > 0)
                              infoItem('Px: ', o.order.price.toString()),
                            if (o.order.stopPrice != null &&
                                o.order.stopPrice! > 0)
                              infoItem(
                                'Stop: ',
                                o.order.stopPrice!.toString(),
                                color: isStop
                                    ? Colors.orange
                                    : (isTake ? Colors.teal : Colors.orange),
                              ),
                            if (o.order.trailing != null &&
                                o.order.trailing! > 0)
                              infoItem(
                                'Trail: ',
                                o.order.trailing!.toString(),
                                color: Colors.purple,
                              ),
                            if ((o.order.trigger ?? '').isNotEmpty)
                              infoItem(
                                'Trig: ',
                                o.order.trigger!,
                                color: trigColor(
                                  (o.order.trigger ?? '').toLowerCase(),
                                ),
                              ),
                            infoItem('State: ', state),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                minimumSize: const Size(0, 0),
                              ),
                              onPressed:
                                  o.order.orderType.toLowerCase() == 'limit' &&
                                      _vm.canTradeSymbol(o.order.instrumentName)
                                  ? () => _showModifyOrderDialog(o)
                                  : null,
                              child: const Text('Modify'),
                            ),
                            TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                minimumSize: const Size(0, 0),
                              ),
                              onPressed: () => _vm.cancelOrder(o),
                              child: const Text('Cancel'),
                            ),
                            // Per-order chasing toggle with tooltip when disabled
                            Builder(
                              builder: (context) {
                                final isLimit =
                                    o.order.orderType.toLowerCase() == 'limit';
                                final isPostOnly = o.order.postOnly;
                                final metadataVerified = _vm.canTradeSymbol(
                                  o.order.instrumentName,
                                );
                                final eligible =
                                    isLimit && isPostOnly && metadataVerified;
                                final chased = _vm.isOrderChased(o);
                                String? disabledReason;
                                if (!metadataVerified) {
                                  disabledReason =
                                      'Verified instrument metadata unavailable';
                                } else if (!eligible) {
                                  if (!isLimit && !isPostOnly) {
                                    disabledReason = '仅支持 Post-Only 限价单';
                                  } else if (!isLimit) {
                                    disabledReason = '仅支持限价单';
                                  } else if (!isPostOnly) {
                                    disabledReason = '仅支持 Post-Only 订单';
                                  }
                                }
                                final tip = eligible
                                    ? '追价：自动跟随最优价（仅此订单）'
                                    : (disabledReason ?? '不可用');
                                return Tooltip(
                                  message: tip,
                                  child: Opacity(
                                    opacity: eligible ? 1.0 : 0.6,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Checkbox(
                                          value: chased,
                                          onChanged: eligible
                                              ? (v) => setState(
                                                  () => _vm.setOrderChasing(
                                                    o,
                                                    v ?? false,
                                                  ),
                                                )
                                              : null,
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        const Text(
                                          'Chase',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
        _statusPanel(),
      ],
    );
  }

  Widget _buildPositionsTab() {
    return Column(
      children: [
        // Actions for Positions
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Open: ${_vm.positions.length}',
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              FilledButton(
                onPressed:
                    _vm.positions.isNotEmpty &&
                        _vm.positions.every(
                          (position) => _vm.canTradeSymbol(
                            position.position.instrumentName,
                          ),
                        )
                    ? _showCloseAllPositionsDialog
                    : null,
                child: const Text('Close All'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: _vm.positions.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final p = _vm.positions[index].position;
              final sideColor = p.direction == 'buy'
                  ? Colors.green
                  : Colors.red;
              final dynMark =
                  _vm.getLatestMarkPrice(p.instrumentName) ?? p.markPrice;
              // Ensure account metrics are available for liquidation price calculation
              final tp =
                  _vm.findTradingPairVm(p.instrumentName) ??
                  TradingPairVM(TradingPair.unverified(p.instrumentName));
              PositionPnl? positionPnl;
              if (tp.pair.isVerified &&
                  tp.pair.type == TradingPairType.future) {
                positionPnl = calculatePositionPnl(
                  pair: tp.pair,
                  position: p,
                  markPrice: dynMark,
                );
              }
              final pnlAmount =
                  positionPnl?.settlementAmountAsDouble ?? p.floatingProfitLoss;
              final pnlColor = pnlAmount >= 0 ? Colors.green : Colors.red;
              final pnlText = positionPnl == null
                  ? 'API PnL: ${p.floatingProfitLoss.isFinite ? _formatTradeHistoryNumber(p.floatingProfitLoss) : '-'} (unit unavailable)'
                  : _formatPositionPnl(positionPnl);
              final hasVerifiedFuture =
                  tp.pair.isVerified && tp.pair.type == TradingPairType.future;
              final marginCurrency = hasVerifiedFuture
                  ? tp.pair.marginCurrency.trim()
                  : '';
              // fire-and-forget, safe during build as it calls notifyListeners when done
              if (marginCurrency.isNotEmpty) {
                // ignore: discarded_futures
                _vm.ensureAccountMetricsForCurrency(marginCurrency);
              }
              final liq = hasVerifiedFuture
                  ? _vm.getEstimatedLiquidationPrice(p)
                  : null;
              final entity = !hasVerifiedFuture || marginCurrency.isEmpty
                  ? null
                  : _vm.getAccountEntityForCurrency(marginCurrency);

              return LayoutBuilder(
                builder: (context, constraints) {
                  final isCompact = constraints.maxWidth < 420;
                  final labelStyle = TextStyle(
                    color: Colors.grey.shade700,
                    fontSize: isCompact ? 12 : 13,
                  );
                  final valueStyle = TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                    fontSize: isCompact ? 12 : 13,
                  );

                  Widget infoItem(String label, String value) => RichText(
                    text: TextSpan(
                      children: [
                        TextSpan(text: label, style: labelStyle),
                        TextSpan(text: value, style: valueStyle),
                      ],
                    ),
                  );

                  Widget copyableInfoItem(
                    String label,
                    String value, {
                    String tooltip = 'Copy',
                  }) => Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Flexible(child: infoItem(label, value)),
                      const SizedBox(width: 4),
                      IconButton(
                        onPressed: () => _copyToClipboard(value),
                        icon: const Icon(Icons.copy, size: 14),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 24,
                          height: 24,
                        ),
                        tooltip: tooltip,
                      ),
                    ],
                  );

                  final tp =
                      _vm.findTradingPairVm(p.instrumentName) ??
                      TradingPairVM(TradingPair.unverified(p.instrumentName));
                  final nativeSize = tp.pair.isVerified
                      ? positionNativeApiAmount(tp.pair, p)
                      : p.size.abs();
                  final baseExposure = tp.pair.isVerified
                      ? apiAmountToBaseExposure(tp.pair, nativeSize, dynMark)
                      : p.sizeCurrency.abs();
                  final apiSizeStr = tp.pair.isVerified
                      ? '${_formatTradeHistoryNumber(nativeSize)} ${tp.pair.apiAmountCurrency}'
                      : '${_formatTradeHistoryNumber(nativeSize)} (unit unavailable)';
                  final baseExposureStr = tp.pair.isVerified
                      ? '${baseExposure > 0 ? _formatTradeHistoryNumber(baseExposure) : '-'} ${tp.pair.baseCurrency}'
                      : '${_formatTradeHistoryNumber(baseExposure)} (unit unavailable)';
                  final avgStr = p.averagePrice.toString();
                  final markStr = dynMark.toString();
                  final liqStr = liq != null ? liq.toStringAsFixed(2) : '-';
                  final entStr = entity?.toStringAsFixed(2) ?? '-';

                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    isThreeLine: true,
                    title: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          p.instrumentName,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: sideColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: sideColor.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Text(
                            p.direction.toUpperCase(),
                            style: TextStyle(
                              color: sideColor,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Text(
                          pnlText,
                          key: ValueKey('${p.instrumentName}-position-pnl'),
                          style: TextStyle(
                            color: pnlColor,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        // Key metrics as a wrapping row for small screens
                        Wrap(
                          spacing: 12,
                          runSpacing: 4,
                          children: [
                            copyableInfoItem(
                              'API Size: ',
                              apiSizeStr,
                              tooltip: 'Copy API Size',
                            ),
                            copyableInfoItem(
                              'Base Exposure: ',
                              baseExposureStr,
                              tooltip: 'Copy Base Exposure',
                            ),
                            copyableInfoItem(
                              'Avg: ',
                              avgStr,
                              tooltip: 'Copy Avg',
                            ),
                            infoItem('Reference: ', markStr),
                            infoItem('Liq: ', liqStr),
                            infoItem(isCompact ? 'Ent: ' : 'Entity: ', entStr),
                          ],
                        ),
                        const SizedBox(height: 6),
                        // Actions row wraps on compact screens
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            TextButton.icon(
                              onPressed:
                                  _vm.canTradeSymbol(p.instrumentName) &&
                                      p.kind != 'margin'
                                  ? () => _showIncreasePositionDialog(
                                      _vm.positions[index],
                                    )
                                  : null,
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('加仓'),
                            ),

                            TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                minimumSize: const Size(0, 0),
                              ),
                              onPressed:
                                  (_vm.canTradeSymbol(p.instrumentName) &&
                                      p.kind != 'margin')
                                  ? () => _showClosePositionDialog(
                                      _vm.positions[index],
                                    )
                                  : null,
                              child: const Text('Close'),
                            ),
                            TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                minimumSize: const Size(0, 0),
                              ),
                              onPressed:
                                  (_vm.canTradeSymbol(p.instrumentName) &&
                                      p.kind != 'margin')
                                  ? () => _showProtectPositionDialog(
                                      _vm.positions[index],
                                    )
                                  : null,
                              child: const Text('Protect'),
                            ),
                            Tooltip(
                              message:
                                  '保本止损：在该仓位均价下达 Stop Market 订单，数量为 100%，以最新成交价触发（合约使用 reduce-only，仅用于减仓/平仓）。',
                              child: TextButton(
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  minimumSize: const Size(0, 0),
                                ),
                                onPressed:
                                    (_vm.canTradeSymbol(p.instrumentName) &&
                                        p.kind != 'margin')
                                    ? () => _vm.placeBreakevenStop(
                                        _vm.positions[index],
                                      )
                                    : null,
                                child: const Text('SL at BE'),
                              ),
                            ),
                            TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                minimumSize: const Size(0, 0),
                              ),
                              onPressed:
                                  (_vm.canTradeSymbol(p.instrumentName) &&
                                      p.kind != 'margin')
                                  ? () => _showReversePositionDialog(
                                      _vm.positions[index],
                                    )
                                  : null,
                              child: const Text('Reverse'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
        _statusPanel(),
      ],
    );
  }

  Future<void> _showCloseAllPositionsDialog() async {
    final controller = TextEditingController(text: '100');
    String orderMode = 'limit'; // 'limit' | 'market'
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            final percentage = double.tryParse(controller.text.trim());
            final validPercentage = isValidPositionPercentage(percentage);
            final validAmounts =
                validPercentage &&
                _vm.positions.every((position) {
                  final pair = _vm
                      .findTradingPairVm(position.position.instrumentName)
                      ?.pair;
                  return pair != null &&
                      positionPercentageApiAmount(
                        pair: pair,
                        position: position.position,
                        percentage: percentage!,
                        preserveFullPosition: true,
                      ).canSubmit;
                });
            return AlertDialog(
              title: const Text('Close All Positions'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Total positions: ${_vm.positions.length}'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Percentage to close',
                      suffixText: '%',
                      errorText: validPercentage
                          ? validAmounts
                                ? null
                                : '部分仓位的平仓数量低于最小交易数量'
                          : '请输入大于 0 且不超过 100 的百分比',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Order Type',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Limit (post-only)'),
                    value: 'limit',
                    // ignore: deprecated_member_use
                    groupValue: orderMode,
                    // ignore: deprecated_member_use
                    onChanged: (v) => setState(() => orderMode = v ?? 'limit'),
                  ),
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Market'),
                    value: 'market',
                    // ignore: deprecated_member_use
                    groupValue: orderMode,
                    // ignore: deprecated_member_use
                    onChanged: (v) => setState(() => orderMode = v ?? 'limit'),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    orderMode == 'limit'
                        ? 'Places post-only limit orders at top-of-book.'
                        : 'Places reduce-only market orders for all positions.',
                    style: TextStyle(fontSize: 12, color: _subtleTextColor),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                ListenableBuilder(
                  listenable: _vm,
                  builder: (context, _) => FilledButton(
                    onPressed:
                        _vm.positions.isNotEmpty &&
                            _vm.positions.every(
                              (position) => _vm.canTradeSymbol(
                                position.position.instrumentName,
                              ),
                            ) &&
                            validAmounts
                        ? () => Navigator.pop(context, true)
                        : null,
                    child: const Text('Close All'),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    if (ok == true) {
      final pct = double.tryParse(controller.text.trim());
      await _vm.closeAllPositions(
        percentage: pct,
        market: orderMode == 'market',
      );
    }
  }

  Widget _buildHistoryTab() {
    final symbols = _vm.tradingPairs.map((e) => e.symbol).toList();
    _historySymbol ??= symbols.isNotEmpty ? symbols.first : null;
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _collapsibleHeader(
            title: 'History Filters',
            expanded: _historyFiltersExpanded,
            onToggle: () {
              setState(
                () => _historyFiltersExpanded = !_historyFiltersExpanded,
              );
              // ignore: discarded_futures
              SettingsStore.saveHistoryFiltersExpanded(_historyFiltersExpanded);
            },
          ),
          if (_historyFiltersExpanded) ...[
            const SizedBox(height: 6),
            Card(
              color: _sectionColor,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text('Instrument:'),
                    DropdownButton<String>(
                      value: _historySymbol,
                      items: symbols
                          .map(
                            (s) => DropdownMenuItem<String>(
                              value: s,
                              child: Text(s),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _historySymbol = v),
                    ),
                    const Text('Range:'),
                    DropdownButton<String>(
                      value: _selectedQuickRange,
                      hint: const Text('选择时间范围'),
                      items:
                          const [
                                '最近 24 小时',
                                '一天',
                                '一周',
                                'WTD',
                                '一个月',
                                'MTD',
                                '三个月',
                                '半年',
                                '一年',
                                'YTD',
                                '自定义',
                              ]
                              .map(
                                (label) => DropdownMenuItem<String>(
                                  value: label,
                                  child: Text(label),
                                ),
                              )
                              .toList(),
                      onChanged: (v) {
                        setState(() {
                          _selectedQuickRange = v;
                          // 对于非自定义范围，不在此处更新 From/To，
                          // 而是在点击 Load 时再计算。
                          // 选择“自定义”时，保留用户当前的 From/To 设置。
                        });
                      },
                    ),
                    if (_selectedQuickRange == '自定义') ...[
                      TextButton(
                        onPressed: () async {
                          final dt = await _pickDateTime(initial: _historyFrom);
                          if (dt != null) setState(() => _historyFrom = dt);
                        },
                        child: Text('From: ${_displayDateTime(_historyFrom)}'),
                      ),
                      TextButton(
                        onPressed: () async {
                          final dt = await _pickDateTime(initial: _historyTo);
                          if (dt != null) setState(() => _historyTo = dt);
                        },
                        child: Text('To: ${_displayDateTime(_historyTo)}'),
                      ),
                    ],
                    FilledButton(
                      onPressed: (_historySymbol != null && _vm.isAuthenticated)
                          ? () {
                              // 非自定义范围：按需在此时计算 From/To
                              if (_selectedQuickRange != null &&
                                  _selectedQuickRange != '自定义') {
                                final range = _computeQuickRange(
                                  _selectedQuickRange!,
                                );
                                final from = range.$1;
                                final to = range.$2;
                                setState(() {
                                  _historyFrom = from;
                                  _historyTo = to;
                                });
                              }
                              _vm.loadTradeHistory(
                                _historySymbol!,
                                _historyFrom,
                                _historyTo,
                              );
                            }
                          : null,
                      child: const Text('Load'),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Select:'),
                  Checkbox(
                    tristate: true,
                    value: _vm.isAllTradeHistorySelected,
                    onChanged: (v) {
                      if (v == null) {
                        _vm.invertAllTradeHistorySelection();
                      } else if (v) {
                        _vm.setAllTradeHistorySelection(true);
                      } else {
                        _vm.setAllTradeHistorySelection(false);
                      }
                    },
                  ),
                  if (_vm.tradeHistorySelectedRealizedPnL != null)
                    Text(
                      _formatTradeHistoryPnl(),
                      key: const ValueKey('trade-history-selected-pnl'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: _vm.tradeHistorySelectedRealizedPnL! >= 0
                            ? Colors.green
                            : Colors.red,
                      ),
                    ),
                ],
              ),
              SizedBox(
                width: double.infinity,
                child: _buildTradeHistorySelectedSummary(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: AnimatedBuilder(
              animation: _vm,
              builder: (context, _) {
                return ListView.builder(
                  itemCount: _vm.tradeHistoryGroups.length,
                  itemBuilder: (context, index) {
                    final g = _vm.tradeHistoryGroups[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            InkWell(
                              onTap: () => _vm.onGroupSelectionChanged(g, null),
                              child: Row(
                                children: [
                                  Checkbox(
                                    tristate: true,
                                    value: g.triState,
                                    onChanged: (v) =>
                                        _vm.onGroupSelectionChanged(g, v),
                                  ),
                                  Text(
                                    '${g.day.year}-${g.day.month.toString().padLeft(2, '0')}-${g.day.day.toString().padLeft(2, '0')}',
                                  ),
                                ],
                              ),
                            ),
                            const Divider(height: 8),
                            ...g.rows.expand(
                              (row) => [
                                _buildTradeHistoryRow(row),
                                if (row.isMerged && row.isExpanded)
                                  ...row.children.map(
                                    (child) =>
                                        _buildTradeHistoryChildRow(child),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          // Collapsible position controls below list, above status/footer
          _collapsibleHeader(
            title: '仓位选择',
            expanded: _historyPositionsExpanded,
            onToggle: () {
              setState(
                () => _historyPositionsExpanded = !_historyPositionsExpanded,
              );
              // ignore: discarded_futures
              SettingsStore.saveHistoryPositionsExpanded(
                _historyPositionsExpanded,
              );
            },
          ),
          if (_historyPositionsExpanded) ...[
            const SizedBox(height: 6),
            Card(
              color: _sectionColor,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '仓位: '
                      '${(_vm.currentTradeHistoryPositionIndex ?? -1) >= 0 ? (_vm.currentTradeHistoryPositionIndex! + 1) : 0}'
                      '/${_vm.tradeHistoryPositionCount}',
                    ),
                    OutlinedButton(
                      onPressed: _vm.tradeHistoryPositionCount > 0
                          ? _vm.selectPrevTradeHistoryPosition
                          : null,
                      child: const Text('上一仓位'),
                    ),
                    FilledButton(
                      onPressed: _vm.tradeHistoryPositionCount > 0
                          ? _vm.selectNextTradeHistoryPosition
                          : null,
                      child: const Text('下一仓位'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusPanel() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      color: _sectionColor,
      child: Row(
        children: [
          const Text('Status:'),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _vm.statusMessage,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTradeHistoryRow(TradeHistoryRowVM row) {
    final tp = _historyTradingPairFor(row.instrumentName);
    final valUnit = tp.pair.quoteCurrency;
    final amtUnit = tp.pair.apiAmountCurrency;
    final side = row.displaySide;
    final titleSide = side.toUpperCase();
    final title = row.isMerged
        ? '${row.instrumentName} • $titleSide (${row.children.length} trades)'
        : '${row.instrumentName} • $titleSide';
    final timeText = row.isMerged
        ? '${_hhmmss(row.oldestExecutedAtLocal)}–${_hhmmss(row.newestExecutedAtLocal)}'
        : _hhmmss(row.newestExecutedAtLocal);
    final value = row.displayQuoteNotional(instrument: tp.pair);
    final priceText = row.isMerged
        ? _formatTradeHistoryParentPrice(row, instrument: tp.pair)
        : _formatTradeHistoryPrice(row.primaryTrade.price);
    final feeText = formatTradeHistoryFeeAmounts(row.feeAmounts);
    final subtitleParts = <String>[
      timeText,
      if (row.isMerged && row.shortOrderId.isNotEmpty)
        'Order: ${row.shortOrderId}',
      'Amt: ${_formatTradeHistoryNumber(row.displayAmount)} $amtUnit',
      'Px: $priceText',
      'Val: ${value != null ? value.toStringAsFixed(2) : '-'} $valUnit',
      'Fee: $feeText',
    ];

    return ListTile(
      dense: true,
      leading: SizedBox(
        width: 88,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (row.isMerged)
              IconButton(
                onPressed: () => _vm.toggleTradeHistoryRowExpanded(row),
                icon: Icon(row.isExpanded ? Icons.remove : Icons.add, size: 16),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                tooltip: row.isExpanded ? 'Collapse trades' : 'Expand trades',
              )
            else
              const SizedBox(width: 32),
            Checkbox(
              tristate: row.isMerged,
              value: row.triState,
              onChanged: (v) => _vm.onTradeHistoryRowSelectionChanged(row, v),
            ),
          ],
        ),
      ),
      onTap: () => _vm.onTradeHistoryRowSelectionChanged(
        row,
        row.triState == true ? false : true,
      ),
      selected: row.triState == true,
      title: Text(title),
      subtitle: Text(subtitleParts.join('  ')),
      trailing: Icon(
        Icons.circle,
        size: 10,
        color: _tradeHistorySideColor(side),
      ),
    );
  }

  Widget _buildTradeHistoryChildRow(TradeHistoryEntryVM entry) {
    final tp = _historyTradingPairFor(entry.trade.instrumentName);
    final notional = tryTradeQuoteNotional(pair: tp.pair, trade: entry.trade);
    final val = notional == null ? null : dToDouble(notional);
    final valUnit = tp.pair.quoteCurrency;
    final amtUnit = tp.pair.apiAmountCurrency;
    final feeText = formatTradeHistoryFeeAmounts(
      summarizeTradeHistoryFees([entry.trade]),
    );

    return Padding(
      padding: const EdgeInsets.only(left: 40),
      child: ListTile(
        dense: true,
        leading: Checkbox(
          value: entry.isSelected,
          onChanged: (v) => _vm.onEntrySelectionChanged(entry, v ?? false),
        ),
        onTap: () => _vm.onEntrySelectionChanged(entry, !entry.isSelected),
        selected: entry.isSelected,
        title: Text(
          '${entry.trade.instrumentName} • ${entry.trade.direction.toUpperCase()}',
        ),
        subtitle: Text(
          '${_hhmmss(entry.executedAtLocal)}  '
          'Amt: ${_formatTradeHistoryNumber(entry.trade.amount)} $amtUnit  '
          'Px: ${_formatTradeHistoryPrice(entry.trade.price)}  '
          'Val: ${val != null ? val.toStringAsFixed(2) : '-'} $valUnit  '
          'Fee: $feeText',
        ),
        trailing: Icon(
          Icons.circle,
          size: 10,
          color: _tradeHistorySideColor(entry.trade.direction.toLowerCase()),
        ),
      ),
    );
  }

  TradingPairVM _historyTradingPairFor(String symbol) {
    return _vm.findTradingPairVm(symbol) ??
        TradingPairVM(TradingPair.unverified(symbol));
  }

  Color _tradeHistorySideColor(String side) {
    switch (side.toLowerCase()) {
      case 'buy':
        return Colors.green;
      case 'sell':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  String _formatTradeHistoryParentPrice(
    TradeHistoryRowVM row, {
    required TradingPair instrument,
  }) {
    final avg = row.displayAveragePrice(instrument: instrument);
    final avgText = avg != null
        ? _formatTradeHistoryPrice(avg)
        : _formatTradeHistoryPrice(row.primaryTrade.price);
    if (!row.hasMixedPrices) return avgText;
    final range = row.priceRange;
    return '$avgText (${_formatTradeHistoryPrice(range.min)}–${_formatTradeHistoryPrice(range.max)})';
  }

  String _formatTradeHistoryNumber(double value) {
    if (!value.isFinite) return '-';
    final fixed = value.toStringAsFixed(12);
    return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  String _formatTradeHistoryPrice(double value) {
    if (!value.isFinite) return '-';
    final fixed = value.abs() >= 1
        ? value.toStringAsFixed(8)
        : value.toStringAsFixed(12);
    return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  String _formatPositionPnl(PositionPnl pnl) {
    final settlement = pnl.settlementAmountAsDouble;
    final settlementDigits = settlement.abs() >= 1 ? 2 : 8;
    final primary =
        '${settlement >= 0 ? '+' : ''}${settlement.toStringAsFixed(settlementDigits)} ${pnl.settlementCurrency}';
    final quote = pnl.quoteEquivalentAsDouble;
    final quoteCurrency = pnl.quoteCurrency;
    if (quote == null || quoteCurrency == null || quoteCurrency.isEmpty) {
      return 'PnL: $primary';
    }
    return 'PnL: $primary (${quote >= 0 ? '+' : ''}${quote.toStringAsFixed(2)} $quoteCurrency)';
  }

  String _formatTradeHistoryPnl() {
    final amount = _vm.tradeHistorySelectedRealizedPnL!;
    final settlementCurrency =
        _vm.tradeHistorySelectedSettlementCurrency ?? 'SETTLEMENT';
    final digits = amount.abs() >= 1 ? 2 : 8;
    final primary =
        '${amount >= 0 ? '+' : ''}${amount.toStringAsFixed(digits)} $settlementCurrency';
    final quote = _vm.tradeHistorySelectedRealizedPnlQuoteEquivalent;
    final quoteCurrency = _vm.tradeHistorySelectedQuoteCurrency;
    if (quote == null || quoteCurrency == null || quoteCurrency.isEmpty) {
      return 'PnL: $primary';
    }
    return 'PnL: $primary (${quote >= 0 ? '+' : ''}${quote.toStringAsFixed(2)} $quoteCurrency)';
  }

  // --- Trade History Selected Summary (copyable fields) ---
  Widget _buildTradeHistorySelectedSummary() {
    final netAmt =
        _vm.tradeHistorySelectedBuyAmount - _vm.tradeHistorySelectedSellAmount;
    final avgB = _vm.tradeHistorySelectedAverageBuyPrice;
    final avgS = _vm.tradeHistorySelectedAverageSellPrice;

    // Determine units from current history symbol/context
    String amountUnit = 'AMOUNT';
    String baseUnit = 'BASE';
    String quoteUnit = 'QUOTE';
    final symbol =
        _historySymbol ??
        (_vm.tradeHistoryGroups.isNotEmpty &&
                _vm.tradeHistoryGroups.first.leafEntries.isNotEmpty
            ? _vm
                  .tradeHistoryGroups
                  .first
                  .leafEntries
                  .first
                  .trade
                  .instrumentName
            : null);
    if (symbol != null) {
      final tp =
          _vm.findTradingPairVm(symbol) ??
          TradingPairVM(TradingPair.unverified(symbol));
      amountUnit =
          _vm.tradeHistorySelectedAmountCurrency ?? tp.pair.apiAmountCurrency;
      baseUnit = tp.pair.baseCurrency;
      quoteUnit =
          _vm.tradeHistorySelectedQuoteCurrency ?? tp.pair.quoteCurrency;
    }

    final avgUnit = '$quoteUnit/$baseUnit';
    final items = <(String, String)>[
      ('Selected', _vm.tradeHistorySelectedCount.toString()),
      if (_vm.tradeHistorySelectedExcludedInvalidCount > 0)
        (
          'Excluded invalid',
          _vm.tradeHistorySelectedExcludedInvalidCount.toString(),
        ),
      if (_vm.tradeHistorySelectionUnavailableReason != null)
        (
          'PnL coverage',
          'Unavailable: ${_vm.tradeHistorySelectionUnavailableReason}',
        ),
      ('Net Amt ($amountUnit)', netAmt.toStringAsFixed(4)),
      ('Avg(B) ($avgUnit)', avgB != null ? avgB.toStringAsFixed(2) : '-'),
      ('Avg(S) ($avgUnit)', avgS != null ? avgS.toStringAsFixed(2) : '-'),
      (
        'Buy Amt ($amountUnit)',
        _vm.tradeHistorySelectedBuyAmount.toStringAsFixed(4),
      ),
      (
        'Sell Amt ($amountUnit)',
        _vm.tradeHistorySelectedSellAmount.toStringAsFixed(4),
      ),
      (
        'Buy Val ($quoteUnit)',
        _vm.tradeHistorySelectedBuyValue.toStringAsFixed(2),
      ),
      (
        'Sell Val ($quoteUnit)',
        _vm.tradeHistorySelectedSellValue.toStringAsFixed(2),
      ),
      ('Fee', _vm.tradeHistorySelectedFeeSummary),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final it in items) ...[
            _summaryField(it.$1, it.$2),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _summaryField(String label, String value) {
    return Container(
      key: ValueKey('trade-history-summary-$label'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: _sectionColor,
        border: Border.all(color: _borderColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: TextStyle(fontSize: 12, color: _subtleTextColor),
          ),
          SelectableText(
            value,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: () => _copyToClipboard(value),
            icon: const Icon(Icons.copy, size: 14),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
            tooltip: 'Copy',
          ),
        ],
      ),
    );
  }

  Future<void> _copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied: $text'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    return Material(
      color: _panelColor,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Row(
          children: [
            const Text('Connection:'),
            const SizedBox(width: 8),
            _dot(_vm.isConnected ? Colors.green : Colors.red),
            const SizedBox(width: 16),
            const Text('Auth:'),
            const SizedBox(width: 8),
            _dot(_vm.isAuthenticated ? Colors.green : Colors.red),
          ],
        ),
      ),
    );
  }

  Widget _dot(Color color) => Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );

  Widget _amountBox({
    required String id,
    required String label,
    required double initial,
    required ValueChanged<double> onChanged,
    String? unit,
    bool seedInitialWhenEmpty = true,
  }) {
    return SizedBox(
      width: 150,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label:'),
          const SizedBox(width: 6),
          Expanded(
            child: Builder(
              builder: (context) {
                final controller = _amountControllerFor(id);
                final focus = _amountFocusFor(id);

                // Only seed initial value when not focused and empty,
                // to avoid fighting with user typing during rebuilds.
                if (seedInitialWhenEmpty &&
                    !focus.hasFocus &&
                    controller.text.isEmpty) {
                  final newText = initial > 0 ? initial.toString() : '';
                  if (controller.text != newText) controller.text = newText;
                }

                return TextFormField(
                  // Stable key to retain focus
                  key: ValueKey(id),
                  controller: controller,
                  focusNode: focus,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(hintText: '', suffixText: unit),
                  onChanged: (v) {
                    if (!focus.hasFocus) return;
                    final d = double.tryParse(v);
                    if (d == null) return;
                    final positive = d < 0 ? -d : d;
                    if (d < 0) {
                      final s = positive.toString();
                      if (controller.text != s) {
                        controller.text = s;
                        controller.selection = TextSelection.fromPosition(
                          TextPosition(offset: controller.text.length),
                        );
                      }
                    }
                    onChanged(positive);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _priceBox({
    required String id,
    required String label,
    required double initial,
    required TradingPairVM tp,
    required bool isBuy,
    required ValueChanged<double> onChanged,
  }) {
    return SizedBox(
      width: 150,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label:'),
          const SizedBox(width: 6),
          Expanded(
            child: Builder(
              builder: (context) {
                final controller = _priceControllerFor(id);
                final focus = _priceFocusFor(id);

                // Determine the intended display based on focus and custom/auto mode
                if (!focus.hasFocus) {
                  final custom = isBuy ? tp.buyLimitPrice : tp.sellLimitPrice;
                  final used =
                      custom ??
                      (_vm.computeLimitPrice(tp, isBuy ? 'buy' : 'sell') ?? 0);
                  final newText = used > 0 ? used.toString() : '';
                  if (controller.text != newText) {
                    controller.text = newText;
                  }
                }

                return TextFormField(
                  // Stable key to retain focus
                  key: ValueKey(id),
                  controller: controller,
                  focusNode: focus,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(hintText: 'auto'),
                  onChanged: (v) {
                    // Only treat as custom input if user is actively editing
                    if (!focus.hasFocus) return;
                    final d = double.tryParse(v);
                    if (d == null) return;
                    final positive = d < 0 ? -d : d;
                    if (d < 0) {
                      final s = positive.toString();
                      if (controller.text != s) {
                        controller.text = s;
                        controller.selection = TextSelection.fromPosition(
                          TextPosition(offset: controller.text.length),
                        );
                      }
                    }
                    onChanged(positive);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _formatCompactNumber(double value) {
    if (value == 0) return '0';
    final abs = value.abs();
    final fixed = abs >= 1000
        ? value.toStringAsFixed(2)
        : abs >= 1
        ? value.toStringAsFixed(6)
        : value.toStringAsFixed(8);
    return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  bool _supportsManualAmountUnitToggle(TradingPairVM tp) {
    if (tp.usePercentInput) return false;
    return isInverseFuturePair(tp.pair) || tp.pair.type == TradingPairType.spot;
  }

  ManualOrderAmountUnit _manualAmountUnitFor(String id) =>
      _manualAmountUnits[id] ?? ManualOrderAmountUnit.base;

  Widget _manualAmountUnitToggle(TradingPairVM tp, {required bool isBuy}) {
    final id = '${tp.symbol}-${isBuy ? 'buy' : 'sell'}-amt';
    final unit = _manualAmountUnitFor(id);
    final colorScheme = Theme.of(context).colorScheme;
    final units = isInverseFuturePair(tp.pair)
        ? <(ManualOrderAmountUnit, String)>[
            (ManualOrderAmountUnit.base, tp.pair.baseCurrency),
            (ManualOrderAmountUnit.apiUsd, 'API ${tp.pair.apiAmountCurrency}'),
          ]
        : <(ManualOrderAmountUnit, String)>[
            (ManualOrderAmountUnit.base, tp.pair.baseCurrency),
            (ManualOrderAmountUnit.quote, tp.pair.quoteCurrency),
          ];

    Widget unitButton({
      required Key key,
      required String label,
      required ManualOrderAmountUnit value,
    }) {
      final selected = unit == value;
      return Semantics(
        key: key,
        button: true,
        selected: selected,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () =>
              _switchManualAmountUnit(tp, isBuy: isBuy, nextUnit: value),
          child: Container(
            height: 30,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: selected ? colorScheme.secondaryContainer : null,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: selected
                    ? colorScheme.secondary
                    : colorScheme.outlineVariant,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: selected ? colorScheme.onSecondaryContainer : null,
              ),
            ),
          ),
        ),
      );
    }

    return Wrap(
      spacing: 4,
      children: units
          .map(
            (entry) => unitButton(
              key: ValueKey('$id-unit-${_manualAmountUnitKey(entry.$1)}'),
              label: entry.$2,
              value: entry.$1,
            ),
          )
          .toList(),
    );
  }

  String _manualAmountUnitKey(ManualOrderAmountUnit unit) {
    switch (unit) {
      case ManualOrderAmountUnit.base:
        return 'base';
      case ManualOrderAmountUnit.quote:
        return 'quote';
      case ManualOrderAmountUnit.apiUsd:
        return 'api';
    }
  }

  String _manualAmountUnitLabel(TradingPair pair, ManualOrderAmountUnit unit) {
    switch (unit) {
      case ManualOrderAmountUnit.base:
        return pair.baseCurrency;
      case ManualOrderAmountUnit.quote:
        return pair.quoteCurrency;
      case ManualOrderAmountUnit.apiUsd:
        return 'API ${pair.apiAmountCurrency}';
    }
  }

  void _switchManualAmountUnit(
    TradingPairVM tp, {
    required bool isBuy,
    required ManualOrderAmountUnit nextUnit,
  }) {
    final id = '${tp.symbol}-${isBuy ? 'buy' : 'sell'}-amt';
    final currentUnit = _manualAmountUnitFor(id);
    if (currentUnit == nextUnit) return;
    if (!isInverseFuturePair(tp.pair) &&
        nextUnit == ManualOrderAmountUnit.apiUsd) {
      return;
    }
    if (tp.pair.type != TradingPairType.spot &&
        nextUnit == ManualOrderAmountUnit.quote) {
      return;
    }

    final controller = _amountControllers[id];
    final rawText = controller?.text.trim() ?? '';
    if (rawText.isEmpty) {
      final nextAmount = _emptyInitialAmountForUnit(tp, nextUnit);
      setState(() {
        _manualAmountUnits[id] = nextUnit;
        if (isBuy) {
          tp.buyAmount = nextAmount;
        } else {
          tp.sellAmount = nextAmount;
        }
        if (controller != null) {
          controller.text = nextAmount > 0
              ? _formatCompactNumber(nextAmount)
              : '';
        }
      });
      return;
    }

    final amount = double.tryParse(rawText);
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入有效的下单数量')));
      return;
    }

    final reference = _manualAmountReferencePrice(tp, isBuy: isBuy);
    if (reference == null || reference <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('缺少参考价格，无法切换 Amount 单位')));
      return;
    }

    final nextAmount = _convertManualAmountBetweenUnits(
      amount: amount,
      referencePrice: reference,
      currentUnit: currentUnit,
      nextUnit: nextUnit,
    );
    setState(() {
      _manualAmountUnits[id] = nextUnit;
      if (isBuy) {
        tp.buyAmount = nextAmount;
      } else {
        tp.sellAmount = nextAmount;
      }
      if (controller != null) {
        controller.text = _formatCompactNumber(nextAmount);
        controller.selection = TextSelection.fromPosition(
          TextPosition(offset: controller.text.length),
        );
      }
    });
  }

  double _emptyInitialAmountForUnit(
    TradingPairVM tp,
    ManualOrderAmountUnit nextUnit,
  ) {
    if (nextUnit == ManualOrderAmountUnit.apiUsd) return tp.pair.minTradeAmount;
    return 0.0;
  }

  double _convertManualAmountBetweenUnits({
    required double amount,
    required double referencePrice,
    required ManualOrderAmountUnit currentUnit,
    required ManualOrderAmountUnit nextUnit,
  }) {
    if (currentUnit == ManualOrderAmountUnit.base) {
      return amount * referencePrice;
    }
    if (nextUnit == ManualOrderAmountUnit.base) {
      return amount / referencePrice;
    }
    return amount;
  }

  double? _manualAmountReferencePrice(TradingPairVM tp, {required bool isBuy}) {
    if (tp.useMarketOrder) {
      final price = isBuy ? tp.bestAsk : tp.bestBid;
      return price > 0 ? price : null;
    }
    return _vm.computeLimitPrice(
      tp,
      isBuy ? 'buy' : 'sell',
      custom: isBuy ? tp.buyLimitPrice : tp.sellLimitPrice,
    );
  }

  Widget _manualAmountInput(TradingPairVM tp, {required bool isBuy}) {
    final id = '${tp.symbol}-${isBuy ? 'buy' : 'sell'}-amt';
    final hasUnitToggle = _supportsManualAmountUnitToggle(tp);
    final unit = hasUnitToggle
        ? _manualAmountUnitFor(id)
        : ManualOrderAmountUnit.base;
    final amountBox = _amountBox(
      id: id,
      label: isBuy ? 'Buy' : 'Sell',
      initial: isBuy ? tp.buyAmount : tp.sellAmount,
      unit: hasUnitToggle
          ? null
          : (tp.pair.type == TradingPairType.future &&
                    tp.pair.amountUnit == AmountUnit.usd
                ? tp.pair.apiAmountCurrency
                : tp.pair.baseCurrency),
      seedInitialWhenEmpty:
          !hasUnitToggle ||
          unit == ManualOrderAmountUnit.apiUsd ||
          (tp.pair.type == TradingPairType.spot &&
              unit == ManualOrderAmountUnit.base),
      onChanged: (v) => setState(() {
        if (isBuy) {
          tp.buyAmount = v;
        } else {
          tp.sellAmount = v;
        }
      }),
    );
    if (!hasUnitToggle) return amountBox;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        amountBox,
        _manualAmountUnitToggle(tp, isBuy: isBuy),
      ],
    );
  }

  Widget _amountStepper(TradingPairVM tp, {required bool isBuy}) {
    double? step = tp.pair.contractSize;
    if (_supportsManualAmountUnitToggle(tp)) {
      final id = '${tp.symbol}-${isBuy ? 'buy' : 'sell'}-amt';
      final unit = _manualAmountUnitFor(id);
      if (unit == ManualOrderAmountUnit.base && isInverseFuturePair(tp.pair)) {
        final reference = _manualAmountReferencePrice(tp, isBuy: isBuy);
        step = reference != null && reference > 0
            ? tp.pair.contractSize / reference
            : null;
      } else if (unit == ManualOrderAmountUnit.quote) {
        final reference = _manualAmountReferencePrice(tp, isBuy: isBuy);
        step = reference != null && reference > 0
            ? tp.pair.contractSize * reference
            : null;
      }
    }
    final enabled = step != null && step > 0;
    final effectiveStep = step ?? 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          iconSize: 20,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          padding: EdgeInsets.zero,
          onPressed: enabled
              ? () {
                  setState(() {
                    final current = isBuy ? tp.buyAmount : tp.sellAmount;
                    final nv = double.parse(
                      (Decimal.parse(current.toString()) -
                              Decimal.parse(effectiveStep.toString()))
                          .toString(),
                    );
                    final bounded = nv <= 0 ? effectiveStep : nv;
                    if (isBuy) {
                      tp.buyAmount = bounded;
                    } else {
                      tp.sellAmount = bounded;
                    }
                    final id = '${tp.symbol}-${isBuy ? 'buy' : 'sell'}-amt';
                    final c = _amountControllers[id];
                    if (c != null) c.text = _formatCompactNumber(bounded);
                  });
                }
              : null,
          icon: const Icon(Icons.remove),
        ),
        Text(
          enabled ? _formatCompactNumber(effectiveStep) : '-',
          style: const TextStyle(fontSize: 12),
        ),
        IconButton(
          iconSize: 20,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          padding: EdgeInsets.zero,
          onPressed: enabled
              ? () {
                  setState(() {
                    final current = isBuy ? tp.buyAmount : tp.sellAmount;
                    final nv = double.parse(
                      (Decimal.parse(current.toString()) +
                              Decimal.parse(effectiveStep.toString()))
                          .toString(),
                    );
                    if (isBuy) {
                      tp.buyAmount = nv;
                    } else {
                      tp.sellAmount = nv;
                    }
                    final id = '${tp.symbol}-${isBuy ? 'buy' : 'sell'}-amt';
                    final c = _amountControllers[id];
                    if (c != null) c.text = _formatCompactNumber(nv);
                  });
                }
              : null,
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }

  double? _manualAmountInputValue(TradingPairVM tp, {required bool isBuy}) {
    final id = '${tp.symbol}-${isBuy ? 'buy' : 'sell'}-amt';
    final text = _amountControllers[id]?.text.trim();
    if (text != null && text.isNotEmpty) return double.tryParse(text);
    return isBuy ? tp.buyAmount : tp.sellAmount;
  }

  OrderAmountConversion _manualOrderConversion(
    TradingPairVM tp,
    String direction,
    double inputAmount, {
    double? customPrice,
    ManualOrderAmountUnit? inputUnitOverride,
  }) {
    final isBuy = direction.toLowerCase() == 'buy';
    final id = '${tp.symbol}-${isBuy ? 'buy' : 'sell'}-amt';
    final orderType = tp.useMarketOrder
        ? ManualOrderType.market
        : ManualOrderType.limit;
    final limitPrice = orderType == ManualOrderType.limit
        ? _vm.computeLimitPrice(tp, direction, custom: customPrice)
        : null;
    final inputUnit =
        inputUnitOverride ??
        (_supportsManualAmountUnitToggle(tp)
            ? _manualAmountUnitFor(id)
            : ManualOrderAmountUnit.base);
    return convertOrderAmountForApi(
      pair: tp.pair,
      inputAmount: inputAmount,
      inputUnit: inputUnit,
      orderType: orderType,
      direction: direction,
      limitPrice: limitPrice,
      bestBid: tp.bestBid,
      bestAsk: tp.bestAsk,
    );
  }

  Future<void> _handleManualOrderButton(
    TradingPairVM tp,
    String direction,
  ) async {
    final isBuy = direction.toLowerCase() == 'buy';
    double? amount;
    bool? usedAvail;
    double? buffer;
    final isMarket = tp.useMarketOrder;
    final customPrice = isBuy ? tp.buyLimitPrice : tp.sellLimitPrice;

    if (tp.pair.type == TradingPairType.future && tp.usePercentInput) {
      final atPrice = isMarket
          ? (isBuy
                ? (tp.bestAsk > 0 ? tp.bestAsk : null)
                : (tp.bestBid > 0 ? tp.bestBid : null))
          : _vm.computeLimitPrice(tp, direction, custom: customPrice);
      final res = _vm.computePercentOrderAmountWithMeta(
        tp,
        direction,
        atPrice: atPrice,
      );
      final computed = res.$1;
      if (computed == null || computed <= 0) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法计算基于百分比的下单数量')));
        return;
      }
      amount = computed;
      usedAvail = res.$2;
      buffer = res.$3;
    } else {
      amount = _manualAmountInputValue(tp, isBuy: isBuy);
      if (amount == null || amount <= 0) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请输入有效的下单数量')));
        return;
      }
    }

    final conversion = _manualOrderConversion(
      tp,
      direction,
      amount,
      customPrice: customPrice,
      inputUnitOverride: tp.usePercentInput && isInverseFuturePair(tp.pair)
          ? ManualOrderAmountUnit.apiUsd
          : null,
    );
    if (!conversion.canSubmit) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(conversion.errorMessage ?? '无法计算 API 下单数量')),
      );
      return;
    }

    if (isMarket) {
      await _confirmAndPlaceMarketOrder(tp, direction, conversion);
    } else {
      await _confirmAndPlaceOrder(
        tp,
        direction,
        conversion,
        customPrice: customPrice,
        usedAvailableFunds: usedAvail,
        bufferFactor: buffer,
      );
    }
  }

  Widget _tickAdjuster(TradingPairVM tp, {required bool isBuy}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(isBuy ? 'Buy Δ' : 'Sell Δ'),
        const SizedBox(width: 4),
        IconButton(
          iconSize: 20,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          padding: EdgeInsets.zero,
          onPressed: () => setState(() {
            if (isBuy) {
              tp.buyOffsetTicks--;
            } else {
              tp.sellOffsetTicks--;
            }
          }),
          icon: const Icon(Icons.remove),
        ),
        Text(
          '${isBuy ? tp.buyOffsetTicks : tp.sellOffsetTicks}t',
          style: const TextStyle(fontSize: 12),
        ),
        IconButton(
          iconSize: 20,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          padding: EdgeInsets.zero,
          onPressed: () => setState(() {
            if (isBuy) {
              tp.buyOffsetTicks++;
            } else {
              tp.sellOffsetTicks++;
            }
          }),
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }

  Future<void> _confirmAndPlaceOrder(
    TradingPairVM tp,
    String direction,
    OrderAmountConversion conversion, {
    double? customPrice,
    bool? usedAvailableFunds,
    double? bufferFactor,
  }) async {
    final est = conversion.referencePrice;
    if (est == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No price available for confirmation')),
      );
      return;
    }
    bool enableChasing = false;
    bool postOnly = true;
    bool reduceOnly = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        final isFut = tp.pair.type == TradingPairType.future;
        final quote = tp.pair.quoteCurrency;
        final usePct = isFut && tp.usePercentInput;
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Confirm Order'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Instrument: ${tp.symbol}'),
                  Text('Side: ${direction.toUpperCase()}'),
                  Text('Limit Price: $est'),
                  if (usePct)
                    Text(
                      'Input: Percent  •  Size: '
                      '${(direction.toLowerCase() == 'buy' ? tp.buyPercent : tp.sellPercent).toStringAsFixed(0)}%  •  Lev: ${tp.leverage}x',
                    ),
                  if (usePct && usedAvailableFunds != null)
                    Text(
                      'Sizing basis: ${usedAvailableFunds ? 'Available Funds' : 'Equity (fallback)'}',
                    ),
                  if (usePct && bufferFactor != null)
                    Text(
                      'Safety buffer: use ${(bufferFactor * 100).toStringAsFixed(0)}% of funds',
                    ),
                  ..._orderAmountConfirmationLines(conversion),
                  Text(
                    'Notional: ${conversion.notional.toStringAsFixed(2)} $quote',
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Post-only'),
                    value: postOnly,
                    onChanged: (v) => setState(() {
                      postOnly = v!;
                      if (!postOnly) enableChasing = false;
                    }),
                  ),
                  if (isFut)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Reduce-only（仅减仓）'),
                      value: reduceOnly,
                      onChanged: (v) => setState(() => reduceOnly = v!),
                    ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListenableBuilder(
                        listenable: _vm,
                        builder: (context, _) => Checkbox(
                          value: enableChasing,
                          onChanged: postOnly && _vm.canTradeSymbol(tp.symbol)
                              ? (v) =>
                                    setState(() => enableChasing = v ?? false)
                              : null,
                        ),
                      ),
                      const Flexible(
                        child: Text(
                          'Enable Continuous Chasing (this order)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                ListenableBuilder(
                  listenable: _vm,
                  builder: (context, _) => FilledButton(
                    onPressed: _vm.canTradeSymbol(tp.symbol)
                        ? () => Navigator.pop(context, true)
                        : null,
                    child: const Text('Place'),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    if (ok == true) {
      await _vm.placeOrder(
        tp,
        direction,
        conversion.apiAmount,
        customPrice: customPrice,
        enableChasing: enableChasing,
        postOnly: postOnly,
        reduceOnly: reduceOnly,
      );
    }
  }

  List<Widget> _orderAmountConfirmationLines(OrderAmountConversion conversion) {
    final pair = conversion.pair;
    final inputUnitLabel = switch (conversion.inputUnit) {
      ManualOrderAmountUnit.base => pair.baseCurrency,
      ManualOrderAmountUnit.quote => pair.quoteCurrency,
      ManualOrderAmountUnit.apiUsd => pair.apiAmountCurrency,
    };
    return [
      Text(
        'Input Amount: ${conversion.inputAmount.toStringAsFixed(8)} $inputUnitLabel',
      ),
      Text(
        'Actual Base: ${conversion.baseAmount.toStringAsFixed(8)} ${pair.baseCurrency}',
      ),
      Text(
        'API Amount: ${conversion.apiAmount.toStringAsFixed(8)} ${pair.apiAmountCurrency}',
      ),
      Text(
        conversion.referencePrice == null
            ? 'Reference: unavailable'
            : 'Reference: ${conversion.referencePrice!.toStringAsFixed(6)} (${conversion.referenceLabel ?? 'Price'})',
      ),
      Text(
        conversion.roundedDown
            ? 'Round Result: ${conversion.rawApiAmount.toStringAsFixed(8)} -> ${conversion.apiAmount.toStringAsFixed(8)} (contractSize ${pair.contractSize})'
            : 'Round Result: unchanged (contractSize ${pair.contractSize})',
        style: TextStyle(fontSize: 12, color: _subtleTextColor),
      ),
    ];
  }

  Future<void> _confirmAndPlaceMarketOrder(
    TradingPairVM tp,
    String direction,
    OrderAmountConversion conversion,
  ) async {
    bool reduceOnly = false;
    final est = conversion.referencePrice;
    final isFut = tp.pair.type == TradingPairType.future;
    final quoteUnit = tp.pair.quoteCurrency;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Confirm Market Order'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Instrument: ${tp.symbol}'),
              Text('Side: ${direction.toUpperCase()}'),
              ..._orderAmountConfirmationLines(conversion),
              if (est != null)
                Text(
                  'Est Px: ${est.toStringAsFixed(6)} (${conversion.referenceLabel ?? 'Market'})  •  Est Notional: ${conversion.notional.toStringAsFixed(2)} $quoteUnit',
                )
              else
                const Text('Estimates unavailable • executes at market'),
              if (isFut && tp.usePercentInput)
                Text(
                  'Input: Percent  •  Size: ${(direction.toLowerCase() == 'buy' ? tp.buyPercent : tp.sellPercent).toStringAsFixed(0)}%  •  Lev: ${tp.leverage}x',
                  style: TextStyle(fontSize: 12, color: _subtleTextColor),
                ),
              if (isFut)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Reduce-only（仅减仓）'),
                  value: reduceOnly,
                  onChanged: (v) => setState(() => reduceOnly = v!),
                ),
              const SizedBox(height: 8),
              Text(
                '提示: 市价单将以当前可成交最优价格执行，最终成交价可能与估算不同。',
                style: TextStyle(fontSize: 12, color: _subtleTextColor),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ListenableBuilder(
              listenable: _vm,
              builder: (context, _) => FilledButton(
                onPressed: _vm.canTradeSymbol(tp.symbol)
                    ? () => Navigator.pop(context, true)
                    : null,
                child: const Text('Place'),
              ),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      await _vm.placeMarketOrder(
        tp,
        direction,
        conversion.apiAmount,
        reduceOnly: reduceOnly,
      );
    }
  }

  Widget _chip(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
    ),
  );

  Widget _leverageSelector(TradingPairVM tp) {
    final maxLev = tp.pair.maxLeverage > 0 ? tp.pair.maxLeverage : 1;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Lev:', style: TextStyle(fontSize: 12)),
        const SizedBox(width: 6),
        DropdownButton<int>(
          value: tp.leverage.clamp(1, maxLev),
          items: List.generate(maxLev, (i) => i + 1)
              .map((e) => DropdownMenuItem(value: e, child: Text('${e}x')))
              .toList(),
          onChanged: (v) =>
              setState(() => tp.leverage = (v ?? 1).clamp(1, maxLev)),
          underline: const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _inputModeToggle(TradingPairVM tp) {
    return Wrap(
      spacing: 6,
      children: [
        ChoiceChip(
          label: const Text('Amount'),
          selected: !tp.usePercentInput,
          onSelected: (_) => setState(() => tp.usePercentInput = false),
        ),
        ChoiceChip(
          label: const Text('% Size'),
          selected: tp.usePercentInput,
          onSelected: (_) {
            setState(() => tp.usePercentInput = true);
            if (tp.pair.isVerified &&
                tp.pair.type == TradingPairType.future &&
                tp.pair.marginCurrency.isNotEmpty) {
              // ignore: discarded_futures
              _vm.ensureAccountMetricsForCurrency(tp.pair.marginCurrency);
            }
          },
        ),
      ],
    );
  }

  Widget _orderTypeToggle(TradingPairVM tp) {
    // Spot only: toggle between Limit and Market
    return Wrap(
      spacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text('Order:', style: TextStyle(fontSize: 12)),
        ChoiceChip(
          label: const Text('Limit'),
          selected: !tp.useMarketOrder,
          onSelected: (_) => setState(() => tp.useMarketOrder = false),
        ),
        ChoiceChip(
          label: const Text('Market'),
          selected: tp.useMarketOrder,
          onSelected: (_) => setState(() => tp.useMarketOrder = true),
        ),
      ],
    );
  }

  Widget _percentSlider(TradingPairVM tp, {required bool isBuy}) {
    final v = isBuy ? tp.buyPercent : tp.sellPercent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Size: ${v.toStringAsFixed(0)}%  •  Lev ${tp.leverage}x',
          style: TextStyle(fontSize: 12, color: _subtleTextColor),
        ),
        Slider(
          value: v.clamp(1, 100),
          min: 1,
          max: 100,
          divisions: 99,
          label: '${v.toStringAsFixed(0)}%'.toString(),
          onChanged: (nv) => setState(() {
            if (isBuy) {
              tp.buyPercent = nv;
            } else {
              tp.sellPercent = nv;
            }
          }),
        ),
      ],
    );
  }

  Widget _modifySpotAmountUnitToggle({
    required ManualOrderAmountUnit unit,
    required ValueChanged<ManualOrderAmountUnit> onChanged,
  }) {
    return Wrap(
      spacing: 4,
      children: [
        ChoiceChip(
          label: const Text('Base'),
          selected: unit == ManualOrderAmountUnit.base,
          onSelected: (_) => onChanged(ManualOrderAmountUnit.base),
        ),
        ChoiceChip(
          label: const Text('Quote'),
          selected: unit == ManualOrderAmountUnit.quote,
          onSelected: (_) => onChanged(ManualOrderAmountUnit.quote),
        ),
      ],
    );
  }

  // history summary row is inlined above

  Future<void> _showModifyOrderDialog(OrderVM o) async {
    // Resolve instrument's amount unit for label
    final tp =
        _vm.findTradingPairVm(o.order.instrumentName) ??
        TradingPairVM(TradingPair.unverified(o.order.instrumentName));
    final isInverse = isInverseFuturePair(tp.pair);
    final isSpot = tp.pair.type == TradingPairType.spot;
    final initialPrice = o.editablePrice > 0 ? o.editablePrice : o.order.price;
    final initialBaseAmount = isInverse && initialPrice > 0
        ? o.order.amount / initialPrice
        : o.editableAmount;
    final priceController = TextEditingController(
      text: initialPrice.toString(),
    );
    final amountController = TextEditingController(
      text: initialBaseAmount.toString(),
    );
    var amountUnit = ManualOrderAmountUnit.base;
    var amountEdited = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final parsedPrice = double.tryParse(priceController.text.trim());
            final validPrice =
                parsedPrice != null && parsedPrice.isFinite && parsedPrice > 0;
            final parsedAmount = double.tryParse(amountController.text.trim());
            final conversion =
                amountEdited && validPrice && parsedAmount != null
                ? convertOrderAmountForApi(
                    pair: tp.pair,
                    inputAmount: parsedAmount,
                    inputUnit: isInverse
                        ? ManualOrderAmountUnit.base
                        : amountUnit,
                    orderType: ManualOrderType.limit,
                    direction: o.order.direction,
                    limitPrice: parsedPrice,
                  )
                : null;
            final amountIsValid =
                !amountEdited ||
                (parsedAmount != null &&
                    parsedAmount.isFinite &&
                    parsedAmount > 0 &&
                    conversion?.canSubmit == true);

            void switchUnit(ManualOrderAmountUnit nextUnit) {
              if (amountUnit == nextUnit) return;
              final currentAmount = double.tryParse(
                amountController.text.trim(),
              );
              final currentPrice = double.tryParse(priceController.text.trim());
              if (currentAmount != null &&
                  currentAmount > 0 &&
                  currentPrice != null &&
                  currentPrice > 0) {
                amountController.text = _formatCompactNumber(
                  _convertManualAmountBetweenUnits(
                    amount: currentAmount,
                    referencePrice: currentPrice,
                    currentUnit: amountUnit,
                    nextUnit: nextUnit,
                  ),
                );
                amountController.selection = TextSelection.fromPosition(
                  TextPosition(offset: amountController.text.length),
                );
              }
              amountEdited = true;
              setDialogState(() => amountUnit = nextUnit);
            }

            return AlertDialog(
              title: const Text('Modify Order'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: priceController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Price',
                      errorText: validPrice ? null : '请输入有效的价格',
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  TextField(
                    controller: amountController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText:
                          'Amount (${_manualAmountUnitLabel(tp.pair, amountUnit)})',
                      errorText: amountIsValid
                          ? null
                          : conversion?.errorMessage ?? '请输入有效的下单数量',
                    ),
                    onChanged: (_) => setDialogState(() => amountEdited = true),
                  ),
                  if (isSpot) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _modifySpotAmountUnitToggle(
                        unit: amountUnit,
                        onChanged: switchUnit,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      isInverse
                          ? '说明: 反向期货这里按 ${tp.pair.baseCurrency} 编辑。仅修改 Price 时保持原 API ${tp.pair.apiAmountCurrency} amount；编辑 Amount 后提交前会按价格换算。'
                          : isSpot
                          ? '说明: 现货可按 ${tp.pair.baseCurrency} 或 ${tp.pair.quoteCurrency} 编辑。仅修改 Price 时保持原 API amount；编辑 Amount 后按价格换算。'
                          : '说明: 线性期货/期权 amount 为标的币数量。当缺少 contracts 参数时 amount 为必填。',
                      style: TextStyle(fontSize: 12, color: _subtleTextColor),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                ListenableBuilder(
                  listenable: _vm,
                  builder: (context, _) => FilledButton(
                    onPressed:
                        _vm.canTradeSymbol(o.order.instrumentName) &&
                            validPrice &&
                            amountIsValid
                        ? () => Navigator.pop(context, true)
                        : null,
                    child: const Text('Update'),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    final priceText = priceController.text;
    final amountText = amountController.text;
    priceController.dispose();
    amountController.dispose();
    if (!mounted) return;
    if (ok == true) {
      final p = double.tryParse(priceText);
      final a = double.tryParse(amountText);
      if (p == null || !p.isFinite || p <= 0) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请输入有效的价格')));
        return;
      }
      if (!amountEdited) {
        await _vm.modifyOrderValues(o, newPrice: p);
        return;
      }

      if (a == null || !a.isFinite || a <= 0) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请输入有效的下单数量')));
        return;
      }
      final conversion = convertOrderAmountForApi(
        pair: tp.pair,
        inputAmount: a,
        inputUnit: isInverse ? ManualOrderAmountUnit.base : amountUnit,
        orderType: ManualOrderType.limit,
        direction: o.order.direction,
        limitPrice: p,
      );
      if (!conversion.canSubmit) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(conversion.errorMessage ?? '无法计算 API 下单数量')),
        );
        return;
      }
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Confirm Modify Amount'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Instrument: ${tp.symbol}'),
              Text('Price: ${p.toStringAsFixed(6)}'),
              ..._orderAmountConfirmationLines(conversion),
              Text(
                'Notional: ${conversion.notional.toStringAsFixed(2)} ${tp.pair.quoteCurrency}',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ListenableBuilder(
              listenable: _vm,
              builder: (context, _) => FilledButton(
                onPressed: _vm.canTradeSymbol(o.order.instrumentName)
                    ? () => Navigator.pop(context, true)
                    : null,
                child: const Text('Update'),
              ),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (confirm == true) {
        await _vm.modifyOrderValues(
          o,
          newPrice: p,
          newAmount: conversion.apiAmount,
        );
      }
    }
  }

  Future<void> _showIncreasePositionDialog(PositionVM position) async {
    final symbol = position.position.instrumentName;
    final livePair = _vm.findTradingPairVm(symbol);
    if (livePair == null || !livePair.pair.isVerified) return;
    final direction = position.position.direction;
    final draft = TradingPairVM(livePair.pair)..leverage = livePair.leverage;
    final amount = TextEditingController(
      text: draft.pair.minTradeAmount.toString(),
    );
    final price = TextEditingController(
      text: _vm.computeLimitPrice(livePair, direction)?.toString() ?? '',
    );
    var mode = 'base';
    var market = false;
    var postOnly = true;
    var chasing = false;
    var busy = false;
    String? error;
    await _vm.ensureAccountMetricsForCurrency(draft.pair.marginCurrency);
    if (!mounted) {
      amount.dispose();
      price.dispose();
      return;
    }
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => ListenableBuilder(
            listenable: _vm,
            builder: (context, _) {
              draft.bestBid = livePair.bestBid;
              draft.bestAsk = livePair.bestAsk;
              final input = double.tryParse(amount.text.trim());
              final limitPrice = market
                  ? null
                  : double.tryParse(price.text.trim());
              draft.buyPercent = input ?? 0;
              draft.sellPercent = input ?? 0;
              final reference = market
                  ? (direction == 'buy' ? livePair.bestAsk : livePair.bestBid)
                  : limitPrice;
              final percentAmount =
                  mode == 'percent' &&
                      input != null &&
                      isValidPositionPercentage(input)
                  ? _vm
                        .computePercentOrderAmountWithMeta(
                          draft,
                          direction,
                          atPrice: reference,
                        )
                        .$1
                  : null;
              final conversion = convertPositionAmountForApi(
                pair: draft.pair,
                inputAmount: mode == 'percent'
                    ? percentAmount ?? 0
                    : input ?? 0,
                inputUnit: mode == 'quote'
                    ? ManualOrderAmountUnit.quote
                    : ManualOrderAmountUnit.base,
                orderType: market
                    ? ManualOrderType.market
                    : ManualOrderType.limit,
                direction: direction,
                reference: (
                  price: reference,
                  label: market ? 'Market' : 'Limit',
                ),
              );
              final canSubmit =
                  _vm.canTradeSymbol(symbol) &&
                  conversion.canSubmit &&
                  (market || (limitPrice != null && limitPrice > 0));
              return AlertDialog(
                title: Text('加仓 $symbol · ${direction.toUpperCase()}'),
                content: SizedBox(
                  width: 440,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('与当前仓位方向一致，新增敞口；不使用 Reduce-only。'),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Market 市价'),
                          value: market,
                          onChanged: busy
                              ? null
                              : (v) => setDialogState(() {
                                  market = v;
                                  if (market) chasing = false;
                                }),
                        ),
                        if (!market)
                          TextField(
                            controller: price,
                            enabled: !busy,
                            decoration: const InputDecoration(
                              labelText: 'Limit price',
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            onChanged: (_) => setDialogState(() {}),
                          ),
                        DropdownButtonFormField<String>(
                          initialValue: mode,
                          decoration: const InputDecoration(
                            labelText: 'Amount unit',
                          ),
                          items: [
                            DropdownMenuItem(
                              value: 'base',
                              child: Text(draft.pair.baseCurrency),
                            ),
                            DropdownMenuItem(
                              value: 'quote',
                              child: Text(draft.pair.quoteCurrency),
                            ),
                            const DropdownMenuItem(
                              value: 'percent',
                              child: Text('可用资金百分比'),
                            ),
                          ],
                          onChanged: busy
                              ? null
                              : (v) => setDialogState(() {
                                  mode = v!;
                                  amount.text = mode == 'percent'
                                      ? '10'
                                      : draft.pair.minTradeAmount.toString();
                                }),
                        ),
                        TextField(
                          controller: amount,
                          enabled: !busy,
                          decoration: InputDecoration(
                            labelText: mode == 'percent'
                                ? 'Percent (0–100]'
                                : 'Amount',
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          onChanged: (_) => setDialogState(() {}),
                        ),
                        DropdownButtonFormField<int>(
                          initialValue: draft.leverage,
                          decoration: const InputDecoration(
                            labelText: 'Leverage',
                          ),
                          items: List.generate(
                            draft.pair.maxLeverage,
                            (i) => DropdownMenuItem(
                              value: i + 1,
                              child: Text('${i + 1}x'),
                            ),
                          ),
                          onChanged: busy
                              ? null
                              : (v) =>
                                    setDialogState(() => draft.leverage = v!),
                        ),
                        if (!market)
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Post-only'),
                            value: postOnly,
                            onChanged: busy
                                ? null
                                : (v) => setDialogState(() {
                                    postOnly = v!;
                                    if (!postOnly) chasing = false;
                                  }),
                          ),
                        if (!market && postOnly)
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('追价'),
                            value: chasing,
                            onChanged: busy
                                ? null
                                : (v) => setDialogState(() => chasing = v!),
                          ),
                        Text(
                          'API amount: ${conversion.apiAmount} ${draft.pair.apiAmountCurrency}',
                        ),
                        if (conversion.errorMessage != null)
                          Text(
                            conversion.errorMessage!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        if (error != null)
                          Text(
                            error!,
                            style: const TextStyle(color: Colors.red),
                          ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: busy ? null : () => Navigator.pop(dialogContext),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: !canSubmit || busy
                        ? null
                        : () async {
                            setDialogState(() {
                              busy = true;
                              error = null;
                            });
                            try {
                              final order = await _vm.increasePosition(
                                position,
                                amount: conversion.apiAmount,
                                market: market,
                                price: limitPrice,
                                postOnly: postOnly,
                                enableChasing: chasing,
                                leverage: draft.leverage,
                              );
                              if (order == null) {
                                throw StateError(
                                  'Order was not placed; see logs',
                                );
                              }
                              if (dialogContext.mounted) {
                                Navigator.pop(dialogContext);
                              }
                            } catch (e) {
                              if (dialogContext.mounted) {
                                setDialogState(() {
                                  busy = false;
                                  error = e.toString();
                                });
                              }
                            }
                          },
                    child: Text(busy ? '提交中…' : '确认加仓'),
                  ),
                ],
              );
            },
          ),
        ),
      );
    } finally {
      amount.dispose();
      price.dispose();
    }
  }

  Future<void> _showClosePositionDialog(PositionVM p) async {
    final tp =
        _vm.findTradingPairVm(p.position.instrumentName) ??
        TradingPairVM(TradingPair.unverified(p.position.instrumentName));
    final percentController = TextEditingController(text: '100');
    final baseAmtController = TextEditingController();
    final quoteAmtController = TextEditingController();
    final priceController = TextEditingController();
    final pnlController = TextEditingController();

    String mode = 'Percentage'; // 'Percentage' | 'Base' | 'Quote'
    String orderMode = 'limit'; // 'limit' | 'market'
    bool initialized = false;
    bool suppressSync = false;
    OrderAmountConversion? confirmedExplicitConversion;

    double positionBaseSize() {
      final reference = resolvePositionAmountReference(
        position: p.position,
        latestMarkPrice: _vm.getLatestMarkPrice(p.position.instrumentName),
      ).price;
      return apiAmountToBaseExposure(
        tp.pair,
        positionNativeApiAmount(tp.pair, p.position),
        reference,
      );
    }

    String closeDirection() => p.position.isLong ? 'sell' : 'buy';

    double bestPrice() {
      // Prefer top-of-book; fallback to mark price
      final est = _vm.getEstimatedPrice(
        p.position.instrumentName,
        closeDirection(),
      );
      if (est != null && est > 0) return est;
      return p.position.markPrice > 0
          ? p.position.markPrice
          : p.position.averagePrice;
    }

    double effectivePrice() {
      if (orderMode == 'market') {
        return resolvePositionAmountReference(
              position: p.position,
              latestMarkPrice: _vm.getLatestMarkPrice(
                p.position.instrumentName,
              ),
            ).price ??
            0;
      }
      final custom = double.tryParse(priceController.text.trim());
      return _vm.computeLimitPrice(
            tp,
            closeDirection(),
            custom: custom != null && custom.isFinite && custom > 0
                ? custom
                : null,
          ) ??
          0;
    }

    AmountReference amountReference() => resolvePositionAmountReference(
      position: p.position,
      preferredPrice: orderMode == 'limit' ? effectivePrice() : null,
      preferredLabel: 'Limit Price',
      latestMarkPrice: _vm.getLatestMarkPrice(p.position.instrumentName),
    );

    OrderAmountConversion? explicitConversion() {
      final controller = mode == 'Base'
          ? baseAmtController
          : mode == 'Quote'
          ? quoteAmtController
          : null;
      if (controller == null) return null;
      final value = double.tryParse(controller.text.trim());
      return convertPositionAmountForApi(
        pair: tp.pair,
        inputAmount: value ?? double.nan,
        inputUnit: mode == 'Quote'
            ? ManualOrderAmountUnit.quote
            : ManualOrderAmountUnit.base,
        orderType: orderMode == 'market'
            ? ManualOrderType.market
            : ManualOrderType.limit,
        direction: closeDirection(),
        reference: amountReference(),
      );
    }

    double intendedApiAmount() {
      if (mode == 'Percentage') {
        final percentage = double.tryParse(percentController.text.trim());
        if (percentage == null) return 0;
        return positionPercentageApiAmount(
          pair: tp.pair,
          position: p.position,
          percentage: percentage,
          preserveFullPosition: true,
        ).apiAmount;
      }
      return explicitConversion()?.apiAmount ?? 0;
    }

    double intendedBaseAmount() {
      return apiAmountToBaseExposure(
        tp.pair,
        intendedApiAmount(),
        effectivePrice(),
      );
    }

    double estimatePnl() {
      final price = effectivePrice();
      final apiAmount = intendedApiAmount();
      final baseAmt = intendedBaseAmount();
      final avg = p.position.averagePrice;
      final totalApiAmount = tp.pair.isVerified
          ? positionNativeApiAmount(tp.pair, p.position)
          : 0;
      if (price <= 0 ||
          apiAmount <= 0 ||
          baseAmt <= 0 ||
          avg <= 0 ||
          totalApiAmount <= 0) {
        return 0;
      }
      final fullPnl = calculatePositionPnl(
        pair: tp.pair,
        position: p.position,
        markPrice: price,
      );
      final partial =
          (fullPnl.settlementAmount.toRational() *
                  dFrom(apiAmount).toRational() /
                  dFrom(totalApiAmount).toRational())
              .toDecimal(scaleOnInfinitePrecision: 24);
      return dToDouble(partial);
    }

    void syncPnlFromPrice() {
      if (suppressSync) return;
      suppressSync = true;
      final pnl = estimatePnl();
      pnlController.text = pnl.isFinite ? pnl.toStringAsFixed(6) : '';
      suppressSync = false;
    }

    void syncPriceFromPnl() {
      if (suppressSync) return;
      final target = double.tryParse(pnlController.text.trim());
      final avg = p.position.averagePrice;
      if (target == null || avg <= 0) return;

      final apiAmount = intendedApiAmount();
      final baseAmt = intendedBaseAmount();
      double? nextPrice;
      if (tp.pair.isInverseFuture) {
        if (apiAmount <= 0) return;
        final signedApiAmount = dFrom(
          p.position.isLong ? apiAmount : -apiAmount,
        );
        final inversePrice =
            (Decimal.one / dFrom(avg) -
                    dFrom(target).toRational() / signedApiAmount.toRational())
                .toDecimal(scaleOnInfinitePrecision: 24);
        if (inversePrice == Decimal.zero) return;
        nextPrice = dToDouble(
          (Decimal.one / inversePrice).toDecimal(scaleOnInfinitePrecision: 24),
        );
      } else {
        if (baseAmt <= 0) return;
        final signedBaseAmount = dFrom(p.position.isLong ? baseAmt : -baseAmt);
        nextPrice = dToDouble(
          (dFrom(avg).toRational() +
                  dFrom(target).toRational() / signedBaseAmount.toRational())
              .toDecimal(scaleOnInfinitePrecision: 24),
        );
      }
      if (!nextPrice.isFinite || nextPrice <= 0) return;
      suppressSync = true;
      priceController.text = nextPrice.toStringAsFixed(6);
      suppressSync = false;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            final pos = p.position;
            final price = effectivePrice();
            final closeApiAmount = intendedApiAmount();
            final closeBase = intendedBaseAmount();
            final pnl = estimatePnl();
            final pnlQuote = tp.pair.isInverseFuture && price > 0
                ? pnl * price
                : null;
            final bestPx = bestPrice();
            final percentage = double.tryParse(percentController.text.trim());
            final percentageAmount = percentage == null
                ? null
                : positionPercentageApiAmount(
                    pair: tp.pair,
                    position: p.position,
                    percentage: percentage,
                    preserveFullPosition: true,
                  );
            final conversion = explicitConversion();
            final customPriceText = priceController.text.trim();
            final customPrice = double.tryParse(customPriceText);
            final validCustomPrice =
                orderMode == 'market' ||
                customPriceText.isEmpty ||
                (customPrice != null &&
                    customPrice.isFinite &&
                    customPrice > 0);
            final validSize = mode == 'Percentage'
                ? isValidPositionPercentage(percentage) &&
                      percentageAmount?.canSubmit == true
                : conversion?.canSubmit == true;
            final sizeError = mode == 'Percentage'
                ? isValidPositionPercentage(percentage)
                      ? percentageAmount?.errorMessage
                      : '请输入大于 0 且不超过 100 的百分比'
                : conversion?.errorMessage;
            if (!initialized) {
              pnlController.text = pnl.toStringAsFixed(6);
              initialized = true;
            }
            return AlertDialog(
              title: const Text('Close Position'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Position summary
                    Text(
                      '${pos.instrumentName}  •  ${pos.isLong ? 'LONG' : 'SHORT'}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Size: ${_formatTradeHistoryNumber(positionNativeApiAmount(tp.pair, pos))} ${tp.pair.apiAmountCurrency}'
                      '${tp.pair.isInverseFuture ? ' / ${_formatTradeHistoryNumber(positionBaseSize())} ${tp.pair.baseCurrency}' : ''}',
                    ),
                    Text(
                      'Avg / Reference: ${_formatTradeHistoryPrice(pos.averagePrice)} / ${_formatTradeHistoryPrice(pos.markPrice)} ${tp.pair.quoteCurrency}',
                    ),
                    const SizedBox(height: 8),
                    // Order type selector
                    Row(
                      children: [
                        const Text('Order Type:'),
                        const SizedBox(width: 12),
                        DropdownButton<String>(
                          value: orderMode,
                          items: const [
                            DropdownMenuItem(
                              value: 'limit',
                              child: Text('Limit (post-only)'),
                            ),
                            DropdownMenuItem(
                              value: 'market',
                              child: Text('Market'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() {
                              orderMode = v;
                              syncPnlFromPrice();
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Mode selector
                    Row(
                      children: [
                        const Text('Size Mode:'),
                        const SizedBox(width: 12),
                        DropdownButton<String>(
                          value: mode,
                          items: const [
                            DropdownMenuItem(
                              value: 'Percentage',
                              child: Text('Percentage'),
                            ),
                            DropdownMenuItem(
                              value: 'Base',
                              child: Text('Base Currency'),
                            ),
                            DropdownMenuItem(
                              value: 'Quote',
                              child: Text('Quote Currency'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() {
                              mode = v;
                              syncPnlFromPrice();
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (mode == 'Percentage')
                      TextField(
                        controller: percentController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Percentage (0-100)',
                        ).copyWith(errorText: sizeError),
                        onChanged: (_) => setState(() {
                          syncPnlFromPrice();
                        }),
                      ),
                    if (mode == 'Base')
                      TextField(
                        controller: baseAmtController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Amount (Base)',
                          suffixText: tp.pair.baseCurrency,
                          errorText: sizeError,
                        ),
                        onChanged: (_) => setState(() {
                          syncPnlFromPrice();
                        }),
                      ),
                    if (mode == 'Quote')
                      TextField(
                        controller: quoteAmtController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Amount (Quote)',
                          suffixText: tp.pair.quoteCurrency,
                          errorText: sizeError,
                        ),
                        onChanged: (_) => setState(() {
                          syncPnlFromPrice();
                        }),
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: priceController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'Custom Limit Price (optional)',
                        errorText: validCustomPrice ? null : '请输入有效的价格',
                        helperText:
                            'Best ${closeDirection().toUpperCase() == 'SELL' ? 'Bid' : 'Ask'}: ${bestPx.toStringAsFixed(6)}',
                      ),
                      enabled: orderMode != 'market',
                      onChanged: (_) => setState(() {
                        syncPnlFromPrice();
                      }),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: pnlController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText:
                            'Est. PnL target (${tp.pair.settlementCurrency})',
                      ),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color:
                            (double.tryParse(pnlController.text.trim()) ??
                                    pnl) >=
                                0
                            ? Colors.green
                            : Colors.red,
                      ),
                      onChanged: (_) => setState(() {
                        syncPriceFromPnl();
                      }),
                    ),
                    const SizedBox(height: 12),
                    // Estimates
                    Text('Close Direction: ${closeDirection().toUpperCase()}'),
                    Text(
                      'Used Price: ${price.toStringAsFixed(6)} ('
                      '${orderMode == 'market' ? 'Market' : ((double.tryParse(priceController.text) ?? 0) > 0 ? 'Custom' : 'Best')}'
                      ') ${tp.pair.quoteCurrency}',
                    ),
                    Text(
                      'API Amount To Close: ${_formatTradeHistoryNumber(closeApiAmount)} ${tp.pair.apiAmountCurrency}',
                    ),
                    Text(
                      'Base Exposure To Close: ${_formatTradeHistoryNumber(closeBase)} ${tp.pair.baseCurrency}',
                    ),
                    if (conversion != null) ...[
                      const SizedBox(height: 6),
                      ..._orderAmountConfirmationLines(conversion),
                    ],
                    // Keep a readout as well for clarity
                    Text(
                      'Est. PnL: ${pnl >= 0 ? '+' : ''}${pnl.toStringAsFixed(8)} ${tp.pair.settlementCurrency}',
                    ),
                    if (pnlQuote != null)
                      Text(
                        'Quote Equivalent: ${pnlQuote >= 0 ? '+' : ''}${pnlQuote.toStringAsFixed(2)} ${tp.pair.quoteCurrency}',
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                ListenableBuilder(
                  listenable: _vm,
                  builder: (context, _) => FilledButton(
                    onPressed:
                        _vm.canTradeSymbol(p.position.instrumentName) &&
                            validSize &&
                            validCustomPrice
                        ? () {
                            confirmedExplicitConversion = conversion;
                            Navigator.pop(context, true);
                          }
                        : null,
                    child: const Text('Close'),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    if (ok == true) {
      final price = double.tryParse(priceController.text);
      if (mode == 'Percentage') {
        final pct = double.tryParse(percentController.text);
        if (orderMode == 'market') {
          await _vm.closePositionMarket(p, percentage: pct);
        } else {
          await _vm.closePosition(p, percentage: pct, customPrice: price);
        }
      } else {
        final nativeApiAmount = confirmedExplicitConversion?.apiAmount;
        if (nativeApiAmount == null) return;
        if (orderMode == 'market') {
          await _vm.closePositionMarket(p, nativeApiAmount: nativeApiAmount);
        } else {
          await _vm.closePosition(
            p,
            nativeApiAmount: nativeApiAmount,
            customPrice: price,
          );
        }
      }
    }
  }

  Future<void> _showProtectPositionDialog(PositionVM p) async {
    final tp =
        _vm.findTradingPairVm(p.position.instrumentName) ??
        TradingPairVM(TradingPair.unverified(p.position.instrumentName));
    // Defaults
    String orderType =
        'stop_market'; // stop_market, take_market, trailing_stop, stop_limit, take_limit
    String sizeMode = 'Percentage'; // Percentage | Base | Quote
    String triggerSource = 'last_price'; // Bitfinex native stop trigger
    final percentController = TextEditingController(text: '100');
    final baseAmtController = TextEditingController();
    final quoteAmtController = TextEditingController();
    final triggerPxController = TextEditingController();
    final limitPxController = TextEditingController();
    final trailingOffsetController = TextEditingController();
    OrderAmountConversion? confirmedExplicitConversion;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            final mark = p.position.markPrice;
            final percentage = double.tryParse(percentController.text.trim());
            final percentageAmount = percentage == null
                ? null
                : positionPercentageApiAmount(
                    pair: tp.pair,
                    position: p.position,
                    percentage: percentage,
                  );
            final triggerPrice = double.tryParse(
              triggerPxController.text.trim(),
            );
            final limitPrice = double.tryParse(limitPxController.text.trim());
            final trailingOffset = double.tryParse(
              trailingOffsetController.text.trim(),
            );
            final reference = resolvePositionAmountReference(
              position: p.position,
              latestMarkPrice: _vm.getLatestMarkPrice(
                p.position.instrumentName,
              ),
              fallbackPrice: limitPrice ?? triggerPrice,
              fallbackLabel: limitPrice != null
                  ? 'Limit Price'
                  : 'Trigger Price',
            );
            final explicitValue = sizeMode == 'Base'
                ? double.tryParse(baseAmtController.text.trim())
                : sizeMode == 'Quote'
                ? double.tryParse(quoteAmtController.text.trim())
                : null;
            final conversion = sizeMode == 'Percentage'
                ? null
                : convertPositionAmountForApi(
                    pair: tp.pair,
                    inputAmount: explicitValue ?? double.nan,
                    inputUnit: sizeMode == 'Quote'
                        ? ManualOrderAmountUnit.quote
                        : ManualOrderAmountUnit.base,
                    orderType: orderType.endsWith('_market')
                        ? ManualOrderType.market
                        : ManualOrderType.limit,
                    direction: p.position.isLong ? 'sell' : 'buy',
                    reference: reference,
                  );
            final validSize = sizeMode == 'Percentage'
                ? isValidPositionPercentage(percentage) &&
                      percentageAmount?.canSubmit == true
                : conversion?.canSubmit == true;
            final sizeError = sizeMode == 'Percentage'
                ? isValidPositionPercentage(percentage)
                      ? percentageAmount?.errorMessage
                      : '请输入大于 0 且不超过 100 的百分比'
                : conversion?.errorMessage;
            bool validPositive(double? value) =>
                value != null && value.isFinite && value > 0;
            final validOrderParams = switch (orderType) {
              'trailing_stop' => validPositive(trailingOffset),
              'stop_limit' || 'take_limit' =>
                validPositive(triggerPrice) && validPositive(limitPrice),
              _ => validPositive(triggerPrice),
            };
            return AlertDialog(
              title: const Text('Add SL/TP'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${p.position.instrumentName}  •  ${p.position.isLong ? 'LONG' : 'SHORT'}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Text('Type'),
                        const SizedBox(width: 12),
                        DropdownButton<String>(
                          value: orderType,
                          items: const [
                            DropdownMenuItem(
                              value: 'stop_market',
                              child: Text('Stop Market'),
                            ),
                            DropdownMenuItem(
                              value: 'stop_limit',
                              child: Text('Stop Limit'),
                            ),
                            DropdownMenuItem(
                              value: 'take_market',
                              enabled: false,
                              child: Text('Take Market'),
                            ),
                            DropdownMenuItem(
                              value: 'take_limit',
                              enabled: false,
                              child: Text('Take Limit'),
                            ),
                            DropdownMenuItem(
                              value: 'trailing_stop',
                              child: Text('Trailing Stop'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() => orderType = v);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text('Size Mode'),
                        const SizedBox(width: 12),
                        DropdownButton<String>(
                          value: sizeMode,
                          items: const [
                            DropdownMenuItem(
                              value: 'Percentage',
                              child: Text('Percentage'),
                            ),
                            DropdownMenuItem(
                              value: 'Base',
                              child: Text('Base'),
                            ),
                            DropdownMenuItem(
                              value: 'Quote',
                              child: Text('Quote'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() => sizeMode = v);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (sizeMode == 'Percentage')
                      TextField(
                        controller: percentController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Percentage (0-100)',
                        ).copyWith(errorText: sizeError),
                        onChanged: (_) => setState(() {}),
                      ),
                    if (sizeMode == 'Base')
                      TextField(
                        controller: baseAmtController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Amount (Base)',
                          suffixText: tp.pair.baseCurrency,
                          errorText: sizeError,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    if (sizeMode == 'Quote')
                      TextField(
                        controller: quoteAmtController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Amount (Quote)',
                          suffixText: tp.pair.quoteCurrency,
                          errorText: sizeError,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text('Trigger Source'),
                        const SizedBox(width: 12),
                        DropdownButton<String>(
                          value: triggerSource,
                          items: const [
                            DropdownMenuItem(
                              value: 'mark_price',
                              enabled: false,
                              child: Text('Mark Price'),
                            ),
                            DropdownMenuItem(
                              value: 'index_price',
                              enabled: false,
                              child: Text('Index Price'),
                            ),
                            DropdownMenuItem(
                              value: 'last_price',
                              child: Text('Last Price'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() => triggerSource = v);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (orderType != 'trailing_stop')
                      TextField(
                        controller: triggerPxController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Trigger Price',
                          helperText: 'Mark: ${mark.toStringAsFixed(6)}',
                          errorText: validPositive(triggerPrice)
                              ? null
                              : '请输入有效的触发价格',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    if (orderType == 'stop_limit' || orderType == 'take_limit')
                      TextField(
                        controller: limitPxController,
                        keyboardType: TextInputType.number,
                        decoration:
                            const InputDecoration(
                              labelText: 'Limit Price',
                            ).copyWith(
                              errorText: validPositive(limitPrice)
                                  ? null
                                  : '请输入有效的限价',
                            ),
                        onChanged: (_) => setState(() {}),
                      ),
                    if (orderType == 'trailing_stop')
                      TextField(
                        controller: trailingOffsetController,
                        keyboardType: TextInputType.number,
                        decoration:
                            const InputDecoration(
                              labelText: 'Trailing Offset',
                              helperText: 'Distance from peak (quote currency)',
                            ).copyWith(
                              errorText: validPositive(trailingOffset)
                                  ? null
                                  : '请输入有效的跟踪距离',
                            ),
                        onChanged: (_) => setState(() {}),
                      ),
                    if (conversion != null) ...[
                      const SizedBox(height: 8),
                      ..._orderAmountConfirmationLines(conversion),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                ListenableBuilder(
                  listenable: _vm,
                  builder: (context, _) => FilledButton(
                    onPressed:
                        _vm.canTradeSymbol(p.position.instrumentName) &&
                            validSize &&
                            validOrderParams
                        ? () {
                            confirmedExplicitConversion = conversion;
                            Navigator.pop(context, true);
                          }
                        : null,
                    child: const Text('Place'),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    if (ok == true) {
      final tpx = double.tryParse(triggerPxController.text.trim());
      final lpx = double.tryParse(limitPxController.text.trim());
      final toff = double.tryParse(trailingOffsetController.text.trim());
      if (sizeMode == 'Percentage') {
        final pct = double.tryParse(percentController.text.trim());
        await _vm.addProtectionOrder(
          p,
          type: orderType,
          triggerPrice: tpx,
          limitPrice: lpx,
          trailingOffset: toff,
          percentage: pct,
          triggerSource: triggerSource,
        );
      } else {
        final nativeApiAmount = confirmedExplicitConversion?.apiAmount;
        if (nativeApiAmount == null) return;
        await _vm.addProtectionOrder(
          p,
          type: orderType,
          triggerPrice: tpx,
          limitPrice: lpx,
          trailingOffset: toff,
          nativeApiAmount: nativeApiAmount,
          triggerSource: triggerSource,
        );
      }
    }
  }

  Future<void> _showReversePositionDialog(PositionVM p) async {
    final tp =
        _vm.findTradingPairVm(p.position.instrumentName) ??
        TradingPairVM(TradingPair.unverified(p.position.instrumentName));
    final percentController = TextEditingController(text: '100');
    String orderMode = 'market'; // 'market' | 'limit'

    double bestPrice(String direction) {
      // Prefer top-of-book; fallback to mark/avg
      final est = _vm.getEstimatedPrice(p.position.instrumentName, direction);
      if (est != null && est > 0) return est;
      if (_vm.getLatestMarkPrice(p.position.instrumentName) != null) {
        return _vm.getLatestMarkPrice(p.position.instrumentName)!;
      }
      return p.position.markPrice > 0
          ? p.position.markPrice
          : p.position.averagePrice;
    }

    String reverseDirection() => p.position.isLong ? 'sell' : 'buy';

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            final parsedPercentage = double.tryParse(
              percentController.text.trim(),
            );
            final pct = parsedPercentage ?? 0;
            final normalizedAmount = parsedPercentage == null
                ? null
                : reversePositionApiAmount(
                    pair: tp.pair,
                    position: p.position,
                    targetPercentage: parsedPercentage,
                  );
            final validPercentage =
                isValidPositionPercentage(parsedPercentage) &&
                normalizedAmount?.canSubmit == true;
            final dir = reverseDirection();
            final usedPx = bestPrice(dir);
            final reversePnl = tp.pair.isVerified && usedPx > 0
                ? calculatePositionPnl(
                    pair: tp.pair,
                    position: p.position,
                    markPrice: usedPx,
                  )
                : null;
            final currentApiAmount = positionNativeApiAmount(
              tp.pair,
              p.position,
            );
            final targetApiAmount = currentApiAmount * (pct / 100);
            final netApiAmount = normalizedAmount?.apiAmount ?? 0;
            final currentBase = apiAmountToBaseExposure(
              tp.pair,
              currentApiAmount,
              usedPx,
            );
            final targetBase = apiAmountToBaseExposure(
              tp.pair,
              targetApiAmount,
              usedPx,
            );
            final netBase = apiAmountToBaseExposure(
              tp.pair,
              netApiAmount,
              usedPx,
            );

            return AlertDialog(
              title: const Text('Reverse Position'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Instrument: ${p.position.instrumentName}'),
                    const SizedBox(height: 6),
                    TextField(
                      controller: percentController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'New position size as % of current',
                        suffixText: '%',
                        errorText: validPercentage
                            ? null
                            : normalizedAmount?.errorMessage ??
                                  '请输入大于 0 且不超过 100 的百分比',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Order Type',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Market'),
                      value: 'market',
                      // ignore: deprecated_member_use
                      groupValue: orderMode,
                      // ignore: deprecated_member_use
                      onChanged: (v) =>
                          setState(() => orderMode = v ?? 'market'),
                    ),
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Limit (post-only)'),
                      value: 'limit',
                      // ignore: deprecated_member_use
                      groupValue: orderMode,
                      // ignore: deprecated_member_use
                      onChanged: (v) =>
                          setState(() => orderMode = v ?? 'market'),
                    ),
                    const SizedBox(height: 8),
                    Text('Reverse Direction: ${dir.toUpperCase()}'),
                    Text(
                      'Current API Size: ${_formatTradeHistoryNumber(currentApiAmount)} ${tp.pair.apiAmountCurrency}',
                    ),
                    Text(
                      'Target New Position: ${_formatTradeHistoryNumber(targetApiAmount)} ${tp.pair.apiAmountCurrency} / '
                      '${_formatTradeHistoryNumber(targetBase)} ${tp.pair.baseCurrency}',
                    ),
                    Text(
                      'Net Order: ${_formatTradeHistoryNumber(currentApiAmount)} x '
                      '(1 + ${pct.toStringAsFixed(2)}%) = '
                      '${_formatTradeHistoryNumber(netApiAmount)} ${tp.pair.apiAmountCurrency}',
                    ),
                    Text(
                      'Base Exposure: ${_formatTradeHistoryNumber(currentBase)} + '
                      '${_formatTradeHistoryNumber(targetBase)} = '
                      '${_formatTradeHistoryNumber(netBase)} ${tp.pair.baseCurrency}',
                    ),
                    Text(
                      'Used Price: ${usedPx.toStringAsFixed(6)} ${tp.pair.quoteCurrency} '
                      '(${orderMode == 'market' ? 'Market' : 'Limit'})',
                    ),
                    if (reversePnl != null)
                      Text('Estimated Close ${_formatPositionPnl(reversePnl)}'),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                ListenableBuilder(
                  listenable: _vm,
                  builder: (context, _) => FilledButton(
                    onPressed:
                        _vm.canTradeSymbol(p.position.instrumentName) &&
                            validPercentage
                        ? () => Navigator.pop(context, true)
                        : null,
                    child: const Text('Reverse'),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (ok == true) {
      final pct = double.tryParse(percentController.text.trim());
      await _vm.reversePosition(
        p,
        percentage: pct,
        market: orderMode == 'market',
      );
    }
  }

  String _displayDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  String _hhmmss(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';
  String _displayDateTime(DateTime d) => '${_displayDate(d)} ${_hhmmss(d)}';

  Future<DateTime?> _pickDateTime({required DateTime initial}) async {
    // 1) Pick date
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (date == null) return null;
    if (!mounted) return null;
    // 2) Pick time (HH:MM)
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initial.hour, minute: initial.minute),
    );
    final pickedHour = time?.hour ?? initial.hour;
    final pickedMinute = time?.minute ?? initial.minute;
    // 3) Pick seconds via a small dialog
    final secController = TextEditingController(
      text: initial.second.toString().padLeft(2, '0'),
    );
    if (!mounted) return null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('选择秒'),
          content: TextField(
            controller: secController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Seconds (0-59)'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
    int pickedSecond = initial.second;
    if (ok == true) {
      final s = int.tryParse(secController.text.trim());
      if (s != null) {
        pickedSecond = s.clamp(0, 59);
      }
    }
    return DateTime(
      date.year,
      date.month,
      date.day,
      pickedHour,
      pickedMinute,
      pickedSecond,
    );
  }

  (DateTime, DateTime) _computeQuickRange(String label) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    DateTime start = today;
    DateTime end = today;
    final key = label.trim().toUpperCase();
    if (key == '最近 24 小时' || key == '24H') {
      return (now.subtract(const Duration(hours: 24)), now);
    }
    if (key == '一天' || key == '1D') {
      start = end;
    } else if (key == '一周' || key == '1W') {
      start = end.subtract(const Duration(days: 6));
    } else if (key == 'WTD') {
      final weekday = today.weekday; // Mon=1..Sun=7
      final diff = (weekday - DateTime.monday + 7) % 7;
      start = today.subtract(Duration(days: diff));
    } else if (key == '一个月' || key == '1M') {
      start = _addMonths(today, -1);
    } else if (key == 'MTD') {
      start = DateTime(today.year, today.month, 1);
    } else if (key == '三个月' || key == '3M') {
      start = _addMonths(today, -3);
    } else if (key == '半年' || key == '6M') {
      start = _addMonths(today, -6);
    } else if (key == '一年' || key == '1Y') {
      start = DateTime(today.year - 1, today.month, today.day);
    } else if (key == 'YTD') {
      start = DateTime(today.year, 1, 1);
    }
    final endOfDay = DateTime(end.year, end.month, end.day, 23, 59, 59, 999);
    return (start, endOfDay);
  }

  DateTime _addMonths(DateTime dt, int months) {
    final y = dt.year;
    final m0 = dt.month;
    final d = dt.day;
    final m = m0 + months;
    var year = y + ((m - 1) ~/ 12);
    var month = ((m - 1) % 12) + 1;
    if (m <= 0) {
      year = y + ((m - 12) ~/ 12);
      month = ((m - 1) % 12 + 12) % 12 + 1;
    }
    final lastDay = _daysInMonth(year, month);
    final day = d > lastDay ? lastDay : d;
    return DateTime(year, month, day);
  }

  int _daysInMonth(int year, int month) {
    final beginningNextMonth = (month == 12)
        ? DateTime(year + 1, 1, 1)
        : DateTime(year, month + 1, 1);
    return beginningNextMonth.subtract(const Duration(days: 1)).day;
  }
}
