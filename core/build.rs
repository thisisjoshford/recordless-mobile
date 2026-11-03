//! Builds `native/wipe.cpp`: replacement C++ `operator new`/`delete` and the
//! wiping `free`/`realloc` that whisper.cpp/ggml are compiled to call (see
//! `native/whisper_wipe.cmake`, wired up in `.cargo/config.toml`).
fn main() {
    println!("cargo:rerun-if-changed=native/wipe.cpp");
    println!("cargo:rerun-if-changed=native/wipe_free.h");
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if !matches!(target_os.as_str(), "ios" | "macos") {
        panic!("recordless_core targets Apple platforms only (malloc_size/memset_s)");
    }
    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .file("native/wipe.cpp")
        .warnings(true)
        .cargo_metadata(false)
        .compile("recordless_wipe");
    let out = std::env::var("OUT_DIR").unwrap();
    println!("cargo:rustc-link-search=native={out}");
    // Whole-archive: the replacement operators must be in every image the core
    // is linked into, even where nothing references them by name.
    println!("cargo:rustc-link-lib=static:+whole-archive=recordless_wipe");
}
