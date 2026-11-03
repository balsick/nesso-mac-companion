// Build-time settings for the Nesso Hub firmware.
#pragma once

#include <Arduino.h>

// --- Protocol -------------------------------------------------------------
// Must match Protocol.version in mac/Sources/NessoHub/Protocol.swift.
#define HUB_PROTOCOL_VERSION 2
#define HUB_FIRMWARE_VERSION "0.3.0"

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

// Set to 1 for a Nesso used upside down: turned 180° in the plane of the
// screen, with the USB-C end on top, as in a back shell that holds the
// Modulino Pixels above the Nesso with the cable going up. The screen turns,
// taps follow it, and KEY1 and KEY2 keep their roles.
// arduino-cli can also set it: --build-property
// compiler.cpp.extra_flags=-DMOUNT_UPSIDE_DOWN=1
#ifndef MOUNT_UPSIDE_DOWN
#define MOUNT_UPSIDE_DOWN 0
#endif

// 2 is a half turn. The panel stays 135 x 240, and the driver mirrors its
// window inside the controller's 240 x 320 memory, so nothing shifts.
#define SCREEN_ROTATION (MOUNT_UPSIDE_DOWN ? 2 : 0)

// The touch controller reports in the screen's rotation-0 frame; a half turn
// mirrors both axes.
#define TOUCH_SWAP_XY 0
#define TOUCH_INVERT_X MOUNT_UPSIDE_DOWN
#define TOUCH_INVERT_Y MOUNT_UPSIDE_DOWN

// --- Page limits ----------------------------------------------------------
#define MAX_ROWS 8
#define MAX_TILES 16
#define MAX_ICONS 24
#define MAX_ICON_PIXELS (56 * 56)

// --- Timing ---------------------------------------------------------------
#define BUTTON_POLL_MS 20
#define BUTTON_DEBOUNCE_MS 30
#define BUTTON_LONG_MS 800
// A key the page gives a hold: its loader shows once the key has been down
// HOLD_SHOW_MS, so a click never flashes it, and the hold fires at HOLD_MS.
// After that the "done" screen stays until the next page, or HOLD_DONE_MS.
#define HOLD_SHOW_MS 200
#define HOLD_MS 1200
#define HOLD_FRAME_MS 33
// Let go early and the ring runs back to empty: this long from full.
#define HOLD_UNWIND_MS 400
#define HOLD_DONE_MS 4000
#define TOUCH_POLL_MS 20
#define TOUCH_RELEASE_POLLS 3
#define TAP_SLOP_PX 10
#define BATTERY_POLL_MS 5000
#define TAP_FLASH_MS 180
#define I2C_CLOCK_HZ 400000

// --- Modulino Pixels ------------------------------------------------------
// On the Qwiic connector, so on the same bus as the touch and the expander.
// The Modulino library's 0x6C is the 8-bit form of this address.
#define PIXELS_ADDR 0x36
#define PIXELS_COUNT 8
// Out of 31. The LEDs sit next to the screen and are bright even at this.
#define PIXELS_DEFAULT_BRIGHTNESS 4
#define PIXELS_FRAME_MS 30
#define PIXELS_PULSE_MS 2400
#define PIXELS_BLINK_MS 1000
// How often to look for a module that was not there.
#define PIXELS_PROBE_MS 3000
// Sends the LEDs in reverse, so the first one in a "pixels" message is still
// the leftmost for a module that sits the other way round. Turning the Nesso
// upside down turns the Modulino with it, hence the default. Set it to 0 if
// the Modulino is also screwed on rotated 180°, which undoes the turn.
#ifndef PIXELS_REVERSE
#define PIXELS_REVERSE MOUNT_UPSIDE_DOWN
#endif

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
