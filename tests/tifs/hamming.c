/* Linux software Hamming ECC as a shared library for the test tools. */
#include <stdint.h>
#include <stdbool.h>
#include <errno.h>
#include <string.h>
#define EXPORT_SYMBOL(x)
typedef uint32_t u32;
#undef __BIG_ENDIAN
#include "hamming_body.c"
