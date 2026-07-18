#ifndef MOZJPEGSHIM_H
#define MOZJPEGSHIM_H

#include <stddef.h>
#include <stdint.h>

// Encode a packed RGBA buffer (4 bytes/pixel) to JPEG using mozjpeg. The alpha
// channel is ignored (JPEG has no alpha), so callers should composite over an
// opaque background beforehand.
//
// quality    : 1..100
// progressive: 0 = baseline, 1 = progressive (recommended, smaller).
//
// On success returns 1 and sets *out to a malloc'd buffer of *outSize bytes
// that the caller MUST release with mozjpegshim_free(). On failure returns 0.
int mozjpegshim_encode_rgba(const uint8_t *rgba,
                            int width,
                            int height,
                            int stride,
                            int quality,
                            int progressive,
                            uint8_t **out,
                            size_t *outSize);

void mozjpegshim_free(uint8_t *ptr);

#endif /* MOZJPEGSHIM_H */
