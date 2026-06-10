/*
 * asan_options.c — disable LeakSanitizer for all simdutf fuzz targets.
 *
 * WHY: ASan enables LSan (leak detection) by default on Linux. Under Mayhem's
 * ptrace-based coverage collection, LSan detects the tracer process and aborts
 * with exit code 1 (printing "LeakSanitizer does not work under ptrace").
 * Mayhem treats a non-zero exit as a broken run and records 0 edges, even
 * though the target code executed correctly.
 *
 * HOW: The `__asan_default_options` weak symbol is the standard ASan mechanism
 * for injecting runtime options at link time. Returning "detect_leaks=0" turns
 * off LSan globally for any binary that links this file. This is identical to
 * setting ASAN_OPTIONS=detect_leaks=0 at runtime, but baked into the binary so
 * Mayhem's environment does not need to export it.
 *
 * This file must be compiled and linked BEFORE the ASan runtime so the weak
 * symbol is visible. build.sh adds asan_options.o to every harness link line.
 */
const char *__asan_default_options(void) {
    return "detect_leaks=0";
}
