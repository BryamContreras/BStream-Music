// Device-side clock markers for profile_android_scroll.mjs. Build example:
// aarch64-linux-android21-clang -O2 -std=c11 -Wall -Wextra -Werror \
//   tool/android_profile_clock.c -o build/diagnostics/bstream_profile_clock
// The BOOTTIME sample is bracketed around MONOTONIC and averaged to minimize
// the skew between the two clocks. This executable never changes device state.
#define _POSIX_C_SOURCE 200809L

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

static int64_t nanoseconds(const struct timespec* value) {
  return (int64_t)value->tv_sec * INT64_C(1000000000) + value->tv_nsec;
}

int main(void) {
  struct timespec boot_before;
  struct timespec monotonic;
  struct timespec boot_after;
  if (clock_gettime(CLOCK_BOOTTIME, &boot_before) != 0 ||
      clock_gettime(CLOCK_MONOTONIC, &monotonic) != 0 ||
      clock_gettime(CLOCK_BOOTTIME, &boot_after) != 0) {
    perror("clock_gettime");
    return 1;
  }
  const int64_t first_boot_ns = nanoseconds(&boot_before);
  const int64_t boot_ns =
      first_boot_ns + (nanoseconds(&boot_after) - first_boot_ns) / 2;
  printf("BSTREAM_CLOCK %" PRId64 " %" PRId64 "\n", boot_ns,
         nanoseconds(&monotonic));
  return 0;
}
