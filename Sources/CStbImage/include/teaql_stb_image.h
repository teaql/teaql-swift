#ifndef TEAQL_STB_IMAGE_H
#define TEAQL_STB_IMAGE_H

int teaql_image_info(const unsigned char *bytes, int length, int *width, int *height);
int teaql_image_decode(const unsigned char *bytes, int length, int width, int height);

#endif
