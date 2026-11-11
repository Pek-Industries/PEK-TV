import 'package:flutter/material.dart';

import 'cloud.dart';
import 'common.dart';
import 'plan_ui.dart' show showUpgradeDialog;
import 'tokens.dart';

/// Keeps the lapsed-plan state fresh and shows the one-time "your account was deleted" box.
///
/// The warning itself is the [LapseBanner] at the top of the shell: it stays there for as long as the plan is lapsed (grace, then ended) and
/// goes away by itself once a plan is bought. It lives inside the shell, so it is never over a movie, an episode, the music player or a
/// plugin screen. A lapsed plan never deletes anything: after the grace, cloud backup is off and only the main profile can be used; buying a
/// plan again unlocks the other profiles and backup continues for everything. The box below is only for an account that was deleted (on
/// another device or the website): the next time this device asks, it is told once and signed out.
class LapseNotice {
  LapseNotice._();

  static bool _busy = false;

  static bool _front(BuildContext context) => context.mounted && (ModalRoute.of(context)?.isCurrent ?? false);

  /// Called on start, when the app comes back and every 30 minutes: asks the cloud (at most once a minute) so the banner is current.
  static Future<void> maybeShow(BuildContext context) async {
    if (_busy) return;
    _busy = true;
    try {
      if (Cloud.goneNoticePending) {
        if (_front(context)) await _showGone(context);
        return;
      }
      if (!Cloud.linked) return;
      await Cloud.refreshPlan(); // the plan may have been paid a minute ago, or the account deleted since the last look
      if (Cloud.goneNoticePending && _front(context)) await _showGone(context);
    } finally {
      _busy = false;
    }
  }

  static Future<void> _showGone(BuildContext context) async {
    if (!_front(context)) return;
    await Cloud.clearGoneNotice();
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Your PEK Cloud account was deleted'),
        content: const Text(
          'This PEK Cloud account was deleted, so you have been signed out here. You can create a new account on the website at any time.',
        ),
        actions: [TextButton(autofocus: true, onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );
  }
}

/// The banner across the top of the app while a PEK Cloud plan is lapsed: amber while the renewal is overdue (grace), red once the plan has
/// ended (backup off, main profile only, nothing deleted). One button opens the upgrade dialog; the X hides it until the app is started
/// again (or the state gets worse, grace -> ended).
class LapseBanner {
  LapseBanner._();

  static final ValueNotifier<String> _hidden = ValueNotifier('');

  static String _date(int ms) {
    const m = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${m[d.month - 1]} ${d.day}, ${d.year}';
  }

  static String _left(int ms) {
    final days = (ms - DateTime.now().millisecondsSinceEpoch) / Duration.millisecondsPerDay;
    if (days < 1) return 'less than a day';
    final n = days.ceil();
    return n == 1 ? '1 day' : '$n days';
  }

  /// Puts the banner above [child]. The tree has the same shape with and without the banner, so the pages below keep their state.
  static Widget wrap({required Widget child}) => ListenableBuilder(
        listenable: Listenable.merge([Cloud.changes, _hidden]),
        builder: (context, _) {
          final state = Cloud.lapseState;
          final show = Cloud.linked && state != 'none' && _hidden.value != state;
          return Column(
            children: [
              if (show) _bar(context, state) else const SizedBox.shrink(),
              Expanded(child: MediaQuery.removePadding(context: context, removeTop: show, child: child)),
            ],
          );
        },
      );

  static Widget _bar(BuildContext context, String state) {
    final p = context.pek;
    final rem = p.rem;
    final grace = state == 'grace';
    final top = p.sidebar ? p.safeY : MediaQuery.paddingOf(context).top;
    final title = grace ? 'Payment overdue' : 'Your PEK Cloud plan has ended';
    final body = grace
        ? 'PEK Cloud stays on until ${_date(Cloud.graceEnds)} (${_left(Cloud.graceEnds)} left). Pay now to keep your cloud backup and all your profiles.'
        : 'Cloud backup is off and only your main profile is available. Your data is kept: subscribe again and your other profiles unlock and backup continues for everything.';
    final why = grace ? 'Pay to keep your cloud backup on.' : 'Subscribe again to unlock your other profiles and turn cloud backup back on. Your data is kept.';
    const white = Colors.white;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: TextStyle(fontSize: 1.0 * rem, fontWeight: FontWeight.w800, color: white)),
        SizedBox(height: 0.15 * rem),
        Text(body, style: TextStyle(fontSize: 0.85 * rem, color: white)),
      ],
    );
    final action = TextButton(
      style: TextButton.styleFrom(
        foregroundColor: grace ? const Color(0xFF92400E) : const Color(0xFF991B1B),
        backgroundColor: white,
        padding: EdgeInsets.symmetric(horizontal: 1.0 * rem, vertical: 0.4 * rem),
      ),
      onPressed: () => showUpgradeDialog(context, why: why),
      child: Text(grace ? 'Pay now' : 'Subscribe again', style: TextStyle(fontSize: 0.85 * rem, fontWeight: FontWeight.w800)),
    );
    final close = IconButton(
      tooltip: 'Hide until the app restarts',
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.close, color: white),
      onPressed: () => _hidden.value = state,
    );
    return Container(
      width: double.infinity,
      color: grace ? const Color(0xFFB45309) : const Color(0xFFB91C1C),
      padding: EdgeInsets.fromLTRB(rem + (p.sidebar ? p.safeX : 0), top + 0.6 * rem, 0.4 * rem, 0.6 * rem),
      child: p.sidebar
          ? Row(children: [
              const Icon(Icons.warning_amber_rounded, color: white),
              SizedBox(width: 0.8 * rem),
              Expanded(child: text),
              SizedBox(width: rem),
              action,
              close,
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.warning_amber_rounded, color: white)),
                SizedBox(width: 0.7 * rem),
                Expanded(child: text),
                close,
              ]),
              SizedBox(height: 0.4 * rem),
              Align(alignment: Alignment.centerLeft, child: Padding(padding: EdgeInsets.only(left: 2 * rem), child: action)),
            ]),
    );
  }
}
