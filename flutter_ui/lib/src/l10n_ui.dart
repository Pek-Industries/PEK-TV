import 'package:flutter/material.dart';

import 'common.dart';
import 'l10n.dart';
import 'tokens.dart';
import 'widgets.dart';

/// One language in a list: its own name, the English name under it, and a tick on the one in use. Works with touch, D-pad and screen
/// readers (the row says it is one of a group and whether it is selected).
class _LanguageRow extends StatelessWidget {
  const _LanguageRow({required this.title, required this.subtitle, required this.selected, required this.onTap, this.autofocus = false});
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final t = context.pek.tokens;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      child: ListRow(
        title: title,
        subtitle: subtitle,
        autofocus: autofocus,
        onTap: onTap,
        trailing: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: selected ? t.accent : t.textMuted),
      ),
    );
  }
}

/// The rows: "System default", then every language by its own name.
List<Widget> _languageRows(String current, {bool autofocusFirst = false}) => [
      _LanguageRow(
        title: 'System default'.tr,
        subtitle: 'Follows your device language'.tr,
        selected: current == L10n.system,
        autofocus: autofocusFirst,
        onTap: () => L10n.set(L10n.system),
      ),
      for (final l in L10n.languages)
        _LanguageRow(
          title: l.nativeName,
          subtitle: l.englishName == l.nativeName ? '' : l.englishName,
          selected: current == l.code,
          onTap: () => L10n.set(l.code),
        ),
    ];

/// Settings > Language.
class LanguageSection extends StatelessWidget {
  const LanguageSection({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: L10n.choice,
      builder: (context, current, _) => Section(
        title: 'Language'.tr,
        hint: 'Choose the language PEK TV uses. Text that has not been translated yet stays in English.'.tr,
        children: _languageRows(current),
      ),
    );
  }
}

/// First launch, before the welcome tour: pick the language (the screen changes language as soon as one is tapped). "Continue" keeps
/// the choice, including "System default", so the question is not asked again.
class LanguageChoiceScreen extends StatelessWidget {
  const LanguageChoiceScreen({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: p.safeX + rem, vertical: rem),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 30 * rem),
              child: ValueListenableBuilder<String>(
                valueListenable: L10n.choice,
                builder: (context, current, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Semantics(header: true, child: Text('Choose your language'.tr, style: TextStyle(fontSize: 1.7 * rem, fontWeight: FontWeight.w800, height: 1.15))),
                  SizedBox(height: 0.5 * rem),
                  Text('You can change this any time in Settings, under Language.'.tr, style: TextStyle(color: t.textMuted, fontSize: rem, height: 1.4)),
                  SizedBox(height: rem),
                  Expanded(child: ListView(children: _languageRows(current, autofocusFirst: true))),
                  SizedBox(height: rem),
                  PekButton(label: 'Continue'.tr, primary: true, onTap: () async {
                    await L10n.set(L10n.choice.value); // writes the choice even when it is still "System default"
                    onDone();
                  }),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
