#!/usr/bin/env bash
# Synthesises the DEBUG-only self-test fixture: a short fictional meeting
# spoken by macOS `say`, converted to 16 kHz mono 16-bit WAV. It is synthetic
# test data, not a recording, and is copied only into Debug app bundles
# (project.yml). Usage: make-selftest-fixture.sh <out.wav>
set -euo pipefail
out="$1"
tmp="$(dirname "$out")/selftest-$$.aiff"
mkdir -p "$(dirname "$out")"
# [[slnc N]] inserts N ms of silence so the VAD sees separate utterances.
text='Good morning everyone, thanks for joining the weekly planning meeting. [[slnc 1200]]
First item is the release schedule. We agreed to ship the beta on Friday, and the final build two weeks later. [[slnc 1200]]
The design team will update the onboarding screens by Wednesday. [[slnc 1000]]
There is one open question about pricing for the team plan. We will decide that next week after the survey results come in. [[slnc 1200]]
Action items. The engineering lead will fix the login crash before the beta. Marketing will draft the announcement post. Support will prepare the help center articles. [[slnc 1200]]
Any other business? No? Great, thanks everyone, see you next week.'
say -v Samantha -r 175 -o "$tmp" "$text" 2>/dev/null || say -r 175 -o "$tmp" "$text"
afconvert -f WAVE -d LEI16@16000 -c 1 "$tmp" "$out"
rm -f "$tmp"
