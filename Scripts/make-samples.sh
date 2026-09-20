#!/usr/bin/env bash
#
# Generates the audio on the website: the same three passages, spoken by MoxSpeak and by
# the macOS voice, so a visitor can hear the difference rather than be told about it.
#
# Regenerated from this script rather than hand-made, so the samples always come from the
# build that is actually shipping. Run it after a release build:
#
#   ./build-app.sh && Scripts/make-samples.sh
#
# The macOS side uses `say` with Samantha, Apple's own US English voice and the one a
# person is most likely to have heard. Both sides read identical text and are encoded
# identically, so the only variable is the voice.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT="docs/samples"
CLI=".build/release/moxspeak-native"
VOICE="${MOXSPEAK_SAMPLE_VOICE:-af_heart}"

mkdir -p "${OUT}"

# Three shapes of text, because the failure modes differ. Prose tests rhythm, technical
# copy tests acronyms and numbers, and narrative tests whether it sounds like a person.
sample() {
  local name="$1" text="$2"
  echo "==> ${name}"

  # MoxSpeak, through the same engine and text pipeline the app uses.
  "${CLI}" say "${text}" --voice "${VOICE}" --out "${OUT}/${name}-moxspeak.wav"
  afconvert -f mp4f -d aac -b 64000 "${OUT}/${name}-moxspeak.wav" "${OUT}/${name}-moxspeak.m4a"
  rm -f "${OUT}/${name}-moxspeak.wav"

  # macOS, for the comparison.
  say -v Samantha -o "${OUT}/${name}-macos.aiff" "${text}"
  afconvert -f mp4f -d aac -b 64000 "${OUT}/${name}-macos.aiff" "${OUT}/${name}-macos.m4a"
  rm -f "${OUT}/${name}-macos.aiff"

  printf "    %-10s moxspeak %sK   macos %sK\n" "${name}" \
    "$(( $(stat -f%z "${OUT}/${name}-moxspeak.m4a") / 1024 ))" \
    "$(( $(stat -f%z "${OUT}/${name}-macos.m4a") / 1024 ))"
}

sample "article" \
"Researchers have known for decades that the rate at which a glacier sheds mass depends \
less on the air above it than on the water beneath it. What they found under the ice \
last winter was not what anyone expected."

sample "technical" \
"The API returns a 429 when you exceed 60 requests per hour. Back off exponentially, \
starting at 2 seconds, and read the X-RateLimit-Reset header rather than guessing."

sample "fiction" \
"She had read the letter four times before she noticed the postmark. It had been sent \
from a town she had not thought about in eleven years, by someone who was supposed to \
be dead."

echo
echo "Done. ${OUT}/"
