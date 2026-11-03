# Injected into whisper.cpp's CMake build (whisper-rs-sys forwards CMAKE_*
# environment variables as -D definitions; .cargo/config.toml sets
# CMAKE_PROJECT_INCLUDE to this file). Runs after every project() call, so the
# top-level whisper.cpp project and the ggml subproject both inherit it.
#
# Force-includes wipe_free.h into C/C++/ObjC sources (not the Metal shader
# embedding assembly), so every free()/realloc() in whisper.cpp and ggml zeroes
# the block before releasing it.
set(RECORDLESS_WIPE_FREE_H "${CMAKE_CURRENT_LIST_DIR}/wipe_free.h")
add_compile_options("$<$<COMPILE_LANGUAGE:C,CXX,OBJC,OBJCXX>:-include${RECORDLESS_WIPE_FREE_H}>")
