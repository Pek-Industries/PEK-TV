import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pek_tv_ui/src/account_gate.dart';
import 'package:pek_tv_ui/src/store.dart';
import 'package:pek_tv_ui/src/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The account gate's screens, set straight from AccountGate's state (no storage, no network), and its shield over the app.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late int taps;

  Widget app() => MaterialApp(
        home: PekRoot(
          isPhone: true,
          child: Stack(fit: StackFit.expand, children: [
            AccountGate.shield(Scaffold(body: Center(child: ElevatedButton(onPressed: () => taps++, child: const Text('Behind'))))),
            const AccountGateLayer(),
          ]),
        ),
      );

  void show(GateState s, {String reason = '', bool selfHosted = true}) {
    AccountGate.reason = reason;
    AccountGate.serverName = selfHosted ? 'Living Room PC' : 'PEK Cloud';
    AccountGate.selfHosted = selfHosted;
    AccountGate.state.value = s;
  }

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({}); // the theme (PekRoot) reads a setting; an empty in-memory store is enough
    await Store.init();
  });

  setUp(() {
    taps = 0;
    AccountGate.state.value = GateState.none;
    AccountGate.nextTry.value = null;
  });

  Future<void> done(WidgetTester tester) async {
    AccountGate.state.value = GateState.none;
    await tester.pumpWidget(const SizedBox()); // stops the gate's countdown timer
  }

  testWidgets('nothing in front of the app while the account is fine', (tester) async {
    await tester.pumpWidget(app());
    expect(find.text('Can’t access the server right now'), findsNothing);
    await tester.tap(find.text('Behind'));
    expect(taps, 1);
    await done(tester);
  });

  testWidgets('a self-hosted server that does not answer blocks the app and names it', (tester) async {
    await tester.pumpWidget(app());
    show(GateState.unreachable);
    AccountGate.nextTry.value = DateTime.now().add(const Duration(seconds: 30));
    await tester.pump();
    expect(find.text('Can’t access the server right now'), findsOneWidget);
    expect(find.textContaining('Living Room PC isn’t answering'), findsOneWidget);
    expect(find.textContaining('Trying again in'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    // The app behind it cannot be tapped.
    await tester.tap(find.text('Behind'), warnIfMissed: false);
    expect(taps, 0);
    await done(tester);
  });

  testWidgets('PEK Cloud not answering says so', (tester) async {
    await tester.pumpWidget(app());
    show(GateState.unreachable, selfHosted: false);
    await tester.pump();
    expect(find.textContaining('PEK Cloud isn’t answering'), findsOneWidget);
    await done(tester);
  });

  testWidgets('signing out while blocked asks first, on the gate itself', (tester) async {
    await tester.pumpWidget(app());
    show(GateState.unreachable);
    await tester.pump();
    await tester.tap(find.text('Sign out'));
    await tester.pump();
    expect(find.text('Sign out on this device?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(find.text('Can’t access the server right now'), findsOneWidget);
    await done(tester);
  });

  testWidgets('removed from the server: told once, OK lets them back into the app', (tester) async {
    await tester.pumpWidget(app());
    show(GateState.ended, reason: 'account_removed');
    await tester.pump();
    expect(find.text('You were removed from Living Room PC'), findsOneWidget);
    expect(find.text('Sign in'), findsNothing);
    await tester.tap(find.text('OK'));
    await tester.pump();
    expect(AccountGate.state.value, GateState.none);
    await tester.tap(find.text('Behind'));
    expect(taps, 1);
    await done(tester);
  });

  testWidgets('password changed and signed out by the owner offer to sign in again', (tester) async {
    await tester.pumpWidget(app());
    show(GateState.ended, reason: 'password_changed');
    await tester.pump();
    expect(find.text('Your password was changed'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Later'), findsOneWidget);
    show(GateState.ended, reason: 'signed_out_by_owner');
    AccountGate.state.value = GateState.none;
    await tester.pump();
    show(GateState.ended, reason: 'signed_out_by_owner');
    await tester.pump();
    expect(find.text('You were signed out'), findsOneWidget);
    expect(find.textContaining('The owner of Living Room PC signed your account out'), findsOneWidget);
    await done(tester);
  });

  testWidgets('a new server key: disconnected, with pair again', (tester) async {
    await tester.pumpWidget(app());
    show(GateState.unpaired);
    await tester.pump();
    expect(find.text('This device was disconnected from Living Room PC'), findsOneWidget);
    expect(find.text('Pair again'), findsOneWidget);
    expect(find.text('Use this device instead'), findsOneWidget);
    await done(tester);
  });
}
