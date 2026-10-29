#include "ui.h"

#include <mbedtls/base64.h>

namespace ui {

// Drawing goes through a full-screen sprite so repaints never flicker.
static LGFX_Sprite canvas(&display);
static bool buffered = false;

static const int16_t HEADER_H = 20;
static const int16_t SUB_H = 14;
static const int16_t MARGIN = 4;
static const int16_t GAP = 4;
static const int16_t RADIUS = 8;

static LovyanGFX* target() { return buffered ? (LovyanGFX*)&canvas : (LovyanGFX*)&display; }

static void flush() {
  if (buffered) canvas.pushSprite(0, 0);
}

// --- Model ---------------------------------------------------------------

enum Font : uint8_t { FONT_S, FONT_M, FONT_L, FONT_XL };

struct Tile {
  String id;
  String label;
  String icon;
  uint16_t bg = COL_PANEL;
  uint16_t fg = COL_TEXT;
  Font font = FONT_M;
  // Laid out when the page arrives, so hit-testing matches what was drawn.
  int16_t x = 0, y = 0, w = 0, h = 0;
};

struct Page {
  String title;
  String sub;
  uint16_t accent = COL_TEAL;
  uint8_t tileCount = 0;
  Tile tiles[MAX_TILES];
};

static Page page;
static bool pageValid = false;
static int8_t flashed = -1;
static uint32_t flashUntilMs = 0;
static int lastDrawnBattery = -1;

enum IconFormat : uint8_t { ICON_RGB565, ICON_A8 };

struct Icon {
  String id;
  uint8_t w = 0, h = 0;
  IconFormat format = ICON_RGB565;
  uint8_t* data = nullptr;
  uint32_t usedAt = 0;
};

static Icon icons[MAX_ICONS];
static uint32_t iconClock = 0;

static Icon* findIcon(const String& id) {
  if (!id.length()) return nullptr;
  for (Icon& icon : icons) {
    if (icon.data && icon.id == id) {
      icon.usedAt = ++iconClock;
      return &icon;
    }
  }
  return nullptr;
}

static uint16_t parseColor(const char* hex, uint16_t fallback) {
  if (!hex || hex[0] != '#' || strlen(hex) != 7) return fallback;
  uint32_t rgb = strtoul(hex + 1, nullptr, 16);
  return display.color565((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
}

static Font parseFont(const char* name) {
  if (!name) return FONT_M;
  if (!strcmp(name, "s")) return FONT_S;
  if (!strcmp(name, "l")) return FONT_L;
  if (!strcmp(name, "xl")) return FONT_XL;
  return FONT_M;
}

static void useFont(LovyanGFX* g, Font font) {
  g->setTextSize(1);
  switch (font) {
    case FONT_S: g->setFont(&fonts::Font2); break;
    case FONT_M: g->setFont(&fonts::FreeSansBold9pt7b); break;
    case FONT_L: g->setFont(&fonts::FreeSansBold12pt7b); break;
    case FONT_XL: g->setFont(&fonts::FreeSansBold24pt7b); break;
  }
}

// --- Drawing -------------------------------------------------------------

static void drawIcon(LovyanGFX* g, const Icon& icon, int16_t x, int16_t y, uint16_t bg, uint16_t fg) {
  if (icon.format == ICON_RGB565) {
    // Rendered by the Mac on the tile's own background, so no blending.
    g->pushImage(x, y, icon.w, icon.h, (const uint16_t*)icon.data);
    return;
  }
  // A8 is a coverage mask: tint it with the tile's foreground.
  uint8_t br = ((bg >> 11) & 0x1F) << 3, bgG = ((bg >> 5) & 0x3F) << 2, bb = (bg & 0x1F) << 3;
  uint8_t fr = ((fg >> 11) & 0x1F) << 3, fgG = ((fg >> 5) & 0x3F) << 2, fb = (fg & 0x1F) << 3;
  for (int16_t row = 0; row < icon.h; row++) {
    for (int16_t col = 0; col < icon.w; col++) {
      uint8_t a = icon.data[row * icon.w + col];
      if (a < 8) continue;
      uint8_t r = br + (((int)fr - br) * a) / 255;
      uint8_t gg = bgG + (((int)fgG - bgG) * a) / 255;
      uint8_t b = bb + (((int)fb - bb) * a) / 255;
      g->drawPixel(x + col, y + row, display.color565(r, gg, b));
    }
  }
}

static void drawTile(LovyanGFX* g, const Tile& tile, bool flash) {
  g->fillRoundRect(tile.x, tile.y, tile.w, tile.h, RADIUS, tile.bg);
  if (flash) {
    g->drawRoundRect(tile.x, tile.y, tile.w, tile.h, RADIUS, COL_TEXT);
    g->drawRoundRect(tile.x + 1, tile.y + 1, tile.w - 2, tile.h - 2, RADIUS - 1, COL_TEXT);
  }

  Icon* icon = findIcon(tile.icon);
  bool hasLabel = tile.label.length() > 0;
  int16_t labelH = 0;
  if (hasLabel) {
    useFont(g, tile.font);
    labelH = g->fontHeight();
  }

  int16_t cx = tile.x + tile.w / 2;
  if (icon) {
    int16_t block = icon->h + (hasLabel ? labelH + 2 : 0);
    int16_t top = tile.y + (tile.h - block) / 2;
    drawIcon(g, *icon, cx - icon->w / 2, top, tile.bg, tile.fg);
    if (hasLabel) {
      useFont(g, tile.font);
      g->setTextColor(tile.fg);
      g->setTextDatum(textdatum_t::top_center);
      g->drawString(tile.label, cx, top + icon->h + 2);
    }
  } else if (hasLabel) {
    useFont(g, tile.font);
    g->setTextColor(tile.fg);
    g->setTextDatum(textdatum_t::middle_center);
    g->drawString(tile.label, cx, tile.y + tile.h / 2);
  }
}

static void drawHeader(LovyanGFX* g) {
  g->fillRect(0, 0, SCREEN_W, HEADER_H, COL_PANEL_ALT);
  g->setFont(&fonts::FreeSansBold9pt7b);
  g->setTextSize(1);
  g->setTextColor(page.accent);
  g->setTextDatum(textdatum_t::middle_left);
  g->drawString(page.title, 5, HEADER_H / 2 + 1);

  int level = hw::batteryLevel();
  lastDrawnBattery = level;
  uint16_t colour = hw::charging() ? COL_ACCENT : (level > 40 ? COL_GREEN : (level > 15 ? COL_ORANGE : COL_RED));
  g->setFont(&fonts::Font0);
  g->setTextColor(colour);
  g->setTextDatum(textdatum_t::middle_right);
  g->drawString(String(level) + "%", SCREEN_W - 4, HEADER_H / 2);

  if (page.sub.length()) {
    g->setFont(&fonts::Font0);
    g->setTextColor(COL_MUTED);
    g->setTextDatum(textdatum_t::middle_left);
    g->drawString(page.sub, 5, HEADER_H + SUB_H / 2);
  }
}

static void render() {
  LovyanGFX* g = target();
  g->fillScreen(COL_BG);
  drawHeader(g);
  for (uint8_t i = 0; i < page.tileCount; i++) drawTile(g, page.tiles[i], i == flashed);
  flush();
}

static void centeredText(LovyanGFX* g, const String& text, int16_t y, const lgfx::IFont* font, uint16_t colour) {
  g->setFont(font);
  g->setTextSize(1);
  g->setTextColor(colour);
  g->setTextDatum(textdatum_t::middle_center);
  g->drawString(text, SCREEN_W / 2, y);
}

// --- Public --------------------------------------------------------------

void begin() {
  canvas.setColorDepth(16);
  buffered = canvas.createSprite(SCREEN_W, SCREEN_H);
  Serial.printf("[ui] framebuffer %s\n", buffered ? "enabled" : "unavailable, drawing direct");
}

void showSplash() {
  LovyanGFX* g = target();
  g->fillScreen(COL_BG);
  centeredText(g, "Nesso Hub", 104, &fonts::FreeSansBold12pt7b, COL_TEAL);
  centeredText(g, HUB_FIRMWARE_VERSION, 132, &fonts::Font2, COL_MUTED);
  flush();
}

void showWaiting() {
  pageValid = false;
  LovyanGFX* g = target();
  g->fillScreen(COL_BG);
  centeredText(g, "Nesso Hub", 84, &fonts::FreeSansBold12pt7b, COL_TEAL);
  centeredText(g, "waiting for", 120, &fonts::Font2, COL_TEXT);
  centeredText(g, "the Mac", 138, &fonts::Font2, COL_TEXT);
  centeredText(g, "BLE: " BLE_NAME, SCREEN_H - 14, &fonts::Font0, COL_MUTED);
  flush();
}

void applyPage(JsonObjectConst json, JsonArray missing) {
  page.title = json["title"] | "";
  page.sub = json["sub"] | "";
  page.accent = parseColor(json["accent"], COL_TEAL);
  page.tileCount = 0;

  int16_t y = HEADER_H + (page.sub.length() ? SUB_H : 0) + GAP;
  for (JsonObjectConst row : json["rows"].as<JsonArrayConst>()) {
    int16_t h = row["h"] | 44;
    JsonArrayConst tiles = row["tiles"].as<JsonArrayConst>();
    int16_t count = tiles.size();
    if (!count) {
      y += h + GAP;
      continue;
    }
    int16_t w = (SCREEN_W - 2 * MARGIN - (count - 1) * GAP) / count;
    int16_t x = MARGIN;
    for (JsonObjectConst t : tiles) {
      if (page.tileCount >= MAX_TILES) break;
      Tile& tile = page.tiles[page.tileCount++];
      tile.id = t["id"] | "";
      tile.label = t["label"] | "";
      tile.icon = t["icon"] | "";
      tile.bg = parseColor(t["bg"], COL_PANEL);
      tile.fg = parseColor(t["fg"], COL_TEXT);
      tile.font = parseFont(t["font"]);
      tile.x = x;
      tile.y = y;
      tile.w = w;
      tile.h = h;
      x += w + GAP;

      if (tile.icon.length() && !findIcon(tile.icon)) {
        bool listed = false;
        for (JsonVariant id : missing) listed |= tile.icon == id.as<const char*>();
        if (!listed) missing.add(tile.icon);
      }
    }
    y += h + GAP;
  }

  pageValid = true;
  if (flashed >= page.tileCount) flashed = -1;
  render();
}

void addIcon(JsonObjectConst json) {
  String id = json["id"] | "";
  int w = json["w"] | 0, h = json["h"] | 0;
  const char* format = json["f"] | "rgb565";
  const char* b64 = json["d"] | "";
  if (!id.length() || w <= 0 || h <= 0 || w * h > MAX_ICON_PIXELS) {
    Serial.printf("[icon] rejected '%s' %dx%d\n", id.c_str(), w, h);
    return;
  }

  IconFormat fmt = strcmp(format, "a8") ? ICON_RGB565 : ICON_A8;
  size_t expected = (size_t)w * h * (fmt == ICON_A8 ? 1 : 2);
  uint8_t* data = (uint8_t*)malloc(expected);
  if (!data) {
    Serial.println("[icon] out of memory");
    return;
  }
  size_t written = 0;
  int err = mbedtls_base64_decode(data, expected, &written, (const unsigned char*)b64, strlen(b64));
  if (err || written != expected) {
    Serial.printf("[icon] '%s' bad payload (err %d, %u of %u bytes)\n", id.c_str(), err, written, expected);
    free(data);
    return;
  }

  // Replace an icon with the same id, else a free slot, else the least
  // recently drawn one.
  Icon* slot = nullptr;
  for (Icon& icon : icons) {
    if (icon.data && icon.id == id) slot = &icon;
  }
  if (!slot) {
    for (Icon& icon : icons) {
      if (!icon.data) {
        slot = &icon;
        break;
      }
    }
  }
  if (!slot) {
    slot = &icons[0];
    for (Icon& icon : icons) {
      if (icon.usedAt < slot->usedAt) slot = &icon;
    }
  }
  free(slot->data);
  slot->id = id;
  slot->w = w;
  slot->h = h;
  slot->format = fmt;
  slot->data = data;
  slot->usedAt = ++iconClock;

  if (!pageValid) return;
  for (uint8_t i = 0; i < page.tileCount; i++) {
    if (page.tiles[i].icon == id) {
      render();
      return;
    }
  }
}

String tapTile(int16_t x, int16_t y) {
  if (!pageValid) return "";
  for (uint8_t i = 0; i < page.tileCount; i++) {
    const Tile& t = page.tiles[i];
    if (x >= t.x && x < t.x + t.w && y >= t.y && y < t.y + t.h) {
      if (!t.id.length()) return "";
      flashed = i;
      flashUntilMs = millis() + TAP_FLASH_MS;
      render();
      return t.id;
    }
  }
  return "";
}

void tick() {
  if (!pageValid) return;
  bool dirty = false;
  if (flashed >= 0 && (int32_t)(millis() - flashUntilMs) >= 0) {
    flashed = -1;
    dirty = true;
  }
  if (hw::batteryLevel() != lastDrawnBattery) dirty = true;
  if (dirty) render();
}

bool hasPage() { return pageValid; }

void dumpScreen() {
  if (!buffered) {
    Serial.println("[screen] no framebuffer, cannot dump");
    return;
  }
  static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

  const uint8_t* data = (const uint8_t*)canvas.getBuffer();
  const uint32_t length = canvas.bufferLength();
  Serial.printf("[screen] begin %d %d rgb565 %u\n", SCREEN_W, SCREEN_H, length);

  char line[89];
  uint8_t col = 0;
  for (uint32_t i = 0; i < length; i += 3) {
    uint32_t chunk = data[i] << 16;
    if (i + 1 < length) chunk |= data[i + 1] << 8;
    if (i + 2 < length) chunk |= data[i + 2];

    line[col++] = B64[(chunk >> 18) & 0x3F];
    line[col++] = B64[(chunk >> 12) & 0x3F];
    line[col++] = (i + 1 < length) ? B64[(chunk >> 6) & 0x3F] : '=';
    line[col++] = (i + 2 < length) ? B64[chunk & 0x3F] : '=';

    if (col >= 88) {
      line[col] = 0;
      Serial.println(line);
      col = 0;
      delay(1);  // let the USB CDC drain
    }
  }
  if (col) {
    line[col] = 0;
    Serial.println(line);
  }
  Serial.println("[screen] end");
}

}  // namespace ui
