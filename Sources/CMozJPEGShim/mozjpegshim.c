#include "mozjpegshim.h"

#include <stdio.h>
#include <stdlib.h>
#include <setjmp.h>
#include <jpeglib.h>

// Custom error manager so a fatal libjpeg error unwinds via longjmp
// instead of calling exit() (which would kill the whole app).
struct shim_error_mgr {
    struct jpeg_error_mgr pub;
    jmp_buf setjmp_buffer;
};

static void shim_error_exit(j_common_ptr cinfo) {
    struct shim_error_mgr *err = (struct shim_error_mgr *)cinfo->err;
    longjmp(err->setjmp_buffer, 1);
}

int mozjpegshim_encode_rgba(const uint8_t *rgba,
                            int width,
                            int height,
                            int stride,
                            int quality,
                            int progressive,
                            uint8_t **out,
                            size_t *outSize) {
    if (out == NULL || outSize == NULL) return 0;
    *out = NULL;
    *outSize = 0;
    if (rgba == NULL || width <= 0 || height <= 0) return 0;

    struct jpeg_compress_struct cinfo;
    struct shim_error_mgr jerr;

    unsigned char *mem = NULL;
    unsigned long mem_size = 0;

    cinfo.err = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit = shim_error_exit;

    if (setjmp(jerr.setjmp_buffer)) {
        jpeg_destroy_compress(&cinfo);
        if (mem) free(mem);
        return 0;
    }

    jpeg_create_compress(&cinfo);
    jpeg_mem_dest(&cinfo, &mem, &mem_size);

    cinfo.image_width = width;
    cinfo.image_height = height;
    // Read 4-byte RGBA rows directly (libjpeg-turbo/mozjpeg extension); the
    // alpha byte is ignored during RGB->YCbCr conversion.
    cinfo.input_components = 4;
    cinfo.in_color_space = JCS_EXT_RGBA;

    // mozjpeg's jpeg_set_defaults installs its improved quantization tables
    // and enables trellis quantization — that is where the size win comes from.
    jpeg_set_defaults(&cinfo);
    jpeg_set_quality(&cinfo, quality, TRUE);

    if (progressive) {
        jpeg_simple_progression(&cinfo);
    }

    jpeg_start_compress(&cinfo, TRUE);

    while (cinfo.next_scanline < cinfo.image_height) {
        JSAMPROW row = (JSAMPROW)(rgba + (size_t)cinfo.next_scanline * (size_t)stride);
        jpeg_write_scanlines(&cinfo, &row, 1);
    }

    jpeg_finish_compress(&cinfo);
    jpeg_destroy_compress(&cinfo);

    // jpeg_mem_dest allocates `mem` with malloc; ownership passes to the caller.
    *out = mem;
    *outSize = (size_t)mem_size;
    return 1;
}

void mozjpegshim_free(uint8_t *ptr) {
    if (ptr != NULL) free(ptr);
}
