#include "hw.h"

NessoDisplay display;

namespace hw {

static NessoBattery battery;
static NessoTouch touch;
static bool touchReady = false;

// --- Touch ---------------------------------------------------------------

static bool touchDown = false;
static bool wandered = false;
static uint8_t emptyPolls = 0;
static uint32_t lastTouchPollMs = 0;
static TouchPoint pressStart, lastTouch;
static TouchPoint pendingTap;
static bool hasPendingTap = false;

static void mapTouch(int16_t rawX, int16_t rawY, int16_t& x, int16_t& y) {
#if TOUCH_SWAP_XY
  int16_t tx = rawY, ty = rawX;
#else
  int16_t tx = rawX, ty = rawY;
#endif
#if TOUCH_INVERT_X
  tx = (SCREEN_W - 1) - tx;
#endif
#if TOUCH_INVERT_Y
  ty = (SCREEN_H - 1) - ty;
#endif
  x = constrain(tx, (int16_t)0, (int16_t)(SCREEN_W - 1));
  y = constrain(ty, (int16_t)0, (int16_t)(SCREEN_H - 1));
}

void pollTouch() {
  if (!touchReady) return;
  // The touch controller shares the I2C bus with the keys and the gauge.
  uint32_t now = millis();
  if (now - lastTouchPollMs < TOUCH_POLL_MS) return;
  lastTouchPollMs = now;

  int16_t rawX = 0, rawY = 0;
  if (touch.read(rawX, rawY)) {
    emptyPolls = 0;
    mapTouch(rawX, rawY, lastTouch.x, lastTouch.y);
    if (!touchDown) {
      touchDown = true;
      wandered = false;
      pressStart = lastTouch;
    } else if (abs(lastTouch.x - pressStart.x) > TAP_SLOP_PX ||
               abs(lastTouch.y - pressStart.y) > TAP_SLOP_PX) {
      wandered = true;
    }
    return;
  }

  if (!touchDown) return;
  // The FT6336 drops the odd sample; do not end the press on one.
  if (++emptyPolls < TOUCH_RELEASE_POLLS) return;

  emptyPolls = 0;
  touchDown = false;
  if (!wandered) {
    // Report where the finger went down: on a 135px panel the release point
    // drifts more than the press point does.
    pendingTap = pressStart;
    hasPendingTap = true;
  }
}

bool takeTap(TouchPoint& out) {
  if (!hasPendingTap) return false;
  out = pendingTap;
  hasPendingTap = false;
  return true;
}

void injectTap(int16_t x, int16_t y) {
  pendingTap.x = x;
  pendingTap.y = y;
  hasPendingTap = true;
}

// --- Keys ----------------------------------------------------------------

struct KeyState {
  bool down = false;
  bool rawDown = false;
  uint32_t changedAtMs = 0;
  uint32_t pressedAtMs = 0;
  bool longSent = false;
  bool hold = false;
  uint32_t injectedUntilMs = 0;
};

static KeyState keys[2];
static KeyHandler keyHandler = nullptr;
static uint32_t lastKeyPollMs = 0;

void onKey(KeyHandler handler) { keyHandler = handler; }

static bool readKey(uint8_t i) {
  if ((int32_t)(millis() - keys[i].injectedUntilMs) < 0) return true;
  // The keys sit on the I2C expander, active-low with a pull-up.
  return digitalRead(i == 0 ? KEY1 : KEY2) == LOW;
}

void pollKeys() {
  uint32_t now = millis();
  if (now - lastKeyPollMs < BUTTON_POLL_MS) return;
  lastKeyPollMs = now;

  for (uint8_t i = 0; i < 2; i++) {
    KeyState& k = keys[i];
    bool raw = readKey(i);
    if (raw != k.rawDown) {
      k.rawDown = raw;
      k.changedAtMs = now;
    }
    if (raw != k.down && (now - k.changedAtMs) >= BUTTON_DEBOUNCE_MS) {
      k.down = raw;
      if (k.down) {
        k.pressedAtMs = now;
        k.longSent = false;
      } else if (!k.longSent && keyHandler) {
        bool loaderShown = k.hold && (now - k.pressedAtMs) >= HOLD_SHOW_MS;
        keyHandler(i + 1, loaderShown ? "cancel" : "click");
      }
    }
    uint32_t longMs = k.hold ? HOLD_MS : BUTTON_LONG_MS;
    // Not while a release is being debounced: a key let go just before the
    // mark, or a loop held up past it, must not count as held.
    if (k.down && k.rawDown && !k.longSent && (now - k.pressedAtMs) >= longMs) {
      k.longSent = true;
      if (keyHandler) keyHandler(i + 1, "long");
    }
  }
}

void setHold(uint8_t index, bool hold) {
  if (index >= 1 && index <= 2) keys[index - 1].hold = hold;
}

uint32_t heldMs(uint8_t index) {
  if (index < 1 || index > 2) return 0;
  const KeyState& k = keys[index - 1];
  return k.down && !k.longSent ? millis() - k.pressedAtMs : 0;
}

void injectPress(uint8_t index, uint32_t ms) {
  if (index >= 1 && index <= 2) keys[index - 1].injectedUntilMs = millis() + ms;
}

// --- Battery -------------------------------------------------------------

static int battLevel = 0;
static bool battCharging = false;
static uint32_t lastBatteryMs = 0;

static void readBattery() {
  battLevel = battery.getChargeLevel();
  NessoBattery::ChargeStatus status = battery.getChargeStatus();
  battCharging = status == NessoBattery::PRE_CHARGE || status == NessoBattery::CHARGING;
}

void pollBattery() {
  uint32_t now = millis();
  if (now - lastBatteryMs < BATTERY_POLL_MS) return;
  lastBatteryMs = now;
  readBattery();
}

int batteryLevel() { return battLevel; }
bool charging() { return battCharging; }

// --- Bring-up ------------------------------------------------------------

void begin() {
  display.begin();
  display.setRotation(SCREEN_ROTATION);
  display.setEpdMode(epd_mode_t::epd_fastest);
  display.fillScreen(COL_BG);

  pinMode(KEY1, INPUT_PULLUP);
  pinMode(KEY2, INPUT_PULLUP);

  battery.begin();
  battery.enableCharge();
  readBattery();

  touchReady = touch.begin();
  Serial.printf("[touch] %s\n", touchReady ? "ready" : "not found");

  // Everything above brought Wire up at 100 kHz; every device on the bus
  // supports Fast Mode, and the keys and touch are polled continuously.
  Wire.setClock(I2C_CLOCK_HZ);
}

}  // namespace hw
