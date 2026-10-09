#include "protocol.h"
#include "sha256.h"
#include "cJSON.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const char *PAGE="12345678-1234-4234-9234-123456789abc";
static const char *TASK="87654321-4321-4321-8321-cba987654321";
static const char *TRANSFER="11111111-2222-4333-8444-555555555555";
static const char *sample="{\"version\":1,\"width\":800,\"height\":480,\"pixelFormat\":\"mono1-msb-white1\",\"rowBytes\":100,\"pageID\":\"12345678-1234-4234-9234-123456789abc\",\"revision\":5,\"hash\":\"d4777c4a41f0a7c95d9cfe865094d51480f44347ea1173fd321477e1a9739d9b\",\"frameURL\":\"/api/frame.bin\",\"pollSeconds\":30,\"pages\":[{\"id\":\"12345678-1234-4234-9234-123456789abc\",\"name\":\"我的日程\"}],\"taskIDs\":[\"87654321-4321-4321-8321-cba987654321\"],\"focusedTaskID\":null}";
static void rejects_number(const char *key,double value) {
    cJSON *root=cJSON_Parse(sample);assert(root);cJSON_ReplaceItemInObjectCaseSensitive(root,key,cJSON_CreateNumber(value));
    char *json=cJSON_PrintUnformatted(root);ink_manifest_t m;
    assert(!ink_manifest_parse(json,strlen(json),&m));free(json);cJSON_Delete(root);
}
static void sync_tests(void) {
    /* Cache ABI stays unchanged: transfer IDs are never stored in this struct. */
    assert(sizeof(ink_manifest_t)==6904);
    cJSON *root=cJSON_Parse(sample);assert(root);
    cJSON_ReplaceItemInObjectCaseSensitive(root,"frameURL",cJSON_CreateString("/api/sync/frame.bin"));
    assert(cJSON_AddStringToObject(root,"transferID",TRANSFER));
    char *json=cJSON_PrintUnformatted(root),transfer[INK_UUID_SIZE];ink_manifest_t m;
    assert(ink_sync_manifest_parse(json,strlen(json),&m,transfer));assert(!strcmp(transfer,TRANSFER));
    assert(!ink_manifest_parse(json,strlen(json),&m));free(json);
    cJSON_ReplaceItemInObjectCaseSensitive(root,"transferID",cJSON_CreateString("not-a-uuid"));
    json=cJSON_PrintUnformatted(root);assert(!ink_sync_manifest_parse(json,strlen(json),&m,transfer));free(json);
    cJSON_DeleteItemFromObjectCaseSensitive(root,"transferID");
    json=cJSON_PrintUnformatted(root);assert(!ink_sync_manifest_parse(json,strlen(json),&m,transfer));free(json);
    assert(cJSON_AddStringToObject(root,"transferID",TRANSFER));assert(cJSON_AddStringToObject(root,"transferID",TASK));
    json=cJSON_PrintUnformatted(root);assert(!ink_sync_manifest_parse(json,strlen(json),&m,transfer));free(json);cJSON_Delete(root);
    assert(ink_manifest_parse(sample,strlen(sample),&m));
    ink_status_t status,immutable;
    assert(ink_status_begin(&status,TRANSFER,&m,INK_STATUS_DOWNLOADED,NULL));immutable=status;
    char body[1024],retry[1024];assert(ink_status_json(&status,body,sizeof(body)));
    root=cJSON_Parse(body);assert(root);assert(cJSON_GetArraySize(root)==5);
    assert(!strcmp(cJSON_GetObjectItem(root,"transferID")->valuestring,TRANSFER));
    assert(!strcmp(cJSON_GetObjectItem(root,"state")->valuestring,"downloaded"));cJSON_Delete(root);
    assert(!ink_status_json(&status,body,32));
    ink_manifest_t other=m;assert(ink_status_matches_frame(&status,&other));
    ++other.revision;assert(!ink_status_matches_frame(&status,&other));other=m;strcpy(other.page_id,TASK);
    assert(!ink_status_matches_frame(&status,&other));other=m;other.hash[0]='0';assert(!ink_status_matches_frame(&status,&other));
    status=immutable;status.hash[1]='z';assert(!ink_status_json(&status,body,sizeof(body)));
    status=immutable;memset(status.transfer_id,'a',sizeof(status.transfer_id));assert(!ink_status_valid(&status));
    status=immutable;memset(status.hash,'a',sizeof(status.hash));assert(!ink_status_valid(&status));
    status=immutable;memset(status.error,'a',sizeof(status.error));assert(!ink_status_valid(&status));
    status=immutable;status.revision=-1;assert(!ink_status_valid(&status));status.revision=INT64_C(9007199254740992);assert(!ink_status_valid(&status));
    status=immutable;status.state=(ink_status_state_t)99;assert(!ink_status_valid(&status));
    status=immutable;strcpy(status.error,"wrong state");assert(!ink_status_valid(&status));
    status=immutable;assert(!ink_status_advance(&status,INK_STATUS_DISPLAYED,NULL));assert(!memcmp(&status,&immutable,sizeof(status)));
    assert(ink_status_advance(&status,INK_STATUS_REFRESHING,NULL));assert(ink_status_matches_frame(&status,&m));
    assert(ink_status_advance(&status,INK_STATUS_FAILED,"SPI \"busy\"\n timeout"));
    assert(ink_status_json(&status,body,sizeof(body)));root=cJSON_Parse(body);assert(root);
    assert(!strcmp(cJSON_GetObjectItem(root,"error")->valuestring,"SPI \"busy\"\n timeout"));cJSON_Delete(root);
    assert(!ink_status_advance(&status,INK_STATUS_DISPLAYED,NULL));
    char escaped[96];memset(escaped,'\1',95);escaped[95]=0;
    assert(ink_status_begin(&status,TRANSFER,&m,INK_STATUS_FAILED,escaped));
    assert(ink_status_json(&status,body,sizeof(body)));root=cJSON_Parse(body);assert(root);
    assert(!strcmp(cJSON_GetObjectItem(root,"error")->valuestring,escaped));cJSON_Delete(root);
    char too_long[97];memset(too_long,'x',96);too_long[96]=0;
    assert(!ink_status_begin(&status,TRANSFER,&m,INK_STATUS_FAILED,too_long));
    char ack[160];snprintf(ack,sizeof(ack),"{\"ok\":true,\"transferID\":\"%s\"}",TRANSFER);
    assert(ink_status_ack(ack,strlen(ack),&status));
    const char *bad_acks[]={"{\"ok\":true}","{\"ok\":false,\"transferID\":\"11111111-2222-4333-8444-555555555555\"}",
        "{\"ok\":true,\"transferID\":\"87654321-4321-4321-8321-cba987654321\"}",
        "{\"ok\":true,\"transferID\":\"11111111-2222-4333-8444-555555555555\"}{}",
        "{\"ok\":true,\"ok\":false,\"transferID\":\"11111111-2222-4333-8444-555555555555\"}"};
    for(size_t i=0;i<sizeof(bad_acks)/sizeof(bad_acks[0]);++i) assert(!ink_status_ack(bad_acks[i],strlen(bad_acks[i]),&status));
    ink_status_tx_t tx={0};assert(ink_status_tx_set(&tx,&immutable));
    ink_status_tx_saved(&tx,false);assert(tx.present&&tx.needs_save);
    assert(!ink_status_tx_response(&tx,200,ack,strlen(ack))); /* persist before reporting */
    ink_status_tx_saved(&tx,true);assert(!tx.needs_save);
    assert(!ink_status_tx_response(&tx,401,ack,strlen(ack)));assert(!ink_status_tx_response(&tx,400,ack,strlen(ack)));
    assert(!ink_status_tx_response(&tx,200,bad_acks[2],strlen(bad_acks[2])));
    assert(!memcmp(&tx.status,&immutable,sizeof(immutable))); /* wrong tuple ACK retains claim */
    assert(ink_status_tx_response(&tx,200,ack,strlen(ack)));assert(!ink_status_tx_clear(&tx,true)); /* downloaded cannot release */
    status=tx.status;assert(ink_status_advance(&status,INK_STATUS_REFRESHING,NULL));assert(ink_status_tx_set(&tx,&status));
    ink_status_tx_saved(&tx,true);assert(ink_status_tx_response(&tx,200,ack,strlen(ack)));
    assert(!ink_status_tx_clear(&tx,true)); /* refreshing cannot release */
    status=tx.status;assert(ink_status_advance(&status,INK_STATUS_DISPLAYED,NULL));assert(ink_status_tx_set(&tx,&status));
    ink_status_tx_saved(&tx,true);assert(ink_status_json(&tx.status,body,sizeof(body)));
    assert(!ink_status_tx_response(&tx,0,NULL,0));assert(!ink_status_tx_clear(&tx,true));
    assert(ink_status_json(&tx.status,retry,sizeof(retry)));assert(!strcmp(body,retry)); /* lost ACK replays exact completion */
    assert(ink_status_tx_response(&tx,200,ack,strlen(ack)));
    assert(!ink_status_tx_clear(&tx,false));assert(tx.present&&tx.acknowledged&&tx.status.state==INK_STATUS_DISPLAYED);
    assert(ink_status_json(&tx.status,retry,sizeof(retry)));assert(!strcmp(body,retry)); /* failed NVS clear blocks new claim */
    assert(ink_status_tx_clear(&tx,true));assert(!tx.present&&!tx.acknowledged);
    assert(ink_status_tx_set(&tx,&immutable));ink_status_tx_saved(&tx,true);
    assert(ink_status_tx_response(&tx,409,NULL,0));assert(tx.stale&&!ink_status_tx_clear(&tx,false));
    assert(ink_status_tx_clear(&tx,true)); /* expired tuple releases without inventing display */
    assert(ink_status_tx_set(&tx,&immutable));ink_status_tx_saved(&tx,true);
    assert(ink_status_tx_response(&tx,410,NULL,0));assert(ink_status_tx_clear(&tx,true));
}
int main(void) {
    ink_manifest_t m;
    assert(ink_manifest_parse(sample,strlen(sample),&m));assert(m.revision==5&&m.task_count==1&&m.page_count==1);
    assert(!strcmp(m.page_id,PAGE)&&!strcmp(m.tasks[0],TASK));assert(m.focused_task_id[0]==0);
    assert(!ink_manifest_parse(sample,strlen(sample)-1,&m));
    char garbage[1024];snprintf(garbage,sizeof(garbage),"%s{}",sample);assert(!ink_manifest_parse(garbage,strlen(garbage),&m));
    rejects_number("width",480);rejects_number("height",800);rejects_number("rowBytes",99);rejects_number("revision",-1);rejects_number("revision",5.5);rejects_number("revision",1e20);rejects_number("pollSeconds",0);
    cJSON *root=cJSON_Parse(sample);cJSON_ReplaceItemInObjectCaseSensitive(root,"focusedTaskID",cJSON_CreateString(TASK));
    char *json=cJSON_PrintUnformatted(root);assert(ink_manifest_parse(json,strlen(json),&m));assert(!strcmp(m.focused_task_id,TASK));free(json);
    cJSON_ReplaceItemInObjectCaseSensitive(root,"frameURL",cJSON_CreateString("http://another-server/frame"));
    json=cJSON_PrintUnformatted(root);assert(!ink_manifest_parse(json,strlen(json),&m));free(json);cJSON_Delete(root);
    assert(ink_uuid_valid(PAGE));assert(!ink_uuid_valid("../12345678-1234-4234-9234-123456789abc"));assert(!ink_uuid_valid("12345678_1234-4234-9234-123456789abc"));
    assert(ink_manifest_parse(sample,strlen(sample),&m));ink_manifest_t other=m;
    assert(ink_manifest_same_frame(&m,&other));++other.revision;assert(!ink_manifest_same_frame(&m,&other));
    assert(ink_manifest_same_pixels(&m,&other)); /* force-publish revision reuses pixels */
    assert(memcmp(&m,&other,sizeof(m))!=0); /* new tuple must still update cache metadata */
    strcpy(other.page_id,TASK);assert(ink_manifest_same_pixels(&m,&other));assert(!ink_manifest_same_frame(&m,&other));
    other=m;strcpy(other.focused_task_id,TASK);assert(ink_manifest_same_pixels(&m,&other));
    assert(ink_manifest_same_frame(&m,&other));assert(memcmp(&m,&other,sizeof(m))!=0); /* local focus can dirty overlay */
    other=m;other.tasks[0][0]='0';assert(ink_manifest_same_pixels(&m,&other));assert(memcmp(&m,&other,sizeof(m))!=0);
    other=m;other.hash[0]=other.hash[0]=='0' ? '1' : '0';assert(!ink_manifest_same_pixels(&m,&other));
    other=(ink_manifest_t){0};assert(!ink_manifest_same_pixels(&other,&other));assert(!ink_manifest_same_pixels(NULL,&m));
    ink_action_t event={0};strcpy(event.event_id,PAGE);strcpy(event.page_id,PAGE);strcpy(event.task_id,TASK);strcpy(event.action,"toggle_task");
    char body[320];assert(ink_action_json(&event,body,sizeof(body)));root=cJSON_Parse(body);assert(root);
    assert(!strcmp(cJSON_GetObjectItem(root,"eventID")->valuestring,PAGE));assert(!strcmp(cJSON_GetObjectItem(root,"taskID")->valuestring,TASK));cJSON_Delete(root);
    assert(!ink_action_json(&event,body,16));event.task_id[0]=0;assert(!ink_action_json(&event,body,sizeof(body)));strcpy(event.task_id,TASK);
    ink_queue_t queue={.version=1};assert(ink_queue_valid(&queue));
    for(unsigned i=0;i<INK_QUEUE_CAPACITY;++i) assert(ink_queue_push(&queue,&event));
    assert(!ink_queue_push(&queue,&event));ink_queue_shift(&queue);assert(queue.count==INK_QUEUE_CAPACITY-1);assert(!strcmp(queue.events[0].event_id,PAGE));assert(ink_queue_valid(&queue));
    queue.count=INK_QUEUE_CAPACITY+1;assert(!ink_queue_valid(&queue));
    const char *ack="{\"ok\":true,\"revision\":6}";assert(ink_action_ack(ack,strlen(ack)));ack="{\"ok\":false,\"revision\":6}";assert(!ink_action_ack(ack,strlen(ack)));
    sync_tests();
    char hash[65];ink_sha256_hex((const uint8_t *)"",0,hash);assert(!strcmp(hash,"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
    ink_sha256_hex((const uint8_t *)"abc",3,hash);assert(!strcmp(hash,"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
    puts("Protocol, sync status/ACK/recovery, cache ABI, UUID, action queue and SHA-256 tests passed.");return 0;
}
