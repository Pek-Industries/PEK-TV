import 'package:flutter/material.dart';

import 'common.dart';
import 'settings_extra.dart' show ToggleRow;
import 'store.dart';

/// Settings > Mode > Layout: Simple (a streaming-app home: banner, rows of cards, genre chips, trailers) or Advanced (the dashboard,
/// filters, plugins and everything else PEK TV has). Kept on this device, like music mode. Switching rebuilds the shell
/// underneath (main.dart keys it on the layout), so every screen pushed on top is closed first.
class InterfaceSection extends StatelessWidget {
  const InterfaceSection({super.key});

  Future<void> _set(BuildContext context, bool simple) async {
    if (Store.simpleMode == simple) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    await Store.setSimpleMode(simple);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Store.simpleModeN, Store.changed]),
      builder: (context, _) {
        final simple = Store.simpleMode;
        return Section(
          title: 'Layout',
          hint: simple
              ? 'Simple: big banner, rows of movie and show cards, genres at the top. Switch to Advanced for the dashboard, filters and plugins; nothing is deleted.'
              : 'Advanced is the full PEK TV. Simple turns the home screen into a streaming-app look that is easy to use: pick a card, press Play.',
          children: [
            ToggleRow(title: 'Simple', subtitle: 'Cards, banner and trailers, like a streaming app', on: simple, onTap: () => _set(context, true)),
            ToggleRow(title: 'Advanced', subtitle: 'Dashboard, filters, plugins and every setting', on: !simple, onTap: () => _set(context, false)),
            if (simple) ...[
              ToggleRow(
                title: 'Play trailers',
                subtitle: Store.simpleTrailers ? 'On: the banner and a title\u2019s page play its trailer' : 'Off: pictures only',
                on: Store.simpleTrailers,
                onTap: () => Store.setSimpleTrailers(!Store.simpleTrailers),
              ),
              ToggleRow(
                title: 'Trailer sound',
                subtitle: Store.simpleSound ? 'On' : 'Off: trailers play muted',
                on: Store.simpleSound,
                onTap: () => Store.setSimpleSound(!Store.simpleSound),
              ),
            ],
          ],
        );
      },
    );
  }
}
