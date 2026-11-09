# Nesso Hub

An [Arduino Nesso N1](https://docs.arduino.cc/hardware/nesso-n1/) as a
Bluetooth companion screen for the Mac. In a Google Meet call it shows big
mic and camera toggles and your favourite reactions, and it can react on its
own when someone joins a meeting. The rest of the time it shows your Claude
Code sessions: which ones wait for you and which ones are working, on the
screen and on a [Modulino Pixels](https://docs.arduino.cc/hardware/modulino-pixels/)
next to it.

```
 Nesso N1  <── BLE (JSON lines) ──>  Nesso Hub.app  <── AppleScript ──>  Chrome (Meet tab)
 renders pages,                      menu bar app,                      the page is driven
 reports taps and keys               picks what to show                 by injected JavaScript
```

The Nesso knows nothing about Meet. The Mac sends it **pages** (rows of tiles
with labels, colours and icons) and it reports back which tile was tapped and
which key was pressed. Everything app-specific lives on the Mac, so a new use
needs no reflashing. Meet is driven through Chrome's AppleScript support, so
there is no browser extension to install.

## What it does

- **Meet page**, whenever a Meet tab has a call or a lobby open, even with
  Chrome in the background:
  - mic and camera toggles, coloured by their state; the two side keys toggle
    them too;
  - hold KEY1 to leave the call: a full-screen ring fills up while you hold,
    and letting go early runs it back and cancels;
  - up to nine reactions. Any emoji in Meet's full picker works, not just the
    quick bar: the ones that are not in it are found through the picker's
    search, by the shortcodes Meet uses (`:United-Kingdom-flag:`).
- **Claude page**, when no call is on and a Claude Code session is open, in
  the Claude app or in a terminal:
  - how many wait for you (a permission prompt or a question), how many
    finished while you were looking elsewhere, how many are working;
  - the sessions themselves, most urgent first, five at a time: KEY2 shows
    the next five. Open sessions with nothing new come last, in grey;
  - tap a session to open it, in the Claude app or in its terminal; KEY1
    opens the most urgent one.
- **Claude LEDs** on the Modulino Pixels, whatever the screen shows, call or
  not: one LED per session, most urgent first. Orange and blinking: it waits
  for you. Green: it finished and you have not looked at it yet. Blue and
  breathing: it is working. Dim white: it is open, with nothing new.
- **Sessions window** (menu bar → Floating Sessions Window): the Claude
  page's sessions in a small window that floats over every other one, in
  every Space and over full-screen apps, like a picture in picture. It helps
  during a call, when the Nesso shows Meet. Click a session to open it, or a
  counter to open the most urgent session it counts. It never takes the
  focus, it grows and shrinks with the list, and it stays where you drag it.
  The chevron at the end of the counters folds it down to a pill with the
  counters alone and no title bar. Drag the pill by its grip, unfold it with
  the chevron or a double click on the grip, and close it with a right click.
- **Clock page** the rest of the time.
- **Reactions window** (menu bar → Choose Reactions…): every emoji in Meet's
  picker, in Meet's groups, searchable in English and Italian and by
  shortcode, with a live preview of the Nesso.
- **Automations**: "when *person* joins the meeting *title*, send *emoji*",
  once per meeting. They run with or without the Nesso connected.

## Hardware and firmware

The firmware is in `firmware/NessoHub`. It needs the `esp32:esp32` core 3.3.x
and the `Arduino_Nesso_N1` and `ArduinoJson` (7.x) libraries.

The Modulino Pixels is optional: plug it into the Qwiic connector, before or
after boot, and the Nesso finds it at its default address. No library is
needed for it.

```sh
arduino-cli core install esp32:esp32
arduino-cli lib install Arduino_Nesso_N1 ArduinoJson
arduino-cli compile -b esp32:esp32:arduino_nesso_n1 -u -p /dev/cu.usbmodem101 firmware/NessoHub
```

For a Nesso used upside down, with the USB-C end on top, set
`MOUNT_UPSIDE_DOWN` to 1 in `firmware/NessoHub/config.h`, or pass it when
building:

```sh
arduino-cli compile -b esp32:esp32:arduino_nesso_n1 --build-property compiler.cpp.extra_flags=-DMOUNT_UPSIDE_DOWN=1 -u -p /dev/cu.usbmodem101 firmware/NessoHub
```

The screen and the touch turn half way round, and the Modulino Pixels LEDs
keep their left-to-right order. If the Modulino is also screwed on rotated
180°, set `PIXELS_REVERSE` to 0.

Over USB it also has a serial console (`status`, `screen`, `tap <x> <y>`,
`press <key> [ms]`, or a JSON message as if the Mac had sent it). `tools/` talks to it with nothing but
the Python standard library:

```sh
python3 tools/nesso_console.py status
python3 tools/nesso_screenshot.py shot.png
```

## The Mac app

Needs macOS 13 or later, a Swift toolchain (Xcode or the Command Line Tools)
and Chrome.

```sh
mac/run.sh          # build, install to /Applications, start, tail the log
mac/run.sh stop
```

`run.sh` signs the app with the first Apple Development identity in your
keychain, or `NESSO_SIGN_IDENTITY`. An ad-hoc signature works too, but macOS
ties permissions to the signature, so every rebuild would ask for them again.

First run:

1. Allow Bluetooth when macOS asks.
2. In Chrome: View → Developer → **Allow JavaScript from Apple Events**.
3. Open a Meet call and allow Nesso Hub to control Chrome when macOS asks.

The log is `~/Library/Logs/Nesso Hub.log` (menu bar → Show Log).

### Configuration

`~/.config/nesso-hub/config.json`, written with the defaults on first run.
Restart the app after editing it by hand.

```json
{
  "browser": "com.google.Chrome",
  "reactions": ["💖", "👍", "🎉", "👏", "😂", "😮"],
  "automations": [
    { "title": "Weekly Sync", "code": "abc-defg-hij", "joins": "Jane Doe", "react": "🎉" }
  ],
  "claude": { "enabled": true, "brightness": 4, "cloud": true, "window": false, "compact": false }
}
```

- `browser`: any Chromium browser with the same AppleScript support (Chrome,
  Edge, Brave), by bundle id.
- `automations`: a meeting is recognised by its `title` (the Calendar event's
  name, which Meet puts in the tab title) or by its `code`; either is enough,
  so a rule outlives a change of code. `joins` is matched against participant
  names, ignoring case and accents.
- `claude`: `enabled` off hides the Claude page and leaves the LEDs dark;
  `brightness` is the LEDs', 1 to 31; `cloud` off leaves out the sessions
  that do not run on this Mac, and with them the keychain; `window` is
  whether the sessions window is open, kept from the menu bar; `compact`
  whether it shows the counters alone, kept from its chevron.

### How Nesso Hub sees the Claude sessions

Claude Code keeps a file for each running session in `~/.claude/sessions`,
whether it runs in a terminal or in the Claude app's Code tab, with what it is
doing: working, waiting for you, or idle. The Claude app keeps its own record
of each session under `~/Library/Application Support/Claude/claude-code-sessions`,
with its title and when it was last opened and last active. Nesso Hub reads
both each second; it needs no setup and no permission.

- **Waits for you**: the session stopped on a permission prompt or on a
  question.
- **Done**: it went idle after you last looked at it. A session of the Claude
  app counts as seen once you open it, or while it is on screen; a terminal
  session once its terminal is in front. A session of the Claude app that
  finished unseen stays done for a day, even once the app has stopped its
  process.
- **Idle**: open, and seen since it last did something. An idle session
  left alone for 12 hours is not shown any more, and neither are archived
  ones.

Sessions that do not run on this Mac, in the cloud or on another computer
under Remote Control, are known only to Anthropic's servers. Nesso Hub lists
them every ten seconds with the API Claude Code uses for its own list,
signed in with Claude Code's token from the keychain. It reads the token
with `/usr/bin/security`, as Claude Code does: Claude Code writes its
keychain items with that tool, so they trust it, and macOS asks nothing,
not for a new login, not after a rebuild, not at night. Should an item ask
after all, a "Deny" stops Nesso Hub reading it until it restarts. Nesso Hub
keeps the token once read and reads the keychain again only when the token
has expired or is refused, at most every ten minutes. A cloud session is
done once it went idle after working, until you open it.

A token answers only for the organisation its login chose, so the cloud
sessions of a Claude app profile signed in to another organisation need a
Claude Code login of their own, kept apart from the default one by its own
config folder:

```sh
CLAUDE_CONFIG_DIR=~/.claude-other claude auth login
```

and choose that organisation in the browser. Nesso Hub uses every Claude
Code login in the keychain whose folder is right in your home folder, and
merges what they list; it finds a new one within ten minutes. It matches
each login to its folder: Claude Code names a login's keychain item after
the SHA-256 of its folder's path. Logging in again in the same folder is
picked up the same way. A login whose folder is elsewhere is left out, and
named in the log: it is most likely another app's, one that embeds Claude
Code with a folder of its own, as Arduino App Lab does in Application
Support.

A token lasts a few hours, and only Claude Code renews it, when it runs with
that login's folder: the Claude app gives its own sessions a token of its
own, so even the default login lapses if Claude Code only runs inside the
app. Four and a half minutes before a token expires, Nesso Hub runs
`claude mcp list` with its folder: loading the organisation's claude.ai
connectors, Claude Code checks the token and renews it, under its own lock,
without a model call. It renews only in a token's last five minutes, so
asking earlier would start every MCP server for nothing. The log says
whether it did. Nesso Hub never renews a token itself,
which would spend the refresh token behind Claude Code's back. A login that
lapsed more than a day ago counts as abandoned and only goes to the log.

Tapping a session of the Claude app opens it through the app's
`claude://code/continue?session=…` link, and a cloud one through
`claude://code/<id>`; tapping a terminal session brings its terminal forward,
though not the right tab.

With two instances of the Claude app open (`open -n -a Claude`), each signed
in to its own organisation, a link sent to the app as a whole lands in
either. So Nesso Hub hands the link to the right instance itself, as the
'GURL' Apple event macOS would send: a running session to the instance that
runs it, a finished one to the instance its organisation was last seen in,
and a cloud one to the instance of the organisation its Claude Code login
lists, which Nesso Hub learns from the sessions of this Mac that login lists
under Remote Control. The first time, macOS asks whether Nesso Hub may
control Claude. When the instance is not known, the link goes to the app as
a whole.

### How the automations see who is in

Meet only draws a tile for some of the people in a large call, so the tiles
are not enough. Nesso Hub opens the People panel for a moment, so that Meet
builds its list, and closes it again. The list stays in the page out of
sight, Meet keeps it up to date, and its search still filters it: the app
types the person's name into it and checks the participants each second.
People who were invited but have not joined are listed in the same panel and
are ignored. Right after you join, Meet takes a moment to draw the People
button, so the app keeps looking for it for 30 seconds before it gives up on
that call.

The Meet REST API would be the clean way to do this, but it needs a Google
Cloud project, and the hidden project behind Apps Script does not have the
Meet API enabled.

### Command line helpers

They need the app's Automation permission, so they run through the app:

```sh
open -n -W "/Applications/Nesso Hub.app" --stdout out.txt --args meet-probe
```

- `meet-probe`: the buttons the Meet script sees, for when Meet changes.
- `meet-js file.js`: runs your own script in the Meet tab.
- `meet-react 🦄 [--dry]`: sends a reaction step by step; `--dry` stops before
  the click.
- `meet-watch "Name" [seconds]`: looks for someone in the People panel like an
  automation does, without reacting.
- `render-reactions out.png [query]`: draws the Reactions window to a PNG.
- `render-sessions out.png [--compact]`: draws the sessions window to a PNG,
  with the sessions of this Mac only, so that it needs no keychain.
- `claude-probe [seconds]`: the Claude sessions as the Claude page sees them,
  and what the cloud API lists, printed each time they change.

## Protocol

One BLE service, `8c3b0001-5b1e-4c39-9d5e-6f1a7e2b9c40`, with an RX
characteristic the Mac writes to (`…0002…`) and a TX characteristic the Nesso
notifies on (`…0003…`). Each direction carries one JSON object per line, split
into as many writes or notifications as it takes.

Mac → Nesso:

| `t` | Fields | |
|---|---|---|
| `hello` | | Asks the Nesso to introduce itself. |
| `page` | `title`, `sub`, `accent`, `rows: [{h, tiles: [{id, label, icon, bg, fg, font}]}]`, `holds: [{k, label, done, icon, bg}]` | Replaces the screen. Tiles share their row's width; `font` is `s`, `m`, `l` or `xl`. A key in `holds` becomes hold-to-confirm: see below. |
| `icon` | `id`, `w`, `h`, `f`, `d` | An icon a page refers to: `f` is `rgb565` (big-endian) or `a8` (a mask tinted with the tile's `fg`), `d` is base64. |
| `pixels` | `b`, `leds: [{c, fx}]` | What the Modulino Pixels shows, one entry per LED from the left; the rest go dark. `c` is `#RRGGBB`, `fx` is `pulse`, `blink` or absent for a steady light, `b` is the brightness, 0 to 31. The LEDs also go dark when the Mac disconnects. |

Nesso → Mac:

| `t` | Fields | |
|---|---|---|
| `hello` | `fw`, `proto`, `w`, `h`, `px` | Firmware and protocol version, screen size, and how many LEDs it has: 8 with a Modulino Pixels, 0 without. |
| `need` | `ids` | Icons a page uses that the Nesso does not have. |
| `tap` | `id` | A tile with an `id` was tapped. |
| `key` | `k`, `a` | Side key `1` or `2`, action `click` or `long`. |

A key the page lists in `holds` fires `long` after 1.2 s instead of 0.8 s.
From 0.2 s on, the Nesso covers the screen with a ring that fills up, with the
hold's `icon` and `label`; letting go before it is full runs the ring back
to empty and sends nothing. Once full it sends `long` and shows `done` until the next page
arrives, or for 4 s. A press shorter than 0.2 s is still a `click`.

## Limits

- Meet's class names are obfuscated, so the script finds things by their
  accessible labels, in English and Italian. When Google changes the page, a
  button can stop responding until the script is updated; `meet-probe` and
  `meet-js` are there to find the new way in.
- Reactions sent by the Nesso or by an automation come from you, as if you had
  clicked them.
- The Claude files are Claude Code's and the Claude app's own, not a
  documented interface, so an update of either can change them. Nesso Hub
  skips what it cannot read and logs it once; `claude-probe` shows what it
  still sees.
- The cloud API is not documented either, and it only works while a Claude
  Code login's token is valid. Nesso Hub has Claude Code renew it before it
  expires; when that fails, the menu bar says so, and running `claude` with
  that login's folder renews it.
- A token answers for the one organisation its login chose: the cloud
  sessions of another organisation need a login of their own, as told in
  "How Nesso Hub sees the Claude sessions".

## Licence

MIT, see `LICENSE`. `mac/Resources/emoji-metadata` is Google's
[emoji-metadata](https://github.com/googlefonts/emoji-metadata), under the
Apache License 2.0.
