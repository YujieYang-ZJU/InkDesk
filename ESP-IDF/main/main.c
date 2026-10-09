#include "protocol.h"
#include "sha256.h"
#include "epd.h"
#include "storage.h"
#include "driver/gpio.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "nvs.h"
#include "esp_netif.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "sdkconfig.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *TAG="inkdesk";
static EventGroupHandle_t network;
#define WIFI_CONNECTED_BIT BIT0
static QueueHandle_t buttons;
static ink_manifest_t current;
static ink_queue_t pending;
static uint8_t *frame,*incoming;
static bool have_frame,task_mode,storage_ok,display_ok;
static bool dirty;
static ink_status_tx_t sync_tx;
static bool status_idle_completion;
static bool status_load_ok=true,physically_displayed;
static ink_status_t last_completed;
static bool have_completed;
static unsigned focus_index;
typedef struct { int key;bool long_press; } button_event_t;
static void *allocate(size_t bytes) {
    void *p=heap_caps_malloc(bytes,MALLOC_CAP_SPIRAM|MALLOC_CAP_8BIT);
    return p ? p : malloc(bytes);
}
static void wifi_event(void *arg,esp_event_base_t base,int32_t id,void *data) {
    (void)arg;(void)data;
    if(base==WIFI_EVENT&&id==WIFI_EVENT_STA_START) esp_wifi_connect();
    else if(base==WIFI_EVENT&&id==WIFI_EVENT_STA_DISCONNECTED) {
        xEventGroupClearBits(network,WIFI_CONNECTED_BIT);esp_wifi_connect();
    } else if(base==IP_EVENT&&id==IP_EVENT_STA_GOT_IP) {xEventGroupSetBits(network,WIFI_CONNECTED_BIT);ESP_LOGI(TAG,"Wi-Fi connected");}
}
static esp_err_t wifi_start(void) {
    ESP_ERROR_CHECK(esp_netif_init());ESP_ERROR_CHECK(esp_event_loop_create_default());
    if(!esp_netif_create_default_wifi_sta()) return ESP_ERR_NO_MEM;
    wifi_init_config_t init=WIFI_INIT_CONFIG_DEFAULT();
    if(!storage_ok) init.nvs_enable=0;
    ESP_ERROR_CHECK(esp_wifi_init(&init));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT,ESP_EVENT_ANY_ID,wifi_event,NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT,IP_EVENT_STA_GOT_IP,wifi_event,NULL));
    wifi_config_t config={0};
    if(strlen(CONFIG_INK_WIFI_SSID)>32||strlen(CONFIG_INK_WIFI_PASSWORD)>63) return ESP_ERR_INVALID_ARG;
    memcpy(config.sta.ssid,CONFIG_INK_WIFI_SSID,strlen(CONFIG_INK_WIFI_SSID));
    memcpy(config.sta.password,CONFIG_INK_WIFI_PASSWORD,strlen(CONFIG_INK_WIFI_PASSWORD));
    config.sta.threshold.authmode=CONFIG_INK_WIFI_PASSWORD[0] ? WIFI_AUTH_WPA2_PSK : WIFI_AUTH_OPEN;
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA,&config));
    return esp_wifi_start();
}
static esp_err_t http_request(const char *path,const char *body,uint8_t *buffer,size_t capacity,size_t *used,int *status) {
    *used=0;*status=0;
    char url[256],authorization[192];
    int n=snprintf(url,sizeof(url),"%s%s",CONFIG_INK_BASE_URL,path);
    if(n<0||(size_t)n>=sizeof(url)||strlen(CONFIG_INK_DEVICE_TOKEN)>160) return ESP_ERR_INVALID_ARG;
    snprintf(authorization,sizeof(authorization),"Bearer %s",CONFIG_INK_DEVICE_TOKEN);
    esp_http_client_config_t config={.url=url,.timeout_ms=CONFIG_INK_HTTP_TIMEOUT_MS,.disable_auto_redirect=true,.buffer_size=2048};
    esp_http_client_handle_t client=esp_http_client_init(&config);
    if(!client) return ESP_ERR_NO_MEM;
    esp_err_t error=esp_http_client_set_header(client,"Authorization",authorization);
    if(error==ESP_OK) error=esp_http_client_set_header(client,"Accept",body ? "application/json" : "*/*");
    if(body) {
        if(error==ESP_OK) error=esp_http_client_set_method(client,HTTP_METHOD_POST);
        if(error==ESP_OK) error=esp_http_client_set_header(client,"Content-Type","application/json");
    }
    size_t body_size=body ? strlen(body) : 0;
    if(error==ESP_OK) error=esp_http_client_open(client,(int)body_size);
    for(size_t sent=0;error==ESP_OK&&sent<body_size;) {
        int written=esp_http_client_write(client,body+sent,(int)(body_size-sent));
        if(written<=0) error=ESP_FAIL;else sent+=(size_t)written;
    }
    if(error==ESP_OK) {
        int64_t length=esp_http_client_fetch_headers(client);*status=esp_http_client_get_status_code(client);
        if(*status!=200) error=ESP_FAIL;
        else if(length>(int64_t)capacity) error=ESP_ERR_INVALID_SIZE;
    }
    while(error==ESP_OK&&*used<capacity) {
        int received=esp_http_client_read(client,(char *)buffer+*used,(int)(capacity-*used));
        if(received<0) {error=ESP_FAIL;break;}
        if(received==0) break;
        *used+=(size_t)received;
    }
    if(error==ESP_OK&&*used==capacity) {
        char extra;int got=esp_http_client_read(client,&extra,1);
        if(got!=0) error=ESP_ERR_INVALID_SIZE;
    }
    if(error==ESP_OK&&!esp_http_client_is_complete_data_received(client)) error=ESP_FAIL;
    esp_http_client_close(client);esp_http_client_cleanup(client);
    /* Never log URL, authorization header, Wi-Fi password or response bodies. */
    return error;
}
static esp_err_t get_manifest(ink_manifest_t *manifest,char transfer_id[INK_UUID_SIZE]) {
    char *json=allocate(INK_MANIFEST_MAX+1);if(!json) return ESP_ERR_NO_MEM;
    size_t used=0;int status;
    esp_err_t error=http_request("/api/sync/manifest",NULL,(uint8_t *)json,INK_MANIFEST_MAX,&used,&status);
    json[used]=0;
    if(error==ESP_OK&&!ink_sync_manifest_parse(json,used,manifest,transfer_id)) error=ESP_ERR_INVALID_RESPONSE;
    if(status==401||status==403) ESP_LOGE(TAG,"Device token rejected; update menuconfig after rotating token on Mac");
    free(json);return error;
}
static void set_status(const ink_status_t *status) {
    ink_status_tx_set(&sync_tx,status);status_idle_completion=false;
}
static esp_err_t persist_status(void) {
    if(!sync_tx.needs_save) return ESP_OK;
    esp_err_t error=storage_ok ? ink_status_save(&sync_tx.status) : ESP_OK;
    ink_status_tx_saved(&sync_tx,error==ESP_OK);
    if(error!=ESP_OK) ESP_LOGE(TAG,"Cannot persist sync status (%s); retaining immutable status in RAM",esp_err_to_name(error));
    return error;
}
static esp_err_t clear_status(void) {
    esp_err_t error=storage_ok ? ink_status_save(NULL) : ESP_OK;
    if(error!=ESP_OK) {ESP_LOGE(TAG,"Sync ACK received; journal clear failed; retaining completion");return error;}
    if(!ink_status_tx_clear(&sync_tx,true)) return ESP_ERR_INVALID_STATE;
    status_idle_completion=false;return ESP_OK;
}
static void advance_status(ink_status_state_t state,const char *error) {
    ink_status_t next=sync_tx.status;
    if(ink_status_advance(&next,state,error)) set_status(&next);
}
static esp_err_t service_status(void) {
    if(!sync_tx.present) return ESP_OK;
    esp_err_t error=persist_status();if(error!=ESP_OK) return error;
    if(!sync_tx.acknowledged) {
        char body[1024],reply[2048];size_t used;int status;
        if(!ink_status_json(&sync_tx.status,body,sizeof(body))) return ESP_ERR_INVALID_STATE;
        error=http_request("/api/sync/status",body,(uint8_t *)reply,sizeof(reply)-1,&used,&status);reply[used]=0;
        if((status==409||status==410)&&ink_status_tx_response(&sync_tx,status,NULL,0)) {
            /* Lease expired/tuple retired: retain actual pixels/actions, claim again. */
            ESP_LOGW(TAG,"Sync transfer expired (HTTP %d); reclaiming after journal clear",status);
        } else {
            if(error!=ESP_OK||!ink_status_tx_response(&sync_tx,status,reply,used)) {
                if(status>=400&&status<500) ESP_LOGE(TAG,"Sync status rejected (HTTP %d); immutable status retained",status);
                return error==ESP_OK ? ESP_ERR_INVALID_RESPONSE : error;
            }
        }
    }
    if(sync_tx.stale||sync_tx.status.state==INK_STATUS_DISPLAYED||sync_tx.status.state==INK_STATUS_FAILED) {
        bool completed=!sync_tx.stale&&sync_tx.status.state==INK_STATUS_DISPLAYED;
        ink_status_t finished=sync_tx.status;
        error=clear_status();
        if(error==ESP_OK&&completed) {last_completed=finished;have_completed=true;}
        return error;
    }
    bool matches=have_frame&&ink_status_matches_frame(&sync_tx.status,&current);
    if(!matches) advance_status(INK_STATUS_FAILED,"Verified frame unavailable after restart");
    else if(sync_tx.status.state==INK_STATUS_DOWNLOADED) advance_status(INK_STATUS_REFRESHING,NULL);
    else if(!display_ok) advance_status(INK_STATUS_FAILED,"Display initialization failed");
    /* REFRESHING stays journaled until ink_epd_show actually returns. */
    return ESP_OK;
}
static void apply_focus(void) {
    bool old_mode=task_mode;unsigned old_index=focus_index;
    task_mode=current.focused_task_id[0]!=0&&current.task_count!=0;focus_index=0;
    for(uint32_t i=0;i<current.task_count;++i)
        if(!strcmp(current.focused_task_id,current.tasks[i])) focus_index=i;
    for(uint32_t i=0;i<pending.count;++i) {
        const ink_action_t *e=&pending.events[i];
        if(strcmp(e->page_id,current.page_id)) continue;
        if(!strcmp(e->action,"exit_task")||!strcmp(e->action,"next_page")||!strcmp(e->action,"previous_page")) task_mode=false;
        else if(e->task_id[0]) for(uint32_t j=0;j<current.task_count;++j)
            if(!strcmp(e->task_id,current.tasks[j])) {focus_index=j;task_mode=true;}
    }
    if(old_mode!=task_mode||old_index!=focus_index) dirty=true;
}
static esp_err_t poll_frame(void) {
    ink_manifest_t *first=allocate(sizeof(*first)),*second=allocate(sizeof(*second));
    if(!first||!second) {free(first);free(second);return ESP_ERR_NO_MEM;}
    char transfer[INK_UUID_SIZE]={0},verified_transfer[INK_UUID_SIZE]={0};
    esp_err_t error=get_manifest(first,transfer);
    bool same_pixels=error==ESP_OK&&have_frame&&ink_manifest_same_pixels(&current,first);
    if(error==ESP_OK&&!same_pixels) {
        size_t used;int status;
        error=http_request("/api/sync/frame.bin",NULL,incoming,INK_FRAME_BYTES,&used,&status);
        if(error==ESP_OK&&used!=INK_FRAME_BYTES) error=ESP_ERR_INVALID_SIZE;
    }
    if(error==ESP_OK) {
        char hash[65];ink_sha256_hex(same_pixels ? frame : incoming,INK_FRAME_BYTES,hash);
        if(strcmp(hash,first->hash)) error=ESP_ERR_INVALID_CRC;
    }
    /* Verify the pinned transfer and pixels, including when reusing a cache. */
    if(error==ESP_OK) error=get_manifest(second,verified_transfer);
    if(error==ESP_OK&&(!ink_manifest_same_frame(first,second)||strcmp(transfer,verified_transfer))) error=ESP_ERR_INVALID_STATE;
    if(error==ESP_OK) {
        /* A new revision/transfer can name identical pixels. Preserve actual
         * display proof and bytes, but persist the new tuple/task metadata. */
        bool metadata_changed=!have_frame||memcmp(&current,second,sizeof(current))!=0;
        if(!same_pixels) {memcpy(frame,incoming,INK_FRAME_BYTES);dirty=true;physically_displayed=false;}
        current=*second;have_frame=true;
        apply_focus();
        if(metadata_changed) {
            esp_err_t saved=ink_cache_save(&current,frame);
            if(saved!=ESP_OK) ESP_LOGW(TAG,"Accepted frame in RAM; flash cache unavailable (%s)",esp_err_to_name(saved));
            ESP_LOGI(TAG,"Accepted verified frame, revision %lld",(long long)current.revision);
        }
        ink_status_t status;
        /* Only this boot's successful panel refresh is evidence of display.
         * Restoring bytes from cache leaves physically_displayed=false. */
        ink_status_state_t state=same_pixels&&physically_displayed&&!dirty ? INK_STATUS_DISPLAYED : INK_STATUS_DOWNLOADED;
        if(state==INK_STATUS_DISPLAYED&&have_completed&&!strcmp(transfer,last_completed.transfer_id)
            &&ink_status_matches_frame(&last_completed,&current)) {
            /* The host returns its completed claim when nothing newer is queued.
             * Retain ordinary polling without repeating HTTP status/NVS writes. */
        } else if(ink_status_begin(&status,transfer,&current,state,NULL)) {set_status(&status);status_idle_completion=state==INK_STATUS_DISPLAYED&&!metadata_changed;}
        else error=ESP_ERR_INVALID_STATE;
    } else if(transfer[0]) {
        ink_status_t status;
        if(ink_status_begin(&status,transfer,first,INK_STATUS_FAILED,esp_err_to_name(error))) set_status(&status);
    }
    free(first);free(second);return error;
}
static void uuid(char out[INK_UUID_SIZE]) {
    uint8_t b[16];esp_fill_random(b,sizeof(b));b[6]=(b[6]&15)|0x40;b[8]=(b[8]&63)|0x80;
    snprintf(out,INK_UUID_SIZE,"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]);
}
static bool enqueue(const char *action,const char *task_id) {
    if(!storage_ok||!have_frame) {ESP_LOGW(TAG,"Control unavailable until a manifest is cached and NVS works");return false;}
    for(uint32_t i=0;i<pending.count;++i) {
        const ink_action_t *e=&pending.events[i];
        if(!strcmp(e->action,"next_page")||!strcmp(e->action,"previous_page")||strcmp(e->page_id,current.page_id)) {
            ESP_LOGW(TAG,"Waiting for queued navigation/context to synchronize; input not accepted");return false;
        }
    }
    ink_action_t event={0};uuid(event.event_id);
    snprintf(event.action,sizeof(event.action),"%s",action);memcpy(event.page_id,current.page_id,INK_UUID_SIZE);
    if(task_id) snprintf(event.task_id,sizeof(event.task_id),"%s",task_id);
    if(!ink_queue_push(&pending,&event)) {ESP_LOGW(TAG,"Pending queue full (24); reconnect before more actions");return false;}
    esp_err_t error=ink_queue_save(&pending);
    if(error!=ESP_OK) {memset(&pending.events[--pending.count],0,sizeof(event));ESP_LOGE(TAG,"Cannot persist action; input not accepted");return false;}
    dirty=true;ESP_LOGI(TAG,"Queued %s (%u pending)",action,(unsigned)pending.count);return true;
}
static bool flush_one(void) {
    if(!pending.count||!storage_ok) return true;
    char body[320],reply[2048];
    if(!ink_action_json(&pending.events[0],body,sizeof(body))) return false;
    size_t used;int status;
    esp_err_t error=http_request("/api/action",body,(uint8_t *)reply,sizeof(reply)-1,&used,&status);reply[used]=0;
    if(error!=ESP_OK||!ink_action_ack(reply,used)) {
        if(status>=400&&status<500) ESP_LOGE(TAG,"Queued action rejected (HTTP %d). Retained for review; see firmware.md",status);
        return false;
    }
    ink_action_t first=pending.events[0];ink_queue_shift(&pending);
    error=ink_queue_save(&pending);
    if(error!=ESP_OK) {
        /* ACK may have arrived but disk commit failed. Replay same immutable UUID. */
        memmove(pending.events+1,pending.events,pending.count*sizeof(first));pending.events[0]=first;++pending.count;
        ESP_LOGE(TAG,"ACK received; queue commit failed; retaining same eventID");return false;
    }
    dirty=true;return true;
}
static void process_button(button_event_t event) {
    /* Deliberate local recovery: hold all three buttons for five seconds. */
    if(event.key==3) {
        if(!storage_ok) return;
        ink_queue_t saved=pending;
        memset(pending.events,0,sizeof(pending.events));pending.count=0;
        if(ink_queue_save(&pending)!=ESP_OK) {pending=saved;ESP_LOGE(TAG,"Cannot discard queue; original retained");}
        else {ESP_LOGW(TAG,"Unsynchronized actions discarded by three-button recovery gesture");dirty=true;apply_focus();}
        return;
    }
    if(!have_frame) return;
    if(event.key==2&&event.long_press) {enqueue("refresh",NULL);return;}
    if(event.key==1&&event.long_press) {
        if(task_mode) {if(enqueue("exit_task",NULL)) task_mode=false;}
        else if(current.task_count) {if(enqueue("next_task",current.tasks[focus_index])) task_mode=true;}
        return;
    }
    if(task_mode) {
        if(!current.task_count) return;
        if(event.key==1) enqueue("toggle_task",current.tasks[focus_index]);
        else {
            unsigned target=event.key==0 ? (focus_index+current.task_count-1)%current.task_count : (focus_index+1)%current.task_count;
            if(enqueue(event.key==0 ? "previous_task" : "next_task",current.tasks[target])) focus_index=target;
        }
    } else enqueue(event.key==0 ? "previous_page" : event.key==2 ? "next_page" : "refresh",NULL);
}
static void button_task(void *arg) {
    (void)arg;const int pins[]={CONFIG_INK_BUTTON_LEFT,CONFIG_INK_BUTTON_MIDDLE,CONFIG_INK_BUTTON_RIGHT};
    bool stable[3]={false},candidate[3]={false},suppressed[3]={false};
    unsigned samples[3]={0};int64_t down[3]={0},chord_start=0;bool chord_sent=false;
    for(;;) {
        int64_t now=esp_timer_get_time();
        for(int key=0;key<3;++key) {
            bool pressed=gpio_get_level(pins[key])==0;
            if(pressed!=candidate[key]) {candidate[key]=pressed;samples[key]=1;}
            else if(samples[key]<3) ++samples[key];
            if(samples[key]>=3&&pressed!=stable[key]) {
                stable[key]=pressed;
                if(pressed) down[key]=now;
                else if(!suppressed[key]&&now-down[key]>=100000) {
                    button_event_t event={key,now-down[key]>=900000};
                    if(xQueueSend(buttons,&event,0)!=pdTRUE) ESP_LOGW(TAG,"Button input buffer full");
                }
                if(!pressed) suppressed[key]=false;
            }
        }
        if(stable[0]&&stable[1]&&stable[2]) {
            if(!chord_start) chord_start=now;
            if(!chord_sent&&now-chord_start>=5000000) {
                button_event_t discard={.key=3,.long_press=true};
                if(xQueueSend(buttons,&discard,0)==pdTRUE) {
                    chord_sent=true;suppressed[0]=suppressed[1]=suppressed[2]=true;
                }
            }
        } else {chord_start=0;chord_sent=false;}
        vTaskDelay(pdMS_TO_TICKS(20));
    }
}
static esp_err_t start_buttons(void) {
    const int inputs[]={CONFIG_INK_BUTTON_LEFT,CONFIG_INK_BUTTON_MIDDLE,CONFIG_INK_BUTTON_RIGHT};
    const int display[]={CONFIG_INK_EPD_SCLK,CONFIG_INK_EPD_MOSI,CONFIG_INK_EPD_CS,CONFIG_INK_EPD_DC,CONFIG_INK_EPD_RST,CONFIG_INK_EPD_BUSY};
    uint64_t mask=0;
    for(int i=0;i<3;++i) {
        if(!GPIO_IS_VALID_GPIO(inputs[i])) return ESP_ERR_INVALID_ARG;
        for(int j=0;j<6;++j) if(inputs[i]==display[j]) return ESP_ERR_INVALID_ARG;
        if(mask&(1ULL<<inputs[i])) return ESP_ERR_INVALID_ARG;
        mask|=1ULL<<inputs[i];
    }
    gpio_config_t config={.pin_bit_mask=mask,.mode=GPIO_MODE_INPUT,.pull_up_en=GPIO_PULLUP_ENABLE};
    esp_err_t error=gpio_config(&config);if(error!=ESP_OK) return error;
    buttons=xQueueCreate(24,sizeof(button_event_t));if(!buttons) return ESP_ERR_NO_MEM;
    return xTaskCreate(button_task,"ink_buttons",3072,NULL,5,NULL)==pdPASS ? ESP_OK : ESP_ERR_NO_MEM;
}
void app_main(void) {
    ESP_LOGI(TAG,"InkDesk E1001: 800x480 mono; awake USB/polling mode");
    storage_ok=ink_storage_init(&pending)==ESP_OK;
    if(!storage_ok) {ESP_LOGE(TAG,"NVS unavailable/corrupt; preserving data; action recording disabled");memset(&pending,0,sizeof(pending));pending.version=1;}
    if(storage_ok) {
        esp_err_t loaded=ink_status_load(&sync_tx.status);
        if(loaded==ESP_OK) {sync_tx.present=true;ESP_LOGI(TAG,"Restored immutable pending sync status (%u)",(unsigned)sync_tx.status.state);}
        else if(loaded!=ESP_ERR_NVS_NOT_FOUND) {status_load_ok=false;ESP_LOGE(TAG,"Sync journal unavailable/corrupt; preserved for review; frame claims disabled");}
    }
    frame=allocate(INK_FRAME_BYTES);incoming=allocate(INK_FRAME_BYTES);
    if(!frame||!incoming) {ESP_LOGE(TAG,"Insufficient memory; enable E1001 OPI PSRAM");return;}
    display_ok=ink_epd_init()==ESP_OK;
    if(!display_ok) ESP_LOGE(TAG,"Display initialization failed; check GPIO configuration");
    have_frame=ink_cache_load(&current,frame);
    if(have_frame) {apply_focus();dirty=true;ESP_LOGI(TAG,"Verified cached frame loaded (%u pending)",(unsigned)pending.count);}
    if(start_buttons()!=ESP_OK) {ESP_LOGE(TAG,"Button GPIO initialization failed");return;}
    network=xEventGroupCreate();if(!network) return;
    bool configured=CONFIG_INK_WIFI_SSID[0]&&CONFIG_INK_DEVICE_TOKEN[0]&&strlen(CONFIG_INK_DEVICE_TOKEN)<=160
        &&!strncmp(CONFIG_INK_BASE_URL,"http://",7)&&CONFIG_INK_BASE_URL[strlen(CONFIG_INK_BASE_URL)-1]!='/';
    if(configured) {if(wifi_start()!=ESP_OK) configured=false;}
    if(!configured) ESP_LOGW(TAG,"Configure Wi-Fi, http://Mac-IP:port and device token in menuconfig; cached content still works");
    int64_t next_poll=0,next_action=0,next_display=0,next_status=0;
    unsigned failure_count=0,status_failures=0;
    for(;;) {
        button_event_t event;
        while(xQueueReceive(buttons,&event,0)==pdTRUE) {process_button(event);next_action=0;}
        int64_t now=esp_timer_get_time();
        bool connected=configured&&(xEventGroupGetBits(network)&WIFI_CONNECTED_BIT);
        if(connected&&sync_tx.present&&now>=next_status) {
            bool idle=status_idle_completion;
            ink_status_state_t completed_state=sync_tx.status.state;
            esp_err_t error=service_status();
            if(error==ESP_OK) {
                status_failures=0;next_status=0;
                if(!sync_tx.present&&!idle) next_poll=completed_state==INK_STATUS_FAILED ? esp_timer_get_time()+30000000 : 0;
            } else {
                unsigned delay=2U<<(status_failures<5?status_failures++:5);
                next_status=esp_timer_get_time()+(int64_t)delay*1000000;
                ESP_LOGW(TAG,"Sync status retry (%s); frame claim blocked",esp_err_to_name(error));
            }
        }
        if(connected&&pending.count&&now>=next_action) {
            /* Commit each ACK, but drain contiguous successes before redraw. */
            bool flushed=true;
            for(unsigned sent=0;pending.count&&sent<INK_QUEUE_CAPACITY;++sent)
                if(!flush_one()) {flushed=false;break;}
            if(flushed) {failure_count=0;next_poll=0;next_action=esp_timer_get_time()+250000;}
            else {unsigned delay=2U<<(failure_count<5?failure_count++:5);next_action=esp_timer_get_time()+(int64_t)delay*1000000;}
        }
        if(connected&&status_load_ok&&!sync_tx.present&&now>=next_poll) {
            esp_err_t error=poll_frame();
            int seconds=error==ESP_OK ? current.poll_seconds : CONFIG_INK_POLL_SECONDS;
            if(error!=ESP_OK) ESP_LOGW(TAG,"Poll failed (%s); retaining verified frame",esp_err_to_name(error));
            next_poll=esp_timer_get_time()+(int64_t)seconds*1000000;
        }
        bool transfer_ready=sync_tx.present&&sync_tx.acknowledged&&sync_tx.status.state==INK_STATUS_REFRESHING
            &&ink_status_matches_frame(&sync_tx.status,&current);
        if(dirty&&have_frame&&display_ok&&(!sync_tx.present||transfer_ready)&&esp_timer_get_time()>=next_display) {
            esp_err_t error=ink_epd_show(frame,pending.count,task_mode,focus_index);
            if(error==ESP_OK) {
                dirty=false;physically_displayed=true;
                if(transfer_ready) {advance_status(INK_STATUS_DISPLAYED,NULL);next_status=0;}
                ESP_LOGI(TAG,"Physical display refresh succeeded, revision %lld",(long long)current.revision);
            } else {
                if(transfer_ready) {advance_status(INK_STATUS_FAILED,esp_err_to_name(error));next_status=0;}
                ESP_LOGE(TAG,"Display refresh failed (%s); retry in 30 seconds",esp_err_to_name(error));
            }
            next_display=esp_timer_get_time()+(error==ESP_OK ? 1000000 : 30000000);
        }
        vTaskDelay(pdMS_TO_TICKS(100));
    }
}
