#include <simdutf.h>
#include <cstddef>
#include <cstdint>
#include <string>

#ifndef UTF_BENCH_SIMDUTF_REVISION
#error "Define UTF_BENCH_SIMDUTF_REVISION to the actual simdutf git revision"
#endif

extern "C" {
const char *utf_bench_simdutf_revision() noexcept {
    return UTF_BENCH_SIMDUTF_REVISION;
}
const char *utf_bench_simdutf_implementation() noexcept {
    // Resolve runtime dispatch before recording the name. No measured call allocates.
    (void)simdutf::validate_utf8("", 0);
    static const std::string name(simdutf::get_active_implementation()->name());
    return name.c_str();
}
std::size_t utf_bench_simdutf_invalid(const char *input, std::size_t length) noexcept {
    const auto result = simdutf::validate_utf8_with_errors(input, length);
    return result.error == simdutf::SUCCESS ? length : result.count;
}
int utf_bench_simdutf_valid(const char *input, std::size_t length) noexcept {
    return simdutf::validate_utf8(input, length) ? 1 : 0;
}
// No capacity argument: callers MUST provision worst-case output capacity.
// On failure count is a source offset; partial output may already be written.
int utf_bench_simdutf_to16(const char *input, std::size_t length,
    char16_t *output, std::size_t *count) noexcept {
    const auto result = simdutf::convert_utf8_to_utf16le_with_errors(input, length, output);
    *count = result.count;
    return result.error == simdutf::SUCCESS ? 1 : 0;
}
int utf_bench_simdutf_to8(const char16_t *input, std::size_t length,
    char *output, std::size_t *count) noexcept {
    const auto result = simdutf::convert_utf16le_to_utf8_with_errors(input, length, output);
    *count = result.count;
    return result.error == simdutf::SUCCESS ? 1 : 0;
}
}
