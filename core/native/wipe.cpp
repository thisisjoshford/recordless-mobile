// Zero C/C++ heap blocks before they are freed.
//
// 1. Replacement global operator new/delete (every replaceable form). Linked
//    into the image, these are what whisper.cpp's std::string / std::vector /
//    new / delete bind to at static link time. Deletes zero malloc_size(p)
//    bytes with memset_s (not elidable) before free().
// 2. recordless_wiping_free / recordless_wiping_realloc: whisper.cpp and ggml
//    are compiled with wipe_free.h force-included, which renames their free()
//    and realloc() calls to these. On iOS ggml's CPU buffers and Metal shared
//    (unified memory) buffers are posix_memalign'd and free()d, so this wipes
//    them too.
//
// This file must not include wipe_free.h: it calls the real free/realloc.

#define __STDC_WANT_LIB_EXT1__ 1
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <malloc/malloc.h>
#include <new>
#include <stdexcept>
#include <string>
#include <string.h>
#include <vector>

namespace {

// Test probe (see the extern "C" recordless_wipe_probe_* below). Off unless a
// probe runs; production frees pay one relaxed load.
std::atomic<bool> g_probe_on{false};
thread_local const unsigned char *t_probe_addr = nullptr;
thread_local int t_probe_result = 0; // 0 not seen, 1 seen zeroed, -1 seen non-zero

inline void probe(const void *ptr, size_t n) {
    if (!g_probe_on.load(std::memory_order_relaxed) || t_probe_addr == nullptr) return;
    const unsigned char *p = static_cast<const unsigned char *>(ptr);
    if (t_probe_addr < p || t_probe_addr >= p + n) return;
    // The block is wiped but not yet freed: reading it here is defined.
    bool zero = true;
    for (size_t i = 0; i < n; i++) zero &= (p[i] == 0);
    t_probe_result = zero ? 1 : -1;
}

inline void wipe_and_free(void *ptr) {
    if (ptr == nullptr) return;
    // 0 for pointers malloc did not hand out; those are passed through unwiped.
    size_t n = malloc_size(ptr);
    if (n != 0) {
        memset_s(ptr, n, 0, n);
        probe(ptr, n);
    }
    std::free(ptr);
}

void *alloc_or_throw(size_t n) {
    if (n == 0) n = 1;
    for (;;) {
        if (void *p = std::malloc(n)) return p;
        std::new_handler h = std::get_new_handler();
        if (h == nullptr) throw std::bad_alloc();
        h();
    }
}

void *aligned_alloc_or_throw(size_t n, std::align_val_t al) {
    size_t align = static_cast<size_t>(al);
    if (align < sizeof(void *)) align = sizeof(void *);
    if (n == 0) n = 1;
    for (;;) {
        void *p = nullptr;
        if (posix_memalign(&p, align, n) == 0 && p != nullptr) return p;
        std::new_handler h = std::get_new_handler();
        if (h == nullptr) throw std::bad_alloc();
        h();
    }
}

} // namespace

extern "C" void recordless_wiping_free(void *ptr) { wipe_and_free(ptr); }

extern "C" void *recordless_wiping_realloc(void *ptr, size_t size) {
    if (ptr == nullptr) return std::malloc(size);
    size_t old = malloc_size(ptr);
    if (old == 0) return std::realloc(ptr, size); // not a malloc block we can size
    if (size == 0) {
        wipe_and_free(ptr);
        return std::malloc(0);
    }
    if (size <= old) return ptr; // still fits; nothing is left behind
    void *fresh = std::malloc(size);
    if (fresh == nullptr) return nullptr; // ptr stays valid, as with realloc
    std::memcpy(fresh, ptr, old);
    wipe_and_free(ptr);
    return fresh;
}

// Referenced from Rust so this object is always linked into the image.
extern "C" int recordless_native_wipe_installed(void) { return 1; }

// ---- replaceable global allocation functions ----

void *operator new(size_t n) { return alloc_or_throw(n); }
void *operator new[](size_t n) { return alloc_or_throw(n); }
void *operator new(size_t n, const std::nothrow_t &) noexcept {
    try { return alloc_or_throw(n); } catch (...) { return nullptr; }
}
void *operator new[](size_t n, const std::nothrow_t &) noexcept {
    try { return alloc_or_throw(n); } catch (...) { return nullptr; }
}
void *operator new(size_t n, std::align_val_t al) { return aligned_alloc_or_throw(n, al); }
void *operator new[](size_t n, std::align_val_t al) { return aligned_alloc_or_throw(n, al); }
void *operator new(size_t n, std::align_val_t al, const std::nothrow_t &) noexcept {
    try { return aligned_alloc_or_throw(n, al); } catch (...) { return nullptr; }
}
void *operator new[](size_t n, std::align_val_t al, const std::nothrow_t &) noexcept {
    try { return aligned_alloc_or_throw(n, al); } catch (...) { return nullptr; }
}

void operator delete(void *p) noexcept { wipe_and_free(p); }
void operator delete[](void *p) noexcept { wipe_and_free(p); }
void operator delete(void *p, size_t) noexcept { wipe_and_free(p); }
void operator delete[](void *p, size_t) noexcept { wipe_and_free(p); }
void operator delete(void *p, const std::nothrow_t &) noexcept { wipe_and_free(p); }
void operator delete[](void *p, const std::nothrow_t &) noexcept { wipe_and_free(p); }
void operator delete(void *p, std::align_val_t) noexcept { wipe_and_free(p); }
void operator delete[](void *p, std::align_val_t) noexcept { wipe_and_free(p); }
void operator delete(void *p, size_t, std::align_val_t) noexcept { wipe_and_free(p); }
void operator delete[](void *p, size_t, std::align_val_t) noexcept { wipe_and_free(p); }
void operator delete(void *p, std::align_val_t, const std::nothrow_t &) noexcept { wipe_and_free(p); }
void operator delete[](void *p, std::align_val_t, const std::nothrow_t &) noexcept { wipe_and_free(p); }

// ---- test probes (host tests in core/src/native_wipe.rs) ----
//
// Each probe frees a block whose address it has registered; the free path
// checks, between wiping and free(), that the whole block reads as zero. No
// freed memory is ever read. Returns 1 (wiped), -1 (freed unwiped through our
// path: a bug) or 0 (never reached our free path).

namespace {
struct ProbeScope {
    explicit ProbeScope(const void *addr) {
        g_probe_on.store(true, std::memory_order_relaxed);
        t_probe_addr = static_cast<const unsigned char *>(addr);
        t_probe_result = 0;
    }
    ~ProbeScope() { t_probe_addr = nullptr; }
    int result() const { return t_probe_result; }
};

// Keep the compiler from eliding new/delete pairs (it may, for replaceable
// allocation functions).
template <class T> void escape(T *p) { asm volatile("" : : "r"(p) : "memory"); }
} // namespace

extern "C" int recordless_wipe_probe_string(void) {
    auto *s = new std::string(300, 'T'); // heap buffer, not the small-string buffer
    escape(s);
    ProbeScope scope(s->data());
    delete s;
    return scope.result();
}

extern "C" int recordless_wipe_probe_vector(void) {
    auto *v = new std::vector<int32_t>(1000, 0x5a5a5a5a);
    escape(v);
    ProbeScope scope(v->data());
    delete v;
    return scope.result();
}

extern "C" int recordless_wipe_probe_aligned(void) {
    struct alignas(128) Block { unsigned char bytes[512]; };
    auto *b = new Block;
    std::memset(b->bytes, 0xA5, sizeof b->bytes);
    escape(b);
    ProbeScope scope(b->bytes);
    delete b;
    return scope.result();
}

extern "C" int recordless_wipe_probe_c_free(void) {
    auto *p = static_cast<unsigned char *>(std::malloc(4096));
    if (p == nullptr) return 0;
    std::memset(p, 0x77, 4096);
    escape(p);
    ProbeScope scope(p);
    recordless_wiping_free(p);
    return scope.result();
}

extern "C" int recordless_wipe_probe_c_realloc(void) {
    auto *p = static_cast<unsigned char *>(std::malloc(64));
    if (p == nullptr) return 0;
    std::memset(p, 0x33, 64);
    escape(p);
    ProbeScope scope(p);
    void *q = recordless_wiping_realloc(p, 1 << 20); // must move
    int r = scope.result();
    recordless_wiping_free(q);
    return r;
}

// std::runtime_error keeps its message in a buffer that libc++.dylib allocates
// and frees inside its own code (~runtime_error is defined in the dylib). 1
// here means deletes made inside system libraries also reach the replacement.
extern "C" int recordless_wipe_probe_system_library(void) {
    std::string msg(200, 'S');
    auto *e = new std::runtime_error(msg);
    escape(e);
    ProbeScope scope(e->what());
    delete e;
    return scope.result();
}
