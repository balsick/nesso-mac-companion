// The screen, 135x240 or 240x135 on its side. The Mac describes a page as
// rows of tiles; this file keeps the last page, the icon cache, and draws
// both.
#pragma once

#include <Arduino.h>
#include <ArduinoJson.h>

#include "hw.h"

namespace ui {

void begin();
void showSplash();
void showWaiting();
// Redraws whatever is showing after hw::rotate(). The page keeps the Mac's
// row heights until the Mac sends one laid out for the new size.
void rotated();

// Replaces the current page. Fills `missing` with the ids of icons the page
// uses that are not cached yet, so the Mac can be asked for them.
void applyPage(JsonObjectConst page, JsonArray missing);
// Caches an icon and repaints if the current page uses it.
void addIcon(JsonObjectConst icon);

// The id of the tile under (x, y), or "" if there is none. Flashes the tile so
// a tap gets feedback before the Mac answers.
String tapTile(int16_t x, int16_t y);

// Drives the hold loader: "cancel" runs the ring back to empty and then puts
// the page back, "long" shows the hold's done screen until the next page
// arrives.
void keyAction(uint8_t index, const char* action);

// Clears expired tap flashes, repaints the battery reading, and animates the
// loader of a key being held.
void tick();
bool hasPage();

// Streams the framebuffer as base64 RGB565, for tools/nesso_screenshot.py.
void dumpScreen();

}  // namespace ui
