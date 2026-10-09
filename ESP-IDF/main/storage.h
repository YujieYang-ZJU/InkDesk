#pragma once
#include "esp_err.h"
#include "protocol.h"
esp_err_t ink_storage_init(ink_queue_t *queue);
esp_err_t ink_queue_save(const ink_queue_t *queue);
/* Separate NVS journal; no change to cached manifest/frame layout. */
esp_err_t ink_status_load(ink_status_t *status);
esp_err_t ink_status_save(const ink_status_t *status); /* NULL clears after ACK. */
bool ink_cache_load(ink_manifest_t *manifest,uint8_t *frame);
esp_err_t ink_cache_save(const ink_manifest_t *manifest,const uint8_t *frame);
