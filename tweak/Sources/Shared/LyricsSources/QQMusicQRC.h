#pragma once
#include <stddef.h>
#include <stdint.h>

// QQ Music's nonstandard 3DES block operation. Input length must be a multiple of eight.
void SGQQQRCDecrypt(const uint8_t *input, size_t length, uint8_t *output);
