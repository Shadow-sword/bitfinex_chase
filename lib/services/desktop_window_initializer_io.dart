import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_window_state.dart';
import 'settings_store.dart';

DesktopWindowStateController? _desktopWindowStateController;

Future<void> initializeDesktopWindowState() async {
  if (!_isDesktopPlatform) return;

  _desktopWindowStateController ??= DesktopWindowStateController();
  try {
    await _desktopWindowStateController!.initialize();
  } catch (error, stackTrace) {
    debugPrint('Failed to initialize desktop window state: $error');
    debugPrintStack(stackTrace: stackTrace);
  }
}

bool get _isDesktopPlatform {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows;
}

class DesktopWindowStateController with WindowListener {
  DesktopWindowStateController({
    WindowManager? windowManager,
    ScreenRetriever? screenRetriever,
  }) : _windowManager = windowManager ?? WindowManager.instance,
       _screenRetriever = screenRetriever ?? ScreenRetriever.instance;

  static const _saveDebounce = Duration(milliseconds: 350);

  final WindowManager _windowManager;
  final ScreenRetriever _screenRetriever;

  var _initialized = false;
  Timer? _saveTimer;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    await _windowManager.ensureInitialized();

    final storedState = await SettingsStore.loadDesktopWindowState();
    final displays = await _loadDisplays();
    final restoredBounds = DesktopWindowStateResolver.restoreBounds(
      storedState,
      displays,
    );
    final restoredSize = DesktopWindowStateResolver.restoreSize(storedState);

    await _windowManager.waitUntilReadyToShow(
      WindowOptions(
        title: 'BitfinexChase',
        size:
            restoredBounds?.size ??
            restoredSize ??
            DesktopWindowStateResolver.defaultSize,
        center: restoredBounds == null,
        minimumSize: DesktopWindowStateResolver.minimumSize,
      ),
    );

    if (restoredBounds != null) {
      await _windowManager.setBounds(restoredBounds);
    }
    await _windowManager.show();
    await _windowManager.focus();

    _windowManager.addListener(this);
  }

  @override
  void onWindowMove() => _scheduleSave();

  @override
  void onWindowMoved() => _saveNow();

  @override
  void onWindowResize() => _scheduleSave();

  @override
  void onWindowResized() => _saveNow();

  @override
  void onWindowClose() => _saveNow();

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, _saveNow);
  }

  void _saveNow() {
    _saveTimer?.cancel();
    unawaited(_saveCurrentState());
  }

  Future<void> _saveCurrentState() async {
    try {
      final bounds = await _windowManager.getBounds();
      if (!_isUsableBounds(bounds)) return;

      final displays = await _loadDisplays();
      final display = DesktopWindowStateResolver.displayForBounds(
        bounds,
        displays,
      );
      await SettingsStore.saveDesktopWindowState(
        DesktopWindowState.fromBounds(bounds: bounds, display: display),
      );
    } catch (error, stackTrace) {
      debugPrint('Failed to save desktop window state: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<List<DesktopDisplaySnapshot>> _loadDisplays() async {
    try {
      final displays = await _screenRetriever.getAllDisplays();
      return displays
          .map(_snapshotFromDisplay)
          .whereType<DesktopDisplaySnapshot>()
          .toList();
    } catch (error, stackTrace) {
      debugPrint('Failed to read desktop displays: $error');
      debugPrintStack(stackTrace: stackTrace);
      return const [];
    }
  }

  DesktopDisplaySnapshot? _snapshotFromDisplay(Display display) {
    final visibleSize = display.visibleSize ?? display.size;
    if (visibleSize.width <= 0 || visibleSize.height <= 0) return null;

    final visiblePosition = display.visiblePosition ?? Offset.zero;
    return DesktopDisplaySnapshot(
      id: display.id,
      name: display.name,
      visibleFrame: visiblePosition & visibleSize,
    );
  }

  bool _isUsableBounds(Rect bounds) {
    return bounds.left.isFinite &&
        bounds.top.isFinite &&
        bounds.width.isFinite &&
        bounds.height.isFinite &&
        bounds.width > 0 &&
        bounds.height > 0;
  }
}
