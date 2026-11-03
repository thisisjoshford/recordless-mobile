/* Force-included into every C, C++ and Objective-C translation unit of
 * whisper.cpp and ggml (see whisper_wipe.cmake). It renames their calls to
 * `free` and `realloc` so the freed block is zeroed first. The definitions
 * live in wipe.cpp, linked into the same static library.
 *
 * Declared before any system header so that <stdlib.h>'s own declarations of
 * free/realloc become (identical) redeclarations of the wiping functions. */
#ifndef RECORDLESS_WIPE_FREE_H
#define RECORDLESS_WIPE_FREE_H
#ifndef __ASSEMBLER__

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif
void recordless_wiping_free(void *ptr);
void *recordless_wiping_realloc(void *ptr, size_t size);
#ifdef __cplusplus
}
#endif

#define free recordless_wiping_free
#define realloc recordless_wiping_realloc

#endif /* __ASSEMBLER__ */
#endif /* RECORDLESS_WIPE_FREE_H */
