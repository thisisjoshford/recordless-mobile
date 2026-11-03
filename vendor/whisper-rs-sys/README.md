# whisper-rs-sys 0.15.0, Recordless patch

Used through `[patch.crates-io]` in the workspace `Cargo.toml`. Upstream
(<https://codeberg.org/tazz4843/whisper-rs>, Unlicense; whisper.cpp 1.8.3, MIT,
`whisper.cpp/LICENSE`) builds whisper.cpp with its own ggml. Recordless also
links llama.cpp (llama-cpp-sys-2), which brings another ggml, and two copies
clash at link time.

Changes from upstream:

- Only `whisper.cpp/include/whisper.h`, `whisper.cpp/src/whisper.cpp` and
  `whisper-arch.h` are kept (no ggml, CoreML, OpenVINO, CMake files).
- `build.rs` compiles `whisper.cpp` with `cc` against the ggml headers that
  llama-cpp-sys-2 installs (located with `DEP_LLAMA_GGML_CMAKE_DIR`),
  force-includes `RECORDLESS_WIPE_FREE_H` (core/native/wipe_free.h), generates
  bindings from those headers and links only `libwhisper.a`. Apple targets only.
- Depends on `llama-cpp-sys-2 = "=0.1.160"` (the same exact version as
  recordless_core) and `extern crate`s it so its ggml stays on the link line.

`recordless_core`'s `build.rs` checks that `ggml_init` is defined once across
llama-cpp-sys-2's archives and not in `libwhisper.a`. To move to a newer
llama-cpp-sys-2, bump both pins and run the host test
`synthetic_speech_is_transcribed_and_summarised` (see core/src/lib.rs).
