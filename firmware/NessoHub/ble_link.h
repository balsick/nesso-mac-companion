// The BLE link to the Mac: one GATT service, newline-terminated JSON both ways.
#pragma once

#include <Arduino.h>

namespace ble {

typedef void (*LineHandler)(const String& line);
typedef void (*ConnectionHandler)(bool connected);

void begin(LineHandler onLine, ConnectionHandler onConnection);
// Delivers received lines and connection changes on the loop task. The BLE
// callbacks run on the stack's own task, so they only queue.
void poll();
bool connected();
// Sends one JSON line, split into notifications.
void send(const String& line);

}  // namespace ble
