// Nesso N1 hardware: screen, touch, the two keys and the battery gauge.
#pragma once

#include <Arduino.h>
#include <Arduino_Nesso_N1.h>

#include "config.h"

// The display is shared with ui.cpp, which does all the drawing.
extern NessoDisplay display;

namespace hw {

void begin();

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
typedef void (*KeyHandler)(uint8_t index, const char* action);
void onKey(KeyHandler handler);
void pollKeys();

void pollBattery();
int batteryLevel();
bool charging();

}  // namespace hw
