#include "pixels.h"

#include <Wire.h>

#include "config.h"

namespace pixels {

enum Effect : uint8_t { FX_STEADY, FX_PULSE, FX_BLINK };

struct Led {
  uint8_t r = 0, g = 0, b = 0;
  Effect fx = FX_STEADY;
};

static Led leds[PIXELS_COUNT];
static uint8_t brightness = PIXELS_DEFAULT_BRIGHTNESS;
static bool reversed = PIXELS_REVERSE;
static bool found = false;
static uint32_t lastProbeMs = 0;
static uint32_t lastFrameMs = 0;
// What the module shows, so an unchanged frame is not sent again.
static uint8_t shown[PIXELS_COUNT * 4];
static bool shownValid = false;

// The module shares the bus with the touch controller, the expander and the
// gauge, all of which answer at their own addresses.
static bool probe() {
  Wire.beginTransmission(PIXELS_ADDR);
  return Wire.endTransmission() == 0;
}

static float level(Effect fx, uint32_t now) {
  switch (fx) {
    case FX_PULSE: {
      // A slow breath that never quite goes out, so a working session still
      // reads as lit at a glance.
      float phase = (float)(now % PIXELS_PULSE_MS) / PIXELS_PULSE_MS;
      return 0.15f + 0.85f * (0.5f - 0.5f * cosf(phase * 2 * PI));
    }
    case FX_BLINK:
      return now % PIXELS_BLINK_MS < PIXELS_BLINK_MS * 6 / 10 ? 1.0f : 0.0f;
    default:
      return 1.0f;
  }
}

// Each LED is four bytes: the 5-bit brightness under three marker bits, then
// blue, green and red, as the Modulino firmware expects.
static void show(uint32_t now) {
  uint8_t frame[PIXELS_COUNT * 4];
  for (uint8_t i = 0; i < PIXELS_COUNT; i++) {
    float k = level(leds[i].fx, now);
    uint8_t* out = frame + (reversed ? PIXELS_COUNT - 1 - i : i) * 4;
    out[0] = 0xE0 | (brightness & 0x1F);
    out[1] = (uint8_t)(leds[i].b * k);
    out[2] = (uint8_t)(leds[i].g * k);
    out[3] = (uint8_t)(leds[i].r * k);
  }
  if (shownValid && !memcmp(frame, shown, sizeof(frame))) return;

  Wire.beginTransmission(PIXELS_ADDR);
  Wire.write(frame, sizeof(frame));
  if (Wire.endTransmission() != 0) {
    Serial.println("[pixels] module gone");
    found = false;
    shownValid = false;
    return;
  }
  memcpy(shown, frame, sizeof(frame));
  shownValid = true;
}

void begin() {
  found = probe();
  lastProbeMs = millis();
  Serial.printf("[pixels] %s\n", found ? "Modulino Pixels found" : "no Modulino Pixels");
  if (found) show(millis());
}

void apply(JsonObjectConst msg) {
  brightness = constrain(msg["b"] | (int)PIXELS_DEFAULT_BRIGHTNESS, 0, 31);
  JsonArrayConst list = msg["leds"].as<JsonArrayConst>();
  for (uint8_t i = 0; i < PIXELS_COUNT; i++) {
    Led& led = leds[i];
    led = Led();
    if (i >= list.size()) continue;
    JsonObjectConst entry = list[i];
    const char* hex = entry["c"] | "";
    if (hex[0] == '#' && strlen(hex) == 7) {
      uint32_t rgb = strtoul(hex + 1, nullptr, 16);
      led.r = (rgb >> 16) & 0xFF;
      led.g = (rgb >> 8) & 0xFF;
      led.b = rgb & 0xFF;
    }
    const char* fx = entry["fx"] | "";
    if (!strcmp(fx, "pulse")) led.fx = FX_PULSE;
    if (!strcmp(fx, "blink")) led.fx = FX_BLINK;
  }
  if (found) show(millis());
}

void clear() {
  for (Led& led : leds) led = Led();
  if (found) show(millis());
}

void setRotation(uint8_t rotation) {
  // With the USB-C end on the right, the end of the bar that is on the left
  // at rotation 0 goes to the bottom; upside down, it goes to the right.
  // Either way the first LED has to move to the other end.
  bool turned = rotation == 1 || rotation == 2;
  reversed = PIXELS_REVERSE ? !turned : turned;
  if (found) show(millis());
}

void tick() {
  uint32_t now = millis();
  if (!found) {
    if (now - lastProbeMs < PIXELS_PROBE_MS) return;
    lastProbeMs = now;
    if (!probe()) return;
    Serial.println("[pixels] Modulino Pixels plugged in");
    found = true;
    shownValid = false;
  }
  if (now - lastFrameMs < PIXELS_FRAME_MS) return;
  lastFrameMs = now;
  show(now);
}

bool present() { return found; }

}  // namespace pixels
