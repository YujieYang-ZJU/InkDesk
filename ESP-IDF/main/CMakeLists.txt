idf_component_register(SRCS "main.c" "protocol.c" "sha256.c" "epd.c" "storage.c" "vendor/cJSON.c"
                       INCLUDE_DIRS "." "vendor"
                       REQUIRES esp_wifi esp_event esp_netif esp_http_client nvs_flash spiffs esp_timer esp_driver_gpio esp_driver_spi)
