import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, KeyEvent, KeyUpEvent, LogicalKeyboardKey;

import 'tokens.dart';
import 'widgets.dart' show PekFocusable;
import 'suggest.dart' show SuggestAnchor;

/// A text box in the app's look (the web UI's `ui.textInput`).
///
/// On a phone it is a plain text box. On a TV (remote control) the box is first just a thing the focus can rest on, like a
/// button: moving through a form with Up / Down passes over it without opening the on-screen keyboard (which used to pop up on
/// every box and take the arrow keys, so the focus never came out). OK / Enter starts typing; Done on the keyboard, Up / Down
/// (see [DpadEscape]) or moving the focus away ends it.
class PekField extends StatefulWidget {
  const PekField({super.key, required this.label, required this.controller, this.hint, this.obscure = false, this.onSubmitted, this.autofocus = false, this.keyboardType, this.onChanged, this.enabled = true});
  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool obscure;
  final VoidCallback? onSubmitted;
  final bool autofocus;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final bool enabled; // false: shown greyed out and cannot be edited (the email once its code has been sent)

  @override
  State<PekField> createState() => _PekFieldState();
}

class _PekFieldState extends State<PekField> {
  final FocusNode _shell = FocusNode(debugLabel: 'PekField shell'); // what the remote lands on (TV only)
  final FocusNode _edit = FocusNode(debugLabel: 'PekField text');
  bool _editing = false;

  static bool _select(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter || k == LogicalKeyboardKey.gameButtonA;

  @override
  void initState() {
    super.initState();
    _edit.addListener(() {
      // The focus left the text (Up / Down, a click elsewhere ...): typing is over, the keyboard goes with it.
      if (!_edit.hasFocus && _editing && mounted) setState(() => _editing = false);
    });
  }

  @override
  void dispose() {
    _shell.dispose();
    _edit.dispose();
    super.dispose();
  }

  void _startEditing() {
    if (!widget.enabled || _editing) return;
    setState(() => _editing = true);
    final c = widget.controller;
    c.selection = TextSelection.collapsed(offset: c.text.length);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) _edit.requestFocus();
    });
  }

  /// Typing is over: back to the resting focus on the box (the keyboard closes because the text lost the focus).
  void _stopEditing() {
    if (!_editing) return;
    setState(() => _editing = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _shell.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final tv = p.isTv;
    OutlineInputBorder border(Color c) => OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: c == Colors.transparent ? BorderSide.none : BorderSide(color: c));

    Widget field(bool ring) => TextField(
          controller: widget.controller,
          focusNode: _edit,
          obscureText: widget.obscure,
          autofocus: widget.autofocus && !tv, // on a TV the resting focus (the shell) takes the autofocus, not the keyboard
          canRequestFocus: !tv || _editing,
          enabled: widget.enabled,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: widget.keyboardType,
          textInputAction: tv ? TextInputAction.done : null,
          onChanged: widget.onChanged,
          onTapOutside: (_) {}, // a tap on a suggestion under the box must not drop the focus first
          onSubmitted: (_) {
            if (tv) _stopEditing();
            widget.onSubmitted?.call();
          },
          style: TextStyle(color: t.text),
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            labelStyle: TextStyle(color: t.textMuted),
            hintStyle: TextStyle(color: t.textMuted.withAlpha(180)),
            filled: true,
            fillColor: t.surface,
            enabledBorder: border(ring ? t.text.withAlpha(150) : Colors.transparent),
            disabledBorder: border(Colors.transparent),
            focusedBorder: border(t.text.withAlpha(ring && !_editing ? 150 : 70)),
            border: border(Colors.transparent),
          ),
        );

    Widget box;
    if (!tv) {
      // A text box keeps the arrow keys for its caret, so on a remote the focus went in and never came out (the GitHub install
      // box, the library search ...). DpadEscape lets Up / Down (and Left / Right at the ends) move on.
      box = DpadEscape(controller: widget.controller, child: field(false));
    } else {
      box = Focus(
        focusNode: _shell,
        autofocus: widget.autofocus,
        canRequestFocus: widget.enabled,
        onKeyEvent: (node, KeyEvent e) {
          if (_editing || e is! KeyDownEvent || !_select(e.logicalKey)) return KeyEventResult.ignored;
          _startEditing();
          return KeyEventResult.handled;
        },
        child: ListenableBuilder(
          listenable: _shell,
          builder: (context, _) => GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _startEditing,
            // While it is only resting, touches go to the tap above; while typing, to the text (caret, selection).
            child: IgnorePointer(ignoring: !_editing, child: DpadEscape(controller: widget.controller, child: field(_shell.hasFocus))),
          ),
        ),
      );
    }
    return Padding(padding: EdgeInsets.only(bottom: 0.75 * p.rem), child: box);
  }
}

/// A text box takes the arrow keys for its caret, so on a remote the focus got stuck in it. Up and Down always leave the
/// box; Left leaves it when the caret is at the start (or the box is empty) and Right when it is at the end. The move is a
/// normal focus move, so it lands on whatever is next to the box (a suggestion list under it, the next button ...).
class DpadEscape extends StatelessWidget {
  const DpadEscape({super.key, required this.controller, required this.child});
  final TextEditingController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, KeyEvent e) {
        if (e is KeyUpEvent) return KeyEventResult.ignored;
        final k = e.logicalKey;
        final sel = controller.selection;
        final atStart = !sel.isValid || (sel.isCollapsed && sel.baseOffset <= 0);
        final atEnd = !sel.isValid || (sel.isCollapsed && sel.baseOffset >= controller.text.length);
        TraversalDirection? d;
        if (k == LogicalKeyboardKey.arrowDown) {
          // A suggestions list under the box (search bars): go straight onto its first row.
          if (e is KeyDownEvent && SuggestAnchor.focusFirst(context)) return KeyEventResult.handled;
          d = TraversalDirection.down;
        } else if (k == LogicalKeyboardKey.arrowUp) {
          d = TraversalDirection.up;
        } else if (k == LogicalKeyboardKey.arrowLeft && atStart) {
          d = TraversalDirection.left;
        } else if (k == LogicalKeyboardKey.arrowRight && atEnd) {
          d = TraversalDirection.right;
        }
        if (d == null) return KeyEventResult.ignored;
        if (e is KeyDownEvent) FocusManager.instance.primaryFocus?.focusInDirection(d);
        return KeyEventResult.handled;
      },
      child: child,
    );
  }
}

/// A drop-down list in the app's look: a field that shows the current choice and opens a menu right under it.
/// Works with the D-pad (the menu's rows take focus) and a long list scrolls inside the menu.
class PekDropdown<T> extends StatelessWidget {
  const PekDropdown({super.key, required this.value, required this.items, required this.onChanged, this.label});

  /// The current choice (must be one of [items], otherwise the field shows nothing).
  final T value;

  /// (value, text shown) in the order they are listed.
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;
  final String? label;

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final rect = RelativeRect.fromLTRB(topLeft.dx, topLeft.dy + box.size.height + 4, overlay.size.width - topLeft.dx - box.size.width, 0);
    final p = context.pek;
    final picked = await showMenu<int>(
      context: context,
      position: rect,
      color: p.tokens.glassStrong,
      surfaceTintColor: Colors.transparent,
      constraints: BoxConstraints(minWidth: box.size.width, maxWidth: box.size.width, maxHeight: (overlay.size.height * 0.5).clamp(160.0, 420.0)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: p.tokens.border)),
      items: [
        for (var i = 0; i < items.length; i++)
          PopupMenuItem<int>(
            value: i,
            height: p.isTv ? 3 * p.rem : 2.75 * p.rem,
            child: Row(children: [
              Expanded(child: Text(items[i].$2, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: p.rem, fontWeight: items[i].$1 == value ? FontWeight.w700 : FontWeight.w500, color: items[i].$1 == value ? p.tokens.accent : p.tokens.text))),
              if (items[i].$1 == value) Icon(Icons.check, size: 1.1 * p.rem, color: p.tokens.accent),
            ]),
          ),
      ],
    );
    if (picked != null && items[picked].$1 != value) onChanged(items[picked].$1);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    var shown = '';
    for (final e in items) {
      if (e.$1 == value) shown = e.$2;
    }
    return Semantics(
      button: true,
      label: label == null ? shown : '$label: $shown',
      child: PekFocusable(
        onTap: () => _open(context),
        radius: 14,
        background: t.surface,
        borderColor: t.border,
        minHeight: p.isTv ? 3 * rem : 2.75 * rem,
        alignment: Alignment.centerLeft,
        padding: EdgeInsets.symmetric(horizontal: 1.1 * rem, vertical: 0.5 * rem),
        child: Row(children: [
          Expanded(child: Text(shown, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: rem, color: t.text))),
          Icon(Icons.arrow_drop_down, color: t.textMuted),
        ]),
      ),
    );
  }
}
