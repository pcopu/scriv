#include "ScrivCLICoverage.h"
#include <stddef.h>

/* LLVM's documented no-filesystem runtime integration. Defining this symbol
 * prevents extraction of the runtime initializer from the static archive, so
 * LLVM_PROFILE_FILE and normal atexit profile writing are never initialized.
 * https://clang.llvm.org/docs/SourceBasedCodeCoverage.html
 * This translation unit must remain uninstrumented.
 */
int __llvm_profile_runtime = 0;

/* Public compiler-rt ABI. Explicit declarations avoid the no-op macros used
 * by instr_prof_interface.h when this C translation unit is uninstrumented.
 * Availability/link behavior must be verified with the selected Apple CLT.
 */
extern uint64_t __llvm_profile_get_size_for_buffer(void);
extern int __llvm_profile_write_buffer(char *buffer);

int scriv_cli_coverage_size(uint64_t *size) {
    if (size == NULL) return SCRIV_CLI_COVERAGE_INVALID_ARGUMENT;
    *size = 0;
    uint64_t required = __llvm_profile_get_size_for_buffer();
    if (required == 0 || required > SCRIV_CLI_COVERAGE_MAX_BYTES)
        return SCRIV_CLI_COVERAGE_SIZE_LIMIT;
    *size = required;
    return SCRIV_CLI_COVERAGE_OK;
}

int scriv_cli_coverage_copy(char *buffer, uint64_t capacity, uint64_t *written) {
    if (written == NULL) return SCRIV_CLI_COVERAGE_INVALID_ARGUMENT;
    *written = 0;
    if (buffer == NULL) return SCRIV_CLI_COVERAGE_INVALID_ARGUMENT;
    if (capacity > SCRIV_CLI_COVERAGE_MAX_BYTES)
        return SCRIV_CLI_COVERAGE_SIZE_LIMIT;
    uint64_t required = 0;
    int status = scriv_cli_coverage_size(&required);
    if (status != SCRIV_CLI_COVERAGE_OK) return status;
    if (capacity < required) return SCRIV_CLI_COVERAGE_BUFFER_TOO_SMALL;
    if (__llvm_profile_write_buffer(buffer) != 0)
        return SCRIV_CLI_COVERAGE_WRITE_FAILED;
    *written = required;
    return SCRIV_CLI_COVERAGE_OK;
}
