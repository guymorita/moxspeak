# Using MoxSpeak from a launcher

MoxSpeak answers a `moxspeak://` URL, which is the one automation surface every launcher
on macOS already speaks. There is no extension to install and nothing to keep up to date.

| URL | |
|---|---|
| `moxspeak://speak` | Read the selection, or the last thing copied |
| `moxspeak://pause` | Pause or resume |
| `moxspeak://stop` | Stop |
| `moxspeak://back` | Back 15 seconds |
| `moxspeak://forward` | Forward 15 seconds |
| `moxspeak://skip?seconds=-30` | Move by any amount |
| `moxspeak://speak?text=Hello` | Read this exact text, ignoring the selection |

Always open these with **`open -g`**. Without `-g`, macOS brings MoxSpeak to the front, it
becomes the frontmost application, and the selection it goes looking for is its own.

The built-in shortcuts keep working. This is an extra door, not a replacement.

You may not need any of this for skipping: MoxSpeak publishes a real Now Playing timeline,
so the media keys, the Control Center buttons and a paired set of AirPods already move by
fifteen seconds and can scrub.

## Raycast

Copy `raycast/` somewhere, then Raycast → Extensions → Script Commands → Add Directory and
point it there. Three commands appear, and you can give any of them a hotkey.

## Alfred

No file needed. New workflow, add a Hotkey trigger, connect it to **Run Script** with
Language `/bin/bash`:

```bash
open -g "moxspeak://speak"
```

## Shortcuts, Keyboard Maestro, BetterTouchTool, anything else

Same idea: a **Open URL** action with `moxspeak://speak`, or a shell action running the
line above.

## Passing text in

If the calling tool already has the text, hand it over and MoxSpeak will not go looking
for a selection at all:

```bash
open -g "moxspeak://speak?text=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read()))' <<< "some text")"
```
