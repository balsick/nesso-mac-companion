// Build-time settings for the Nesso Hub firmware.
#pragma once

#include <Arduino.h>

// --- Protocol -------------------------------------------------------------
// Must match Protocol.version in mac/Sources/NessoHub/Protocol.swift.
#define HUB_PROTOCOL_VERSION 3
#define HUB_FIRMWARE_VERSION "0.4.0"

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
// The panel the right way up. On its side the screen is PANEL_H x PANEL_W,
// and the Mac lays its pages out for that.
#define PANEL_W 135
#define PANEL_H 240

// LovyanGFX's rotations: 0 with the USB-C end down, 1 with it on the right,
// 2 upside down, 3 with it on the left. The driver moves the panel's window
// inside the controller's 240 x 320 memory for each, so nothing shifts.
// KEY1 and KEY2 keep their roles whichever way the Nesso is turned.
//
// With AUTO_ROTATE the accelerometer picks the rotation, and the screen
// turns to whichever side is up; SCREEN_ROTATION is where it starts when the
// Nesso lies flat. With AUTO_ROTATE 0 the screen stays at SCREEN_ROTATION.
// arduino-cli can also set them: --build-property
// "compiler.cpp.extra_flags=-DAUTO_ROTATE=0 -DSCREEN_ROTATION=2"
#ifndef SCREEN_ROTATION
#define SCREEN_ROTATION 0
#endif
#ifndef AUTO_ROTATE
#define AUTO_ROTATE 1
#endif

// A side is up once it takes this much of gravity, in g, and beats the
// other side by ROTATE_MARGIN_G, for ROTATE_SETTLE_MS. Flat on a desk or
// standing on a corner, the screen stays as it is.
#define ROTATE_MIN_G 0.5f
#define ROTATE_MARGIN_G 0.3f

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
#define IMU_POLL_MS 100
#define ROTATE_SETTLE_MS 600
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
// The module's first LED is the one next to its green power LED. 1 is for a
// Modulino below the Nesso with that LED on the right at rotation 0: the
// order is reversed, so the first LED of a "pixels" message is on the left.
// The module turns with the Nesso and the order follows the rotation; on its
// side, where the bar stands upright, the first LED is the top one. Set it
// to 0 for a Modulino screwed on the other way round.
#ifndef PIXELS_REVERSE
#define PIXELS_REVERSE 1
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
