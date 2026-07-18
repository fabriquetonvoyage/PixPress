#include "webpshim.h"

#include <webp/encode.h>
#include <stdlib.h>

int webpshim_encode_rgba(const uint8_t *rgba,
                         int width,
                         int height,
                         int stride,
                         float quality,
                         int lossless,
                         int method,
                         uint8_t **out,
                         size_t *outSize) {
    if (out == NULL || outSize == NULL) return 0;
    *out = NULL;
    *outSize = 0;

    if (rgba == NULL || width <= 0 || height <= 0) return 0;

    WebPConfig config;
    if (!WebPConfigInit(&config)) return 0;

    int effort = (method < 0) ? 6 : method;
    if (effort > 6) effort = 6;

    if (lossless) {
        if (!WebPConfigLosslessPreset(&config, effort)) return 0;
        config.lossless = 1;
        // For lossless, quality steers the size/speed tradeoff.
        config.quality = quality;
    } else {
        config.lossless = 0;
        config.quality = quality;
        config.method = effort;
    }

    if (!WebPValidateConfig(&config)) return 0;

    WebPPicture pic;
    if (!WebPPictureInit(&pic)) return 0;
    pic.use_argb = 1;
    pic.width = width;
    pic.height = height;

    if (!WebPPictureImportRGBA(&pic, rgba, stride)) {
        WebPPictureFree(&pic);
        return 0;
    }

    WebPMemoryWriter writer;
    WebPMemoryWriterInit(&writer);
    pic.writer = WebPMemoryWrite;
    pic.custom_ptr = &writer;

    int ok = WebPEncode(&config, &pic);
    WebPPictureFree(&pic);

    if (!ok) {
        WebPMemoryWriterClear(&writer);
        return 0;
    }

    // Ownership of writer.mem transfers to the caller.
    *out = writer.mem;
    *outSize = writer.size;
    return 1;
}

void webpshim_free(uint8_t *ptr) {
    if (ptr != NULL) WebPFree(ptr);
}
