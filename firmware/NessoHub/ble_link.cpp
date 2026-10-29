#include "ble_link.h"

#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

#include <deque>

#include "config.h"

namespace ble {

static LineHandler lineHandler = nullptr;
static ConnectionHandler connectionHandler = nullptr;

static BLECharacteristic* tx = nullptr;
static SemaphoreHandle_t lock = nullptr;

// Written by the BLE task, read by poll(); guarded by `lock`.
static String partial;
static std::deque<String> lines;
static bool isConnected = false;
static bool connectionChanged = false;

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer*) override {
    xSemaphoreTake(lock, portMAX_DELAY);
    isConnected = true;
    connectionChanged = true;
    partial = "";
    xSemaphoreGive(lock);
  }
  void onDisconnect(BLEServer*) override {
    xSemaphoreTake(lock, portMAX_DELAY);
    isConnected = false;
    connectionChanged = true;
    lines.clear();
    xSemaphoreGive(lock);
  }
};

class RxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    String value = c->getValue();
    xSemaphoreTake(lock, portMAX_DELAY);
    for (size_t i = 0; i < value.length(); i++) {
      char ch = value[i];
      if (ch == '\n') {
        if (partial.length()) lines.push_back(partial);
        partial = "";
      } else if (partial.length() < RX_LINE_MAX) {
        partial += ch;
      }
    }
    xSemaphoreGive(lock);
  }
};

void begin(LineHandler onLine, ConnectionHandler onConnection) {
  lineHandler = onLine;
  connectionHandler = onConnection;
  lock = xSemaphoreCreateMutex();
  partial.reserve(1024);

  BLEDevice::init(BLE_NAME);
  BLEDevice::setMTU(517);
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService* service = server->createService(HUB_SERVICE_UUID);
  tx = service->createCharacteristic(HUB_TX_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  tx->addDescriptor(new BLE2902());
  BLECharacteristic* rx = service->createCharacteristic(
      HUB_RX_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  rx->setCallbacks(new RxCallbacks());
  service->start();

  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(HUB_SERVICE_UUID);
  advertising->setScanResponse(true);
  BLEDevice::startAdvertising();
  Serial.printf("[ble] advertising as %s\n", BLE_NAME);
}

void poll() {
  bool changed = false, nowConnected = false;
  std::deque<String> ready;
  xSemaphoreTake(lock, portMAX_DELAY);
  changed = connectionChanged;
  nowConnected = isConnected;
  connectionChanged = false;
  ready.swap(lines);
  xSemaphoreGive(lock);

  if (changed) {
    Serial.printf("[ble] %s\n", nowConnected ? "connected" : "disconnected");
    // The stack stops advertising when a central connects; start again so the
    // Mac can find us after it goes away.
    if (!nowConnected) BLEDevice::startAdvertising();
    if (connectionHandler) connectionHandler(nowConnected);
  }
  for (const String& line : ready) {
    if (lineHandler) lineHandler(line);
  }
}

bool connected() { return isConnected; }

void send(const String& line) {
  if (!isConnected || !tx) return;
  String framed = line + "\n";
  for (size_t at = 0; at < framed.length(); at += TX_CHUNK) {
    size_t n = min((size_t)TX_CHUNK, framed.length() - at);
    tx->setValue((uint8_t*)framed.c_str() + at, n);
    tx->notify();
  }
}

}  // namespace ble
