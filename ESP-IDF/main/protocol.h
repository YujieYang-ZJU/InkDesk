#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define INK_WIDTH 800
#define INK_HEIGHT 480
#define INK_FRAME_BYTES 48000
#define INK_MAX_TASKS 96
#define INK_MAX_PAGES 24
#define INK_QUEUE_CAPACITY 24
#define INK_MANIFEST_MAX 65536
#define INK_UUID_SIZE 37

typedef struct {
    char id[INK_UUID_SIZE];
    char name[96];
} ink_page_t;
typedef struct {
    int64_t revision;
    int poll_seconds;
    char page_id[INK_UUID_SIZE];
    char hash[65];
    char focused_task_id[INK_UUID_SIZE];
    uint32_t page_count, task_count;
    ink_page_t pages[INK_MAX_PAGES];
    char tasks[INK_MAX_TASKS][INK_UUID_SIZE];
} ink_manifest_t;
typedef struct {
    char event_id[INK_UUID_SIZE];
    char action[20];
    char page_id[INK_UUID_SIZE];
    char task_id[INK_UUID_SIZE];
} ink_action_t;
typedef struct {
    uint32_t version, count;
    ink_action_t events[INK_QUEUE_CAPACITY];
} ink_queue_t;
/* Keep transfer metadata outside ink_manifest_t: v1 frame caches store that
 * struct verbatim and remain readable by updated firmware. */
typedef enum {
    INK_STATUS_DOWNLOADED=1, INK_STATUS_REFRESHING, INK_STATUS_DISPLAYED, INK_STATUS_FAILED
} ink_status_state_t;
typedef struct {
    uint32_t version;
    ink_status_state_t state;
    int64_t revision;
    char transfer_id[INK_UUID_SIZE];
    char page_id[INK_UUID_SIZE];
    char hash[65];
    char error[96];
} ink_status_t;
typedef struct {
    ink_status_t status;
    bool present,acknowledged,needs_save,stale;
} ink_status_tx_t;

bool ink_uuid_valid(const char *s);
bool ink_manifest_parse(const char *json, size_t size, ink_manifest_t *out);
bool ink_sync_manifest_parse(const char *json, size_t size, ink_manifest_t *out, char transfer_id[INK_UUID_SIZE]);
bool ink_manifest_same_frame(const ink_manifest_t *a, const ink_manifest_t *b);
bool ink_manifest_same_pixels(const ink_manifest_t *a, const ink_manifest_t *b);
bool ink_status_valid(const ink_status_t *status);
bool ink_status_begin(ink_status_t *out, const char *transfer_id, const ink_manifest_t *manifest, ink_status_state_t state, const char *error);
bool ink_status_advance(ink_status_t *status, ink_status_state_t state, const char *error);
bool ink_status_matches_frame(const ink_status_t *status, const ink_manifest_t *manifest);
bool ink_status_json(const ink_status_t *status, char *out, size_t capacity);
bool ink_status_ack(const char *json, size_t size, const ink_status_t *status);
bool ink_status_tx_set(ink_status_tx_t *tx, const ink_status_t *status);
void ink_status_tx_saved(ink_status_tx_t *tx, bool success);
bool ink_status_tx_response(ink_status_tx_t *tx, int http_status, const char *json, size_t size);
bool ink_status_tx_clear(ink_status_tx_t *tx, bool commit_success);
bool ink_action_json(const ink_action_t *event, char *out, size_t capacity);
bool ink_action_ack(const char *json, size_t size);
bool ink_queue_valid(const ink_queue_t *q);
bool ink_queue_push(ink_queue_t *q, const ink_action_t *event);
void ink_queue_shift(ink_queue_t *q);
