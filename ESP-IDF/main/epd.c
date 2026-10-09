/* E1001 pinout/UC8179 commands adapted from Seeed-Studio/Seeed_GFX,
 * commit 0dfdd7135425be82b5bb4b4b58d74dd51ab29a59.
 * See NOTICE-Seeed-GFX.txt. No Arduino dependency or custom LUT.
 */
#include "epd.h"
#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdkconfig.h"
#include <stdio.h>
#include <string.h>
static spi_device_handle_t panel;
static const char *TAG="ink_epd";
static void delay_ms(unsigned ms) { vTaskDelay(pdMS_TO_TICKS(ms) ? pdMS_TO_TICKS(ms) : 1); }
static esp_err_t ready(void) {
    int64_t deadline=esp_timer_get_time()+(int64_t)CONFIG_INK_EPD_BUSY_TIMEOUT_MS*1000;
    delay_ms(10);
    while(gpio_get_level(CONFIG_INK_EPD_BUSY)==CONFIG_INK_EPD_BUSY_LEVEL) {
        if(esp_timer_get_time()>=deadline) { ESP_LOGE(TAG,"Panel BUSY timeout; check panel/pins/power"); return ESP_ERR_TIMEOUT; }
        delay_ms(10);
    }
    return ESP_OK;
}
static esp_err_t send(bool data,const uint8_t *bytes,size_t size) {
    if(!size) return ESP_OK;
    gpio_set_level(CONFIG_INK_EPD_DC,data ? 1 : 0);
    spi_transaction_t t={.length=size*8,.tx_buffer=bytes};
    return spi_device_transmit(panel,&t);
}
static esp_err_t command(uint8_t cmd,const uint8_t *data,size_t size) {
    esp_err_t e=send(false,&cmd,1);return e==ESP_OK ? send(true,data,size) : e;
}
#define DO(expr) do { esp_err_t error=(expr); if(error!=ESP_OK) return error; } while(0)
esp_err_t ink_epd_init(void) {
    const int outputs[]={CONFIG_INK_EPD_SCLK,CONFIG_INK_EPD_MOSI,CONFIG_INK_EPD_CS,CONFIG_INK_EPD_DC,CONFIG_INK_EPD_RST};
    for(size_t i=0;i<sizeof(outputs)/sizeof(outputs[0]);++i) {
        if(!GPIO_IS_VALID_OUTPUT_GPIO(outputs[i])) return ESP_ERR_INVALID_ARG;
        for(size_t j=0;j<i;++j) if(outputs[i]==outputs[j]) return ESP_ERR_INVALID_ARG;
        if(outputs[i]==CONFIG_INK_EPD_BUSY) return ESP_ERR_INVALID_ARG;
    }
    if(!GPIO_IS_VALID_GPIO(CONFIG_INK_EPD_BUSY)) return ESP_ERR_INVALID_ARG;
    gpio_config_t out={.pin_bit_mask=(1ULL<<CONFIG_INK_EPD_CS)|(1ULL<<CONFIG_INK_EPD_DC)|(1ULL<<CONFIG_INK_EPD_RST),.mode=GPIO_MODE_OUTPUT};
    DO(gpio_config(&out));gpio_set_level(CONFIG_INK_EPD_CS,1);gpio_set_level(CONFIG_INK_EPD_RST,1);
    gpio_config_t in={.pin_bit_mask=1ULL<<CONFIG_INK_EPD_BUSY,.mode=GPIO_MODE_INPUT};DO(gpio_config(&in));
    spi_bus_config_t bus={.mosi_io_num=CONFIG_INK_EPD_MOSI,.miso_io_num=-1,.sclk_io_num=CONFIG_INK_EPD_SCLK,.quadwp_io_num=-1,.quadhd_io_num=-1,.max_transfer_sz=2048};
    DO(spi_bus_initialize(SPI2_HOST,&bus,SPI_DMA_CH_AUTO));
    spi_device_interface_config_t dev={.clock_speed_hz=CONFIG_INK_EPD_SPI_HZ,.mode=0,.spics_io_num=CONFIG_INK_EPD_CS,.queue_size=1};
    return spi_bus_add_device(SPI2_HOST,&dev,&panel);
}
static esp_err_t full_init(void) {
    gpio_set_level(CONFIG_INK_EPD_RST,1);delay_ms(5);
    gpio_set_level(CONFIG_INK_EPD_RST,0);delay_ms(20);
    gpio_set_level(CONFIG_INK_EPD_RST,1);delay_ms(150);
    const uint8_t power[]={0x07,0x07,0x3f,0x3f},booster[]={0x17,0x17,0x28,0x17};
    const uint8_t settings[]={0x1f},resolution[]={0x03,0x20,0x01,0xe0};
    const uint8_t zero[]={0},interval[]={0x10,0x07},tcon[]={0x22};
    DO(command(0x01,power,sizeof(power)));DO(command(0x06,booster,sizeof(booster)));
    DO(command(0x04,NULL,0));delay_ms(100);DO(ready());
    DO(command(0x00,settings,sizeof(settings)));DO(command(0x61,resolution,sizeof(resolution)));
    DO(command(0x15,zero,sizeof(zero)));DO(command(0x50,interval,sizeof(interval)));DO(command(0x60,tcon,sizeof(tcon)));
    return ESP_OK;
}
/* Tiny built-in glyphs for pending status only; content is rendered on Mac. */
static const uint8_t digits[10][5]={{0x3e,0x51,0x49,0x45,0x3e},{0,0x42,0x7f,0x40,0},{0x62,0x51,0x49,0x49,0x46},{0x22,0x41,0x49,0x49,0x36},{0x18,0x14,0x12,0x7f,0x10},{0x27,0x45,0x45,0x45,0x39},{0x3c,0x4a,0x49,0x49,0x30},{1,0x71,9,5,3},{0x36,0x49,0x49,0x49,0x36},{6,0x49,0x49,0x29,0x1e}};
static uint8_t glyph(char ch,int col) {
    if(ch>='0'&&ch<='9') return digits[ch-'0'][col];
    static const uint8_t S[]={0x26,0x49,0x49,0x49,0x32},Y[]={3,4,0x78,4,3},N[]={0x7f,2,4,8,0x7f},C[]={0x3e,0x41,0x41,0x41,0x22};
    static const uint8_t T[]={1,1,0x7f,1,1},A[]={0x7e,9,9,9,0x7e},K[]={0x7f,8,0x14,0x22,0x41};
    switch(ch) {case 'S':return S[col];case 'Y':return Y[col];case 'N':return N[col];case 'C':return C[col];case 'T':return T[col];case 'A':return A[col];case 'K':return K[col];default:return 0;}
}
static uint8_t overlay_byte(uint8_t original,size_t offset,const char *badge) {
    const int x=(int)(offset%100)*8,y=(int)(offset/100);
    if(y<464 || x<704) return original;
    uint8_t value=0xff;
    for(int bit=0;bit<8;++bit) {
        int px=x+bit;bool black=(y==464||y==479||px==704||px==799);
        int tx=px-709,ty=y-468;
        if(tx>=0&&ty>=0&&ty<7) {
            size_t ci=(size_t)(tx/6);int col=tx%6;
            if(ci<strlen(badge)&&col<5) black|=(glyph(badge[ci],col)&(1U<<ty))!=0;
        }
        if(black) value&=(uint8_t)~(0x80U>>bit);
    }
    return value;
}
esp_err_t ink_epd_show(const uint8_t frame[INK_FRAME_BYTES],unsigned pending,bool task_mode,unsigned task_index) {
    if(!panel || !frame) return ESP_ERR_INVALID_STATE;
    DO(full_init());
    char badge[16]={0};
    if(pending) snprintf(badge,sizeof(badge),"SYNC %u",pending);
    else if(task_mode) snprintf(badge,sizeof(badge),"TASK %u",task_index+1);
    uint8_t chunk[1024] __attribute__((aligned(4)));
    /* Both BW planes receive identical pixel data, as Seeed EPaper::update. */
    for(int plane=0;plane<2;++plane) {
        DO(command(plane ? 0x13 : 0x10,NULL,0));
        for(size_t offset=0;offset<INK_FRAME_BYTES;) {
            size_t size=INK_FRAME_BYTES-offset;if(size>sizeof(chunk)) size=sizeof(chunk);
            memcpy(chunk,frame+offset,size);
            if(badge[0]) for(size_t i=0;i<size;++i) chunk[i]=overlay_byte(chunk[i],offset+i,badge);
            /* This E1001 full-BW panel path uses black=1; wire/cache use white=1.
             * Convert only outgoing pixels, including the local status badge. */
            for(size_t i=0;i<size;++i) chunk[i]=(uint8_t)~chunk[i];
            DO(send(true,chunk,size));offset+=size;
        }
    }
    DO(command(0x12,NULL,0));delay_ms(10);DO(ready());
    const uint8_t interval[]={0xf7},sleep[]={0xa5};
    DO(command(0x50,interval,sizeof(interval)));DO(command(0x02,NULL,0));DO(ready());
    return command(0x07,sleep,sizeof(sleep));
}
