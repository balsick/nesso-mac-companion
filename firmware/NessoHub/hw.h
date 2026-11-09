// Nesso N1 hardware: screen, touch, the two keys and the battery gauge.
#pragma once

#include <Arduino.h>
#include <Arduino_Nesso_N1.h>

#include "config.h"

// The display is shared with ui.cpp, which does all the drawing.
extern NessoDisplay display;

namespace hw {

void begin();

// The screen as it is turned now: PANEL_W x PANEL_H the right way up or
// upside down, the other way round on its side. Rotations as in config.h.
uint8_t rotation();
int16_t width();
int16_t height();
void rotate(uint8_t rotation);

// Turns the screen to whichever side is up, from the accelerometer. Returns
// true when it turned. Does nothing while auto-rotation is off.
bool pollRotation();
void setAutoRotate(bool on);
bool autoRotate();
// The accelerometer, for the console: the raw reading in g, and the rotation
// it calls for, or -1 when no side is clearly up.
bool readImu(float& x, float& y, float& z, int8_t& wants);

struct TouchPoint {
  int16_t x = 0;
  int16_t y = 0;
};

void pollTouch();
// Returns true once per tap, on release. A press that wanders further than
// TAP_SLOP_PX is not a tap.
bool takeTap(TouchPoint& out);
// Test aid for the serial console.
void injectTap(int16_t x, int16_t y);

// Actions: "click" on a short press, "long" once a press passes BUTTON_LONG_MS.
// index is 1 for KEY1 and 2 for KEY2, as printed on the case.
//
// A key with a hold fires "long" at HOLD_MS instead, and a release after
// HOLD_SHOW_MS, once its loader is showing, is a "cancel" rather than a click.
typedef void (*KeyHandler)(uint8_t index, const char* action);
void onKey(KeyHandler handler);
void pollKeys();
void setHold(uint8_t index, bool hold);
// How long the key has been down; 0 once it is up or its "long" has fired.
uint32_t heldMs(uint8_t index);
// Test aid for the serial console: the key reads as pressed for `ms`.
void injectPress(uint8_t index, uint32_t ms);

void pollBattery();
int batteryLevel();
bool charging();

}  // namespace hw
