#!/bin/bash
#
# @raycast.schemaVersion 1
# @raycast.title Pause or Resume
# @raycast.mode silent
# @raycast.packageName MoxSpeak
# @raycast.icon ⏸
# @raycast.description Pauses what MoxSpeak is reading, or resumes it.

# -g keeps MoxSpeak in the background. Without it, `open` brings MoxSpeak to the front,
# it becomes the frontmost application, and the selection it goes looking for is its own.
open -g "moxspeak://pause"
