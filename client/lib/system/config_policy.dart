/// Pure-Dart parsers that translate the string-typed `brightness` and
/// `screenTimeout` fields on [HyacinthConfig] into actionable, sealed
/// values. No Flutter imports — trivially unit-testable.
///
/// Parsing is total: any malformed input collapses to a safe default
/// (`BrightnessAuto` / `TimeoutAlwaysOn`) rather than throwing. The
/// display layer never has to handle parse exceptions.
library;

/// What the system should do with screen brightness.
sealed class BrightnessSetting {
  const BrightnessSetting();
}

/// Hand brightness back to the system's auto / ambient sensor mode.
class BrightnessAuto extends BrightnessSetting {
  const BrightnessAuto();
}

/// Pin brightness to a fixed level on the 0..100 scale.
class BrightnessManual extends BrightnessSetting {
  const BrightnessManual(this.level);

  /// 0..100, inclusive. Always clamped at parse time.
  final int level;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BrightnessManual && other.level == level;

  @override
  int get hashCode => level.hashCode;

  @override
  String toString() => 'BrightnessManual($level)';
}

/// What the system should do with the screen-off timeout.
sealed class TimeoutSetting {
  const TimeoutSetting();
}

/// Disable the screen-off timeout entirely (Integer.MAX_VALUE on Android).
class TimeoutAlwaysOn extends TimeoutSetting {
  const TimeoutAlwaysOn();
}

/// Use a fixed timeout duration.
class TimeoutDuration extends TimeoutSetting {
  const TimeoutDuration(this.value);

  final Duration value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TimeoutDuration && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'TimeoutDuration($value)';
}

/// Parses a config-string brightness into a [BrightnessSetting].
///
/// Accepted forms:
/// - `"auto"` (any case, with surrounding whitespace) → [BrightnessAuto]
/// - integer string `"0".."100"` → [BrightnessManual] (clamped)
/// - decimal `"0.5"` etc. → [BrightnessManual] (rounded, clamped)
/// - anything else → [BrightnessAuto]
BrightnessSetting parseBrightness(String v) {
  final s = v.trim().toLowerCase();
  if (s.isEmpty) return const BrightnessAuto();
  if (s == 'auto') return const BrightnessAuto();
  final asInt = int.tryParse(s);
  if (asInt != null) {
    return BrightnessManual(asInt.clamp(0, 100));
  }
  final asDouble = double.tryParse(s);
  if (asDouble != null) {
    final v = asDouble.round();
    return BrightnessManual(v.clamp(0, 100));
  }
  return const BrightnessAuto();
}

/// Parses a config-string screen timeout into a [TimeoutSetting].
///
/// Accepted forms:
/// - `"always-on"` / `"alwayson"` → [TimeoutAlwaysOn]
/// - `"<n>s"` seconds, `"<n>m"` minutes, `"<n>h"` hours → [TimeoutDuration]
/// - bare integer (`"30"`) → seconds
/// - anything else → [TimeoutAlwaysOn]
TimeoutSetting parseScreenTimeout(String v) {
  final s = v.trim().toLowerCase();
  if (s.isEmpty) return const TimeoutAlwaysOn();
  if (s == 'always-on' || s == 'alwayson' || s == 'always_on') {
    return const TimeoutAlwaysOn();
  }
  // Match `<digits><unit>` where unit is one of s/m/h.
  final match = RegExp(r'^(\d+)\s*([smh])$').firstMatch(s);
  if (match != null) {
    final n = int.parse(match.group(1)!);
    switch (match.group(2)) {
      case 's':
        return TimeoutDuration(Duration(seconds: n));
      case 'm':
        return TimeoutDuration(Duration(minutes: n));
      case 'h':
        return TimeoutDuration(Duration(hours: n));
    }
  }
  final asInt = int.tryParse(s);
  if (asInt != null && asInt > 0) {
    return TimeoutDuration(Duration(seconds: asInt));
  }
  return const TimeoutAlwaysOn();
}
