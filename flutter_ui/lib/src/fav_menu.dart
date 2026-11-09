import 'package:flutter/material.dart';

import 'common.dart';
import 'tokens.dart';
import 'widgets.dart';

/// Asks before anything is deleted. "Cancel" has the focus, so a stray OK press on a remote keeps the item.
/// Returns true only when the person picks the "yes" button.
Future<bool> confirmDelete(BuildContext context, {required String title, required String message, String yes = 'Yes, delete'}) async {
  final p = context.pek;
  final t = p.tokens;
  final rem = p.rem;
  final ok = await showDialog<bool>(
    context: context,
    barrierColor: t.overlay,
    builder: (c) => Dialog(
      backgroundColor: t.glassStrong,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.radius), side: BorderSide(color: t.border)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 36 * rem),
        child: Padding(
          padding: EdgeInsets.all(1.5 * rem),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(fontSize: 1.25 * rem, fontWeight: FontWeight.w700)),
              SizedBox(height: 0.75 * rem),
              Text(message, style: TextStyle(color: t.textMuted)),
              SizedBox(height: 1.25 * rem),
              Wrap(spacing: 0.75 * rem, runSpacing: 0.75 * rem, children: [
                PekButton(label: yes, primary: true, onTap: () => Navigator.pop(c, true)),
                PekButton(label: 'Cancel', autofocus: true, onTap: () => Navigator.pop(c, false)),
              ]),
            ],
          ),
        ),
      ),
    ),
  );
  return ok == true;
}

enum _FavChoice { remove, open }

/// The menu a long press (or a held OK on a remote) opens on a favorite: remove it (after a confirmation) or open it in a plugin.
/// [onRemove] runs only after the person confirmed; [onOpen] runs at once.
Future<void> showFavoriteMenu(
  BuildContext context, {
  required String title,
  required Future<void> Function() onRemove,
  required Future<void> Function() onOpen,
}) async {
  final t = context.pek.tokens;
  final choice = await showModalBottomSheet<_FavChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: t.glassStrong,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(t.radius))),
    builder: (c) => _FavMenuSheet(title: title),
  );
  if (choice == null || !context.mounted) return;
  if (choice == _FavChoice.open) {
    await onOpen();
    return;
  }
  final yes = await confirmDelete(
    context,
    title: 'Remove from favorites?',
    message: 'Are you sure you want to remove "$title" from your favorites? Your files are not touched.',
    yes: 'Yes, remove',
  );
  if (yes) await onRemove();
}

class _FavMenuSheet extends StatefulWidget {
  const _FavMenuSheet({required this.title});
  final String title;

  @override
  State<_FavMenuSheet> createState() => _FavMenuSheetState();
}

class _FavMenuSheetState extends State<_FavMenuSheet> {
  final DateTime _opened = DateTime.now();

  /// The menu opens while the remote's OK button is still held down; the key repeats of that same press must not pick a row.
  bool get _ready => DateTime.now().difference(_opened) > const Duration(milliseconds: 600);

  void _pick(_FavChoice c) {
    if (!_ready) return;
    Navigator.pop(context, c);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(1.25 * rem),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 1.25 * rem, fontWeight: FontWeight.w700, color: t.text)),
          SizedBox(height: 0.75 * rem),
          ListRow(autofocus: true, title: 'Remove from favorites', subtitle: 'You will be asked to confirm first', onTap: () => _pick(_FavChoice.remove)),
          ListRow(title: 'Open in a plugin\u2026', subtitle: 'Choose a plugin that can play or list this title', onTap: () => _pick(_FavChoice.open)),
        ]),
      ),
    );
  }
}
