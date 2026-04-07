import 'package:flutter/widgets.dart';

/// Material 3 window size classes.
/// https://m3.material.io/foundations/layout/applying-layout/window-size-classes
enum WindowSizeClass { compact, medium, expanded }

WindowSizeClass windowSizeFromWidth(double width) {
  if (width < 600) return WindowSizeClass.compact;
  if (width < 840) return WindowSizeClass.medium;
  return WindowSizeClass.expanded;
}

WindowSizeClass windowSizeOf(BuildContext context) =>
    windowSizeFromWidth(MediaQuery.sizeOf(context).width);
