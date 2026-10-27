#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#define STBI_NO_LINEAR
#define STBI_MAX_DIMENSIONS 16384
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#include "teaql_stb_image.h"

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
