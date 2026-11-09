#include "hw.h"

NessoDisplay display;

namespace hw {

static NessoBattery battery;
static NessoTouch touch;
static bool touchReady = false;
static uint8_t screenRotation = SCREEN_ROTATION & 3;

uint8_t rotation() { return screenRotation; }
int16_t width() { return screenRotation & 1 ? PANEL_H : PANEL_W; }
int16_t height() { return screenRotation & 1 ? PANEL_W : PANEL_H; }

// --- Touch ---------------------------------------------------------------

static bool touchDown = false;
static bool wandered = false;
static uint8_t emptyPolls = 0;
static uint32_t lastTouchPollMs = 0;
static TouchPoint pressStart, lastTouch;
static TouchPoint pendingTap;
static bool hasPendingTap = false;

// The touch controller reports in the rotation-0 frame. Turn the point the
// way LovyanGFX turns the screen (Panel_Device::convertRawXY).
static void mapTouch(int16_t rawX, int16_t rawY, int16_t& x, int16_t& y) {
  int16_t tx = rawX, ty = rawY;
  switch (screenRotation) {
    case 1: tx = rawY; ty = (PANEL_W - 1) - rawX; break;
    case 2: tx = (PANEL_W - 1) - rawX; ty = (PANEL_H - 1) - rawY; break;
    case 3: tx = (PANEL_H - 1) - rawY; ty = rawX; break;
  }
  x = constrain(tx, (int16_t)0, (int16_t)(width() - 1));
  y = constrain(ty, (int16_t)0, (int16_t)(height() - 1));
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

// --- Rotation ------------------------------------------------------------

static bool autoRotateOn = AUTO_ROTATE;
static bool imuReady = false;
static uint32_t lastImuPollMs = 0;
// The rotation the accelerometer has been calling for, and since when.
static int8_t candidate = -1;
static uint32_t candidateSinceMs = 0;

void rotate(uint8_t r) {
  screenRotation = r & 3;
  display.setRotation(screenRotation);
  // A press that began in the old frame would land somewhere else.
  touchDown = false;
  hasPendingTap = false;
}

void setAutoRotate(bool on) {
  autoRotateOn = on;
  candidate = -1;
}

bool autoRotate() { return autoRotateOn; }

// At rest the accelerometer feels gravity as a pull upwards. `right` and
// `down` are that pull along the screen's rotation-0 axes. Measured on the
// device: the BMI270's x axis points away from the USB-C end, its y axis to
// the left of the screen, and its z axis out of the screen.
static void upInScreen(float ax, float ay, float& right, float& down) {
  right = -ay;
  down = -ax;
}

// The rotation that puts the top of the screen where `up` points, or -1 when
// the Nesso lies flat or stands on a corner.
static int8_t rotationFor(float right, float down) {
  float side = fabsf(right), upright = fabsf(down);
  if (max(side, upright) < ROTATE_MIN_G || fabsf(side - upright) < ROTATE_MARGIN_G) return -1;
  if (upright > side) return down < 0 ? 0 : 2;
  return right > 0 ? 1 : 3;
}

bool readImu(float& x, float& y, float& z, int8_t& wants) {
  if (!imuReady || !IMU.readAcceleration(x, y, z)) return false;
  float right, down;
  upInScreen(x, y, right, down);
  wants = rotationFor(right, down);
  return true;
}

bool pollRotation() {
  if (!imuReady || !autoRotateOn) return false;
  uint32_t now = millis();
  if (now - lastImuPollMs < IMU_POLL_MS) return false;
  lastImuPollMs = now;

  float x, y, z;
  int8_t wants = -1;
  if (!readImu(x, y, z, wants) || wants < 0 || wants == screenRotation) {
    candidate = -1;
    return false;
  }
  // Only a side that stays up turns the screen, not a Nesso on its way past.
  if (wants != candidate) {
    candidate = wants;
    candidateSinceMs = now;
    return false;
  }
  if (now - candidateSinceMs < ROTATE_SETTLE_MS) return false;
  candidate = -1;
  Serial.printf("[imu] %.2f %.2f %.2f, turning to %d\n", x, y, z, wants);
  rotate(wants);
  return true;
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
  display.setRotation(screenRotation);
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

  // After the clock change: the BMI270 takes an 8 KB config file at start.
  imuReady = IMU.begin();
  Serial.printf("[imu] %s\n", imuReady ? "ready" : "not found");
  // Start the right way up, so the splash is not drawn sideways first. The
  // first sample lands one 25 Hz period after the sensor starts.
  delay(60);
  float x, y, z;
  int8_t wants = -1;
  if (autoRotateOn && readImu(x, y, z, wants) && wants >= 0) rotate(wants);
}

}  // namespace hw
