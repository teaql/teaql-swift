#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#define STBI_NO_LINEAR
#define STBI_MAX_DIMENSIONS 16384
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#include "teaql_stb_image.h"
#include <string.h>
#include <zlib.h>

int teaql_image_info(const unsigned char *bytes, int length, int *width, int *height) {
  int components = 0;
  if (!bytes || length <= 0 || !width || !height) return 0;
  return stbi_info_from_memory(bytes, length, width, height, &components);
}

int teaql_image_decode(const unsigned char *bytes, int length, int width, int height) {
  int decoded_width = 0, decoded_height = 0, components = 0;
  if (!bytes || length <= 0 || width <= 0 || height <= 0) return 0;
  unsigned char *pixels = stbi_load_from_memory(bytes, length, &decoded_width,
                                                &decoded_height, &components, 4);
  if (!pixels) return 0;
  int matches = decoded_width == width && decoded_height == height;
  stbi_image_free(pixels);
  return matches;
}

int teaql_zip_inflate_raw(const unsigned char *input, int input_length,
                          unsigned char *output, int output_length) {
  if (!input || !output || input_length < 0 || output_length < 0) return 0;
  z_stream stream;
  memset(&stream, 0, sizeof(stream));
  stream.next_in = (Bytef *)input;
  stream.avail_in = (uInt)input_length;
  stream.next_out = output;
  /* The caller allocates output_length + 1 so expansion past the limit fails. */
  stream.avail_out = (uInt)output_length + 1;
  if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return 0;
  int result = inflate(&stream, Z_FINISH);
  int valid = result == Z_STREAM_END && stream.total_in == (uLong)input_length &&
              stream.total_out == (uLong)output_length;
  inflateEnd(&stream);
  return valid;
}

unsigned int teaql_zip_crc32(const unsigned char *bytes, int length) {
  if (!bytes || length < 0) return 0;
  return (unsigned int)crc32(0L, bytes, (uInt)length);
}
