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

# Deliberately free of heteronyms. The previous passage opened "She had read the letter",
# and Kokoro said it /riːd/ — present tense — because the pronunciation of "read" depends
# on a part-of-speech call that the G2P front end gets wrong here. Fine to have as a known
# bug; not fine to have as the sample people judge the voice by.
sample "fiction" \
"The lighthouse keeper's daughter kept a list of every ship that passed. On the morning \
of the storm she counted nine going out and only eight coming back, and she never told \
anyone which one was missing."

echo
echo "Done. ${OUT}/"
