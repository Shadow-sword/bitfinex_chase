import 'dart:math' as math;
import 'dart:ui';

class DesktopWindowState {
  const DesktopWindowState({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.displayId,
    this.displayName,
  });

  factory DesktopWindowState.fromBounds({
    required Rect bounds,
    DesktopDisplaySnapshot? display,
  }) {
    return DesktopWindowState(
      x: bounds.left,
      y: bounds.top,
      width: bounds.width,
      height: bounds.height,
      displayId: display?.id,
      displayName: display?.name,
    );
  }

  final double x;
  final double y;
  final double width;
  final double height;
  final String? displayId;
  final String? displayName;

  Rect get bounds => Rect.fromLTWH(x, y, width, height);
  Size get size => Size(width, height);

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'displayId': displayId,
    'displayName': displayName,
  };

  static DesktopWindowState? fromJson(Map<String, Object?> json) {
    final x = _readFiniteDouble(json['x']);
    final y = _readFiniteDouble(json['y']);
    final width = _readFiniteDouble(json['width']);
    final height = _readFiniteDouble(json['height']);
    if (x == null || y == null || width == null || height == null) {
      return null;
    }
    if (width <= 0 || height <= 0) return null;

    return DesktopWindowState(
      x: x,
      y: y,
      width: width,
      height: height,
      displayId: _readString(json['displayId']),
      displayName: _readString(json['displayName']),
    );
  }

  static double? _readFiniteDouble(Object? value) {
    final number = value is num ? value.toDouble() : double.tryParse('$value');
    if (number == null || !number.isFinite) return null;
    return number;
  }

  static String? _readString(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return value;
  }
}

class DesktopDisplaySnapshot {
  const DesktopDisplaySnapshot({
    required this.id,
    required this.visibleFrame,
    this.name,
  });

  final String id;
  final String? name;
  final Rect visibleFrame;
}

class DesktopWindowStateResolver {
  static const defaultSize = Size(1280, 720);
  static const minimumSize = Size(640, 480);

  const DesktopWindowStateResolver._();

  static Rect? restoreBounds(
    DesktopWindowState? state,
    List<DesktopDisplaySnapshot> displays, {
    Size minSize = minimumSize,
  }) {
    if (state == null || displays.isEmpty) return null;

    final display = _restoreDisplayFor(state, displays);
    final restoredSize = restoreSize(state, minSize: minSize);
    if (restoredSize == null) return null;
    final desiredBounds =
        display.id == state.displayId ||
            (state.displayName != null && display.name == state.displayName) ||
            display.visibleFrame.contains(state.bounds.center)
        ? state.bounds
        : _centerIn(display.visibleFrame, restoredSize);

    return fitBounds(desiredBounds, display.visibleFrame, minSize: minSize);
  }

  static Size? restoreSize(
    DesktopWindowState? state, {
    Size minSize = minimumSize,
  }) {
    if (state == null || state.width <= 0 || state.height <= 0) return null;
    return Size(
      math.max(state.width, minSize.width),
      math.max(state.height, minSize.height),
    );
  }

  static DesktopDisplaySnapshot? displayForBounds(
    Rect bounds,
    List<DesktopDisplaySnapshot> displays,
  ) {
    if (displays.isEmpty) return null;

    final center = bounds.center;
    for (final display in displays) {
      if (display.visibleFrame.contains(center)) return display;
    }

    DesktopDisplaySnapshot? bestDisplay;
    var bestArea = 0.0;
    for (final display in displays) {
      final area = _intersectionArea(bounds, display.visibleFrame);
      if (area > bestArea) {
        bestArea = area;
        bestDisplay = display;
      }
    }
    return bestDisplay ?? displays.first;
  }

  static Rect fitBounds(
    Rect desired,
    Rect visibleFrame, {
    Size minSize = minimumSize,
  }) {
    if (visibleFrame.width <= 0 || visibleFrame.height <= 0) {
      return Rect.fromLTWH(
        desired.left,
        desired.top,
        math.max(desired.width, minSize.width),
        math.max(desired.height, minSize.height),
      );
    }

    final width = _clampDimension(
      desired.width,
      minSize.width,
      visibleFrame.width,
    );
    final height = _clampDimension(
      desired.height,
      minSize.height,
      visibleFrame.height,
    );
    final left = _clampPosition(
      desired.left,
      visibleFrame.left,
      visibleFrame.right - width,
    );
    final top = _clampPosition(
      desired.top,
      visibleFrame.top,
      visibleFrame.bottom - height,
    );

    return Rect.fromLTWH(left, top, width, height);
  }

  static DesktopDisplaySnapshot _restoreDisplayFor(
    DesktopWindowState state,
    List<DesktopDisplaySnapshot> displays,
  ) {
    final displayId = state.displayId;
    if (displayId != null) {
      for (final display in displays) {
        if (display.id == displayId) return display;
      }
    }

    final displayName = state.displayName;
    if (displayName != null) {
      for (final display in displays) {
        if (display.name == displayName) return display;
      }
    }

    return displayForBounds(state.bounds, displays) ?? displays.first;
  }

  static Rect _centerIn(Rect frame, Size size) {
    final width = math.min(size.width, frame.width);
    final height = math.min(size.height, frame.height);
    return Rect.fromLTWH(
      frame.left + (frame.width - width) / 2,
      frame.top + (frame.height - height) / 2,
      width,
      height,
    );
  }

  static double _clampDimension(double value, double min, double max) {
    final safeValue = value.isFinite && value > 0 ? value : min;
    final lower = math.min(min, max);
    final upper = math.max(lower, max);
    return safeValue.clamp(lower, upper).toDouble();
  }

  static double _clampPosition(double value, double min, double max) {
    if (max < min) return min;
    final safeValue = value.isFinite ? value : min;
    return safeValue.clamp(min, max).toDouble();
  }

  static double _intersectionArea(Rect a, Rect b) {
    final left = math.max(a.left, b.left);
    final top = math.max(a.top, b.top);
    final right = math.min(a.right, b.right);
    final bottom = math.min(a.bottom, b.bottom);
    final width = right - left;
    final height = bottom - top;
    if (width <= 0 || height <= 0) return 0;
    return width * height;
  }
}
