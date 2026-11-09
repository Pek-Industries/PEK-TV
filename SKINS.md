# PEK TV skins

A skin changes how PEK TV looks: its colours and its corner size. A skin can also change how the app is laid out (where the menu
sits, which buttons it has, how buttons are coloured and animated, what the dashboard shows): see [Layout](#layout-menu-buttons-dashboard).
A skin can't run code, can't contain CSS and can't reach the network: a layout is plain data (names, numbers, colours), never code.

## Installing and removing

- **Install:** Settings → Appearance → *Skin from .zip*, then pick the .zip.
  PEK TV shows the skin's name, author, version and description before it installs anything.
- **From GitHub:** Settings → Appearance → *Skin from GitHub*, then type `owner/repo` (a pasted github.com link
  works too). PEK TV uses the repository's latest release `.zip` (up to 8 MB), or its source code if it has no
  release, and then shows the same details and confirm screen as a .zip install. A skin that came from GitHub is
  labelled "unverified" in the Skins list. The same *Install from GitHub* switch (Settings → Plugins and skins from GitHub) turns it off.
  The repository must hold a skin (`skin.json`), the same layout as the zip below.
- **Use it:** tap the skin in the Appearance list.
- **Remove:** hold the skin's row (OK on a remote, or a long press on a phone), then confirm.
  The skins that ship with PEK TV (PEK Ember, Mono, Cream, Night red, Green, Neon) can't be removed.
- **A zip is a plugin or a skin, never both.** Installing a skin zip as a plugin, or a plugin
  zip as a skin, fails with a message that says which one it is.

## The zip

```
my-skin.zip
└── my-skin/            (the folder is optional; skin.json can also sit at the top of the zip)
    ├── skin.json       (required)
    └── images, fonts   (optional)
```

The folder name (or, without a folder, the skin's name) becomes the skin's id, so installing
a zip with the same id again updates the skin.

## skin.json

```json
{
  "name": "Sunset",
  "author": "PEK TV",
  "version": "1.0.0",
  "description": "Warm dusk colours with soft rounded corners.",
  "tokens": {
    "bg": "#1a0f14",
    "text": "#fff1e8",
    "accent": "#ffb347",
    "radius": "14px"
  }
}
```

| Field | Required | Shown in |
|---|---|---|
| `name` | yes | the Appearance list and the install screen |
| `author` | no | "by …" in the Appearance list and the install screen |
| `description` | no | the Appearance list and the install screen |
| `version` | no | the Appearance list and the install screen |
| `tokens` | no | colours and the corner size (`radius`); see the bundled `skins/neon/skin.json` for every token. The app draws the colours and `radius`; other tokens are checked but not drawn |
| `tokens.bgImage` | no | accepted and checked (a plain CSS gradient, no `url()`), but **not drawn** by the Flutter app, which has no background image |
| `layout` | no | where the menu sits, its buttons, button colours / shape / size / animation, the dashboard, the mini player, poster size. Plain data; see [Layout](#layout-menu-buttons-dashboard). The install screen lists what a skin rearranges |

## No CSS

A skin is its colours, its corner size and (if it wants) a `layout` of plain data, nothing more. **A skin that contains a `skin.css` (any `.css` file) is refused**: by
Skin from .zip / GitHub in the app, by the server, by `SkinBuilder` and by
`tools/make_skin.py`. The message is "skins can't contain CSS (skin.css): a skin is colours and a corner size only. Remove the .css
file and try again."

## Allowed files and limits

`json`, `md`, `txt`, `png`, `jpg`, `jpeg`, `gif`, `webp`, `ico`, `woff`, `woff2`, `ttf`, `otf`.
No code of any kind (`.js`, `.py`, `.html`, `.svg`). Up to 60 files, 2 MB per file, 6 MB in total.
The server (`backend/skin_install.h`) checks all of this again, so a hand-made request gets no
more than the app does.

## Layout: menu, buttons, dashboard

A skin can rearrange the app, not only recolour it. **Everything is optional and independent**: set one thing or all of it, in any
combination. What a skin leaves out stays as the app has it, so a skin with no `layout` looks and works exactly as before. A layout is
**plain data** (names, numbers, colours, ids from fixed lists): no code, no callbacks, no files, nothing that reaches the network.

It is written in code (`SkinBuilder` in Dart, `tools/make_skin.py`, or a `layout` object in `skin.json`). The Skin maker does not edit
layouts, but editing a skin there keeps the layout it has. (The Skin Maker plugin is off on TV devices; code is how a skin gets a layout there.)

```json
{
  "name": "Arcade",
  "tokens": { "bg": "#05010d", "text": "#f6eaff", "accent": "#ff2bd6" },
  "layout": {
    "nav": {
      "position": "right", "show": "icons", "align": "center", "shape": "pill",
      "order": ["music", "movies"], "hide": ["duplicates", "unknown"],
      "labels": { "shows": "Series" }, "icons": { "movies": "fire" },
      "brand": "ARCADE", "footer": "",
      "paint": { "fill": "surface", "border": "accent" },
      "activePaint": { "gradient": ["#ff2bd6", "#00d4ff"], "anim": "flow", "speed": 3 }
    },
    "buttons": {
      "radius": 8, "size": 1.1, "uppercase": true, "weight": 800, "borderWidth": 2,
      "primary": { "gradient": ["#ff2bd6", "#7a5cff", "#00d4ff"], "anim": "flow", "speed": 3, "glow": "#ff2bd680", "text": "#ffffff" },
      "secondary": { "border": "accent", "anim": "shimmer", "when": "focus" }
    },
    "dashboard": { "items": [ { "type": "clock", "size": "m" }, { "type": "nowplaying" }, { "type": "plugin", "folder": "weather" } ], "locked": false },
    "miniPlayer": "top",
    "poster": "l"
  }
}
```

The same in Dart (every call changes only what you pass, so the pieces combine in any order; `.layout(SkinLayout(...))` sets it all at once):

```dart
final arcade = SkinBuilder.fromAccent('Arcade', const Color(0xFFFF2BD6))
    .nav(position: NavPosition.right, show: NavShow.icons, align: NavAlign.center, shape: ButtonShape.pill,
         order: ['music', 'movies'], hide: ['duplicates', 'unknown'],
         labels: {'shows': 'Series'}, icons: {'movies': 'fire'}, brand: 'ARCADE', footer: '',
         paint: const ButtonPaint(fill: 'surface', border: 'accent'),
         activePaint: const ButtonPaint(gradient: ['#ff2bd6', '#00d4ff'], anim: ButtonAnim.flow, speed: 3))
    .buttons(radius: 8, size: 1.1, uppercase: true, weight: 800, borderWidth: 2,
         primary: const ButtonPaint(gradient: ['#ff2bd6', '#7a5cff', '#00d4ff'], anim: ButtonAnim.flow, speed: 3, glow: '#ff2bd680', text: '#ffffff'),
         secondary: const ButtonPaint(border: 'accent', anim: ButtonAnim.shimmer, when: AnimWhen.focus))
    .dashboard(['clock:m', 'nowplaying', 'plugin:weather'])      // 'name', 'name:m' (wide), 'plugin:folder'
    .miniPlayer(MiniZone.top)
    .posters('l');
final skin = arcade.build();   // throws SkinBuildException with a plain message on a mistake
await skin.save();             // Settings > Appearance
```

### The menu (`layout.nav`)

| Field | Values | What it does |
|---|---|---|
| `position` | `left`, `right`, `top`, `bottom` | where the menu sits. Default: the left (the top with the *Top bar* layout; the bottom on a phone). A phone has only `top` and `bottom` |
| `show` | `text`, `icons`, `both` | what each button shows. Default: text on a TV, icon over name on a phone |
| `align` | `start`, `center`, `end` | where the buttons sit along the bar when they do not fill it |
| `shape` | `pill`, `rounded`, `square` | the corner of the menu buttons (`rounded` = the skin's `radius`) |
| `width` | 0.7 to 1.6 | how wide a side menu is, as a multiple of the app's own |
| `gap` | 0 to 2 | the space between buttons, as a multiple of the app's own |
| `order` | screen ids | these come first, in your order; the rest follow in the app's order |
| `hide` | screen ids | buttons to remove (not the ones below). A hidden screen is gone from the menu and the phone's More list |
| `labels` | `{id: name}` | new names, up to 24 characters. The screen's own title follows |
| `icons` | `{id: icon}` | an icon for a button (names below) |
| `brand` | text, up to 24 | the name above the menu (`""` for none). Default: PEK TV / PEK Music |
| `footer` | text, up to 40 | the line under a side menu (`""` for none). Default: System Online |
| `paint` | a [button paint](#button-colours-and-animation) | colours, gradient and animation of every menu button |
| `activePaint` | a button paint | the selected button's, laid on top of `paint` |

**Screen ids:** `dashboard`, `movies`, `shows`, `music`, `updates`, `search`, `history`, `favorites`, `duplicates`, `unknown`, `plugins`,
`settings`, and `plugin:<folder>` for a pinned plugin screen. Music mode uses `mhome`, `msearch`, `mlibrary`, `msettings`.

**Never hidden:** `dashboard`, `settings`, `more`, `mhome`, `msettings`. Without them the person could not reach the rest of the app. The
builder and `make_skin.py` refuse a skin that tries; the app ignores it.

**Icons:** `home`, `movie`, `tv`, `music`, `news`, `search`, `history`, `favorite`, `heart`, `copy`, `help`, `plugin`, `settings`, `more`,
`star`, `bolt`, `fire`, `play`, `live`, `folder`, `person`, `cloud`, `bookmark`, `download`, `game`, `radio`, `podcast`, `explore`, `info`,
`grid`, `list`, `library`, `camera`, `rocket`, `palette`, `bell`, `lock`, `tune`, `sparkle`, `trophy`. A skin names an icon, it can't bring
its own picture. An icon-only button still has its name (read aloud, and shown as a tooltip).

### Buttons (`layout.buttons`)

Applies to PEK's buttons (Refresh, Add widget, Install, and the like).

| Field | Values | What it does |
|---|---|---|
| `shape` | `pill`, `rounded`, `square` | the corner. Default: pill |
| `radius` | 0 to 999 | an exact corner in pixels; wins over `shape` |
| `size` | 0.8 to 1.5 | text, padding and height together, as a multiple of the app's own |
| `padding` | 0.5 to 2 | the side padding only, to make buttons slimmer or roomier |
| `borderWidth` | 0 to 6 | the outline's thickness in pixels (default 1) |
| `uppercase` | true / false | UPPERCASE labels |
| `weight` | 400 to 900 | text weight (rounded to 400, 500 ... 900) |
| `outline` | true / false | outline only, no fill (unless a paint below gives the button a colour) |
| `focusScale` | 1.0 to 1.2 | how much a focused button grows |
| `primary` | a button paint | the accent buttons |
| `secondary` | a button paint | the plain buttons |

### Button colours and animation

A **button paint** is used by `buttons.primary`, `buttons.secondary`, `nav.paint` and `nav.activePaint`. Every field is optional.

| Field | Values | What it does |
|---|---|---|
| `fill` | a colour | the button's colour (ignored when there is a `gradient`) |
| `gradient` | 2 to 6 colours | blended across the button |
| `angle` | -360 to 360 | the gradient's direction in degrees: 0 left to right (default), 90 top to bottom, 45 corner to corner |
| `text` | a colour | the label. Default: black or white, whichever reads better on the fill, so a colour you pick never makes a label unreadable |
| `border` | a colour | the outline |
| `glow` | a colour | a soft glow around the button, always on |
| `anim` | `none`, `flow`, `shimmer`, `breathe` | `flow`: the gradient slides across and loops (needs a `gradient`). `shimmer`: a soft highlight sweeps across every few seconds. `breathe`: the colour gently brightens and dims |
| `speed` | 0.5 to 20 | seconds for one loop (default 4) |
| `when` | `always`, `focus` | `focus` animates only the focused button (kinder to weak TV boxes) |

A **colour** is `#rrggbb`, `#rrggbbaa` (the last two digits are transparency), `#rgb`, or a **palette name** (`accent`, `text`, `bg`, `surface`,
`border`, `borderFocus`, `bgElevated`, `surfaceFocused`, `textMuted`, `accentGlow`). A palette name follows the palette, so
`"border": "accent"` stays right when the person switches colours. Anything else (`red`, `rgb(...)`, `url(...)`) is not a colour and is dropped.

Animations stop on their own when the device is set to reduce motion, and while the screen is not showing. A focused button is always a little
brighter and keeps its focus ring, whatever its colours. On a phone the tab bar uses `nav.paint` / `nav.activePaint` the same way.

### The dashboard (`layout.dashboard`)

`items` is the arrangement, in order: `{ "type": ..., "size": "s" | "m", "folder": ... }`. Types: `clock`, `weather`, `continue`, `recent`,
`favorites`, `nowplaying`, `albums`, `playlists`, `shows`, `pinned`, `stats`, `surprise`, `upnext`, `watched`, `recommend`, and `plugin`
(with the plugin's `folder`). `size: "m"` is wide (clock, plugin, stats, surprise). Unknown types and repeats are dropped; at most 40.

- `"locked": false` (default): the **starting** arrangement. It is used until the person arranges their own dashboard (then theirs wins and
  is what the cloud syncs). *Reset to default* in Add widget goes back to the skin's arrangement.
- `"locked": true`: **always** this arrangement. The person can't move, resize, add or remove widgets while the skin is in use (the *Add widget*
  button and the hold menu are gone). Nothing is saved over their own dashboard, which comes back when they pick another skin.

### Mini player and posters

- `miniPlayer`: `top`, `bottom` (default) or `hidden`. Hidden removes the strip; the full player still opens from the Music page.
- `poster`: `s`, `m` or `l`, the poster size the skin starts with. It is used while the person's Settings > Layout > Poster size is *Auto*;
  their own choice wins.

### Combining

The fields never depend on each other, so mix freely. Some ideas:

- **Icon rail:** `nav: { position: "left", show: "icons", width: 0.8, brand: "", footer: "" }`
- **Kiosk:** `nav: { hide: [...] }`, `dashboard: { items: [...], locked: true }`, `miniPlayer: "hidden"`
- **Neon arcade:** a gradient `flow` on the primary buttons and the selected menu button, `glow` on both, `shimmer` on focus for the rest
- **Square and calm:** `buttons: { shape: "square", borderWidth: 2, outline: true }`, `nav: { shape: "square", position: "top", align: "center" }`

### Limits worth knowing

- Layout needs colours too: a `skin.json` with a layout and no `tokens` is refused (add at least a colour).
- Plugin screens' own buttons use the same PEK buttons, so they follow the skin; a plugin that draws its own colours does not.
- The install screen says what a skin rearranges ("menu on the right, a fixed dashboard, ..."), so the person knows before they install.
- The layout is backed up with the skin (see *Skins in the cloud*). The web UI ignores a `layout` it does not know.

## Making a skin in the Flutter app

The Skin maker is **PEK's official, bundled plugin `skin-maker`** (`plugins/skin-maker`, with its own icon). It is no longer
built into the app. Settings → Appearance → **Make a skin** (or Plugins → Skin Maker → Open) opens it. Pick a starting look,
change the accent, background, cards and text (the rest of the colours follow them; **More colours** sets each one by hand), set
the corner size, name it and save. A made skin appears in the Appearance list next to the built-in ones, and every profile can choose it.

- **From one accent colour** makes a whole skin from one colour (dark or light) or one hue.
- **Hold** any skin in the Appearance list to use it, edit it, start a new one from it, copy it as a `skin.json`, or delete it.
  Edit / "Make my own" open the plugin on that skin.
- **Copy skin.json** gives a `skin.json` you can install from a .zip (put it in a folder and zip it).
- **Paste skin.json** opens a `skin.json` made elsewhere in the maker, ready to save. Only the name, description and
  colours are used.
- A colour that would make the text hard to read on the background, the cards or the bars is refused
  (in the plugin, and again by the app before it stores anything).

It cannot be removed, and it updates from the PEK Store's Official shelf like Weather and TMDb Discover. The plugin only describes
the screen; it asks the app to save, use or delete a skin through the `skins` permission, which only this official plugin may use.
See FLUTTER_PLUGINS.md ("Skin Maker").

## Making skins from code

Two ways, both giving the same `skin.json` / .zip, so a skin made either way installs in the app.

**1. From the command line: `tools/make_skin.py`** (Python 3, no packages). It works out the colours you leave out, refuses
text that is hard to read, runs the same checks as `backend/skin_install.h`, and packs `my-skin/skin.json` into a .zip. It does **not** accept a `skin.css` (PEK TV draws a skin from its colours and corner size only): `--css` is gone, a `"css"` field in a batch file is an error, and `validate` refuses a zip that contains a `skin.css`.

```
# four colours, the rest follows
tools/make_skin.py new --name Sunset --bg '#1a0f14' --surface '#2a1820' --text '#fff1e8' --accent '#ffb347' --radius 14

# one accent is enough (dark by default, --light for a light skin); a hue works too; --glow adds a bgImage glow that the app checks but does not draw
tools/make_skin.py new --name Ocean --accent '#38bdf8'
tools/make_skin.py new --name Moss --hue 140 --light

# many skins from one JSON list, then check one
tools/make_skin.py batch skins.json --out dist/
tools/make_skin.py validate dist/sunset.zip
```

`--print` shows the skin.json without writing a file, `--folder` writes a skin folder instead of a .zip, `--file image.png` adds an
extra file, `--force` allows low-contrast text, `--layout layout.json` adds a [layout](#layout-menu-buttons-dashboard). A batch file is a list of
`{"name", "accent", "bg", "surface", "text", "radius", "mode", "hue", "glow", "tokens": {...}, "layout": {...}}`.
The tool checks a layout strictly (an unknown field, a wrong value or a typo is an error with a plain message, where the app would quietly
ignore it), and `validate` checks the layout of a zip too.

**2. From Dart: `SkinBuilder`** (`flutter_ui/lib/src/skin_builder.dart`), inside the app or its tests. Colours and layout in one chain,
with the same checks (a mistake throws a `SkinBuildException` with a plain message); `build()` gives a `Skin`, `save()` adds it to
Settings > Appearance, `zip()` / `skinJson()` give an installable file. See [Layout](#layout-menu-buttons-dashboard) for the whole chain.

**3. By hand**: write `skin.json` as above.

## Installing skins in the Flutter app

Settings > Appearance has **Skin from .zip** and **Skin from GitHub**. They use the zip picker plugins use (this
device, library folders and network folders), the GitHub lookup (latest release `.zip`, else the source code), the checks in
`flutter_ui/lib/src/skin_install.dart` (mirroring `backend/skin_install.h`) and a confirm screen. A skin from GitHub is labelled "unverified". Installing the same
skin again updates it; hold it in the list to remove it.

Notes: an installed skin gives the app its **colours, corner size and layout** (`bgImage` and the glass tokens are checked but
not drawn). A skin with no colours or radius in `skin.json` is refused there, even if it has a layout. The skin is kept on the device (not in the server's `skins/` folder).
A `layout` in `skin.json` is read the same careful way as everything else from a file: what the app does not understand is dropped, numbers are
clamped into range, and the screens in the table below can never be hidden. Installing a newer version of a skin replaces its layout (a version
with no `layout` clears it).

## Skins in the cloud (per profile)

When a cloud account is signed in, each profile's skins are saved to the account: the ones made in the Skin maker (or pasted
from a skin.json) and the ones installed from a .zip or GitHub, plus which skin the profile has chosen. Nothing to switch on: the
normal sync (at start, every 5 minutes after a change, and when a profile is opened) sends a new, changed or deleted skin.

- **Per profile.** Every profile has its own list of skins; one profile's skins are not in another's. (Before this, all profiles on a
  device shared one list; a profile that was using one of those skins keeps that skin.) The built-in skins are the same for everyone.
- **Restore.** Signing in on a new device, or again after signing out, brings back every skin and the chosen skin of each profile
  when the profile is opened (signing out removes them from the device; the cloud keeps them).
- **Newest wins.** Changing the same skin on two devices keeps the newer change. Deleting a skin deletes it on the other devices too,
  unless it was changed after the delete.
- **What is stored:** the name, author, version, description, the colours, the corner size and, for an installed skin, where it came
  from (GitHub skins stay labelled "unverified"). Up to 50 skins per profile. Nothing else from a skin zip is kept in the cloud.
  **A skin's layout is backed up too** (menu, buttons, dashboard, mini player, poster size), so a new device gets the whole skin back, not only its
  colours. One skin item holds up to 20,000 characters in the cloud (the app sends up to 19,000; every other kind of item stays at 2,000). A cloud copy
  made by an older app has no layout: the device keeps the layout it has. If a layout were ever too big to fit, the skin still goes up with its colours and
  every device keeps its own layout. The first sync after this update sends each skin that has a layout once more, so layouts that were only on the device are backed up.
- **Needs the new worker:** redeploy the sync worker first (it is what allows 20,000 characters per skin). Until then the skins stay on the device and are
  sent once the worker is updated.
