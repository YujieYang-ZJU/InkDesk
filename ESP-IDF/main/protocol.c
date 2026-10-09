#include "protocol.h"
#include "cJSON.h"
#include <ctype.h>
#include <math.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

bool ink_uuid_valid(const char *s) {
    if (!s || strlen(s) != 36) return false;
    for (size_t i = 0; i < 36; ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (s[i] != '-') return false; }
        else if (!isxdigit((unsigned char)s[i])) return false;
    }
    return true;
}
static const cJSON *get(const cJSON *obj, const char *key) { return cJSON_GetObjectItemCaseSensitive(obj, key); }
static cJSON *parse_object(const char *json,size_t size,size_t maximum) {
    if(!json||!size||size>maximum) return NULL;
    const char *end=NULL;
    cJSON *root=cJSON_ParseWithLengthOpts(json,size,&end,false);
    if(!root) return NULL;
    while(end<json+size&&isspace((unsigned char)*end)) ++end;
    bool ok=cJSON_IsObject(root)&&(end==json+size||(end==json+size-1&&*end=='\0'));
    /* Ambiguous duplicate fields are not a valid envelope/acknowledgement. */
    for(const cJSON *a=root->child;ok&&a;a=a->next)
        for(const cJSON *b=a->next;b;b=b->next)
            if(!strcmp(a->string,b->string)) {ok=false;break;}
    if(!ok) {cJSON_Delete(root);return NULL;} return root;
}
static bool uuid_field(const cJSON *obj, const char *key, char dest[INK_UUID_SIZE]) {
    const cJSON *v = get(obj, key);
    if (!cJSON_IsString(v) || !ink_uuid_valid(v->valuestring)) return false;
    memcpy(dest, v->valuestring, INK_UUID_SIZE);
    return true;
}
static bool number_is(const cJSON *obj, const char *key, int expected) {
    const cJSON *v = get(obj, key);
    return cJSON_IsNumber(v) && v->valuedouble == expected;
}
static bool known_action(const char *s) {
    const char *allowed[] = {"next_page", "previous_page", "refresh", "next_task", "previous_task", "toggle_task", "exit_task"};
    for (size_t i = 0; i < sizeof(allowed)/sizeof(allowed[0]); ++i)
        if (!strcmp(s, allowed[i])) return true;
    return false;
}
static bool manifest_parse(const char *json,size_t size,ink_manifest_t *out,char transfer_id[INK_UUID_SIZE]) {
    if(!out) return false;
    cJSON *root=parse_object(json,size,INK_MANIFEST_MAX);
    if (!root) return false;
    ink_manifest_t m = {0};
    bool ok = cJSON_IsObject(root) && number_is(root, "version", 1) && number_is(root, "width", INK_WIDTH)
        && number_is(root, "height", INK_HEIGHT) && number_is(root, "rowBytes", 100);
    const cJSON *format = get(root, "pixelFormat"), *path = get(root, "frameURL");
    ok = ok && cJSON_IsString(format) && !strcmp(format->valuestring, "mono1-msb-white1")
        && cJSON_IsString(path) && !strcmp(path->valuestring,transfer_id ? "/api/sync/frame.bin" : "/api/frame.bin") && uuid_field(root, "pageID", m.page_id);
    char transfer[INK_UUID_SIZE]={0};
    if(transfer_id) ok=ok&&uuid_field(root,"transferID",transfer);
    const cJSON *rev = get(root, "revision"), *hash = get(root, "hash"), *poll = get(root, "pollSeconds");
    ok = ok && cJSON_IsNumber(rev) && rev->valuedouble >= 0 && rev->valuedouble <= 9007199254740991.0
        && floor(rev->valuedouble) == rev->valuedouble;
    if (ok) m.revision = (int64_t)rev->valuedouble;
    ok = ok && cJSON_IsString(hash) && strlen(hash->valuestring) == 64;
    if (ok) {
        for (int i = 0; i < 64; ++i) {
            if (!isxdigit((unsigned char)hash->valuestring[i])) { ok = false; break; }
            m.hash[i] = (char)tolower((unsigned char)hash->valuestring[i]);
        }
    }
    ok = ok && cJSON_IsNumber(poll) && poll->valuedouble >= 1 && poll->valuedouble <= 3600
        && floor(poll->valuedouble) == poll->valuedouble;
    if (ok) m.poll_seconds = poll->valueint < 10 ? 10 : poll->valueint;
    const cJSON *focus = get(root, "focusedTaskID");
    if (cJSON_IsString(focus)) ok = ok && uuid_field(root, "focusedTaskID", m.focused_task_id);
    else ok = ok && cJSON_IsNull(focus);
    const cJSON *pages = get(root, "pages"), *tasks = get(root, "taskIDs");
    ok = ok && cJSON_IsArray(pages) && cJSON_IsArray(tasks);
    int np = cJSON_GetArraySize(pages), nt = cJSON_GetArraySize(tasks);
    ok = ok && np > 0 && np <= INK_MAX_PAGES && nt >= 0 && nt <= INK_MAX_TASKS;
    bool page_found = false, task_found = m.focused_task_id[0] == '\0';
    for (int i = 0; ok && i < np; ++i) {
        const cJSON *p = cJSON_GetArrayItem(pages, i), *name = get(p, "name");
        ok = uuid_field(p, "id", m.pages[i].id) && cJSON_IsString(name);
        if (ok) { snprintf(m.pages[i].name, sizeof(m.pages[i].name), "%s", name->valuestring); page_found |= !strcmp(m.pages[i].id, m.page_id); }
    }
    for (int i = 0; ok && i < nt; ++i) {
        const cJSON *t = cJSON_GetArrayItem(tasks, i);
        ok = cJSON_IsString(t) && ink_uuid_valid(t->valuestring);
        if (ok) { memcpy(m.tasks[i], t->valuestring, INK_UUID_SIZE); task_found |= !strcmp(m.tasks[i], m.focused_task_id); }
    }
    ok = ok && page_found && task_found;
    if (ok) { m.page_count = (uint32_t)np; m.task_count = (uint32_t)nt; *out = m;if(transfer_id) memcpy(transfer_id,transfer,sizeof(transfer)); }
    cJSON_Delete(root);
    return ok;
}
bool ink_manifest_parse(const char *json,size_t size,ink_manifest_t *out) {return manifest_parse(json,size,out,NULL);}
bool ink_sync_manifest_parse(const char *json,size_t size,ink_manifest_t *out,char transfer_id[INK_UUID_SIZE]) {
    return transfer_id&&manifest_parse(json,size,out,transfer_id);
}
bool ink_manifest_same_frame(const ink_manifest_t *a, const ink_manifest_t *b) {
    return a->revision == b->revision && !strcmp(a->page_id, b->page_id) && !strcmp(a->hash, b->hash);
}
bool ink_manifest_same_pixels(const ink_manifest_t *a,const ink_manifest_t *b) {
    return a&&b&&a->hash[0]&&b->hash[0]&&!strcmp(a->hash,b->hash);
}
static const char *status_name(ink_status_state_t state) {
    switch(state) {
    case INK_STATUS_DOWNLOADED:return "downloaded";
    case INK_STATUS_REFRESHING:return "refreshing";
    case INK_STATUS_DISPLAYED:return "displayed";
    case INK_STATUS_FAILED:return "failed";
    default:return NULL;
    }
}
static bool hash_valid(const char hash[65]) {
    if(!memchr(hash,0,65)||strlen(hash)!=64) return false;
    for(size_t i=0;i<64;++i) if(!isxdigit((unsigned char)hash[i])) return false;
    return true;
}
bool ink_status_valid(const ink_status_t *s) {
    return s&&s->version==1&&status_name(s->state)&&s->revision>=0&&s->revision<=INT64_C(9007199254740991)
        &&memchr(s->transfer_id,0,sizeof(s->transfer_id))&&ink_uuid_valid(s->transfer_id)
        &&memchr(s->page_id,0,sizeof(s->page_id))&&ink_uuid_valid(s->page_id)&&hash_valid(s->hash)
        &&memchr(s->error,0,sizeof(s->error))&&(s->state==INK_STATUS_FAILED||!s->error[0]);
}
bool ink_status_begin(ink_status_t *out,const char *transfer_id,const ink_manifest_t *m,ink_status_state_t state,const char *error) {
    if(!out||!m||!ink_uuid_valid(transfer_id)||!memchr(m->page_id,0,sizeof(m->page_id))||!ink_uuid_valid(m->page_id)
        ||!hash_valid(m->hash)||(error&&strlen(error)>=sizeof(out->error))||state==INK_STATUS_REFRESHING) return false;
    ink_status_t s={.version=1,.state=state,.revision=m->revision};
    memcpy(s.transfer_id,transfer_id,sizeof(s.transfer_id));memcpy(s.page_id,m->page_id,sizeof(s.page_id));
    memcpy(s.hash,m->hash,sizeof(s.hash));if(error) memcpy(s.error,error,strlen(error)+1);
    if(!ink_status_valid(&s)) return false;
    *out=s;return true;
}
bool ink_status_advance(ink_status_t *s,ink_status_state_t state,const char *error) {
    if(!ink_status_valid(s)||(error&&strlen(error)>=sizeof(s->error))) return false;
    bool allowed=(s->state==INK_STATUS_DOWNLOADED&&(state==INK_STATUS_REFRESHING||state==INK_STATUS_FAILED))
        ||(s->state==INK_STATUS_REFRESHING&&(state==INK_STATUS_DISPLAYED||state==INK_STATUS_FAILED));
    if(!allowed) return false;
    ink_status_t next=*s;next.state=state;memset(next.error,0,sizeof(next.error));
    if(error) memcpy(next.error,error,strlen(error)+1);
    if(!ink_status_valid(&next)) return false;
    *s=next;return true;
}
bool ink_status_matches_frame(const ink_status_t *s,const ink_manifest_t *m) {
    return ink_status_valid(s)&&m&&s->revision==m->revision&&!strcmp(s->page_id,m->page_id)&&!strcmp(s->hash,m->hash);
}
bool ink_status_json(const ink_status_t *s,char *out,size_t capacity) {
    if(!out||capacity>INT_MAX||!ink_status_valid(s)) return false;
    cJSON *obj=cJSON_CreateObject();if(!obj) return false;
    bool ok=cJSON_AddStringToObject(obj,"transferID",s->transfer_id)&&cJSON_AddStringToObject(obj,"pageID",s->page_id)
        &&cJSON_AddNumberToObject(obj,"revision",(double)s->revision)&&cJSON_AddStringToObject(obj,"hash",s->hash)
        &&cJSON_AddStringToObject(obj,"state",status_name(s->state));
    if(s->error[0]) ok=ok&&cJSON_AddStringToObject(obj,"error",s->error);
    ok=ok&&cJSON_PrintPreallocated(obj,out,(int)capacity,false);cJSON_Delete(obj);return ok;
}
bool ink_status_ack(const char *json,size_t size,const ink_status_t *status) {
    if(!ink_status_valid(status)) return false;
    cJSON *root=parse_object(json,size,2048);if(!root) return false;
    char transfer[INK_UUID_SIZE];
    bool ok=cJSON_IsTrue(get(root,"ok"))&&uuid_field(root,"transferID",transfer)&&!strcmp(transfer,status->transfer_id);
    cJSON_Delete(root);return ok;
}
bool ink_status_tx_set(ink_status_tx_t *tx,const ink_status_t *status) {
    if(!tx||!ink_status_valid(status)) return false;
    *tx=(ink_status_tx_t){.status=*status,.present=true,.needs_save=true};return true;
}
void ink_status_tx_saved(ink_status_tx_t *tx,bool success) {
    if(tx&&tx->present&&success) tx->needs_save=false;
}
bool ink_status_tx_response(ink_status_tx_t *tx,int http_status,const char *json,size_t size) {
    if(!tx||!tx->present||tx->needs_save||!ink_status_valid(&tx->status)) return false;
    bool stale=http_status==409||http_status==410;
    if(!stale&&(http_status!=200||!ink_status_ack(json,size,&tx->status))) return false;
    tx->acknowledged=true;tx->stale=stale;return true;
}
bool ink_status_tx_clear(ink_status_tx_t *tx,bool commit_success) {
    if(!tx||!tx->present||!ink_status_valid(&tx->status)||tx->needs_save||!tx->acknowledged||!commit_success
        ||(!tx->stale&&tx->status.state!=INK_STATUS_DISPLAYED&&tx->status.state!=INK_STATUS_FAILED)) return false;
    memset(tx,0,sizeof(*tx));return true;
}
static bool event_valid(const ink_action_t *e) {
    return memchr(e->event_id, 0, sizeof(e->event_id)) && ink_uuid_valid(e->event_id)
        && memchr(e->page_id, 0, sizeof(e->page_id)) && ink_uuid_valid(e->page_id)
        && memchr(e->action, 0, sizeof(e->action)) && known_action(e->action)
        && memchr(e->task_id, 0, sizeof(e->task_id)) && (!e->task_id[0] || ink_uuid_valid(e->task_id))
        && (strcmp(e->action, "toggle_task") || e->task_id[0]);
}
bool ink_action_json(const ink_action_t *e, char *out, size_t capacity) {
    if (!e || !out || !event_valid(e)) return false;
    cJSON *obj = cJSON_CreateObject();
    if (!obj) return false;
    bool ok = cJSON_AddStringToObject(obj, "eventID", e->event_id) && cJSON_AddStringToObject(obj, "action", e->action)
        && cJSON_AddStringToObject(obj, "pageID", e->page_id);
    if (e->task_id[0]) ok = ok && cJSON_AddStringToObject(obj, "taskID", e->task_id);
    ok = ok && cJSON_PrintPreallocated(obj, out, (int)capacity, false);
    cJSON_Delete(obj);
    return ok;
}
bool ink_action_ack(const char *json, size_t size) {
    cJSON *root = cJSON_ParseWithLength(json, size);
    if (!root) return false;
    const cJSON *rev = get(root, "revision");
    bool ok = cJSON_IsTrue(get(root, "ok")) && cJSON_IsNumber(rev) && rev->valuedouble >= 0;
    cJSON_Delete(root); return ok;
}
bool ink_queue_valid(const ink_queue_t *q) {
    if (!q || q->version != 1 || q->count > INK_QUEUE_CAPACITY) return false;
    for (uint32_t i = 0; i < q->count; ++i) if (!event_valid(&q->events[i])) return false;
    return true;
}
bool ink_queue_push(ink_queue_t *q, const ink_action_t *e) {
    if (!ink_queue_valid(q) || !event_valid(e) || q->count == INK_QUEUE_CAPACITY) return false;
    q->events[q->count++] = *e; return true;
}
void ink_queue_shift(ink_queue_t *q) {
    if (!q || !q->count) return;
    memmove(q->events, q->events + 1, (q->count - 1) * sizeof(q->events[0]));
    memset(&q->events[--q->count], 0, sizeof(q->events[0]));
}
