#![allow(non_upper_case_globals)]
#![allow(non_camel_case_types)]
#![allow(non_snake_case)]

// whisper.cpp calls into llama-cpp-sys-2's ggml; keep that crate (and its
// native libraries) on the link line even though no Rust code here uses it.
extern crate llama_cpp_sys_2;

include!(concat!(env!("OUT_DIR"), "/bindings.rs"));
