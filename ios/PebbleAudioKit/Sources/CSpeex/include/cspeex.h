/*
 * CSpeex umbrella header.
 *
 * Vendored from the firmware's Speex tree (PebbleOS/third_party/speex/speex, Speex 1.2.1)
 * so the companion app decodes with the exact codec revision the watch encodes with:
 * fixed-point wideband (speex_wb_mode), 16 kHz, 320-sample frames, 9800 bps CBR,
 * one frame per speex_bits chunk, no per-frame header byte.
 *
 * Build configuration (see the CSpeex cSettings in Package.swift): FIXED_POINT,
 * DISABLE_FLOAT_API, DISABLE_VBR, VAR_ARRAYS, DISABLE_WARNINGS, DISABLE_NOTIFICATIONS.
 * This matches the firmware defines except for its embedded-only kernel allocator and
 * fixed-stack overrides, which do not affect the bitstream.
 */
#ifndef CSPEEX_H
#define CSPEEX_H

#include "speex/speex.h"
#include "speex/speex_bits.h"
#include "speex/speex_header.h"
#include "speex/speex_callbacks.h"
#include "speex/speex_stereo.h"

#endif /* CSPEEX_H */
