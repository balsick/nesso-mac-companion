// Nesso Hub: a BLE companion screen for the Mac.
//
// The Nesso knows nothing about Meet or any other app. The Mac sends it a page
// (rows of tiles with labels, colours and icons) and it reports back which tile
// was tapped and which key was pressed. Everything context-specific lives in
// the Mac daemon, so adding a use case never means reflashing.

#include <ArduinoJson.h>

#include "config.h"
#include "hw.h"
#include "ble_link.h"
#include "pixels.h"
#include "ui.h"

// --- Messages from the Mac -------------------------------------------------

static void sendHello() {
  JsonDocument doc;
  doc["t"] = "hello";
  doc["fw"] = HUB_FIRMWARE_VERSION;
  doc["proto"] = HUB_PROTOCOL_VERSION;
  doc["w"] = hw::width();
  doc["h"] = hw::height();
  doc["px"] = pixels::present() ? PIXELS_COUNT : 0;
  String out;
  serializeJson(doc, out);
  ble::send(out);
}

// Shared by the BLE link and the serial console, so pages can be tried out
// over the cable without the Mac daemon.
static void handleLine(const String& line) {
  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, line);
  if (err) {
    Serial.printf("[rx] bad json (%s, %u bytes): %.60s\n", err.c_str(), line.length(), line.c_str());
    return;
  }
  const char* type = doc["t"] | "";

  if (!strcmp(type, "hello")) {
    sendHello();
  } else if (!strcmp(type, "page")) {
    JsonDocument need;
    need["t"] = "need";
    JsonArray ids = need["ids"].to<JsonArray>();
    ui::applyPage(doc.as<JsonObjectConst>(), ids);
    if (ids.size()) {
      String out;
      serializeJson(need, out);
      ble::send(out);
    }
  } else if (!strcmp(type, "icon")) {
    ui::addIcon(doc.as<JsonObjectConst>());
  } else if (!strcmp(type, "pixels")) {
    pixels::apply(doc.as<JsonObjectConst>());
  } else {
    Serial.printf("[rx] unknown message '%s'\n", type);
  }
}

static void handleConnection(bool connected) {
  // Nothing to show until the Mac sends a page; it does so right after it
  // subscribes and says hello. The LEDs show the Mac's state, so they go
  // dark with it rather than keep showing something stale.
  if (!connected) {
    ui::showWaiting();
    pixels::clear();
  }
}

// --- Events to the Mac -----------------------------------------------------

static void sendEvent(const char* type, const char* key, const String& value, const char* action = nullptr) {
  JsonDocument doc;
  doc["t"] = type;
  doc[key] = value;
  if (action) doc["a"] = action;
  String out;
  serializeJson(doc, out);
  Serial.printf("[tx] %s\n", out.c_str());
  ble::send(out);
}

static void onKey(uint8_t index, const char* action) {
  ui::keyAction(index, action);
  // A cancelled hold never happened, as far as the Mac is concerned.
  if (strcmp(action, "cancel")) sendEvent("key", "k", String(index), action);
}

static void pollTaps() {
  hw::TouchPoint p;
  if (!hw::takeTap(p)) return;
  String id = ui::tapTile(p.x, p.y);
  if (id.length()) sendEvent("tap", "id", id);
}

// The screen turned: redraw, and ask the Mac for a page that fits.
static void onRotated() {
  ui::rotated();
  pixels::setRotation(hw::rotation());
  JsonDocument doc;
  doc["t"] = "screen";
  doc["w"] = hw::width();
  doc["h"] = hw::height();
  String out;
  serializeJson(doc, out);
  Serial.printf("[tx] %s\n", out.c_str());
  ble::send(out);
}

// --- Serial console --------------------------------------------------------

static void runCommand(String line) {
  line.trim();
  if (line.startsWith("{")) {
    handleLine(line);
    return;
  }
  int space = line.indexOf(' ');
  String verb = space < 0 ? line : line.substring(0, space);
  String rest = space < 0 ? "" : line.substring(space + 1);

  if (verb == "screen") {
    ui::dumpScreen();
  } else if (verb == "tap") {
    int split = rest.indexOf(' ');
    hw::injectTap(rest.substring(0, split).toInt(), rest.substring(split + 1).toInt());
  } else if (verb == "press") {
    int split = rest.indexOf(' ');
    hw::injectPress(rest.substring(0, split).toInt(), split < 0 ? 100 : rest.substring(split + 1).toInt());
  } else if (verb == "rotate") {
    // A number locks the screen there; "auto" hands it back to the
    // accelerometer.
    if (rest == "auto") {
      hw::setAutoRotate(true);
    } else if (rest.length()) {
      hw::setAutoRotate(false);
      hw::rotate(rest.toInt());
      onRotated();
    }
    Serial.printf("[rotate] %d, %s\n", hw::rotation(), hw::autoRotate() ? "auto" : "locked");
  } else if (verb == "imu") {
    float x, y, z;
    int8_t wants;
    if (hw::readImu(x, y, z, wants)) {
      Serial.printf("[imu] %.2f %.2f %.2f g, up calls for rotation %d\n", x, y, z, wants);
    } else {
      Serial.println("[imu] no reading");
    }
  } else if (verb == "status") {
    Serial.printf("[status] fw %s, ble %s, page %s, pixels %s, rotation %d%s, battery %d%%%s, heap %u\n",
                  HUB_FIRMWARE_VERSION, ble::connected() ? "connected" : "advertising", ui::hasPage() ? "yes" : "no",
                  pixels::present() ? "yes" : "no", hw::rotation(), hw::autoRotate() ? " (auto)" : "",
                  hw::batteryLevel(), hw::charging() ? " (charging)" : "", ESP.getFreeHeap());
  } else if (verb == "help") {
    Serial.println("commands: status | screen | tap <x> <y> | press <key> [ms] | rotate <0-3|auto> | imu | help");
    Serial.println("          or a JSON message, e.g. {\"t\":\"page\",...}, as if the Mac sent it");
  } else {
    Serial.printf("unknown command '%s', try 'help'\n", verb.c_str());
  }
}

static void pollConsole() {
  static String line;
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (line.length()) runCommand(line);
      line = "";
    } else if (line.length() < RX_LINE_MAX) {
      line += c;
    }
  }
}

// --- Arduino entry points --------------------------------------------------

void setup() {
  // Pages typed into the console are a few hundred bytes; the default 256-byte
  // buffer drops the tail of them.
  Serial.setRxBufferSize(RX_LINE_MAX);
  Serial.begin(115200);
  // Drop console output instead of blocking when nobody reads the CDC port.
  Serial.setTxTimeoutMs(0);
  delay(300);
  Serial.println("\n[hub] Nesso Hub " HUB_FIRMWARE_VERSION);

  hw::begin();
  pixels::setRotation(hw::rotation());
  pixels::begin();
  ui::begin();
  ui::showSplash();
  hw::onKey(onKey);
  ble::begin(handleLine, handleConnection);
  ui::showWaiting();
}

void loop() {
  ble::poll();
  hw::pollTouch();
  hw::pollKeys();
  hw::pollBattery();
  if (hw::pollRotation()) onRotated();
  pollTaps();
  ui::tick();
  pixels::tick();
  pollConsole();
  delay(1);
}
