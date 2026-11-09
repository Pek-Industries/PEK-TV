import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pek_tv_ui/src/nav_sound.dart';
import 'package:pek_tv_ui/src/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The navigation sounds (nav_sound.dart): what is sent to the host, and when it is held back. The host is replaced by a
/// recorder on the `pek/host` channel, so no audio is involved. The limits are in real milliseconds, hence the short waits.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final sent = <Map<Object?, Object?>>[];
  const wait = Duration(milliseconds: 30); // lets the channel call and the microtask of select() finish
  const apart = Duration(milliseconds: 400); // longer than every "too soon" window in NavSounds

  Future<void> settle() => Future<void>.delayed(wait);

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Store.init();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('pek/host'), (call) async {
      if (call.method == 'navSound') sent.add(Map<Object?, Object?>.from(call.arguments as Map));
      return null;
    });
  });

  setUp(() async {
    sent.clear();
    await Future<void>.delayed(apart); // so the previous test's sounds cannot hold this one back
  });

  test('on by default, at Medium', () {
    expect(NavSounds.enabled, isTrue);
    expect(NavSounds.level, NavSounds.defaultLevel);
  });

  test('select sends the select sound at the chosen volume', () async {
    await NavSounds.setLevel(3);
    NavSounds.select();
    await settle();
    expect(sent, hasLength(1));
    expect(sent.single['kind'], 1);
    expect(sent.single['volume'], 1.0);
    await NavSounds.setLevel(NavSounds.defaultLevel);
  });

  test('the volume that is set by the tap itself is the one heard', () async {
    NavSounds.select(); // what PekFocusable does first ...
    await NavSounds.setLevel(1); // ... and then the button's own handler runs
    await settle();
    expect(sent.single['volume'], 0.35);
    await NavSounds.setLevel(NavSounds.defaultLevel);
  });

  test('a back straight after a select stays quiet, a lone back plays', () async {
    NavSounds.select();
    NavSounds.back(); // a dialog closing because of the tap
    await settle();
    expect(sent.map((m) => m['kind']), [1]);

    sent.clear();
    await Future<void>.delayed(apart);
    NavSounds.back();
    await settle();
    expect(sent.map((m) => m['kind']), [2]);
  });

  test('a move is not played right after a select (the new screen focusing itself)', () async {
    NavSounds.select();
    NavSounds.move();
    await settle();
    expect(sent.map((m) => m['kind']), [1]);

    sent.clear();
    await Future<void>.delayed(apart);
    NavSounds.move();
    await settle();
    expect(sent.map((m) => m['kind']), [0]);
  });

  test('a held arrow key does not buzz', () async {
    NavSounds.move();
    NavSounds.move();
    NavSounds.move();
    await settle();
    expect(sent, hasLength(1));
  });

  test('nothing plays while muted (the video player), and again once it is unmuted', () async {
    NavSounds.mute();
    NavSounds.select();
    await settle();
    expect(sent, isEmpty);
    NavSounds.unmute();

    await Future<void>.delayed(apart);
    NavSounds.select();
    await settle();
    expect(sent, hasLength(1));
  });

  test('nothing plays when turned off, and the choice is kept', () async {
    await NavSounds.setEnabled(false);
    expect(Store.strGet('pek_nav_sound', scoped: false), 'off');
    NavSounds.select();
    NavSounds.move();
    NavSounds.back();
    await settle();
    expect(sent, isEmpty);

    await NavSounds.setEnabled(true);
    expect(Store.strGet('pek_nav_sound', scoped: false), 'on');
  });
}
