#!/usr/bin/env bash
#
# simdutf/mayhem/build.sh — build simdutf's OSS-Fuzz harnesses as sanitized libFuzzer targets
# (+ standalone reproducers), AND simdutf's OWN CMake/ctest suite for mayhem/test.sh.
#
# The fuzzed surface is the simdutf Unicode/transcoding library on attacker-controlled BYTES.
# Each harness feeds the raw input to simdutf validate/transcode/base64/find routines and
# cross-checks every runtime-dispatched SIMD kernel against the others (differential testing):
#   conversion        — convert_* between UTF-8/16(LE/BE)/32 + Latin1; all impls must agree.
#   safe_conversion   — the *_safe convert variants (bounded output buffers).
#   misc              — validate_*, count_*, *_length, change_endianness, autodetect_encoding.
#   roundtrip         — encode->decode roundtrip via a FuzzedDataProvider (clang-provided header).
#   base64            — base64_to_binary across options/last-chunk modes; impls must agree.
#   base64_details    — lower-level base64 helpers (length/needle scanning).
#   with_replacement  — lossy convert-with-replacement transcoding.
#   find              — simdutf::find() for char/char16_t; differential + bounds invariants.
# Inputs are RAW BYTES (no structured header) — interpreted as UTF-8/16/32 / base64 text.
#
# simdutf dispatches SIMD kernels at RUNTIME via CPUID; we build the library for the BASELINE
# x86-64 ISA (NO -march=native) and -DSIMDUTF_ALWAYS_INCLUDE_FALLBACK=On so every kernel + the
# scalar fallback is compiled in and selected at runtime — the binary runs in any container.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN/OUT). We compile the simdutf library ITSELF with $SANITIZER_FLAGS so the
# transcoding code (not just the harness) is instrumented.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
# Ensure SanitizerCoverage is enabled for the library build so Mayhem sees >0 edges.
# -fsanitize=fuzzer-no-link injects sancov instrumentation without pulling in the libFuzzer
# driver (which is linked separately via $LIB_FUZZING_ENGINE). Only add it when the flags
# don't already contain 'fuzzer' (e.g. a full -fsanitize=fuzzer build already implies it).
if [[ "$SANITIZER_FLAGS" != *fuzzer* ]]; then
  SANITIZER_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link"
fi
# DEBUG_FLAGS: DWARF ≤ 3 required by Mayhem triage (clang-19 default is DWARF-5).
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
export DEBUG_FLAGS
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${SRC:=$(cd "$(dirname "$0")/.." && pwd)}"
: "${OUT:=/mayhem}"
# Standalone driver: use simdutf's OWN fuzz/main.cpp (copied into mayhem/harnesses) — it reads file
# paths from argv and feeds the bytes to LLVMFuzzerTestOneInput. It's purpose-built C++ for these
# harnesses, so we prefer it over the org C default ($STANDALONE_FUZZ_MAIN from the base env).
STANDALONE_FUZZ_MAIN="$SRC/mayhem/harnesses/main.cpp"
export SANITIZER_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS SRC OUT

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"
CXXSTD="-std=c++20"

# ── 1) Build the simdutf static library WITH sanitizers (the fuzzed transcoder is instrumented) ────
#     Baseline x86-64 only (runtime CPUID dispatch); fallback always included so it runs anywhere.
BUILD="$SRC/mayhem-build"
rm -rf "$BUILD"
cmake -S "$SRC" -B "$BUILD" \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_BUILD_TYPE=Debug \
      -DSIMDUTF_CXX_STANDARD=20 \
      -DSIMDUTF_TESTS=Off \
      -DSIMDUTF_TOOLS=Off \
      -DSIMDUTF_FUZZERS=Off \
      -DSIMDUTF_BENCHMARKS=Off \
      -DSIMDUTF_ALWAYS_INCLUDE_FALLBACK=On \
      -DBUILD_SHARED_LIBS=Off \
      -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
      -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
cmake --build "$BUILD" --target simdutf -j"$MAYHEM_JOBS"
cmake --install "$BUILD" --prefix "$BUILD/install"

LIBSIMDUTF="$BUILD/install/lib/libsimdutf.a"
[ -f "$LIBSIMDUTF" ] || LIBSIMDUTF="$(find "$BUILD" -name 'libsimdutf.a' | head -1)"
INCDIR="$BUILD/install/include"
[ -d "$INCDIR" ] || INCDIR="$SRC/include"

# ── 2) Build the standalone run-once main as an object (no libFuzzer runtime; reads a file) ────────
"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS $CXXSTD -I"$INCDIR" -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"

# ── 2b) Build asan_options.o — bakes detect_leaks=0 into every target so LSan does not abort
#        under Mayhem's ptrace-based coverage collection (LSan detects the tracer and calls _exit(1),
#        which Mayhem sees as a broken run with 0 edges). Compiled as C (not C++) for maximum
#        compatibility with the ASan ABI; no sanitizer flags so the symbol is pristine.
"$CC" $DEBUG_FLAGS -c "$SRC/mayhem/asan_options.c" -o "$BUILD/asan_options.o"

# ── 3) Build each OSS-Fuzz harness twice: libFuzzer (-> $OUT/<name>) + standalone reproducer ───────
#     (atomic_base64 is excluded — OSS-Fuzz drops it; libc++ lacks atomic_ref there.)
FUZZERS="conversion safe_conversion misc roundtrip base64 with_replacement base64_details find"
for harness in $FUZZERS; do
  obj="$BUILD/$harness.o"
  "$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS $CXXSTD -I"$INCDIR" -I"$HARNESS_DIR" \
      -c "$HARNESS_DIR/$harness.cpp" -o "$obj"

  # libFuzzer target -> $OUT/<name>  (asan_options.o must appear before the ASan runtime)
  "$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS $CXXSTD $LIB_FUZZING_ENGINE \
      "$BUILD/asan_options.o" "$obj" "$LIBSIMDUTF" -o "$OUT/$harness"

  # standalone reproducer (no libFuzzer runtime) -> $OUT/<name>-standalone
  "$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS $CXXSTD \
      "$BUILD/asan_options.o" "$obj" "$BUILD/standalone_main.o" "$LIBSIMDUTF" -o "$OUT/$harness-standalone"

  echo "built $harness (+ standalone)"
done

# ── 4) Build simdutf's OWN ctest suite with NORMAL flags (clean, separate tree) so test.sh only
#       RUNS it. These are real known-answer transcoding tests; keep them sanitizer-free so test.sh
#       is an honest functional oracle and avoids sanitizer/UB-trap noise. SIMDUTF_FAST_TESTS=On
#       shrinks the randomized trials so the suite finishes in build time. ───────────────────────────
TESTBUILD="$SRC/mayhem-tests"
rm -rf "$TESTBUILD"
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake -S "$SRC" -B "$TESTBUILD" \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_BUILD_TYPE=Release \
      -DSIMDUTF_CXX_STANDARD=20 \
      -DSIMDUTF_TESTS=On \
      -DSIMDUTF_FAST_TESTS=On \
      -DSIMDUTF_TOOLS=Off \
      -DSIMDUTF_FUZZERS=Off \
      -DSIMDUTF_BENCHMARKS=Off \
      -DSIMDUTF_ALWAYS_INCLUDE_FALLBACK=On \
      -DBUILD_SHARED_LIBS=Off
# Build a representative, self-contained subset of the known-answer tests (full suite is 80+ targets).
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  cmake --build "$TESTBUILD" -j"$MAYHEM_JOBS" \
      --target validate_utf8_basic_tests \
      --target validate_utf16le_basic_tests \
      --target validate_utf32_basic_tests \
      --target convert_utf8_to_utf16le_tests \
      --target convert_utf16le_to_utf8_tests \
      --target convert_utf8_to_utf32_tests \
      --target convert_utf32_to_utf8_tests \
      --target base64_tests \
  || echo "WARNING: some test targets failed to build" >&2
echo "built simdutf ctest subset in mayhem-tests/"

echo "build.sh complete:"
ls -la "$OUT"/conversion "$OUT"/safe_conversion "$OUT"/misc "$OUT"/roundtrip \
       "$OUT"/base64 "$OUT"/with_replacement "$OUT"/base64_details "$OUT"/find 2>&1 || true
