#include "storage.h"
#include "sha256.h"
#include "esp_spiffs.h"
#include "esp_log.h"
#include "nvs.h"
#include "nvs_flash.h"
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static const char *TAG="ink_storage";
static nvs_handle_t state;
static bool mounted;
static uint64_t generation;
static int newest_slot=-1;
typedef struct {
    char magic[8];
    uint32_t version,frame_bytes;
    uint64_t generation;
    ink_manifest_t manifest;
    uint8_t digest[32];
} cache_header_t;
esp_err_t ink_storage_init(ink_queue_t *queue) {
    /* Preserve queue on storage problems; never erase NVS automatically. */
    esp_err_t error=nvs_flash_init();if(error!=ESP_OK) return error;
    error=nvs_open("inkdesk",NVS_READWRITE,&state);if(error!=ESP_OK) return error;
    size_t bytes=sizeof(*queue);memset(queue,0,bytes);queue->version=1;
    error=nvs_get_blob(state,"queue",queue,&bytes);
    if(error==ESP_ERR_NVS_NOT_FOUND) {memset(queue,0,sizeof(*queue));queue->version=1;}
    else if(error!=ESP_OK||bytes!=sizeof(*queue)||!ink_queue_valid(queue)) return ESP_ERR_INVALID_STATE;
    esp_vfs_spiffs_conf_t conf={.base_path="/cache",.partition_label="cache",.max_files=3,.format_if_mount_failed=false};
    error=esp_vfs_spiffs_register(&conf);
    if(error==ESP_ERR_NOT_FOUND) return error;
    /* Fresh blank cache partition needs one format; never format an existing damaged filesystem. */
    if(error!=ESP_OK) {
        ESP_LOGW(TAG,"Cache unavailable; preserving stored bytes. Provision cache image as described in firmware.md.");
        return ESP_OK;
    }
    mounted=true;return ESP_OK;
}
esp_err_t ink_queue_save(const ink_queue_t *queue) {
    if(!ink_queue_valid(queue)) return ESP_ERR_INVALID_ARG;
    esp_err_t error=nvs_set_blob(state,"queue",queue,sizeof(*queue));return error==ESP_OK ? nvs_commit(state) : error;
}
esp_err_t ink_status_load(ink_status_t *status) {
    if(!status) return ESP_ERR_INVALID_ARG;
    size_t bytes=sizeof(*status);memset(status,0,bytes);
    esp_err_t error=nvs_get_blob(state,"sync_status",status,&bytes);
    if(error==ESP_OK&&(bytes!=sizeof(*status)||!ink_status_valid(status))) return ESP_ERR_INVALID_STATE;
    return error;
}
esp_err_t ink_status_save(const ink_status_t *status) {
    if(status&&!ink_status_valid(status)) return ESP_ERR_INVALID_ARG;
    esp_err_t error=status ? nvs_set_blob(state,"sync_status",status,sizeof(*status)) : nvs_erase_key(state,"sync_status");
    if(!status&&error==ESP_ERR_NVS_NOT_FOUND) error=ESP_OK;
    return error==ESP_OK ? nvs_commit(state) : error;
}
static bool read_slot(int slot,cache_header_t *header,uint8_t *frame) {
    char path[24];snprintf(path,sizeof(path),"/cache/frame%d.bin",slot);
    FILE *f=fopen(path,"rb");if(!f) return false;
    bool ok=fread(header,1,sizeof(*header),f)==sizeof(*header);
    ok=ok&&!memcmp(header->magic,"INKDSK1",8)&&header->version==1&&header->frame_bytes==INK_FRAME_BYTES;
    uint8_t digest[32];
    if(ok) {ink_sha256((const uint8_t *)header,offsetof(cache_header_t,digest),digest);ok=!memcmp(digest,header->digest,32);}
    ok=ok&&fread(frame,1,INK_FRAME_BYTES,f)==INK_FRAME_BYTES;
    ok=ok&&fgetc(f)==EOF;fclose(f);
    if(ok) {char hex[65];ink_sha256_hex(frame,INK_FRAME_BYTES,hex);ok=!strcmp(hex,header->manifest.hash);}
    return ok;
}
bool ink_cache_load(ink_manifest_t *manifest,uint8_t *frame) {
    if(!mounted) return false;
    cache_header_t header;
    bool found=false;
    for(int slot=0;slot<2;++slot) {
        if(read_slot(slot,&header,frame)&&(!found||header.generation>generation)) {
            found=true;generation=header.generation;newest_slot=slot;*manifest=header.manifest;
        }
    }
    if(!found) return false;
    return read_slot(newest_slot,&header,frame);
}
esp_err_t ink_cache_save(const ink_manifest_t *manifest,const uint8_t *frame) {
    if(!mounted) return ESP_ERR_INVALID_STATE;
    int slot=newest_slot==0 ? 1 : 0;
    char path[24];snprintf(path,sizeof(path),"/cache/frame%d.bin",slot);
    cache_header_t header={0};memcpy(header.magic,"INKDSK1",8);header.version=1;
    header.frame_bytes=INK_FRAME_BYTES;header.generation=generation+1;header.manifest=*manifest;
    ink_sha256((const uint8_t *)&header,offsetof(cache_header_t,digest),header.digest);
    FILE *f=fopen(path,"wb");if(!f) return ESP_FAIL;
    bool ok=fwrite(&header,1,sizeof(header),f)==sizeof(header)&&fwrite(frame,1,INK_FRAME_BYTES,f)==INK_FRAME_BYTES;
    if(fflush(f)!=0) ok=false;
    if(fsync(fileno(f))!=0) ok=false;
    if(fclose(f)!=0) ok=false;
    if(ok) {generation=header.generation;newest_slot=slot;return ESP_OK;}
    return ESP_FAIL;
}
