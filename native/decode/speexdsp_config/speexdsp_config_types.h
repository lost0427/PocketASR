/*
 * Stand-in for the file SpeexDSP's autotools build generates. Android's
 * <stdint.h> supplies the fixed-width types it would have selected.
 */
#ifndef __SPEEX_TYPES_H__
#define __SPEEX_TYPES_H__

#include <stdint.h>

typedef int16_t spx_int16_t;
typedef uint16_t spx_uint16_t;
typedef int32_t spx_int32_t;
typedef uint32_t spx_uint32_t;

#endif
