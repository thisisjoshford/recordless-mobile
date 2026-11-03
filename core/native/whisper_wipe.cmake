# Injected into llama.cpp's CMake build (llama-cpp-sys-2 forwards CMAKE_*
# environment variables as -D definitions; .cargo/config.toml sets
# CMAKE_PROJECT_INCLUDE to this file). Runs after every project() call, so the
# top-level llama.cpp project and the ggml subproject both inherit it. (whisper.cpp
# itself is compiled by vendor/whisper-rs-sys with the same header.)
#
# Force-includes wipe_free.h into C/C++/ObjC sources (not the Metal shader
# embedding assembly), so every free()/realloc() in llama.cpp and ggml zeroes
# the block before releasing it.
set(RECORDLESS_WIPE_FREE_H "${CMAKE_CURRENT_LIST_DIR}/wipe_free.h")
add_compile_options("$<$<COMPILE_LANGUAGE:C,CXX,OBJC,OBJCXX>:-include${RECORDLESS_WIPE_FREE_H}>")
