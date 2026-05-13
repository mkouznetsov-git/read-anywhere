#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ReadArcDjvuDocument ReadArcDjvuDocument;

typedef struct ReadArcDjvuPageInfo {
  uint32_t width;
  uint32_t height;
  uint32_t dpi;
} ReadArcDjvuPageInfo;

ReadArcDjvuDocument* readarc_djvu_open(const uint8_t* data, size_t len);
void readarc_djvu_close(ReadArcDjvuDocument* document);
uint32_t readarc_djvu_page_count(ReadArcDjvuDocument* document);
int32_t readarc_djvu_page_info(ReadArcDjvuDocument* document, uint32_t page_index, ReadArcDjvuPageInfo* out_info);
int32_t readarc_djvu_render_page_rgba(ReadArcDjvuDocument* document, uint32_t page_index, uint32_t target_width, uint32_t target_height, uint8_t* out_rgba, size_t out_len);

#ifdef __cplusplus
}
#endif
