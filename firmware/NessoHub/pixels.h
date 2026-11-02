// A Modulino Pixels on the Qwiic connector: eight RGB LEDs behind a small I2C
// controller. The Mac says what each LED shows; this file animates them.
#pragma once

#include <Arduino.h>
#include <ArduinoJson.h>

namespace pixels {

void begin();

// {"b": 4, "leds": [{"c": "#FF6000", "fx": "blink"}, ...]}: one entry per LED
// from the left, and the LEDs past the end of `leds` go dark. `fx` is "pulse",
// "blink" or absent for a steady light; `b` is the brightness, 0 to 31.
void apply(JsonObjectConst msg);
// Turns every LED off, as when the Mac goes away.
void clear();

// Animates the LEDs, and looks for a module plugged in after boot.
void tick();
bool present();

}  // namespace pixels
