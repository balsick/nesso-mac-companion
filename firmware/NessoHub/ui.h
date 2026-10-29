// The 135x240 screen. The Mac describes a page as rows of tiles; this file
// keeps the last page, the icon cache, and draws both.
#pragma once

#include <Arduino.h>
#include <ArduinoJson.h>

#include "hw.h"

namespace ui {

void begin();
void showSplash();
void showWaiting();

// Replaces the current page. Fills `missing` with the ids of icons the page
// uses that are not cached yet, so the Mac can be asked for them.
void applyPage(JsonObjectConst page, JsonArray missing);
// Caches an icon and repaints if the current page uses it.
void addIcon(JsonObjectConst icon);

// The id of the tile under (x, y), or "" if there is none. Flashes the tile so
// a tap gets feedback before the Mac answers.
String tapTile(int16_t x, int16_t y);

// Clears expired tap flashes and repaints the battery reading.
void tick();
bool hasPage();

// Streams the framebuffer as base64 RGB565, for tools/nesso_screenshot.py.
void dumpScreen();

}  // namespace ui
