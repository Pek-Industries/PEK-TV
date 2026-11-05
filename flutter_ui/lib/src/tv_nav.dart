import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';

/// D-pad navigation for the whole app, done by the `dpad` package (Android's FocusFinder / Leanback model) instead of
/// Flutter's stock "closest widget" focus search, which jumped between the sidebar and the rows, skipped rows and forgot
/// where you were.
///
/// - [root] is installed once in `main.dart`, above every screen, dialog and sheet. It brings the TV traversal policy
///   (beam-based moves, animated scroll-into-view, lazy lists that scroll and continue), focus that never dies (a screen
///   that opens gets focus without `autofocus`, focus comes back after a dialog or an app resume) and press / hold handling.
/// - [region] groups the items of one visual section (the sidebar, one poster row). Moves stay inside the section first,
///   and coming back into it lands on the item you left (focus memory), like Netflix / Prime.
///
/// `PekFocusable`, `PekField` and the Material widgets keep their own focus nodes: the package works with plain `Focus`
/// widgets, so no screen had to be rewritten.
class TvNav {
  /// How long a short glide takes (used by the few places that still scroll by hand).
  static const scrollDuration = Duration(milliseconds: 240);
  static const scrollCurve = Curves.easeOutCubic;

  static final TransitionBuilder _wrap = Dpad.wrap(
    // Room kept around a focused item when it is scrolled into view, so a raised / glowing card is not cut at the edge.
    theme: const DpadThemeData(scrollPadding: 32),
  );

  /// The app-wide root (`MaterialApp.builder`).
  static Widget root(BuildContext context, Widget child) => _wrap(context, child);

  /// One visual section. [rowEndStops]: Right stops at the end of a row. [columnEdgesStop]: Up / Down stop at the ends (a sidebar never lets focus fall off).
  static Widget region({required String memoryKey, required Widget child, bool rowEndStops = false, bool columnEdgesStop = false}) {
    return DpadRegion(
      memoryKey: memoryKey,
      rightEdge: rowEndStops ? DpadEdgeBehavior.stop : DpadEdgeBehavior.leave,
      verticalEdge: columnEdgesStop ? DpadEdgeBehavior.stop : DpadEdgeBehavior.leave,
      child: child,
    );
  }
}
