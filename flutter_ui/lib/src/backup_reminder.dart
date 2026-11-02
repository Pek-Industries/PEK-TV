import 'package:flutter/material.dart';

import 'cloud.dart';
import 'plan_ui.dart' show openSignUpPage, showUpgradeDialog;
import 'store.dart';

/// "Your data is not backed up": shown to people on a free account (and to people not signed in at all), at most once every 6 hours, the next time the app is
/// open (on start, when it comes back to the front, or while it stays open).
///
/// For a signed-in account nothing is shown unless the cloud itself has just confirmed it is on the free plan: a paid
/// account (or one that was paid on the website a minute ago) never sees it, and if the plan cannot be checked (offline)
/// nothing is shown and the next check tries again. Someone not signed in has no plan to check and is told to create an account. The 6 hours only start once the reminder was actually shown.
class BackupReminder {
  BackupReminder._();

  static const _kLast = 'pek_backup_reminder_at'; // this device, not per profile
  static const every = Duration(hours: 6);
  static bool _busy = false;

  static int get _last => int.tryParse(Store.strGet(_kLast, scoped: false) ?? '') ?? 0;

  /// Call whenever the app opens or comes back. [context] is the shell's: the reminder waits while another screen (the
  /// player, a plugin) is on top, so it never lands over a video.
  static Future<void> maybeShow(BuildContext context) async {
    if (_busy) return;
    if (Cloud.entitled) return; // paid accounts are done here
    if (Cloud.lapseState != 'none') return; // a lapsed plan has its own notice (lapse_notice.dart)
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _last < every.inMilliseconds) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return;
    _busy = true;
    try {
      // Double check with the cloud right now before saying anything.
      final linked = Cloud.linked;
      if (linked) {
        final paid = await Cloud.refreshPlan(force: true);
        if (paid || !Cloud.planVerified || Cloud.entitled) return;
      }
      if (!context.mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
      await Store.strSet(_kLast, '${DateTime.now().millisecondsSinceEpoch}', scoped: false);
      final upgrade = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Your data is not backed up'),
          content: Text(
            'Your watch history, resume points, favorites and ratings are saved on this device only. '
            'If you clear the app, reinstall it or lose this device, they are gone, and your other devices will not have them.\n\n'
            '${linked ? 'PEK Cloud backs them up and keeps all your devices in sync.' : 'Create an account on the website, sign in here and get PEK Cloud to back them up and keep all your devices in sync.'}',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Remind me later')),
            TextButton(autofocus: true, onPressed: () => Navigator.pop(c, true), child: Text(linked ? 'Get PEK Cloud' : 'Create an account')),
          ],
        ),
      );
      if (upgrade != true || !context.mounted) return;
      if (linked) {
        await showUpgradeDialog(context, why: 'Back up your watch history and resume points.');
      } else {
        await openSignUpPage(context);
      }
    } finally {
      _busy = false;
    }
  }
}
