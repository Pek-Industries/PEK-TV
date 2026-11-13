import 'package:flutter/widgets.dart';

/// Marks every widget on screen as needing a rebuild, without touching any State. Used when something that plain `build` methods
/// read directly changes (the app language, the accessibility options): screens keep their scroll position and the pages that are
/// open stay open, they just repaint with the new text. Call it from an event handler, never while a build is running.
void refreshWholeApp() {
  void visit(Element e) {
    e.markNeedsBuild();
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
}
