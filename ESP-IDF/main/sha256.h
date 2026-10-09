#pragma once
#include <stddef.h>
#include <stdint.h>
/* Portable SHA-256, used for integrity, not authentication. */
void ink_sha256(const uint8_t *data, size_t size, uint8_t result[32]);
void ink_sha256_hex(const uint8_t *data, size_t size, char result[65]);
