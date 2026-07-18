#ifndef WEBPSHIM_H
#define WEBPSHIM_H

#include <stddef.h>
#include <stdint.h>

// Encode a straight (non-premultiplied) RGBA buffer to WebP.
//
// quality : 0..100 (for lossy) — for lossless it tunes the size/effort tradeoff.
// lossless: 0 = lossy, 1 = lossless.
// method  : encoder effort 0..6 (higher = slower/smaller). Pass -1 for default (6).
//
// On success returns 1 and sets *out to a malloc'd buffer of *outSize bytes that
// the caller MUST release with webpshim_free(). On failure returns 0.
int webpshim_encode_rgba(const uint8_t *rgba,
                         int width,
                         int height,
                         int stride,
                         float quality,
                         int lossless,
                         int method,
                         uint8_t **out,
                         size_t *outSize);

// Release a buffer returned by webpshim_encode_rgba().
void webpshim_free(uint8_t *ptr);

#endif /* WEBPSHIM_H */
