cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(inkdesk_e1001)
# Initial provisioning image. Use app-flash for later updates to retain cache.
spiffs_create_partition_image(cache "${CMAKE_CURRENT_SOURCE_DIR}/cache_seed" FLASH_IN_PROJECT)
