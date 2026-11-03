#!/usr/bin/env bash
#
# mayhem/test.sh — RUN libvips' own meson test suite plus known-answer probes of the built CLI
# (both pre-built by mayhem/build.sh into build/tests).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


fail_build() { echo "mayhem/test.sh: $*" >&2; emit_ctrf "libvips" 0 1 0; exit 1; }

B="$SRC/build/tests"
T="$B/tools"
IMG="$SRC/test/test-suite/images"
[ -f "$B/build.ninja" ] && [ -x "$T/vips" ] && [ -x "$T/vipsheader" ] \
    || fail_build "build/tests missing: mayhem/build.sh must build it"

passed=0; failed=0; skipped=0

# 1) upstream's meson test suite (cli, formats, seq, keep, threading, ... shell scripts and C tests)
LOG=$(mktemp)
meson test -C "$B" --no-rebuild --print-errorlogs --num-processes "$MAYHEM_JOBS" >"$LOG" 2>&1
cat "$LOG"
mnum() { sed -n "s/^$1: *\([0-9][0-9]*\).*/\1/p" "$LOG" | tail -1; }
mok=$(mnum "Ok"); mfail=$(mnum "Fail"); mto=$(mnum "Timeout"); mskip=$(mnum "Skipped")
mxf=$(mnum "Expected Fail"); mup=$(mnum "Unexpected Pass")
[ -n "$mok" ] || fail_build "could not parse the meson test summary"
passed=$(( passed + mok + ${mxf:-0} ))
failed=$(( failed + ${mfail:-0} + ${mto:-0} + ${mup:-0} ))
skipped=$(( skipped + ${mskip:-0} ))
rm -f "$LOG"

# 2) known-answer probes: input image -> exact value printed by the freshly built CLI.
# An empty or wrong answer is a failure (a no-op/neutered binary prints nothing).
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export VIPS_WARNING=0
kat() {   # kat <name> <expected> <command...>
    local name="$1" want="$2" got; shift 2
    got=$("$@" 2>/dev/null | tr -d '\n')
    if [ "$got" = "$want" ]; then passed=$((passed+1)); echo "KAT ok   $name = $got"
    else failed=$((failed+1)); echo "KAT FAIL $name: want '$want' got '$got'" >&2; fi
}
run() { "$@" >/dev/null 2>&1; }

kat jpeg-width   290 "$T/vipsheader" -f width  "$IMG/sample.jpg"
kat jpeg-height  442 "$T/vipsheader" -f height "$IMG/sample.jpg"
kat jpeg-bands   3   "$T/vipsheader" -f bands  "$IMG/sample.jpg"
kat png-width    290 "$T/vipsheader" -f width  "$IMG/sample.png"
kat tiff-height  442 "$T/vipsheader" -f height "$IMG/sample.tif"
kat gif-width    85  "$T/vipsheader" -f width  "$IMG/cogs.gif"
kat gif-height   77  "$T/vipsheader" -f height "$IMG/cogs.gif"
kat jpeg-avg     117.098882 "$T/vips" avg "$IMG/sample.jpg"
kat jpeg-max     242.000000 "$T/vips" max "$IMG/sample.jpg"
kat jpeg-deviate 34.201077  "$T/vips" deviate "$IMG/sample.jpg"

run "$T/vips" invert "$IMG/sample.jpg" "$WORK/inv.v"
kat invert-avg   137.901118 "$T/vips" avg "$WORK/inv.v"

run "$T/vips" rot "$IMG/sample.jpg" "$WORK/rot.v" d90
kat rot90-width  442 "$T/vipsheader" -f width  "$WORK/rot.v"
kat rot90-height 290 "$T/vipsheader" -f height "$WORK/rot.v"

run "$T/vips" extract_area "$IMG/sample.jpg" "$WORK/crop.v" 10 10 20 30
kat crop-width   20  "$T/vipsheader" -f width  "$WORK/crop.v"
kat crop-height  30  "$T/vipsheader" -f height "$WORK/crop.v"
kat crop-avg     135.355556 "$T/vips" avg "$WORK/crop.v"

run "$T/vips" copy "$IMG/sample.jpg" "$WORK/rt.png"
kat png-roundtrip-avg 117.098882 "$T/vips" avg "$WORK/rt.png"
run "$T/vips" copy "$WORK/rt.png" "$WORK/rt.tif"
kat tiff-roundtrip-avg 117.098882 "$T/vips" avg "$WORK/rt.tif"

run "$T/vipsthumbnail" "$IMG/sample.jpg" -s 50 -o "$WORK/th.jpg"
kat thumb-width  33 "$T/vipsheader" -f width  "$WORK/th.jpg"
kat thumb-height 50 "$T/vipsheader" -f height "$WORK/th.jpg"

emit_ctrf "libvips-meson+kat" "$passed" "$failed" "$skipped"
