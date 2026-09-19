/*
 * Minimal config.h for the vendored SpeexDSP subset.
 *
 * We do not run SpeexDSP's autotools configure; this supplies exactly the
 * knobs its sources include unconditionally. Floating point is required:
 * SpeexDSP's own source marks the AGC "doesn't work yet with fixed-point" and
 * compiles out every AGC control under FIXED_POINT. USE_KISS_FFT pulls in the
 * bundled FFT instead of an external library.
 */
#ifndef POCKETASR_SPEEXDSP_CONFIG_H
#define POCKETASR_SPEEXDSP_CONFIG_H

#define FLOATING_POINT 1
#define USE_KISS_FFT 1
#define EXPORT
#define DISABLE_WARNINGS 1

#endif
