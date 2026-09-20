cmake_minimum_required(VERSION 3.14)
project(pocketasr_decode LANGUAGES C)

# Third-party sources are cloned by scripts/ci/build_native_android.sh from
# pinned commits and passed in; local builds may clone them into third_party/.
set(SPEEXDSP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/speexdsp" CACHE PATH "SpeexDSP source tree")
set(DRLIBS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/dr_libs" CACHE PATH "dr_libs source tree")

# SpeexDSP subset: resampler + AGC preprocessor and its FFT/filter
# dependencies. Built floating point: SpeexDSP compiles out the AGC under
# FIXED_POINT (upstream FIXME). The echo canceller (mdf.c) is deliberately not
# built; the one symbol preprocess.c references for it is stubbed in
# pocketasr_chain.c.
set(SPEEXDSP_SOURCES
  ${SPEEXDSP_DIR}/libspeexdsp/resample.c
  ${SPEEXDSP_DIR}/libspeexdsp/preprocess.c
  ${SPEEXDSP_DIR}/libspeexdsp/fftwrap.c
  ${SPEEXDSP_DIR}/libspeexdsp/kiss_fft.c
  ${SPEEXDSP_DIR}/libspeexdsp/kiss_fftr.c
  ${SPEEXDSP_DIR}/libspeexdsp/filterbank.c
)

add_library(pocketasr_decode SHARED
  src/pocketasr_chain.c
  src/pocketasr_decode.c
  src/pocketasr_wav.c
  ${SPEEXDSP_SOURCES}
)

# speexdsp_config must come first so the vendored sources find our config.h.
target_include_directories(pocketasr_decode PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/speexdsp_config
  ${CMAKE_CURRENT_SOURCE_DIR}/src
  ${SPEEXDSP_DIR}/include
  ${SPEEXDSP_DIR}/libspeexdsp
  ${DRLIBS_DIR}
)

set_target_properties(pocketasr_decode PROPERTIES
  C_STANDARD 99
  C_STANDARD_REQUIRED ON
  POSITION_INDEPENDENT_CODE ON
)

# SpeexDSP gates its own config.h include on HAVE_CONFIG_H (as autotools sets).
target_compile_definitions(pocketasr_decode PRIVATE HAVE_CONFIG_H)

target_link_libraries(pocketasr_decode PRIVATE m)

# Host self-test for the chain (resample count, AGC, silence). Built with a
# native compiler, never shipped.
option(POCKETASR_BUILD_TESTS "Build the host chain self-test" OFF)
if(POCKETASR_BUILD_TESTS)
  add_executable(pocketasr_chain_test
    test/chain_test.c
    src/pocketasr_chain.c
    ${SPEEXDSP_SOURCES}
  )
  target_include_directories(pocketasr_chain_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/speexdsp_config
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${SPEEXDSP_DIR}/include
    ${SPEEXDSP_DIR}/libspeexdsp
  )
  target_compile_definitions(pocketasr_chain_test PRIVATE HAVE_CONFIG_H)
  target_link_libraries(pocketasr_chain_test PRIVATE m)

  # WAV writer has no SpeexDSP dependency, so it builds on its own.
  add_executable(pocketasr_wav_test
    test/wav_test.c
    src/pocketasr_wav.c
  )
  target_include_directories(pocketasr_wav_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
  )
  target_link_libraries(pocketasr_wav_test PRIVATE m)
endif()
