import 'deep_link.dart';
import 'pin_grid.dart';
import 'plugin_pins.dart';
import 'plugin_updates.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'activity.dart';
import 'backup_reminder.dart';
import 'lapse_notice.dart';
import 'api.dart' show Api, PluginInfo;
import 'cloud.dart';
import 'cloud_usage.dart';
import 'common.dart';
import 'dashboard.dart';
import 'library.dart';
import 'layouts.dart';
import 'library_pages.dart';
import 'mpv.dart';
import 'music.dart';
import 'music_mode.dart';
import 'news.dart';
import 'pages.dart';
import 'plugin_backup.dart';
import 'discord.dart';
import 'plugin_hooks.dart';
import 'plugin_host.dart' show PluginBack, PluginHost;
import 'plugin_store_ui.dart' show PluginPicture;
import 'plugin_ui.dart';
import 'skin_button.dart';
import 'skin_layout.dart';
import 'skins.dart' show Skins;
import 'store.dart';
import 'tokens.dart';
import 'tv_nav.dart';
import 'weather.dart' show Weather;
import 'widgets.dart';

/// NAV_ITEMS in app_config.js. Watch History also holds what Resume Watching used to; Updates is the news feed.
const _navItems = <(String, String)>[
  ('dashboard', 'Dashboard'),
  ('movies', 'Movies'),
  ('shows', 'TV Shows'),
  ('music', 'Music'),
  ('updates', 'Updates'),
  ('search', 'Search'),
  ('history', 'Watch History'),
  ('favorites', 'Favorites'),
  ('duplicates', 'Duplicates'),
  ('unknown', 'Unknown'),
  ('plugins', 'Plugins'),
  ('settings', 'Settings'),
];

/// The pages you swipe between on a phone, in order. "More" is a page of its own (not a pop-up sheet): it holds every
/// other screen as a tile, and a tap opens that screen on top.
const _swipePages = ['dashboard', 'movies', 'shows', 'music', 'updates', 'more'];

/// Music mode (Settings > Mode): the same shell with four music pages instead.
const _musicPages = ['mhome', 'msearch', 'mlibrary', 'msettings'];
const _musicNav = <(String, String)>[('mhome', 'Home'), ('msearch', 'Search'), ('mlibrary', 'Your Library'), ('msettings', 'Settings')];
const _swipeIcon = {'dashboard': Icons.home_outlined, 'movies': Icons.movie_outlined, 'shows': Icons.tv_outlined, 'music': Icons.music_note_outlined, 'updates': Icons.campaign_outlined, 'more': Icons.more_horiz, 'mhome': Icons.home_outlined, 'msearch': Icons.search, 'mlibrary': Icons.library_music_outlined, 'msettings': Icons.settings_outlined};
const _swipeLabel = {'dashboard': 'Home', 'movies': 'Movies', 'shows': 'Shows', 'music': 'Music', 'updates': 'Updates', 'more': 'More', 'mhome': 'Home', 'msearch': 'Search', 'mlibrary': 'Your Library', 'msettings': 'Settings'};

/// Everything that is not a swipe page.
const _moreIds = ['search', 'history', 'favorites', 'duplicates', 'unknown', 'plugins', 'settings'];

String _titleOf(String id) => _navItems.firstWhere((e) => e.$1 == id, orElse: () => ('', 'PEK TV')).$2;

/// `.pek-shell`: on phones and tablets the pages sit side by side in a PageView (swipe left / right, or tap the bottom
/// bar); on a TV the left sidebar switches the content, because a remote has no swipe.
class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final PageController _pager = PageController();
  int _page = 0; // phone: index into _swipePages
  final ValueNotifier<int> _pageN = ValueNotifier(0); // only the tab bar listens, so a swipe does not rebuild every page
  // Music mode is read once: switching it rebuilds the whole shell (main.dart keys it on the mode).
  final bool _music = Store.musicMode;
  String get _home => _music ? 'mhome' : 'dashboard';
  /// The pages in the order of the tab bar: the app's own, with the skin's order and removed pages applied (skin_layout.dart).
  /// The home page and "More" (music mode: Home and Settings) always stay, so every screen can still be reached.
  List<String> get _pages => Skins.layout.nav.arrange(_music ? _musicPages : _swipePages, keep: _music ? const {'mhome', 'msettings'} : const {'dashboard', 'more'});
  late String _tab = _home; // TV: sidebar selection
  Timer? _syncTimer;
  Timer? _backupTimer;
  Timer? _reminderTimer;

  void _remind() {
    if (!mounted) return;
    // The lapsed-plan notice goes first (and a lapsed account is skipped by the backup reminder), so the banner and the backup box never compete.
    unawaited(LapseNotice.maybeShow(context).then((_) {
      if (mounted) unawaited(BackupReminder.maybeShow(context));
    }));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) Future<void>.delayed(const Duration(seconds: 2), _remind); // back in front: it may be time
  }

  // A plugin was installed, updated or removed: back up a moment later (lets a removal reach the cloud first).
  void _backupSoon() {
    _backupTimer?.cancel();
    _backupTimer = Timer(const Duration(seconds: 4), () {
      if (Cloud.linked) unawaited(PluginBackup.run());
    });
  }
  List<PluginInfo> _pluginScreens = const []; // installed plugins that have a Python screen for this UI

  /// Plugin screens the person pinned (Plugins page > Pin), in pin order. The rest are reached through Plugins.
  List<PluginInfo> get _pinnedScreens {
    final pins = PluginPins.all;
    final out = <PluginInfo>[];
    for (final f in pins) {
      final pl = _pluginScreens.where((e) => e.folder == f).firstOrNull;
      if (pl != null) out.add(pl);
    }
    return out;
  }

  /// The menu with the skin's order, removed buttons and names applied (skin_layout.dart). Dashboard and Settings always stay.
  List<(String, String)> get _nav {
    final base = _navBase;
    final nav = Skins.layout.nav;
    final ids = nav.arrange([for (final e in base) e.$1], keep: _music ? const {'mhome', 'msettings'} : const {'dashboard', 'settings'});
    final titles = {for (final e in base) e.$1: e.$2};
    return [for (final id in ids) (id, nav.labels[id] ?? titles[id] ?? id)];
  }

  /// The menu with one entry per pinned plugin screen, just above Plugins (a plugin's own plugin.json ui.navTab names it).
  List<(String, String)> get _navBase {
    if (_music) return _musicNav;
    final i = _navItems.indexWhere((e) => e.$1 == 'plugins');
    return [
      ..._navItems.sublist(0, i),
      for (final pl in _pinnedScreens) ('plugin:${pl.folder}', pl.navTab.isEmpty ? pl.name : pl.navTab),
      ..._navItems.sublist(i),
    ];
  }

  /// Same for the More page (phones): the fixed screens with the Plugins button, then the pinned plugins, then Settings.
  /// Same for the More page (phones): the fixed screens, then the 10 pin slots as tiles of the same size
  /// ('plugin:<folder>' for a pinned plugin, 'pin+:<n>' for an empty slot).
  List<String> get _more {
    final pins = _pinnedScreens;
    return Skins.layout.nav.arrange([
      ..._moreIds,
      for (final pl in pins) 'plugin:${pl.folder}',
      for (var i = pins.length; i < PluginPins.max; i++) 'pin+:$i',
    ], keep: const {'settings'});
  }

  String _title(String id) {
    final named = Skins.layout.nav.labels[id]; // a name the skin gave this screen
    if (named != null) return named;
    if (id.startsWith('plugin:')) {
      final pl = _pluginScreens.where((e) => 'plugin:${e.folder}' == id).firstOrNull;
      if (pl != null) return pl.navTab.isEmpty ? pl.name : pl.navTab;
    }
    return _titleOf(id);
  }

  /// Plugins that have a Python screen: one menu entry each. Reloaded when the store installs or removes one.
  void _loadPluginScreens() {
    _pluginRetry?.cancel();
    _fetchPluginScreens(0);
  }

  Timer? _pluginRetry;

  void _fetchPluginScreens(int attempt) {
    Activity.begin('plugins', 'Loading plugins\u2026', detail: true);
    Api.plugins().then((l) {
      final screens = l.where((e) => e.flutterScreen).toList();
      Activity.end('plugins', 'Loaded ${l.length} plugins, ${screens.length} with a screen${Api.pluginsNote.isEmpty ? '' : '. ${Api.pluginsNote}'}');
      PluginHost.streamers = [for (final e in l) if (e.flutterScreen && (e.streamer || e.liveProvider)) {'id': e.folder, 'name': e.name, 'stream': e.streamer ? 'true' : 'false', 'live': e.liveProvider ? 'true' : 'false'}];
      if (mounted) setState(() => _pluginScreens = screens);
      if (screens.isEmpty) _retryPluginScreens(attempt); // nothing came back: the server may not have been ready yet
    }).catchError((_) {
      Activity.end('plugins');
      _retryPluginScreens(attempt); // a failed load used to leave the pin list empty until a plugin was installed or removed
    });
  }

  /// Asks again a few seconds later (2 s, 4 s, 6 s), then stops: someone with no plugin screens at all should not poll forever.
  void _retryPluginScreens(int attempt) {
    if (!mounted || attempt >= 3) return;
    _pluginRetry?.cancel();
    _pluginRetry = Timer(Duration(seconds: 2 * (attempt + 1)), () {
      if (mounted) _fetchPluginScreens(attempt + 1);
    });
  }

  void _pinsChanged() {
    if (mounted) setState(() {});
  }

  Timer? _weatherTimer;
  void _weatherSoon() {
    if (!Cloud.linked) return;
    _weatherTimer?.cancel();
    _weatherTimer = Timer(const Duration(seconds: 2), () => unawaited(Cloud.sync(light: true)));
  }

  @override
  void initState() {
    super.initState();
    if (!_music) {
      // Music mode shows no plugin screens and starts no video plugin hooks (Trakt import and the like).
      _loadPluginScreens();
      PluginUpdates.checkOnStartup(); // built-in plugins update from the PEK Store, GitHub ones are offered an update
      Future<void>.delayed(const Duration(seconds: 6), PluginHooks.appStart); // plugins with hooks (Trakt import); once per run
      DiscordPresence.start(); // Discord Rich Presence: connects if this profile linked Discord (discord.dart)
    }
    PluginHost.changed.addListener(_loadPluginScreens);
    PluginPins.changed.addListener(_pinsChanged);
    Store.profile.addListener(_pinsChanged);
    if (!_music) {
      News.loadCache();
      unawaited(News.refresh()); // the unread dot on Updates
    }
    WidgetsBinding.instance.addObserver(this);
    Future<void>.delayed(const Duration(seconds: 8), _remind); // on start, once the app has settled
    _reminderTimer = Timer.periodic(const Duration(minutes: 30), (_) => _remind()); // while it stays open (the 6 hours are kept inside)
    unawaited(DeepLink.start()); // the website's "back to the app" link after creating an account
    // Cloud sync: once at the start, then every 5 minutes when something changed on this device.
    if (Cloud.linked) {
      unawaited(Cloud.sync());
      unawaited(PluginBackup.run());
    }
    _syncTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (Cloud.linked) {
        unawaited(Cloud.sync(light: !Cloud.hasLocalChanges()));
        unawaited(PluginBackup.run()); // cheap when nothing changed: file sizes and times only
      }
    });
    PluginHost.changed.addListener(_backupSoon); // installed / updated here: back it up
    Weather.edited.addListener(_weatherSoon); // a new city / unit: send it to the profile
    Layouts.edited.addListener(_weatherSoon); // a new layout / poster size: same
    Skins.changes.addListener(_weatherSoon); // a new skin (or a skin made / installed / deleted): send it to the profile
    Store.dashEdited.addListener(_weatherSoon); // a changed dashboard: same
    Cloud.changes.addListener(_backupSoon); // just signed in: back up what is installed
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reminderTimer?.cancel();
    _pluginRetry?.cancel();
    PluginHost.changed.removeListener(_loadPluginScreens);
    PluginPins.changed.removeListener(_pinsChanged);
    Store.profile.removeListener(_pinsChanged);
    PluginHost.changed.removeListener(_backupSoon);
    Weather.edited.removeListener(_weatherSoon);
    Layouts.edited.removeListener(_weatherSoon);
    Skins.changes.removeListener(_weatherSoon);
    Store.dashEdited.removeListener(_weatherSoon);
    _weatherTimer?.cancel();
    Cloud.changes.removeListener(_backupSoon);
    _backupTimer?.cancel();
    _syncTimer?.cancel();
    _pageN.dispose();
    _pager.dispose();
    super.dispose();
  }

  /// Opens a screen: on a TV it replaces the content, on a phone swipe pages scroll to it and the rest open on top.
  void _open(String id) {
    final p = context.pek;
    if (p.sidebar) {
      setState(() => _tab = id);
      return;
    }
    final i = _pages.indexOf(id);
    if (i >= 0) {
      _goTo(i);
      return;
    }
    Navigator.push(context, MaterialPageRoute<void>(builder: (c) => SubScreen(title: _title(id), body: _body(c, id))));
  }

  void _goTo(int i) {
    if (_pager.hasClients) {
      _pager.animateToPage(i, duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
    }
  }

  Future<void> _askExit() async {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final yes = await showDialog<bool>(
      context: context,
      barrierColor: t.overlay,
      builder: (c) => Dialog(
        backgroundColor: t.glassStrong,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.radius), side: BorderSide(color: t.border)),
        child: Padding(
          padding: EdgeInsets.all(1.5 * rem),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Are you sure you want to exit?', style: TextStyle(fontSize: 1.25 * rem, fontWeight: FontWeight.w700)),
              SizedBox(height: 0.75 * rem),
              Text('PEK TV will stop running and its temporary cache will be cleared.', style: TextStyle(color: t.textMuted)),
              SizedBox(height: 1.25 * rem),
              Wrap(spacing: 0.75 * rem, runSpacing: 0.75 * rem, children: [
                PekButton(label: 'Yes, exit', primary: true, onTap: () => Navigator.pop(c, true)),
                PekButton(label: 'Close', autofocus: true, onTap: () => Navigator.pop(c, false)),
              ]),
            ],
          ),
        ),
      ),
    );
    if (yes == true) await PekPlayer.exitApp();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (PluginBack.handle()) return; // a plugin screen on the TV that is inside one of its own pages
        // Back: leave a secondary screen / any other page for the first page, then ask before exiting.
        if (p.sidebar ? _tab != _home : _page != 0) {
          if (p.sidebar) {
            setState(() => _tab = _home);
          } else {
            _goTo(0);
          }
        } else {
          _askExit();
        }
      },
      child: Material(color: p.tokens.bg, child: BackupLimitBanner.wrap(child: LapseBanner.wrap(child: p.sidebar ? _tv(context) : _phone(context)))),
    );
  }

  // ---------------------------------------------------------------- the content of one screen

  Widget _body(BuildContext context, String id) {
    final pad = context.pek.pagePad;
    if (id.startsWith('plugin:')) {
      return PluginView(key: ValueKey(id), pluginId: id.substring(7), padding: pad, embedded: context.pek.sidebar, onExit: () => setState(() => _tab = 'dashboard'));
    }
    switch (id) {
      case 'mhome':
        return MusicHomePage(padding: pad, onOpenLibrary: () => _open('mlibrary'));
      case 'msearch':
        return MusicPage(padding: pad, title: 'Search', view: MusicView.search);
      case 'mlibrary':
        return MusicPage(padding: pad, title: 'Your Library', view: MusicView.library);
      case 'msettings':
        return SettingsPage(padding: pad);
      case 'dashboard':
        return DashboardPage(padding: pad, onOpenResume: () => _open('history'), onOpenFavorites: () => _open('favorites'), onOpenMusic: () => _open('music'));
      case 'movies':
      case 'shows':
        return LibraryPage(key: ValueKey(id), tab: id, title: _title(id), padding: pad);
      case 'music':
        return MusicPage(padding: pad);
      case 'more':
        return _MorePage(
          padding: pad,
          onOpen: _open,
          ids: _more,
          pinned: _pinnedScreens,
          available: _pluginScreens,
          onReloadPlugins: _loadPluginScreens,
          titleOf: _title,
          icons: {for (final pl in _pluginScreens) if (pl.icon.isNotEmpty) 'plugin:${pl.folder}': pl.icon},
          hints: {for (final pl in _pluginScreens) 'plugin:${pl.folder}': pl.description},
        );
      case 'search':
        return SearchPage(padding: pad);
      case 'history':
        return HistoryPage(padding: pad);
      case 'updates':
        return UpdatesPage(padding: pad, markSeen: context.pek.sidebar);
      case 'favorites':
        return FavoritesPage(padding: pad);
      case 'duplicates':
        return DuplicatesPage(padding: pad);
      case 'unknown':
        return UnknownPage(padding: pad);
      case 'plugins':
        return PluginsPage(padding: pad);
      case 'settings':
        return SettingsPage(padding: pad);
    }
    return const SizedBox.shrink();
  }

  // ---------------------------------------------------------------- phone / tablet: swipe pages + bottom bar

  Widget _phone(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final skin = Skins.layout;
    final nav = skin.nav;
    final pages = _pages;
    // A skin may have removed pages since the person last swiped: land on one that exists.
    if (_page >= pages.length) {
      _page = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _pageN.value = 0;
        if (_pager.hasClients) _pager.jumpToPage(0);
      });
    }
    final inset = MediaQuery.paddingOf(context);
    final onTop = nav.position == NavPosition.top; // a phone has the bar at the bottom (the app's own) or at the top; sides do not fit
    final showIcon = nav.show != NavShow.text;
    final showLabel = nav.show != NavShow.icons;
    final barPaint = nav.paint.isEmpty ? null : nav.paint;
    final barActive = nav.activePaint.isEmpty ? barPaint : nav.activePaint.over(nav.paint);
    final bar = Container(
      padding: EdgeInsets.only(top: onTop ? inset.top : 0, bottom: onTop ? 0 : inset.bottom),
      decoration: BoxDecoration(color: t.bgElevated, border: onTop ? Border(bottom: BorderSide(color: t.border)) : Border(top: BorderSide(color: t.border))),
      child: IntrinsicHeight(
        child: ValueListenableBuilder<int>(
          valueListenable: _pageN,
          builder: (context, page, _) => Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < pages.length; i++)
                Expanded(
                  child: _BarItem(
                    label: nav.labels[pages[i]] ?? _swipeLabel[pages[i]]!,
                    icon: SkinIcons.byName(nav.icons[pages[i]]) ?? _swipeIcon[pages[i]]!,
                    showIcon: showIcon,
                    showLabel: showLabel,
                    paint: i == page ? barActive : barPaint,
                    active: i == page,
                    badge: pages[i] == 'updates',
                    onTap: () => _goTo(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    final mini = skin.miniPlayer ?? MiniZone.bottom;
    return Column(
      children: [
        if (onTop) bar,
        if (mini == MiniZone.top) const MiniPlayer(),
        Expanded(
          child: PageView(
            controller: _pager,
            // The neighbouring pages are built while the current one is idle, so a swipe only has to slide them in.
            allowImplicitScrolling: true,
            onPageChanged: (i) {
              _page = i;
              _pageN.value = i;
              if (_pages[i] == 'updates') unawaited(News.markAllSeen()); // swiped to Updates: everything counts as read
            },
            children: [for (final id in pages) RepaintBoundary(key: ValueKey('page-$id'), child: _KeepAlive(child: _body(context, id)))],
          ),
        ),
        if (mini == MiniZone.bottom) const MiniPlayer(),
        if (!onTop) bar,
      ],
    );
  }

  // ---------------------------------------------------------------- TV: sidebar + content

  Widget _tv(BuildContext context) => ListenableBuilder(listenable: Layouts.changes, builder: (context, _) => _tvLayout(context));

  /// The menu buttons in a scrolling line (a column for a side menu, a row for a top / bottom one). [align] only matters when the
  /// buttons do not fill the bar: the list then shrinks to its buttons and sits at the start, the middle or the end.
  Widget _navList(Axis axis, int count, IndexedWidgetBuilder itemBuilder, double gap, NavAlign align) {
    final list = ListView.separated(
      scrollDirection: axis,
      shrinkWrap: align != NavAlign.start,
      padding: axis == Axis.vertical ? const EdgeInsets.all(4) : null,
      itemCount: count,
      separatorBuilder: (_, __) => axis == Axis.vertical ? SizedBox(height: gap) : SizedBox(width: gap),
      itemBuilder: itemBuilder,
    );
    if (align == NavAlign.start) return list;
    final center = align == NavAlign.center;
    return Align(
      alignment: axis == Axis.vertical ? (center ? Alignment.center : Alignment.bottomCenter) : (center ? Alignment.center : Alignment.centerRight),
      child: list,
    );
  }

  /// The TV / wide-screen shell. Without a skin layout: the menu on the left (across the top with the Top bar layout), the mini
  /// player at the bottom. A skin (skin_layout.dart) can put the menu on any side, give it icons, reorder / rename / remove its
  /// buttons, change the corner of its buttons, and move or hide the mini player.
  Widget _tvLayout(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final skin = Skins.layout;
    final nav = skin.nav;
    final items = _nav;
    final pos = nav.position ?? (Layouts.id == 'topbar' ? NavPosition.top : NavPosition.left);
    final mini = skin.miniPlayer ?? MiniZone.bottom;
    final show = nav.show ?? NavShow.text;
    final showIcon = show != NavShow.text;
    final showLabel = show != NavShow.icons;
    final radius = nav.shape?.radius(t.radius) ?? 12.0;
    final brand = nav.brand ?? (_music ? 'PEK Music' : 'PEK TV');
    final footer = nav.footer ?? 'System Online';
    final content = Expanded(
      child: Column(children: [
        if (mini == MiniZone.top) const MiniPlayer(),
        Expanded(child: KeyedSubtree(key: ValueKey(_tab), child: _body(context, _tab))),
        if (mini == MiniZone.bottom) const MiniPlayer(),
      ]),
    );

    // Colours / gradient / animation for the menu buttons: the general paint, and the selected button's on top of it.
    final navPaint = nav.paint.isEmpty ? null : nav.paint;
    final navActive = nav.activePaint.isEmpty ? navPaint : nav.activePaint.over(nav.paint);

    Widget item(int i, {required bool fill}) {
      final id = items[i].$1;
      return _NavItem(
        paint: id == _tab ? navActive : navPaint,
        label: items[i].$2,
        icon: SkinIcons.byName(nav.icons[id]) ?? SkinIcons.forScreen(id),
        showIcon: showIcon,
        showLabel: showLabel,
        radius: radius,
        fill: fill,
        markerRight: pos == NavPosition.right,
        active: id == _tab,
        autofocus: id == _tab,
        onTap: () => setState(() => _tab = id),
      );
    }

    if (pos == NavPosition.top || pos == NavPosition.bottom) {
      // Menu across the top (like Arctic) or the bottom.
      final top = pos == NavPosition.top;
      final bar = Container(
        padding: EdgeInsets.fromLTRB(rem + p.safeX, 0.75 * rem + (top ? p.safeY : 0), rem + p.safeX, 0.75 * rem + (top ? 0 : p.safeY)),
        decoration: BoxDecoration(
          color: t.bgElevated,
          border: Border(top: top ? BorderSide.none : BorderSide(color: t.border), bottom: top ? BorderSide(color: t.border) : BorderSide.none),
        ),
        child: Row(children: [
          if (brand.isNotEmpty) Padding(padding: EdgeInsets.only(right: 1.5 * rem), child: Text(brand, maxLines: 1, style: TextStyle(fontSize: 1.25 * rem, fontWeight: FontWeight.w700, color: t.accent))),
          Expanded(
            child: TvNav.region(
              memoryKey: 'shell/topbar',
              child: SizedBox(
                height: 3 * rem,
                child: _navList(Axis.horizontal, items.length, (_, i) => item(i, fill: false), 0.5 * rem * (nav.gap ?? 1.0), nav.align ?? NavAlign.start),
              ),
            ),
          ),
        ]),
      );
      return Column(children: top ? [bar, content] : [content, bar]);
    }

    final right = pos == NavPosition.right;
    final slim = Layouts.id == 'wall' || Layouts.id == 'compact';
    final iconsOnly = show == NavShow.icons;
    var width = (slim ? 11 : 14) * rem;
    if (iconsOnly) width = 6 * rem + p.safeX;
    if (nav.width != null) width = math.max(width * nav.width!, (iconsOnly ? 5.6 : 7.0) * rem + p.safeX);
    final sidebar = Container(
      width: width,
      padding: right
          ? EdgeInsets.fromLTRB(rem, 1.5 * rem + p.safeY, rem + p.safeX, 1.5 * rem + p.safeY)
          : EdgeInsets.fromLTRB(rem + p.safeX, 1.5 * rem + p.safeY, rem, 1.5 * rem + p.safeY),
      decoration: BoxDecoration(color: t.bgElevated, border: right ? Border(left: BorderSide(color: t.border)) : Border(right: BorderSide(color: t.border))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (brand.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(left: 0.5 * rem, bottom: 2 * rem),
              child: Text(brand, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 1.25 * rem, fontWeight: FontWeight.w700, color: t.accent)),
            ),
          Expanded(
            child: TvNav.region(
              memoryKey: 'shell/sidebar',
              columnEdgesStop: true,
              child: _navList(Axis.vertical, items.length, (_, i) => item(i, fill: true), (Layouts.id == 'compact' ? 0.3 : 0.5) * rem * (nav.gap ?? 1.0), nav.align ?? NavAlign.start),
            ),
          ),
          if (footer.isNotEmpty)
            Container(
              padding: EdgeInsets.only(top: rem),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: t.border))),
              child: Text(footer, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 0.85 * rem, color: t.textMuted)),
            ),
        ],
      ),
    );
    return Row(children: right ? [content, sidebar] : [sidebar, content]);
  }
}

/// Keeps a swipe page built while it is off screen, so scroll position and loaded posters survive a swipe away and back.
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});
  final Widget child;
  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// The "More" page: every screen that is not a swipe page, as tiles.
class _MorePage extends StatelessWidget {
  const _MorePage({required this.padding, required this.onOpen, required this.ids, required this.titleOf, this.pinned = const [], this.available = const [], this.onReloadPlugins, this.hints = const {}, this.icons = const {}});
  final EdgeInsets padding;
  final void Function(String id) onOpen;
  final List<String> ids;
  final List<PluginInfo> pinned; // plugin screens on the pin board
  final List<PluginInfo> available; // every installed plugin screen (what the board's + slots offer)
  final VoidCallback? onReloadPlugins; // the pin picker found plugins the menu had missed: reload the menu's list
  final String Function(String id) titleOf;
  final Map<String, String> hints; // plugin screens: their description
  final Map<String, String> icons; // plugin screens: the address of their picture (plugin.json "icon")

  static const _hint = {
    'search': 'Titles, actors, genres, years',
    'history': 'Pick up where you left off',
    'favorites': 'Your saved movies and shows',
    'duplicates': 'Files that appear twice',
    'unknown': 'Files PEK TV could not sort',
    'plugins': 'Installed plugins',
    'settings': 'Sources and app options',
  };

  Widget _pinTile(BuildContext context, String id, double rem, PekScope p) {
    final pl = pinned.firstWhere((e) => 'plugin:${e.folder}' == id);
    return PinTile(
      title: titleOf(id),
      subtitle: pl.description,
      fill: pl.icon.isEmpty ? null : PluginPicture(url: pl.icon, expand: true),
      leading: pl.icon.isEmpty ? SizedBox(width: 3.4 * rem, height: 3.4 * rem, child: Icon(Icons.extension_outlined, size: 2.2 * rem, color: p.tokens.textMuted)) : null,
      onTap: () => onOpen(id),
      onLongPress: () => PinActions.menu(context, pl, (_) => onOpen(id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final rem = p.rem;
    final cols = p.size.width >= 600 ? 3 : 2;
    final gap = 0.75 * rem;
    // Tiles in a row share one height: at least room for a 2-line title + a 3-line description, taller when a title or description
    // needs more lines (the text wraps, it is never cut off).
    final pad = (p.compact ? 0.75 : 1.5) * rem;
    final minTileH = pad * 2 + 1.1 * rem * 1.3 * 2 + 0.5 * rem + 0.92 * rem * 1.35 * 3 + 2;

    Widget grid(List<String> list) {
      final rows = (list.length / cols).ceil();
      return LayoutBuilder(builder: (context, box) {
      final colW = (box.maxWidth - (cols - 1) * (gap + 1)) / cols;
      final base = DefaultTextStyle.of(context).style;
      final scaler = MediaQuery.textScalerOf(context);
      double textH(String text, TextStyle st) {
        final tp = TextPainter(text: TextSpan(text: text, style: base.merge(st)), textDirection: TextDirection.ltr, textScaler: scaler)..layout(maxWidth: math.max(1.0, colW - 2 * pad));
        return tp.height;
      }
      // The height one tile needs for its text (the same layout as PekCard / PinTile).
      double need(String id) {
        if (id.startsWith('pin+:')) return 0;
        final pl = pinned.where((e) => 'plugin:${e.folder}' == id).firstOrNull;
        if (pl != null && pl.icon.isNotEmpty) return 0; // a full picture tile: its name sits on the picture
        final sub = pl != null ? pl.description : (_hint[id] ?? hints[id]);
        final hasLeading = pl != null || id.startsWith('plugin:');
        var h = 2 * pad + (hasLeading ? 3.4 * rem + 0.5 * rem : 0.0);
        h += textH(titleOf(id), TextStyle(fontSize: 1.1 * rem, fontWeight: FontWeight.w600, letterSpacing: -0.2));
        if (sub != null && sub.isNotEmpty) h += 0.5 * rem + textH(sub, TextStyle(fontSize: 0.92 * rem, height: 1.35));
        return h + 4;
      }
      return Column(children: [
        for (var r = 0; r < rows; r++) ...[
          // A thin line between rows and between the two columns, so each button reads as its own.
          if (r > 0) ThinDivider(vertical: gap / 2),
          SizedBox(
              height: [minTileH, for (var c = 0; c < cols; c++) if (r * cols + c < list.length) need(list[r * cols + c])].reduce(math.max),
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var c = 0; c < cols; c++) ...[
                  if (c > 0) Padding(padding: EdgeInsets.symmetric(horizontal: gap / 2), child: SizedBox(width: 1, child: ColoredBox(color: p.tokens.textMuted.withAlpha(60)))),
                  Expanded(
                    child: r * cols + c < list.length && list[r * cols + c].startsWith('pin+:')
                        ? PinTile(onTap: () => PinActions.pick(context, available, onReloaded: onReloadPlugins))
                        : r * cols + c < list.length && pinned.any((e) => 'plugin:${e.folder}' == list[r * cols + c])
                            ? _pinTile(context, list[r * cols + c], rem, p)
                            : r * cols + c < list.length
                        ? PekCard(
                            title: titleOf(list[r * cols + c]),
                            leading: list[r * cols + c].startsWith('plugin:')
                                ? (icons[list[r * cols + c]] == null
                                    ? SizedBox(width: 3.4 * rem, height: 3.4 * rem, child: Icon(Icons.extension_outlined, size: 2.2 * rem, color: p.tokens.textMuted))
                                    : PluginPicture(url: icons[list[r * cols + c]]!, size: 3.4 * rem))
                                : null,
                            subtitle: _hint[list[r * cols + c]] ?? hints[list[r * cols + c]],
                            onTap: () => onOpen(list[r * cols + c]),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ]),
            ),
        ],
      ]);
      });
    }

    return ListView(
      padding: padding,
      children: [
        const Heading('More', weather: true),
        grid(ids),
      ],
    );
  }
}

/// `.nav-item` in the sidebar (and in the phone "More" sheet). Without a skin layout: the name only, 12px corners, the active
/// marker on the left. A skin can add an icon (or show only the icon), change the corner and mirror the marker.
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.label,
    required this.active,
    required this.onTap,
    this.autofocus = false,
    this.center = false,
    this.icon,
    this.showIcon = false,
    this.showLabel = true,
    this.radius = 12,
    this.fill = true,
    this.markerRight = false,
    this.paint,
  });

  /// The skin's colours / gradient / animation for this button (already merged for the selected one). null = the app's own look.
  final ButtonPaint? paint;
  final String label;
  final bool active;
  final bool autofocus;
  final bool center;
  final VoidCallback onTap;
  final IconData? icon;
  final bool showIcon;
  final bool showLabel;
  final double radius;

  /// Stretch across the bar (a side menu). false = the button's own width (a top / bottom menu, where the width is unbounded).
  final bool fill;
  final bool markerRight;

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final rem = p.rem;
    final look = paint == null || paint!.isEmpty ? null : PaintLook(paint!, t);
    final appText = active ? t.text : t.textMuted;
    final ownText = look != null && (look.painted || look.textColor != null); // the skin colours this button's label
    final textColor = look?.label(appText) ?? appText;
    final glyph = showIcon && icon != null ? Icon(icon, size: 1.3 * rem, color: ownText ? textColor : (active ? t.accent : t.textMuted)) : null;
    final text = Text(
      label,
      textAlign: center ? TextAlign.center : TextAlign.start,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: rem, fontWeight: active ? FontWeight.w600 : FontWeight.w500, color: textColor),
    );
    final appBg = active ? t.surfaceFocused : null;
    final bg = look == null ? appBg : look.boxFill(appBg);
    final Widget inner;
    if (glyph != null && showLabel) {
      inner = Row(
        mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: center ? MainAxisAlignment.center : MainAxisAlignment.start,
        children: [glyph, SizedBox(width: 0.7 * rem), Flexible(child: text)],
      );
    } else if (glyph != null) {
      inner = Center(child: Tooltip(message: label, child: glyph)); // icon only: the name is still read aloud and shown on hover
    } else {
      inner = text;
    }
    return PekFocusable(
      autofocus: autofocus,
      onTap: onTap,
      radius: radius,
      alignment: fill ? null : Alignment.center,
      background: bg,
      focusBackground: look != null && look.painted ? bg : null,
      borderColor: look?.border,
      borderWidth: p.layout.buttons.borderWidth ?? 1,
      glow: look?.glow,
      surface: look?.surface,
      child: Stack(
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: rem, vertical: 0.7 * rem),
            child: fill ? SizedBox(width: double.infinity, child: inner) : inner,
          ),
          if (active)
            Positioned.fill(
              child: Align(
                alignment: markerRight ? Alignment.centerRight : Alignment.centerLeft,
                child: FractionallySizedBox(
                  heightFactor: 0.52,
                  child: Container(
                    width: 3,
                    decoration: BoxDecoration(
                      color: t.accent,
                      borderRadius: markerRight ? const BorderRadius.horizontal(left: Radius.circular(3)) : const BorderRadius.horizontal(right: Radius.circular(3)),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// `.bb-item` in the phone tab bar: an icon over a small label; the active item is bright, the rest are muted. A skin can show
/// only the icons or only the names.
class _BarItem extends StatelessWidget {
  const _BarItem({required this.label, required this.icon, required this.active, required this.onTap, this.badge = false, this.showIcon = true, this.showLabel = true, this.paint});

  /// The skin's colours / gradient / animation for this tab (already merged for the selected one). null = the app's own look.
  final ButtonPaint? paint;
  final bool badge; // shows a dot while there are unread Updates
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final bool showIcon;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    final t = p.tokens;
    final look = paint == null || paint!.isEmpty ? null : PaintLook(paint!, t);
    final appC = active ? t.text : t.textMuted;
    final c = look?.label(appC) ?? appC;
    final bg = look?.boxFill(null);
    return PekFocusable(
      onTap: onTap,
      minHeight: 58,
      background: bg,
      focusBackground: look != null && look.painted ? bg : null,
      borderColor: look?.border,
      borderWidth: p.layout.buttons.borderWidth ?? 1,
      glow: look?.glow,
      surface: look?.surface,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (showIcon)
            if (badge)
              ListenableBuilder(
                listenable: Listenable.merge([News.unread, PluginUpdates.unseen]), // news OR a plugin update the person has not seen
                builder: (context, _) => Stack(clipBehavior: Clip.none, children: [
                  Icon(icon, size: 22, color: c),
                  if (News.unread.value + PluginUpdates.unseen.value > 0) Positioned(right: -3, top: -1, child: Container(width: 9, height: 9, decoration: BoxDecoration(color: t.accent, shape: BoxShape.circle))),
                ]),
              )
            else
              Icon(icon, size: 22, color: c),
          if (showIcon && showLabel) const SizedBox(height: 3),
          if (showLabel) Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: (showIcon ? 0.68 : 0.85) * p.rem, fontWeight: active ? FontWeight.w600 : FontWeight.w500, color: c)),
        ],
      ),
    );
  }
}

/// `h1.content-title`: 2rem.
class PageTitle extends StatelessWidget {
  const PageTitle(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) {
    final p = context.pek;
    return Padding(
      padding: EdgeInsets.only(bottom: (p.isTv ? 2 : 1.5) * p.rem),
      child: Text(title, style: TextStyle(fontSize: 2.1 * p.rem, fontWeight: FontWeight.w700, letterSpacing: -0.6, height: 1.1)),
    );
  }
}
