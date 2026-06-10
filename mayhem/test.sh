#!/usr/bin/env bash
#
# simdutf/mayhem/test.sh — RUN a representative subset of simdutf's OWN ctest suite (built by
# mayhem/build.sh with normal flags) and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: simdutf's tests are real KNOWN-ANSWER transcoding/validation tests — each
# transcodes between UTF-8/16/32/Latin1 (or validates/base64s) and asserts BYTE-EXACT results
# against a scalar reference implementation across every runtime-dispatched SIMD kernel. A no-op /
# "return success" patch (or any change that corrupts the transcoder) cannot pass. This script only
# RUNS the pre-built binaries via `ctest`; it never compiles.
#
# Anti-reward-hacking: beyond ctest, the script runs TWO test binaries directly and greps for the
# string " OK" in their output (each SIMD-kernel test line ends with " OK" or "... OK").
# A binary neutered to exit(0) emits NO output — the grep fails and the suite is marked failed.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=$(cd "$(dirname "$0")/.." && pwd)}"
cd "$SRC"

BUILDDIR="$SRC/mayhem-tests"

# The representative subset mayhem/build.sh compiled (must match the --target list there).
TESTS_RE='^(validate_utf8_basic_tests|validate_utf16le_basic_tests|validate_utf32_basic_tests|convert_utf8_to_utf16le_tests|convert_utf16le_to_utf8_tests|convert_utf8_to_utf32_tests|convert_utf32_to_utf8_tests|base64_tests)$'

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

if [ ! -d "$BUILDDIR" ]; then
  echo "missing $BUILDDIR — run mayhem/build.sh first" >&2
  emit_ctrf "ctest" 0 1 0; exit 2
fi
if ! command -v ctest >/dev/null 2>&1; then
  echo "ctest not available — cannot run the test suite" >&2
  emit_ctrf "ctest" 0 1 0; exit 2
fi

# ── Behavioral (anti-exit-0) oracle ──────────────────────────────────────────────────────────────
# Run two test binaries directly and verify they emit " OK" on at least one line. A neutered binary
# (exit 0 / return 0 main) emits NO output — the grep below fails → oracle_failed=1.
#
# validate_utf8_basic_tests: checks that known-good UTF-8 sequences validate as valid AND known-bad
#   sequences validate as invalid — prints "Running '<test>'...  OK" for each kernel+test pair.
# base64_tests: encodes/decodes known-answer base64 strings across all SIMD kernels; same format.
oracle_failed=0

VALIDATE_UTF8="$BUILDDIR/tests/validate_utf8_basic_tests"
BASE64="$BUILDDIR/tests/base64_tests"

for binary in "$VALIDATE_UTF8" "$BASE64"; do
  name="$(basename "$binary")"
  if [ ! -x "$binary" ]; then
    echo "ORACLE FAIL: $name not executable (was it built?)" >&2
    oracle_failed=1
    continue
  fi
  # Capture output; the binary prints "Running '...'...  OK" for every kernel/test it runs.
  bin_out="$("$binary" 2>&1)"
  echo "$bin_out"
  # If the binary emits NO " OK" lines, it was neutered (or completely broken).
  if ! echo "$bin_out" | grep -qF " OK"; then
    echo "ORACLE FAIL: $name produced no ' OK' output — neutered or broken" >&2
    oracle_failed=1
  fi
done

if [ "$oracle_failed" -ne 0 ]; then
  echo "behavioral oracle FAILED — test.sh would pass a neutered program; aborting" >&2
  emit_ctrf "ctest" 0 1 0; exit 1
fi

# ── ctest suite ──────────────────────────────────────────────────────────────────────────────────
echo "=== running ctest subset in $BUILDDIR ==="
out="$(env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
       ctest --test-dir "$BUILDDIR" -R "$TESTS_RE" --output-on-failure -j"$(nproc)" 2>&1)"; rc=$?
echo "$out"

# ctest prints:  N% tests passed, M tests failed out of T
TOTAL=$(printf '%s\n' "$out" | sed -n 's/.*tests passed,[[:space:]]*[0-9][0-9]*[[:space:]]*tests failed out of[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)
FAILED=$(printf '%s\n' "$out" | sed -n 's/.*tests passed,[[:space:]]*\([0-9][0-9]*\)[[:space:]]*tests failed out of.*/\1/p' | tail -1)
: "${TOTAL:=0}" "${FAILED:=0}"
PASSED=$(( TOTAL - FAILED ))
[ "$PASSED" -lt 0 ] && PASSED=0

# If ctest produced no parseable summary, fall back to its exit code.
if [ "$TOTAL" -eq 0 ]; then
  echo "could not parse ctest summary; using ctest exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "ctest" 1 0 0; exit 0; }
  emit_ctrf "ctest" 0 1 0; exit 1
fi

emit_ctrf "ctest" "$PASSED" "$FAILED" 0
