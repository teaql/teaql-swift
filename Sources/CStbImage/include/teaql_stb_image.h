#ifndef TEAQL_STB_IMAGE_H
#define TEAQL_STB_IMAGE_H

int teaql_image_info(const unsigned char *bytes, int length, int *width, int *height);
int teaql_image_decode(const unsigned char *bytes, int length, int width, int height);
int teaql_zip_inflate_raw(const unsigned char *input, int input_length,
                          unsigned char *output, int output_length);
unsigned int teaql_zip_crc32(const unsigned char *bytes, int length);

#endif
