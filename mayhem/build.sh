#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Fuzz harnesses shipped by upstream in fuzz/ (meson `-Dfuzz=true`); one binary per harness.
# The *_buffer_fuzzer set is generated from generic_buffer_fuzzer.cc, one per saver.
MESON_COMMON=(-Dexamples=false -Dcplusplus=false -Ddocs=false
              -Dintrospection=disabled -Dvapi=false -Dmodules=disabled -Dbackend_max_links=4)
# Older commits (before the man/po/tests/tools/fuzz options existed) always build those subdirs; only
# pass the switches the tree knows, so this layer works on both sides of that change.
for opt in man po; do
    grep -q "^option('$opt'" meson_options.txt && MESON_COMMON+=("-D$opt=false")
done
SW_FUZZ=(); SW_NOFUZZ=(); SW_TESTS=()
grep -q "^option('tools'" meson_options.txt && { SW_FUZZ+=(-Dtests=false -Dtools=false); SW_NOFUZZ+=(-Dtests=false -Dtools=false); SW_TESTS+=(-Dtests=true -Dtools=true); }
grep -q "^option('fuzz'" meson_options.txt && { SW_FUZZ+=(-Dfuzz=true); SW_NOFUZZ+=(-Dfuzz=true); SW_TESTS+=(-Dfuzz=false); }

# configure_or_reconfigure <builddir> <meson args...>: idempotent on an already-configured tree
setup() {
    local dir="$1"; shift
    if [ -f "$dir/meson-private/coredata.dat" ]; then
        meson setup --reconfigure "$dir" "$@"
    else
        meson setup "$dir" "$@"
    fi
}

mkdir -p "$SRC/build"

# Same relaxations as upstream's own sanitizer CI (.github/workflows/ci.yml): -fno-sanitize=function
# (libvips casts callbacks through generic function-pointer types everywhere, so it fires on every
# input) and shift-exponent (libvips#4960, boolean.c; upstream suppresses it, but the suppression hook
# needs a newer LLVM than clang-19). ASan and the rest of UBSan stay on and halting. The HWY define is
# upstream CI's workaround for highway AVX3 targets under sanitizers.
RELAX=(-fno-sanitize=function,shift-exponent -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION
       "-DHWY_BROKEN_TARGETS=(HWY_AVX3|HWY_AVX3_DL)")

# Shims linked into every fuzz + standalone binary (passed to the linker as -Wl,<obj>,<obj>):
#  * cache_off.o: vips_cache_set_max(0) from a constructor, so no operation (e.g. a loader keyed on the
#    reused input buffer) is cached across inputs.
#  * lsan_off.o: LeakSanitizer off at build time (ASan/UBSan stay on), a TU defining
#    __lsan_is_turned_off. Only with ASan.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/cache_off.cc" -o "$SRC/build/cache_off.o"
SHIM_LDFLAGS="-Wl,$SRC/build/cache_off.o"
case "$SANITIZER_FLAGS" in
    *address*)
        $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$SRC/build/lsan_off.o"
        SHIM_LDFLAGS="$SHIM_LDFLAGS,$SRC/build/lsan_off.o" ;;
esac

# 1) Sanitized libFuzzer build of the project + harnesses. -fsanitize=fuzzer-no-link is added to the
#    library compile by meson (-Dfuzzing_engine=libfuzzer) so the fuzzed code carries SanCov.
CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O1 ${RELAX[*]}" CXXFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O1 ${RELAX[*]}" \
LDFLAGS="$SANITIZER_FLAGS" \
setup build/fuzz "${MESON_COMMON[@]}" --buildtype=plain --default-library=static \
    "${SW_FUZZ[@]}" -Dfuzzing_engine=libfuzzer \
    -Dfuzzer_ldflags="$SHIM_LDFLAGS"
meson compile -C build/fuzz -j "$MAYHEM_JOBS"

# 2) Standalone (run-once, no libFuzzer runtime) reproducers: upstream's own file-input driver
#    (fuzz/StandaloneFuzzTargetMain.c, -Dfuzzing_engine=none).
CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O1 ${RELAX[*]}" CXXFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O1 ${RELAX[*]}" \
LDFLAGS="$SANITIZER_FLAGS" \
setup build/standalone "${MESON_COMMON[@]}" --buildtype=plain --default-library=static \
    "${SW_NOFUZZ[@]}" -Dfuzzing_engine=none \
    -Dfuzzer_ldflags="$SHIM_LDFLAGS"
meson compile -C build/standalone -j "$MAYHEM_JOBS"

for f in build/fuzz/fuzz/*_fuzzer; do
    [ -x "$f" ] || continue
    name=$(basename "$f")
    cp -f "$f" "$SRC/$name"
    cp -f "build/standalone/fuzz/$name" "$SRC/$name-standalone"
done

# libFuzzer dictionary of every operation/option name, generated from the built library
[ -x build/fuzz/fuzz/generate_vips_dict ] &&
    ASAN_OPTIONS=detect_leaks=0 build/fuzz/fuzz/generate_vips_dict > "$SRC/vips_fuzzer.dict"

# 3) The project's own test suite (meson tests), project's NORMAL flags: no sanitizers, no DWARF pin.
(
    unset CFLAGS CXXFLAGS LDFLAGS
    export CFLAGS="$COVERAGE_FLAGS" CXXFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS"
    setup build/tests "${MESON_COMMON[@]}" --buildtype=debugoptimized \
        "${SW_TESTS[@]}"
)
meson compile -C build/tests -j "$MAYHEM_JOBS"
