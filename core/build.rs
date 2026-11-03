//! Builds `native/wipe.cpp`: replacement C++ `operator new`/`delete` and the
//! wiping `free`/`realloc` that whisper.cpp, llama.cpp and ggml are compiled
//! to call (see `native/whisper_wipe.cmake` and `vendor/whisper-rs-sys`,
//! wired up in `.cargo/config.toml`).
//!
//! Then checks the native archives the core links:
//! - exactly one ggml: `ggml_init` is defined once across llama-cpp-sys-2's
//!   archives and not at all in whisper's (which must use llama's ggml);
//! - every llama.cpp/ggml/whisper.cpp object frees through
//!   `recordless_wiping_free`, never `free`/`realloc` directly.
use std::path::{Path, PathBuf};
use std::process::Command;

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

    check_native_archives();
}

fn archives(dir: &Path) -> Vec<PathBuf> {
    let mut found: Vec<PathBuf> = std::fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("{}: {e}", dir.display()))
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "a"))
        .collect();
    found.sort();
    found
}

fn nm(args: &[&str], archive: &Path) -> String {
    let output = Command::new("nm")
        .args(args)
        .arg(archive)
        .output()
        .unwrap_or_else(|e| panic!("nm {}: {e}", archive.display()));
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn check_native_archives() {
    println!("cargo:rerun-if-env-changed=DEP_LLAMA_GGML_CMAKE_DIR");
    println!("cargo:rerun-if-env-changed=DEP_WHISPER_LIB_DIR");
    let llama_lib = PathBuf::from(std::env::var("DEP_LLAMA_GGML_CMAKE_DIR").expect("DEP_LLAMA_GGML_CMAKE_DIR"))
        .join("..");
    let whisper_lib = PathBuf::from(std::env::var("DEP_WHISPER_LIB_DIR").expect("DEP_WHISPER_LIB_DIR"));
    let llama = archives(&llama_lib);
    let whisper: Vec<PathBuf> = archives(&whisper_lib).into_iter().filter(|p| p.ends_with("libwhisper.a")).collect();
    assert_eq!(whisper.len(), 1, "libwhisper.a not found in {}", whisper_lib.display());

    let defines_ggml_init = |a: &Path| nm(&["-g", "--defined-only"], a).lines().filter(|l| l.ends_with(" T _ggml_init")).count();
    let llama_defs: usize = llama.iter().map(|a| defines_ggml_init(a)).sum();
    assert_eq!(llama_defs, 1, "expected one ggml_init in llama-cpp-sys-2's archives, found {llama_defs}");
    assert_eq!(defines_ggml_init(&whisper[0]), 0, "whisper.cpp brought its own ggml");

    for archive in llama.iter().chain(&whisper) {
        // (llama-cpp-sys-2's cc-built `common_wrapper`, outside this
        // directory, frees only strings from grammar/template helpers the
        // core never calls.)
        let name = archive.file_name().unwrap().to_string_lossy();
        let undefined = nm(&["-u"], archive);
        let direct: Vec<&str> = undefined.lines().map(str::trim).filter(|s| *s == "_free" || *s == "_realloc").collect();
        assert!(direct.is_empty(), "{name} calls free/realloc directly (wipe_free.h not applied; `cargo clean -p llama-cpp-sys-2`)");
        if name.starts_with("libggml-base") || name == "libllama.a" || name == "libwhisper.a" {
            assert!(
                undefined.lines().any(|s| s.trim() == "_recordless_wiping_free"),
                "{name} does not call recordless_wiping_free"
            );
        }
    }
}
