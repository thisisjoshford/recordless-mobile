//! Recordless patch: compile whisper.cpp (one translation unit) against the
//! ggml that llama-cpp-sys-2 installed, instead of building a second ggml.
//!
//! Every C/C++ heap free in whisper.cpp must zero the block first, like ggml
//! and llama.cpp (which get this through CMAKE_PROJECT_INCLUDE): the header
//! named by RECORDLESS_WIPE_FREE_H (.cargo/config.toml) is force-included.
use std::env;
use std::path::PathBuf;

const WHISPER_CPP_VERSION: &str = "1.8.3";

fn main() {
    let target = env::var("TARGET").unwrap();
    if !target.contains("apple") {
        panic!("this whisper-rs-sys patch targets Apple platforms only");
    }
    println!("cargo:rerun-if-changed=wrapper.h");
    println!("cargo:rerun-if-changed=whisper.cpp/src");
    println!("cargo:rerun-if-changed=whisper.cpp/include");
    println!("cargo:rerun-if-env-changed=RECORDLESS_WIPE_FREE_H");
    println!("cargo:rerun-if-env-changed=DEP_LLAMA_GGML_CMAKE_DIR");

    // <out>/lib/cmake from llama-cpp-sys-2; headers are installed at <out>/include.
    let cmake_dir = PathBuf::from(
        env::var("DEP_LLAMA_GGML_CMAKE_DIR")
            .expect("llama-cpp-sys-2 did not report its installed ggml (DEP_LLAMA_GGML_CMAKE_DIR)"),
    );
    let ggml_include = cmake_dir.join("../../include");
    assert!(
        ggml_include.join("ggml.h").is_file(),
        "no ggml.h under {}",
        ggml_include.display()
    );

    let wipe = env::var("RECORDLESS_WIPE_FREE_H").ok().map(PathBuf::from);
    if let Some(h) = &wipe {
        assert!(h.is_file(), "RECORDLESS_WIPE_FREE_H={} does not exist", h.display());
        println!("cargo:rerun-if-changed={}", h.display());
    }

    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let bindings = bindgen::Builder::default()
        .rust_edition(bindgen::RustEdition::Edition2021)
        .rust_target(bindgen::RustTarget::stable(88, 0).map_err(|v| v.to_string()).unwrap())
        .header("wrapper.h")
        .clang_arg("-I./whisper.cpp/include")
        .clang_arg(format!("-I{}", ggml_include.display()))
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()))
        .generate()
        .expect("bindgen failed on whisper.h / ggml.h");
    bindings.write_to_file(out.join("bindings.rs")).expect("write bindings.rs");

    let mut build = cc::Build::new();
    build
        .cpp(true)
        .std("c++17")
        .file("whisper.cpp/src/whisper.cpp")
        .include("whisper.cpp/include")
        .include("whisper.cpp/src")
        .include(&ggml_include)
        .define("WHISPER_VERSION", format!("\"{WHISPER_CPP_VERSION}\"").as_str())
        .define("GGML_USE_METAL", None)
        .define("NDEBUG", None)
        .opt_level(3)
        .debug(false)
        .warnings(false)
        .pic(true);
    if let Some(h) = &wipe {
        build.flag(format!("-include{}", h.display()));
    }
    build.compile("whisper");

    println!("cargo:WHISPER_CPP_VERSION={WHISPER_CPP_VERSION}");
    println!("cargo:lib_dir={}", out.display());
    println!("cargo:rustc-link-lib=dylib=c++");
    println!("cargo:rustc-link-lib=framework=Accelerate");
    println!("cargo:rustc-link-lib=framework=Foundation");
    println!("cargo:rustc-link-lib=framework=Metal");
    println!("cargo:rustc-link-lib=framework=MetalKit");
}
