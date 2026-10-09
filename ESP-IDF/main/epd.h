#pragma once
#include "esp_err.h"
#include "protocol.h"
esp_err_t ink_epd_init(void);
/* Full BW refresh using panel OTP waveform. Frame remains owned by caller. */
esp_err_t ink_epd_show(const uint8_t frame[INK_FRAME_BYTES], unsigned pending, bool task_mode, unsigned task_index);
