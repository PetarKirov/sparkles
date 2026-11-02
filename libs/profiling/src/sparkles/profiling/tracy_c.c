/*
 * ImportC bridge for Tracy's C client API (`PRF20`) — includes only; the
 * symbols live in libTracyClient.so. Imported by `sparkles.profiling.tracy`
 * under `version (SparklesTracy)` alone, and never compiled as a source.
 *
 * `TRACY_ENABLE` must be defined (the `tracy` configuration passes it): without
 * it TracyC.h declares no functions, only empty macros.
 */
#include <stddef.h>
#include <stdint.h>

#pragma attribute(push, nogc, nothrow)
#include <tracy/TracyC.h>
#pragma attribute(pop)
