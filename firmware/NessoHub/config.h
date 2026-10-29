// Build-time settings for the Nesso Hub firmware.
#pragma once

#include <Arduino.h>

// --- Protocol -------------------------------------------------------------
// Must match Protocol.version in mac/Sources/NessoHub/Protocol.swift.
#define HUB_PROTOCOL_VERSION 1
#define HUB_FIRMWARE_VERSION "0.1.0"

// Kept to 8 characters: the 128-bit service UUID already takes 18 of the 31
// advertising bytes.
#define BLE_NAME "NessoHub"

// The Mac writes newline-terminated JSON to RX and receives newline-terminated
// JSON as notifications on TX. Both sides split and reassemble lines, so no
// message is bound by the MTU.
#define HUB_SERVICE_UUID "8c3b0001-5b1e-4c39-9d5e-6f1a7e2b9c40"
#define HUB_RX_UUID "8c3b0002-5b1e-4c39-9d5e-6f1a7e2b9c40"
#define HUB_TX_UUID "8c3b0003-5b1e-4c39-9d5e-6f1a7e2b9c40"

// Notifications are cut to the minimum ATT payload, so they get through even
// before (or without) an MTU exchange. Events are a few dozen bytes anyway.
#define TX_CHUNK 20
// An icon line is base64 of up to MAX_ICON_PIXELS * 2 bytes plus the JSON
// around it.
#define RX_LINE_MAX 12288

// --- Screen ---------------------------------------------------------------
#define SCREEN_W 135
#define SCREEN_H 240
#define SCREEN_ROTATION 0

#define TOUCH_SWAP_XY 0
#define TOUCH_INVERT_X 0
#define TOUCH_INVERT_Y 0

// --- Page limits ----------------------------------------------------------
#define MAX_ROWS 8
#define MAX_TILES 16
#define MAX_ICONS 24
#define MAX_ICON_PIXELS (56 * 56)

// --- Timing ---------------------------------------------------------------
#define BUTTON_POLL_MS 20
#define BUTTON_DEBOUNCE_MS 30
#define BUTTON_LONG_MS 800
#define TOUCH_POLL_MS 20
#define TOUCH_RELEASE_POLLS 3
#define TAP_SLOP_PX 10
#define BATTERY_POLL_MS 5000
#define TAP_FLASH_MS 180
#define I2C_CLOCK_HZ 400000

// --- Colours (RGB565) -----------------------------------------------------
#define COL_BG 0x0000
#define COL_PANEL 0x18E3
#define COL_PANEL_ALT 0x2124
#define COL_TEAL 0x0410
#define COL_TEXT 0xFFFF
#define COL_MUTED 0x8410
#define COL_GREEN 0x1E85
#define COL_ORANGE 0xED03
#define COL_RED 0xE841
#define COL_ACCENT 0x05FF
