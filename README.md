# Nesso Hub

An [Arduino Nesso N1](https://docs.arduino.cc/hardware/nesso-n1/) as a
Bluetooth companion screen for the Mac. In a Google Meet call it shows big
mic and camera toggles and your favourite reactions, and it can react on its
own when someone joins a meeting.

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
  - up to nine reactions. Any emoji in Meet's full picker works, not just the
    quick bar: the ones that are not in it are found through the picker's
    search, by the shortcodes Meet uses (`:United-Kingdom-flag:`).
- **Clock page** the rest of the time.
- **Reactions window** (menu bar → Choose Reactions…): every emoji in Meet's
  picker, in Meet's groups, searchable in English and Italian and by
  shortcode, with a live preview of the Nesso.
- **Automations**: "when *person* joins the meeting *title*, send *emoji*",
  once per meeting. They run with or without the Nesso connected.

## Hardware and firmware

The firmware is in `firmware/NessoHub`. It needs the `esp32:esp32` core 3.3.x
and the `Arduino_Nesso_N1` and `ArduinoJson` (7.x) libraries.

```sh
arduino-cli core install esp32:esp32
arduino-cli lib install Arduino_Nesso_N1 ArduinoJson
arduino-cli compile -b esp32:esp32:arduino_nesso_n1 -u -p /dev/cu.usbmodem101 firmware/NessoHub
```

Over USB it also has a serial console (`status`, `screen`, `tap <x> <y>`, or a
JSON message as if the Mac had sent it). `tools/` talks to it with nothing but
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
  ]
}
```

- `browser`: any Chromium browser with the same AppleScript support (Chrome,
  Edge, Brave), by bundle id.
- `automations`: a meeting is recognised by its `title` (the Calendar event's
  name, which Meet puts in the tab title) or by its `code`; either is enough,
  so a rule outlives a change of code. `joins` is matched against participant
  names, ignoring case and accents.

### How the automations see who is in

Meet only draws a tile for some of the people in a large call, so the tiles
are not enough. Nesso Hub opens the People panel for a moment, so that Meet
builds its list, and closes it again. The list stays in the page out of
sight, Meet keeps it up to date, and its search still filters it: the app
types the person's name into it and checks the participants each second.
People who were invited but have not joined are listed in the same panel and
are ignored.

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

## Protocol

One BLE service, `8c3b0001-5b1e-4c39-9d5e-6f1a7e2b9c40`, with an RX
characteristic the Mac writes to (`…0002…`) and a TX characteristic the Nesso
notifies on (`…0003…`). Each direction carries one JSON object per line, split
into as many writes or notifications as it takes.

Mac → Nesso:

| `t` | Fields | |
|---|---|---|
| `hello` | | Asks the Nesso to introduce itself. |
| `page` | `title`, `sub`, `accent`, `rows: [{h, tiles: [{id, label, icon, bg, fg, font}]}]` | Replaces the screen. Tiles share their row's width; `font` is `s`, `m`, `l` or `xl`. |
| `icon` | `id`, `w`, `h`, `f`, `d` | An icon a page refers to: `f` is `rgb565` (big-endian) or `a8` (a mask tinted with the tile's `fg`), `d` is base64. |

Nesso → Mac:

| `t` | Fields | |
|---|---|---|
| `hello` | `fw`, `proto`, `w`, `h` | Firmware and protocol version, screen size. |
| `need` | `ids` | Icons a page uses that the Nesso does not have. |
| `tap` | `id` | A tile with an `id` was tapped. |
| `key` | `k`, `a` | Side key `1` or `2`, action `click` or `long`. |

## Limits

- Meet's class names are obfuscated, so the script finds things by their
  accessible labels, in English and Italian. When Google changes the page, a
  button can stop responding until the script is updated; `meet-probe` and
  `meet-js` are there to find the new way in.
- Reactions sent by the Nesso or by an automation come from you, as if you had
  clicked them.

## Licence

MIT, see `LICENSE`. `mac/Resources/emoji-metadata` is Google's
[emoji-metadata](https://github.com/googlefonts/emoji-metadata), under the
Apache License 2.0.
