#!/bin/bash
#
# @raycast.schemaVersion 1
# @raycast.title Speak Selection
# @raycast.mode silent
# @raycast.packageName MoxSpeak
# @raycast.icon 🔊
# @raycast.description Reads whatever you have selected, or the last thing you copied.

# -g keeps MoxSpeak in the background. Without it, `open` brings MoxSpeak to the front,
# it becomes the frontmost application, and the selection it goes looking for is its own.
open -g "moxspeak://speak"
