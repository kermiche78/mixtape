// Écran Swag : LilyGO T-Display S3 relié à l'iPhone en Bluetooth.
//
// - Mixtape envoie le titre, l'artiste, la progression et la pochette (service Bluetooth à nous).
// - Pour les autres apps (Spotify, Apple Music…), l'écran lit le morceau en cours grâce au
//   service « Apple Media Service » de l'iPhone (titre et artiste, sans pochette).
// - 3 modes : Texte, Musique, Auto (le texte, et le morceau dès que la musique joue).
//
// Boutons :
//   bouton du haut (GPIO 14) : appui court = son suivant, appui long = changer de mode
//   bouton du bas  (GPIO 0)  : appui court = lecture / pause, appui long = luminosité
//
// Bibliothèques : NimBLE-Arduino 2.x et LovyanGFX (compilé par GitHub, voir display/README.md).

#include <Arduino.h>
#include <Preferences.h>
#include <NimBLEDevice.h>
#define LGFX_USE_V1
#include <LovyanGFX.hpp>

// ---------- Écran (ST7789 170×320, bus parallèle 8 bits) ----------

class LGFX : public lgfx::LGFX_Device {
  lgfx::Panel_ST7789 _panel;
  lgfx::Bus_Parallel8 _bus;
  lgfx::Light_PWM _light;

 public:
  LGFX() {
    {
      auto cfg = _bus.config();
      cfg.freq_write = 20000000;
      cfg.pin_wr = 8;
      cfg.pin_rd = 9;
      cfg.pin_rs = 7;
      cfg.pin_d0 = 39;
      cfg.pin_d1 = 40;
      cfg.pin_d2 = 41;
      cfg.pin_d3 = 42;
      cfg.pin_d4 = 45;
      cfg.pin_d5 = 46;
      cfg.pin_d6 = 47;
      cfg.pin_d7 = 48;
      _bus.config(cfg);
      _panel.setBus(&_bus);
    }
    {
      auto cfg = _panel.config();
      cfg.pin_cs = 6;
      cfg.pin_rst = 5;
      cfg.pin_busy = -1;
      cfg.panel_width = 170;
      cfg.panel_height = 320;
      cfg.offset_x = 35;
      cfg.offset_y = 0;
      cfg.offset_rotation = 0;
      cfg.readable = false;
      cfg.invert = true;
      cfg.rgb_order = false;
      cfg.dlen_16bit = false;
      cfg.bus_shared = false;
      _panel.config(cfg);
    }
    {
      auto cfg = _light.config();
      cfg.pin_bl = 38;
      cfg.invert = false;
      cfg.freq = 22000;
      cfg.pwm_channel = 7;
      _light.config(cfg);
      _panel.setLight(&_light);
    }
    setPanel(&_panel);
  }
};

static LGFX tft;
static LGFX_Sprite frame(&tft);   // image complète 320×170, envoyée d'un coup (pas de scintillement)
static LGFX_Sprite cover(&tft);   // pochette 170×170

static const int W = 320, H = 170, COVER = 170;
static const int PIN_POWER = 15, PIN_BTN_LOW = 0, PIN_BTN_HIGH = 14;

// ---------- Bluetooth ----------

// Service de Mixtape (doit être identique dans l'app : DisplayLink.swift)
#define MIX_SERVICE "8f1c0001-6d69-7874-6170-652d64737033"
#define MIX_INPUT   "8f1c0002-6d69-7874-6170-652d64737033"  // l'app écrit ici
#define MIX_STATUS  "8f1c0003-6d69-7874-6170-652d64737033"  // l'écran prévient l'app (mode changé)

// Apple Media Service (fourni par l'iPhone)
#define AMS_SERVICE  "89D3502B-0F36-433A-8EF4-C502AD55F8DC"
#define AMS_REMOTE   "9B3C81D8-57B1-4A8A-B8DF-0E56F7CA51C2"
#define AMS_UPDATE   "2F7CABCE-808D-411F-9A0C-BB92BA96C102"

static NimBLEServer* server = nullptr;
static NimBLECharacteristic* statusChar = nullptr;
static NimBLEClient* amsClient = nullptr;
static NimBLERemoteCharacteristic* amsRemote = nullptr;
static volatile bool connected = false;
static volatile uint16_t connHandle = 0xFFFF;
static volatile bool needAms = false;      // à faire dans loop() (la découverte bloque)
static volatile bool linkDropped = false;
static uint32_t amsRetryAt = 0;

// ---------- État partagé (Bluetooth ↔ affichage) ----------

struct Track {
  String title, artist, app;
  bool playing = false;
  float elapsed = 0, duration = 0;
  uint32_t stamp = 0;  // millis() quand elapsed a été reçu
  String coverKey;
};

static SemaphoreHandle_t lock;
static Track mix;  // venant de Mixtape
static Track ams;  // venant de l'iPhone (toutes les apps)
static bool mixActive = false;

enum Mode { MODE_TEXT = 0, MODE_MUSIC = 1, MODE_AUTO = 2 };
static const char* MODE_NAMES[] = {"texte", "musique", "auto"};
static Mode mode = MODE_AUTO;
static String userText = "swag";
static uint16_t bgColor;
static uint8_t brightness = 200;
static Preferences prefs;
static volatile bool statusDirty = false;

// Pochette reçue par morceaux
static uint8_t* jpgBuf = nullptr;
static const size_t JPG_MAX = 48 * 1024;
static size_t jpgSize = 0, jpgReceived = 0;
static String jpgKey;
static volatile bool jpgReady = false;
static String coverLoadedKey;

// ---------- Petits outils ----------

// Le texte pixel n'a que les lettres sans accent : « é » devient « e », etc.
static String fold(const std::string& in) {
  String out;
  for (size_t i = 0; i < in.size(); i++) {
    uint8_t c = in[i];
    if (c < 0x80) { out += (char)c; continue; }
    if (c == 0xC3 && i + 1 < in.size()) {
      uint8_t d = in[++i];
      const char* map =
          "AAAAAAACEEEEIIII"   // C3 80..8F
          "DNOOOOO*OUUUUYTs"   // C3 90..9F
          "aaaaaaaceeeeiiii"   // C3 A0..AF
          "dnooooo/ouuuuyty";  // C3 B0..BF
      if (d >= 0x80 && d <= 0xBF) out += map[d - 0x80];
      continue;
    }
    if (c == 0xC5 && i + 1 < in.size()) {  // œ Œ
      uint8_t d = in[++i];
      if (d == 0x93) out += "oe"; else if (d == 0x92) out += "OE";
      continue;
    }
    if (c == 0xE2 && i + 2 < in.size()) {  // ’ ‘ “ ” – — …
      uint8_t d = in[i + 1], e = in[i + 2];
      i += 2;
      if (d == 0x80 && (e == 0x98 || e == 0x99)) out += '\'';
      else if (d == 0x80 && (e == 0x9C || e == 0x9D)) out += '"';
      else if (d == 0x80 && (e == 0x93 || e == 0x94)) out += '-';
      else if (d == 0x80 && e == 0xA6) out += "...";
      continue;
    }
    // autre caractère (emoji…) : on saute ses octets de suite
    while (i + 1 < in.size() && (((uint8_t)in[i + 1]) & 0xC0) == 0x80) i++;
  }
  return out;
}

static std::vector<std::string> split(const std::string& s, char sep) {
  std::vector<std::string> parts;
  size_t start = 0;
  for (size_t i = 0; i <= s.size(); i++) {
    if (i == s.size() || s[i] == sep) {
      parts.push_back(s.substr(start, i - start));
      start = i + 1;
    }
  }
  return parts;
}

static uint16_t hexColor(const std::string& hex, uint16_t fallback) {
  if (hex.size() != 6) return fallback;
  long v = strtol(hex.c_str(), nullptr, 16);
  return lgfx::color565((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF);
}

static uint32_t readU32(const uint8_t* p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }

static void saveSettings() {
  prefs.putUChar("mode", (uint8_t)mode);
  prefs.putString("text", userText);
  prefs.putUShort("bg", bgColor);
  prefs.putUChar("bright", brightness);
}

// ---------- Ce que Mixtape envoie ----------
// 'M' 0x1F titre 0x1F artiste 0x1F lecture(0/1) 0x1F position 0x1F durée 0x1F clé de pochette
// 'S' 0x1F mode 0x1F texte 0x1F couleur (RRGGBB)
// 0x01 taille(u32) : début de pochette (JPEG) · 0x02 position(u32) données · 0x03 fin
// 'X' : Mixtape s'arrête (plus de musique envoyée)

static void handleInput(const uint8_t* data, size_t len) {
  if (len == 0) return;
  uint8_t kind = data[0];

  if (kind == 0x01 && len >= 5) {
    size_t size = readU32(data + 1);
    if (size == 0 || size > JPG_MAX || jpgReady) { jpgSize = 0; return; }
    jpgSize = size;
    jpgReceived = 0;
    jpgKey = (len > 5) ? String((const char*)data + 5, len - 5) : String("");
    return;
  }
  if (kind == 0x02 && len > 5) {
    if (jpgSize == 0) return;
    size_t off = readU32(data + 1), n = len - 5;
    if (off + n > jpgSize) { jpgSize = 0; return; }
    memcpy(jpgBuf + off, data + 5, n);
    jpgReceived += n;
    return;
  }
  if (kind == 0x03) {
    if (jpgSize > 0 && jpgReceived == jpgSize) jpgReady = true;
    else jpgSize = 0;
    return;
  }

  std::string s((const char*)data, len);
  auto p = split(s, 0x1F);
  if (kind == 'M' && p.size() >= 7) {
    xSemaphoreTake(lock, portMAX_DELAY);
    mix.title = fold(p[1]);
    mix.artist = fold(p[2]);
    mix.playing = p[3] == "1";
    mix.elapsed = atof(p[4].c_str());
    mix.duration = atof(p[5].c_str());
    mix.stamp = millis();
    mix.coverKey = String(p[6].c_str());
    mix.app = "MIXTAPE";
    mixActive = mix.title.length() > 0;
    xSemaphoreGive(lock);
  } else if (kind == 'S' && p.size() >= 4) {
    for (int i = 0; i < 3; i++) if (p[1] == MODE_NAMES[i]) mode = (Mode)i;
    userText = fold(p[2]);
    bgColor = hexColor(p[3], bgColor);
    saveSettings();
  } else if (kind == 'X') {
    xSemaphoreTake(lock, portMAX_DELAY);
    mixActive = false;
    xSemaphoreGive(lock);
  }
}

class InputCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c, NimBLEConnInfo& info) override {
    NimBLEAttValue v = c->getValue();
    handleInput(v.data(), v.size());
  }
};

// ---------- Apple Media Service ----------

static void onAmsUpdate(NimBLERemoteCharacteristic*, uint8_t* data, size_t len, bool) {
  if (len < 3) return;
  uint8_t entity = data[0], attr = data[1];
  std::string value((const char*)data + 3, len - 3);
  xSemaphoreTake(lock, portMAX_DELAY);
  if (entity == 0) {  // lecteur
    if (attr == 0) {
      ams.app = fold(value);
      ams.app.toUpperCase();
    } else if (attr == 1) {  // « état,vitesse,position »
      auto p = split(value, ',');
      if (p.size() >= 3) {
        ams.playing = p[0] == "1";
        ams.elapsed = atof(p[2].c_str());
        ams.stamp = millis();
      }
    }
  } else if (entity == 2) {  // morceau
    if (attr == 0) ams.artist = fold(value);
    else if (attr == 2) ams.title = fold(value);
    else if (attr == 3) ams.duration = atof(value.c_str());
  }
  xSemaphoreGive(lock);
}

static void setupAms() {
  needAms = false;
  if (!connected || !server) return;
  NimBLEConnInfo info = server->getPeerInfoByHandle(connHandle);
  if (!info.isEncrypted()) { amsRetryAt = millis() + 1500; needAms = true; return; }
  if (!amsClient) amsClient = server->getClient(info);
  if (!amsClient) return;
  NimBLERemoteService* svc = amsClient->getService(AMS_SERVICE);
  if (!svc) { Serial.println("AMS introuvable"); return; }
  NimBLERemoteCharacteristic* update = svc->getCharacteristic(AMS_UPDATE);
  amsRemote = svc->getCharacteristic(AMS_REMOTE);
  if (!update) return;
  if (!update->subscribe(true, onAmsUpdate, true)) { Serial.println("AMS : abonnement refusé"); return; }
  const uint8_t player[] = {0, 0, 1};       // nom de l'app, état de lecture
  const uint8_t track[] = {2, 0, 2, 3};     // artiste, titre, durée
  update->writeValue(player, sizeof(player), true);
  update->writeValue(track, sizeof(track), true);
  Serial.println("AMS prêt");
}

// 2 = lecture/pause, 3 = suivant, 4 = précédent
static void amsCommand(uint8_t cmd) {
  if (connected && amsRemote) amsRemote->writeValue(&cmd, 1, true);
}

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* s, NimBLEConnInfo& info) override {
    connected = true;
    connHandle = info.getConnHandle();
    s->updateConnParams(info.getConnHandle(), 12, 24, 0, 400);
    NimBLEDevice::startSecurity(info.getConnHandle());
    statusDirty = true;
  }
  void onDisconnect(NimBLEServer* s, NimBLEConnInfo& info, int reason) override {
    connected = false;
    connHandle = 0xFFFF;
    linkDropped = true;
  }
  void onAuthenticationComplete(NimBLEConnInfo& info) override {
    if (info.isEncrypted()) { needAms = true; amsRetryAt = millis() + 300; }
  }
};

static void startBluetooth() {
  NimBLEDevice::init("Ecran Swag");
  NimBLEDevice::setMTU(517);
  NimBLEDevice::setSecurityAuth(true, false, true);  // appairage mémorisé, sans code
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);

  server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  server->advertiseOnDisconnect(true);

  NimBLEService* svc = server->createService(MIX_SERVICE);
  NimBLECharacteristic* input = svc->createCharacteristic(MIX_INPUT, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  input->setCallbacks(new InputCallbacks());
  statusChar = svc->createCharacteristic(MIX_STATUS, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  statusChar->setValue(std::string(MODE_NAMES[mode]));
  svc->start();
  server->start();

  // Annonce : demande l'Apple Media Service (l'écran apparaît dans Réglages › Bluetooth)
  NimBLEAdvertisementData adv;
  adv.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
  const uint8_t solicit[] = {17, 0x15, 0xDC, 0xF8, 0x55, 0xAD, 0x02, 0xC5, 0xF4, 0x8E,
                             0x3A, 0x43, 0x36, 0x0F, 0x2B, 0x50, 0xD3, 0x89};
  adv.addData(solicit, sizeof(solicit));
  NimBLEAdvertisementData scan;
  scan.addServiceUUID(NimBLEUUID(MIX_SERVICE));
  scan.setName("Ecran Swag");

  NimBLEAdvertising* a = NimBLEDevice::getAdvertising();
  a->setAdvertisementData(adv);
  a->setScanResponseData(scan);
  a->enableScanResponse(true);
  a->start();
}

// ---------- Dessin ----------

struct Star { int16_t x, y; uint8_t size; uint8_t phase; };
static const Star STARS[] = {
    {26, 22, 4, 0}, {290, 20, 6, 3}, {60, 136, 6, 6}, {286, 130, 4, 2}, {166, 148, 3, 5},
    {134, 16, 3, 1}, {226, 52, 3, 7}, {14, 84, 3, 4}, {306, 82, 3, 0}, {100, 60, 2, 3},
};
static const Star COVER_STARS[] = {
    {20, 22, 4, 0}, {134, 34, 6, 2}, {40, 134, 6, 5}, {140, 126, 4, 3}, {86, 16, 3, 6}, {14, 80, 3, 1},
};

static uint16_t starColor(int i) {
  static const uint16_t cols[] = {0xFFFF, lgfx::color565(255, 227, 110), lgfx::color565(217, 194, 255)};
  return cols[i % 3];
}

static bool starOn(const Star& s, uint32_t t) { return ((t / 350 + s.phase) % 8) != 0; }

static void drawStars(LGFX_Sprite& g, const Star* stars, int count, int ox, uint32_t t) {
  for (int i = 0; i < count; i++) {
    const Star& s = stars[i];
    if (!starOn(s, t)) continue;
    int sz = s.size;
    uint16_t c = starColor(i);
    g.fillRect(ox + s.x, s.y, sz, sz, c);
    if (sz >= 4) {  // petite croix pixel
      g.fillRect(ox + s.x + sz / 2 - 1, s.y - sz / 2, 2, sz * 2, c);
      g.fillRect(ox + s.x - sz / 2, s.y + sz / 2 - 1, sz * 2, 2, c);
    }
  }
}

// Texte qui défile s'il est trop large pour la zone [x, x+w]
static void scrollText(LGFX_Sprite& g, const String& txt, int x, int y, int w, int size, uint16_t color, uint32_t t) {
  g.setTextSize(size);
  g.setTextColor(color);
  int tw = g.textWidth(txt);
  g.setClipRect(x, y - 2, w, 8 * size + 4);
  if (tw <= w) {
    g.drawString(txt, x, y);
  } else {
    int gap = 40;
    int period = tw + gap;
    int shift = (int)((t / 25) % period);
    g.drawString(txt, x - shift, y);
    g.drawString(txt, x - shift + period, y);
  }
  g.clearClipRect();
}

static String timeText(float s) {
  if (s < 0) s = 0;
  int m = (int)s / 60, sec = (int)s % 60;
  char buf[8];
  snprintf(buf, sizeof(buf), "%d:%02d", m, sec);
  return String(buf);
}

static void drawNote(LGFX_Sprite& g, int cx, int cy) {
  uint16_t w = 0xFFFF;
  g.fillRect(cx - 14, cy - 34, 6, 48, w);
  g.fillRect(cx + 22, cy - 40, 6, 48, w);
  g.fillRect(cx - 14, cy - 40, 42, 8, w);
  g.fillCircle(cx - 22, cy + 14, 11, w);
  g.fillCircle(cx + 14, cy + 8, 11, w);
}

static void drawMusic(const Track& tr, bool withCover, uint32_t t) {
  uint16_t panel = lgfx::color565(11, 7, 18);
  uint16_t violet = lgfx::color565(180, 140, 255);
  frame.fillScreen(panel);

  if (withCover) {
    cover.pushSprite(&frame, 0, 0);
  } else {
    frame.fillRect(0, 0, COVER, COVER, lgfx::color565(59, 19, 122));
    drawStars(frame, COVER_STARS, 6, 0, t);
    drawNote(frame, 85, 85);
  }

  int x = COVER + 12, w = W - x - 10;
  frame.setFont(&fonts::Font0);
  frame.setTextSize(1);
  frame.setTextColor(violet);
  frame.setClipRect(x, 0, w, H);
  frame.drawString(tr.app.length() ? tr.app : String("MUSIQUE"), x, 12);
  frame.clearClipRect();

  scrollText(frame, tr.title.length() ? tr.title : String("..."), x, 58, w, 3, 0xFFFF, t);
  scrollText(frame, tr.artist, x, 92, w, 2, lgfx::color565(201, 189, 224), t);

  float el = tr.elapsed + (tr.playing ? (millis() - tr.stamp) / 1000.0f : 0);
  if (tr.duration > 0) {
    if (el > tr.duration) el = tr.duration;
    int barY = 138;
    frame.fillRect(x, barY, w, 5, lgfx::color565(45, 35, 64));
    frame.fillRect(x, barY, (int)(w * (el / tr.duration)), 5, violet);
    frame.setTextSize(1);
    frame.setTextColor(lgfx::color565(154, 141, 179));
    frame.drawString(timeText(el), x, 150);
    String d = timeText(tr.duration);
    frame.drawString(d, x + w - frame.textWidth(d), 150);
  } else {
    frame.setTextSize(1);
    frame.setTextColor(lgfx::color565(154, 141, 179));
    frame.drawString(tr.playing ? "LECTURE" : "PAUSE", x, 150);
  }
  if (!tr.playing) {  // petit signe pause
    frame.fillRect(W - 22, 10, 4, 12, violet);
    frame.fillRect(W - 14, 10, 4, 12, violet);
  }
}

static void drawText(const String& txt, uint32_t t) {
  frame.fillScreen(bgColor);
  drawStars(frame, STARS, 10, 0, t);
  frame.setFont(&fonts::Font0);
  String s = txt.length() ? txt : String(" ");
  uint16_t shadow = lgfx::color565(29, 6, 64);

  int size = 0;
  for (int sz = 9; sz >= 4; sz--) {
    frame.setTextSize(sz);
    if (frame.textWidth(s) <= W - 24) { size = sz; break; }
  }
  if (size) {
    frame.setTextSize(size);
    int tw = frame.textWidth(s), th = 8 * size;
    int x = (W - tw) / 2, y = (H - th) / 2;
    frame.setTextColor(shadow);
    frame.drawString(s, x + size / 2 + 1, y + size / 2 + 1);
    frame.setTextColor(0xFFFF);
    frame.drawString(s, x, y);
  } else {
    size = 6;
    frame.setTextSize(size);
    int y = (H - 8 * size) / 2;
    int tw = frame.textWidth(s), period = tw + 80;
    int shift = (int)((t / 18) % period);
    for (int k = 0; k < 2; k++) {
      int x = 16 - shift + k * period;
      frame.setTextColor(shadow);
      frame.drawString(s, x + 4, y + 4);
      frame.setTextColor(0xFFFF);
      frame.drawString(s, x, y);
    }
  }
  if (!connected) {  // petit point : pas relié à l'iPhone
    frame.fillRect(W - 8, H - 8, 4, 4, lgfx::color565(120, 110, 140));
  }
}

// ---------- Boutons ----------

struct Button {
  uint8_t pin;
  bool down = false, longDone = false;
  uint32_t since = 0;
};
static Button btnHigh{PIN_BTN_HIGH}, btnLow{PIN_BTN_LOW};

static void cycleMode() {
  mode = (Mode)((mode + 1) % 3);
  saveSettings();
  statusDirty = true;
}

static uint32_t toastUntil = 0;
static String toast;

static void showToast(const String& s) { toast = s; toastUntil = millis() + 1200; }

static void pollButton(Button& b, void (*shortPress)(), void (*longPress)()) {
  bool pressed = digitalRead(b.pin) == LOW;
  uint32_t now = millis();
  if (pressed && !b.down) { b.down = true; b.longDone = false; b.since = now; }
  else if (pressed && b.down && !b.longDone && now - b.since > 700) { b.longDone = true; longPress(); }
  else if (!pressed && b.down) {
    b.down = false;
    if (!b.longDone && now - b.since > 30) shortPress();
  }
}

static void highShort() { amsCommand(3); showToast(">>"); }
static void highLong() {
  cycleMode();
  String n = MODE_NAMES[mode];
  n.toUpperCase();
  showToast(n);
}
static void lowShort() { amsCommand(2); showToast("> / ||"); }
static void lowLong() {
  int b = brightness >= 250 ? 60 : brightness + 70;
  brightness = b > 255 ? 255 : b;
  tft.setBrightness(brightness);
  saveSettings();
}

// ---------- Programme ----------

void setup() {
  pinMode(PIN_POWER, OUTPUT);
  digitalWrite(PIN_POWER, HIGH);  // garde l'écran allumé sur batterie
  pinMode(PIN_BTN_HIGH, INPUT_PULLUP);
  pinMode(PIN_BTN_LOW, INPUT_PULLUP);
  Serial.begin(115200);

  lock = xSemaphoreCreateMutex();
  bgColor = lgfx::color565(74, 20, 140);
  prefs.begin("ecran", false);
  mode = (Mode)prefs.getUChar("mode", MODE_AUTO);
  if (mode > MODE_AUTO) mode = MODE_AUTO;
  userText = prefs.getString("text", "swag");
  bgColor = prefs.getUShort("bg", bgColor);
  brightness = prefs.getUChar("bright", 200);

  tft.init();
  tft.setRotation(1);  // paysage, port USB à droite
  tft.setBrightness(brightness);
  tft.fillScreen(TFT_BLACK);

  frame.setPsram(true);
  frame.setColorDepth(16);
  frame.createSprite(W, H);
  cover.setPsram(true);
  cover.setColorDepth(16);
  cover.createSprite(COVER, COVER);
  jpgBuf = (uint8_t*)ps_malloc(JPG_MAX);

  startBluetooth();
}

void loop() {
  uint32_t now = millis();

  if (linkDropped) {
    linkDropped = false;
    needAms = false;
    amsRemote = nullptr;
    if (amsClient) { NimBLEDevice::deleteClient(amsClient); amsClient = nullptr; }
    xSemaphoreTake(lock, portMAX_DELAY);
    mixActive = false;
    ams = Track();
    xSemaphoreGive(lock);
  }
  if (needAms && now >= amsRetryAt) setupAms();

  if (statusDirty && connected && statusChar) {
    statusDirty = false;
    statusChar->setValue(std::string(MODE_NAMES[mode]));
    statusChar->notify();
  }

  if (jpgReady) {
    cover.fillScreen(TFT_BLACK);
    cover.drawJpg(jpgBuf, jpgSize, 0, 0, COVER, COVER);
    coverLoadedKey = jpgKey;
    jpgSize = 0;
    jpgReady = false;
  }

  pollButton(btnHigh, highShort, highLong);
  pollButton(btnLow, lowShort, lowLong);

  // Quelle musique afficher ?
  xSemaphoreTake(lock, portMAX_DELAY);
  bool otherAppPlaying = ams.playing && ams.title.length() && ams.app != "MIXTAPE";
  bool useMix = mixActive && !otherAppPlaying;
  Track tr = useMix ? mix : ams;
  bool haveTrack = tr.title.length() > 0;
  xSemaphoreGive(lock);

  static uint32_t lastPlaying = 0;
  if (haveTrack && tr.playing) lastPlaying = now;
  bool recentlyPlaying = haveTrack && (tr.playing || now - lastPlaying < 3000);

  bool showMusic = (mode == MODE_MUSIC && haveTrack) || (mode == MODE_AUTO && recentlyPlaying);
  if (showMusic) {
    bool withCover = useMix && coverLoadedKey.length() && coverLoadedKey == tr.coverKey;
    drawMusic(tr, withCover, now);
  } else if (mode == MODE_MUSIC) {
    drawText("PAS DE MUSIQUE", now);
  } else {
    drawText(userText, now);
  }

  if (now < toastUntil) {
    frame.setFont(&fonts::Font0);
    frame.setTextSize(2);
    int tw = frame.textWidth(toast) + 16;
    frame.fillRect((W - tw) / 2, H - 34, tw, 26, TFT_BLACK);
    frame.setTextColor(0xFFFF);
    frame.drawString(toast, (W - tw) / 2 + 8, H - 29);
  }

  frame.pushSprite(0, 0);
  delay(16);
}
