import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'fields.dart' show DpadEscape;
import 'tokens.dart';
import 'widgets.dart';

/// Opens the Fix match page for one movie or show: search TMDb, pick the right entry, and PEK TV remembers the choice (poster and
/// synopsis; see backend `/api/match/*` and FIX_MATCH.md). [key] is a movie's id, or a show's title as the library lists it.
/// Completes with true when the match was changed.
Future<bool> openFixMatch(BuildContext context, {required bool movie, required String key, required String title, int year = 0}) async {
  final changed = await Navigator.push<bool>(
    context,
    MaterialPageRoute<bool>(builder: (_) => FixMatchScreen(movie: movie, itemKey: key, title: title, year: year)),
  );
  return changed ?? false;
}

/// "Battlestar Galactica (2003)" -> ("Battlestar Galactica", 2003). A show that shares its name with another one carries its
/// year in the library title; the search box wants them apart.
({String name, int year}) splitTitleYear(String title, int year) {
  final m = RegExp(r'^(.*?)\s*\(\s*((?:19|20)\d{2})\s*\)\s*$').firstMatch(title);
  if (m != null && m[1]!.trim().isNotEmpty) return (name: m[1]!.trim(), year: year > 0 ? year : int.parse(m[2]!));
  return (name: title.trim(), year: year);
}

class FixMatchScreen extends StatefulWidget {
  const FixMatchScreen({super.key, required this.movie, required this.itemKey, required this.title, this.year = 0});
  final bool movie;
  final String itemKey;
  final String title;
  final int year;

  @override
  State<FixMatchScreen> createState() => _FixMatchScreenState();
}

class _FixMatchScreenState extends State<FixMatchScreen> {
  late final TextEditingController _q;
  late final TextEditingController _y;
  final FocusNode _qFocus = FocusNode();

  List<MatchCandidate>? _results; // null = nothing asked yet
  MatchCandidate? _pinned; // the match the person chose earlier, if any
  bool _searching = false;
  String _error = '';
  String _busyId = ''; // the row being saved ('' = none; 'auto' = going back to the automatic match)
  int _ticket = 0; // so a slow answer to an older search cannot replace a newer one

  String get _kind => widget.movie ? 'movie' : 'show';

  @override
  void initState() {
    super.initState();
    final parts = splitTitleYear(widget.title, widget.year);
    _q = TextEditingController(text: parts.name);
    _y = TextEditingController(text: parts.year > 0 ? '${parts.year}' : '');
    unawaited(_loadPinned());
    unawaited(_search());
  }

  @override
  void dispose() {
    _q.dispose();
    _y.dispose();
    _qFocus.dispose();
    super.dispose();
  }

  Future<void> _loadPinned() async {
    final pinned = await Api.matchState(_kind, widget.itemKey);
    if (mounted) setState(() => _pinned = pinned);
  }

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.isEmpty) return;
    final ticket = ++_ticket;
    setState(() {
      _searching = true;
      _error = '';
    });
    try {
      final list = await Api.matchSearch(_kind, q, year: int.tryParse(_y.text.trim()) ?? 0);
      if (!mounted || ticket != _ticket) return;
      setState(() {
        _results = list;
        _searching = false;
      });
    } catch (_) {
      if (!mounted || ticket != _ticket) return;
      setState(() {
        _searching = false;
        _error = 'Could not reach TMDb. Check the connection and try again.';
      });
    }
  }

  void _say(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  Future<void> _choose(MatchCandidate c) async {
    if (_busyId.isNotEmpty) return;
    setState(() => _busyId = c.id);
    try {
      await Api.matchPin(_kind, widget.itemKey, c);
      if (!mounted) return;
      _say('Matched to ${c.label}');
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyId = '');
      _say(e is ApiError ? e.message : 'Could not save the match.');
    }
  }

  Future<void> _useAutomatic() async {
    if (_busyId.isNotEmpty) return;
    setState(() => _busyId = 'auto');
    try {
      await Api.matchUnpin(_kind, widget.itemKey);
      if (!mounted) return;
      _say('Using the automatic match again');
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyId = '');
      _say(e is ApiError ? e.message : 'Could not change the match.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final pad = EdgeInsets.fromLTRB(rem + p.safeX, 0, rem + p.safeX, rem);
    final results = _results;

    Widget box(TextEditingController c, {required String hint, bool number = false, FocusNode? focus}) => DpadEscape(
          controller: c,
          child: TextField(
            controller: c,
            focusNode: focus,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: number ? TextInputType.number : TextInputType.text,
            inputFormatters: number ? [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)] : null,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            style: TextStyle(color: t.text, fontSize: rem),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(color: t.textMuted.withAlpha(200)),
              filled: true,
              fillColor: t.bg.withAlpha(150),
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(t.radius)),
            ),
          ),
        );

    final header = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(widget.title, style: TextStyle(fontSize: 1.3 * rem, fontWeight: FontWeight.w800)),
      SizedBox(height: 0.25 * rem),
      Text(
        _pinned != null
            ? 'Matched by you to ${_pinned!.label}.'
            : 'Matched automatically. Pick the right ${widget.movie ? 'film' : 'show'} below if it is wrong.',
        style: TextStyle(color: t.textMuted, height: 1.3),
      ),
      SizedBox(height: 0.75 * rem),
      Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(child: box(_q, hint: widget.movie ? 'Search movies' : 'Search shows', focus: _qFocus)),
        SizedBox(width: 0.5 * rem),
        SizedBox(width: 5.5 * rem, child: box(_y, hint: 'Year', number: true)),
        SizedBox(width: 0.5 * rem),
        PekButton(compact: true, shrink: true, label: 'Search', primary: true, onTap: _searching ? null : _search),
      ]),
      if (_pinned != null) ...[
        SizedBox(height: 0.75 * rem),
        Align(
          alignment: Alignment.centerLeft,
          child: PekButton(compact: true, shrink: true, label: _busyId == 'auto' ? 'Working\u2026' : 'Use the automatic match', onTap: _busyId.isEmpty ? _useAutomatic : null),
        ),
      ],
      SizedBox(height: 0.75 * rem),
    ]);

    // One list: the search box on top, then the rows, or a short status line when there is nothing to pick from.
    final Widget status;
    if (_searching && results == null) {
      status = Padding(padding: EdgeInsets.symmetric(vertical: 3 * rem), child: const Center(child: CircularProgressIndicator()));
    } else if (_error.isNotEmpty && results == null) {
      status = _message(_error, retry: true);
    } else if (results != null && results.isEmpty) {
      status = _message('Nothing found. Try fewer words, or leave the year empty.');
    } else {
      status = const SizedBox.shrink();
    }
    final rows = results ?? const <MatchCandidate>[];

    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, foregroundColor: t.text, title: const Text('Fix match')),
      body: Column(children: [
        // A new search over an old list: the old rows stay until the answer arrives, with a thin bar on top.
        SizedBox(height: 3, child: _searching && results != null ? const LinearProgressIndicator(minHeight: 3) : null),
        Expanded(
          child: ListView(padding: pad, children: [
            header,
            status,
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) SizedBox(height: 0.5 * rem),
              _row(rows[i], autofocus: i == 0),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _message(String text, {bool retry = false}) {
    final p = context.pek;
    final rem = p.rem;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 2 * rem),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(text, textAlign: TextAlign.center, style: TextStyle(color: p.tokens.textMuted, height: 1.4)),
        if (retry) ...[
          SizedBox(height: 0.75 * rem),
          PekButton(compact: true, shrink: true, label: 'Try again', primary: true, onTap: _search),
        ],
      ]),
    );
  }

  Widget _row(MatchCandidate c, {bool autofocus = false}) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final isCurrent = _pinned?.id == c.id;
    final busy = _busyId == c.id;
    final thumbW = (p.narrow ? 4.2 : 5.5) * rem;
    final thumb = SizedBox(
      width: thumbW,
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(t.radius / 2),
          child: c.poster.isEmpty
              ? ColoredBox(color: t.bg, child: Icon(Icons.movie_outlined, color: t.textMuted))
              : Image.network(c.poster, fit: BoxFit.cover, errorBuilder: (_, __, ___) => ColoredBox(color: t.bg, child: Icon(Icons.broken_image_outlined, color: t.textMuted))),
        ),
      ),
    );
    return PekFocusable(
      radius: 12,
      autofocus: autofocus,
      background: t.surface,
      borderColor: isCurrent ? t.accent : t.border,
      padding: EdgeInsets.all(0.6 * rem),
      onTap: _busyId.isEmpty ? () => _choose(c) : null,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        thumb,
        SizedBox(width: 0.75 * rem),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(c.label, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 1.05 * rem)),
            if (c.overview.isNotEmpty) ...[
              SizedBox(height: 0.25 * rem),
              Text(c.overview, maxLines: p.narrow ? 3 : 4, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.textMuted, height: 1.35, fontSize: 0.9 * rem)),
            ],
          ]),
        ),
        if (busy)
          Padding(padding: EdgeInsets.only(left: 0.5 * rem), child: SizedBox(width: 1.25 * rem, height: 1.25 * rem, child: const CircularProgressIndicator(strokeWidth: 2)))
        else if (isCurrent)
          Padding(padding: EdgeInsets.only(left: 0.5 * rem), child: Icon(Icons.check_circle, color: t.accent, size: 1.25 * rem)),
      ]),
    );
  }
}
