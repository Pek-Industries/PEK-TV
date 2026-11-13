import 'package:flutter/material.dart';

import 'common.dart';
import 'fields.dart' show PekDropdown;
import 'l10n.dart';
import 'refresh.dart';
import 'settings_extra.dart' show ToggleRow;
import 'store.dart';
import 'tokens.dart';

/// Accessibility options, kept on the device (not per profile), like TV mode.
///
///  * text size: 100 / 115 / 130 / 150 % on top of the device's own font size
///  * reduce motion: the same switch as the system's "remove animations" (`MediaQuery.disableAnimations`), which the focus box,
///    the activity display and skin buttons already honour
///  * stronger focus outline: a thick, high-contrast ring on the selected item on phones and TVs alike
///
/// Screen readers (TalkBack) work through the Semantics in `widgets.dart` and `common.dart`.
class A11y {
  A11y._();

  static const _kText = 'pek_a11y_text';
  static const _kMotion = 'pek_a11y_motion';
  static const _kFocus = 'pek_a11y_focus';

  static const textFactors = <double>[1.0, 1.15, 1.3, 1.5];

  /// Never scale text past this in total (device setting x ours): the layouts are built in rem units and break beyond it.
  static const maxTextScale = 2.0;

  /// Listened to by the app root so MediaQuery is rebuilt when an option changes.
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  static int get textLevel => (int.tryParse(Store.strGet(_kText, scoped: false) ?? '') ?? 0).clamp(0, textFactors.length - 1);
  static bool get reduceMotion => Store.strGet(_kMotion, scoped: false) == '1';
  static bool get strongFocus => Store.strGet(_kFocus, scoped: false) == '1';

  static Future<void> setTextLevel(int level) => _save(_kText, '${level.clamp(0, textFactors.length - 1)}');
  static Future<void> setReduceMotion(bool on) => _save(_kMotion, on ? '1' : '0');
  static Future<void> setStrongFocus(bool on) => _save(_kFocus, on ? '1' : '0');

  static Future<void> _save(String key, String value) async {
    await Store.strSet(key, value, scoped: false);
    changes.value++;
    refreshWholeApp(); // PekFocusable and others read these straight from here
  }

  /// [m] with the person's options applied: the app root puts this over every screen.
  static MediaQueryData apply(MediaQueryData m) {
    var out = m;
    final level = textLevel;
    if (level > 0) {
      final scale = (m.textScaler.scale(1.0) * textFactors[level]).clamp(1.0, maxTextScale).toDouble();
      out = out.copyWith(textScaler: TextScaler.linear(scale));
    }
    if (reduceMotion && !m.disableAnimations) out = out.copyWith(disableAnimations: true);
    return out;
  }
}

/// Settings > Accessibility.
class AccessibilitySection extends StatelessWidget {
  const AccessibilitySection({super.key});

  static const _sizeNames = ['Normal', 'Large', 'Larger', 'Largest'];

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    return ValueListenableBuilder<int>(
      valueListenable: A11y.changes,
      builder: (context, _, __) => Section(
        title: 'Accessibility'.tr,
        hint: 'Screen readers like TalkBack are supported. These options make PEK TV easier to see and use.'.tr,
        children: [
          Padding(padding: EdgeInsets.symmetric(vertical: 0.5 * rem), child: Text('Text size'.tr, style: TextStyle(color: t.textMuted))),
          PekDropdown<int>(
            label: 'Text size'.tr,
            value: A11y.textLevel,
            items: [for (var i = 0; i < _sizeNames.length; i++) (i, _sizeNames[i].tr)],
            onChanged: (v) => A11y.setTextLevel(v),
          ),
          Padding(padding: EdgeInsets.only(top: 0.4 * rem, bottom: 0.6 * rem), child: Text('Makes all text bigger. PEK TV also follows the font size set on your device.'.tr, style: TextStyle(color: t.textMuted, fontSize: 0.85 * rem))),
          ToggleRow(
            title: 'Reduce motion'.tr,
            subtitle: 'Turns off sliding, zooming and fading effects.'.tr,
            on: A11y.reduceMotion,
            onTap: () => A11y.setReduceMotion(!A11y.reduceMotion),
          ),
          ToggleRow(
            title: 'Stronger focus outline'.tr,
            subtitle: 'A thicker, high-contrast outline around the selected item. Helpful with a remote or keyboard.'.tr,
            on: A11y.strongFocus,
            onTap: () => A11y.setStrongFocus(!A11y.strongFocus),
          ),
        ],
      ),
    );
  }
}
