import 'package:flutter/material.dart';

import 'cloud.dart';
import 'plan_ui.dart' show showUpgradeDialog;
import 'store.dart';

/// Tells people whose PEK Cloud plan lapsed what is happening to their account, once every 24 hours while it lasts:
///
///  1. `grace`: the renewal did not go through; PEK Cloud stays on until the grace period ends. Pay on the website to keep it.
///  2. `deletion`: the grace is over, cloud backup is off, and the account and its data will be deleted on a date unless a plan is bought before then.
///  3. After that date the cloud has deleted the account. The next time this device asks, it is told once and signed out.
///
/// Like [BackupReminder] it only speaks when the shell itself is the screen in front, so it never lands over a movie, an episode, the music
/// player or a plugin screen; if one is open it simply waits for the next check (on start, when the app comes back, every 30 minutes).
/// The 24 hours only start once a notice was actually shown. Paying on the website clears everything: the cloud then reports `none`.
class LapseNotice {
  LapseNotice._();

  static const _kLast = 'pek_lapse_notice_at'; // this device, not per profile
  static const every = Duration(hours: 24);
  static bool _busy = false;

  static int get _last => int.tryParse(Store.strGet(_kLast, scoped: false) ?? '') ?? 0;

  static bool _front(BuildContext context) => context.mounted && (ModalRoute.of(context)?.isCurrent ?? false);

  static String _date(int ms) {
    const m = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${m[d.month - 1]} ${d.day}, ${d.year}';
  }

  /// "3 days", "1 day", "less than a day".
  static String _left(int ms) {
    final days = (ms - DateTime.now().millisecondsSinceEpoch) / Duration.millisecondsPerDay;
    if (days < 1) return 'less than a day';
    final n = days.ceil();
    return n == 1 ? '1 day' : '$n days';
  }

  static Future<void> maybeShow(BuildContext context) async {
    if (_busy) return;
    if (!_front(context)) return; // never over a video: wait for the next check
    _busy = true;
    try {
      // The account is already gone: say so once (this is not repeated).
      if (Cloud.goneNoticePending) {
        await _showGone(context);
        return;
      }
      if (!Cloud.linked) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _last < every.inMilliseconds) return;
      // Ask the cloud right now: the plan may have been paid a minute ago, or the account deleted since the last look.
      await Cloud.refreshPlan(force: true);
      if (!_front(context)) return;
      if (Cloud.goneNoticePending) {
        await _showGone(context);
        return;
      }
      if (!Cloud.planVerified) return; // offline: say nothing now, the next check tries again
      final state = Cloud.lapseState;
      if (state == 'none') return;
      await Store.strSet(_kLast, '${DateTime.now().millisecondsSinceEpoch}', scoped: false);
      final String title, body;
      if (state == 'grace') {
        title = 'Your PEK Cloud payment is overdue';
        body = 'Your PEK Cloud renewal did not go through. Cloud backup stays on until ${_date(Cloud.graceEnds)} (${_left(Cloud.graceEnds)} left). '
            'Pay on the website before then to keep it. After that, cloud backup turns off and your account and everything stored in it is scheduled for deletion unless you subscribe again.';
      } else {
        title = 'Your PEK Cloud data will be deleted';
        body = 'Your PEK Cloud plan has ended and cloud backup is off. Your account and everything stored in it (profiles, watch history, resume points and plugin backups) '
            'will be permanently deleted on ${_date(Cloud.deleteAt)} (${_left(Cloud.deleteAt)} left) unless you subscribe again before then. Deleted data cannot be recovered.';
      }
      final again = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Remind me later')),
            TextButton(autofocus: true, onPressed: () => Navigator.pop(c, true), child: Text(state == 'grace' ? 'Pay now' : 'Subscribe again')),
          ],
        ),
      );
      if (again == true && context.mounted) {
        await showUpgradeDialog(context, why: state == 'grace' ? 'Pay to keep your cloud backup on.' : 'Subscribe again to keep your account and data.');
      }
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
          'Your plan was not renewed in time, so your PEK Cloud account and all the data stored in it were permanently deleted. This cannot be undone and the data cannot be recovered. '
          'You have been signed out here. You can create a new account on the website at any time.',
        ),
        actions: [TextButton(autofocus: true, onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );
  }
}
