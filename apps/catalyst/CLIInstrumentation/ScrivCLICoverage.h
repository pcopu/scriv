#ifndef SCRIV_CLI_COVERAGE_H
#define SCRIV_CLI_COVERAGE_H

#if !defined(SCRIV_CLI_AUTOMATION) || !defined(SCRIV_CLI_COVERAGE)
#error "Coverage is available only in explicitly instrumented automation builds."
#endif

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* No allocation, files, environment destinations, counter reset, or exit flush.
 * The caller owns the buffer and must serialize collection. Live counters may
 * change during copying: this is an observed interval, not causal attribution.
 * Raw profiles require compatible LLVM tools and the exact instrumented binary.
 */
#define SCRIV_CLI_COVERAGE_MAX_BYTES (UINT64_C(16) * 1024 * 1024)
enum {
    SCRIV_CLI_COVERAGE_OK = 0,
    SCRIV_CLI_COVERAGE_INVALID_ARGUMENT = 1,
    SCRIV_CLI_COVERAGE_SIZE_LIMIT = 2,
    SCRIV_CLI_COVERAGE_BUFFER_TOO_SMALL = 3,
    SCRIV_CLI_COVERAGE_WRITE_FAILED = 4
};

/* On failure the output size is zero. Neither function snapshots atomically. */
int scriv_cli_coverage_size(uint64_t *size);
int scriv_cli_coverage_copy(char *buffer, uint64_t capacity, uint64_t *written);

#ifdef __cplusplus
}
#endif
#endif
