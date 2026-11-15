// Sound settings (Settings > Playback > Sound, the Sound / Equalizer panels in the players), the Windows side.
// The Dart model is flutter_ui/lib/src/audio_fx.dart; on Android the same thing lives in MpvController.kt (fxRead / fxFilterChain /
// applyAudioFx). This header is the same logic for libmpv on Windows. It has no Windows or Flutter dependency on purpose, so
// pek_audiofx_test.cpp can build and check it with any C++17 compiler.
//
// The settings are JSON like {"delayMs":0,"boost":100,"night":0,"dialogue":0,"bass":0,"treble":0,"downmix":false,"eq":[0,0,0,0,0,0,0,0,0,0]}.
#pragma once
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

namespace pek {

struct AudioFx {
  static constexpr int kBands = 10;
  static constexpr int kFreqs[kBands] = {31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};   // Hz, one octave wide each

  int delayMs = 0;     // -3000..3000, positive = sound later
  int boost = 100;     // 100..200 (%)
  int night = 0;       // 0 off, 1 light, 2 strong
  int dialogue = 0;    // 0 off, 1 low, 2 high
  int bass = 0;        // -10..10 dB
  int treble = 0;      // -10..10 dB
  bool downmix = false;
  int eq[kBands] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0};   // -12..12 dB

  static int Clamp(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

  // ---- reading JSON (the small, flat shape above; unknown keys are ignored, anything missing keeps its default) ----
  static const char* Find(const std::string& j, const char* key) {
    const std::string k = std::string("\"") + key + "\"";
    size_t p = j.find(k);
    if (p == std::string::npos) return nullptr;
    p += k.size();
    while (p < j.size() && (std::isspace(static_cast<unsigned char>(j[p])) || j[p] == ':')) p++;
    return j.c_str() + p;
  }
  static int Int(const std::string& j, const char* key, int def) {
    const char* s = Find(j, key);
    if (!s) return def;
    char* end = nullptr;
    const double v = std::strtod(s, &end);
    if (end == s || !std::isfinite(v)) return def;
    return static_cast<int>(std::lround(v));
  }

  static AudioFx FromJson(const std::string& j) {
    AudioFx f;
    f.delayMs = Clamp(Int(j, "delayMs", 0), -3000, 3000);
    f.boost = Clamp(Int(j, "boost", 100), 100, 200);
    f.night = Clamp(Int(j, "night", 0), 0, 2);
    f.dialogue = Clamp(Int(j, "dialogue", 0), 0, 2);
    f.bass = Clamp(Int(j, "bass", 0), -10, 10);
    f.treble = Clamp(Int(j, "treble", 0), -10, 10);
    const char* d = Find(j, "downmix");
    f.downmix = d && std::strncmp(d, "true", 4) == 0;
    const char* e = Find(j, "eq");
    if (e && *e == '[') {
      int got[kBands] = {};
      int n = 0;
      const char* s = e + 1;
      while (n < kBands) {
        while (*s && (std::isspace(static_cast<unsigned char>(*s)) || *s == ',')) s++;
        char* end = nullptr;
        const double v = std::strtod(s, &end);
        if (end == s || !std::isfinite(v)) break;
        got[n++] = Clamp(static_cast<int>(std::lround(v)), -12, 12);
        s = end;
      }
      if (n == kBands) std::copy(got, got + kBands, f.eq);   // like the Dart side: exactly ten bands or flat
    }
    return f;
  }

  std::string ToJson() const {
    std::string s = "{\"delayMs\":" + std::to_string(delayMs) + ",\"boost\":" + std::to_string(boost) + ",\"night\":" + std::to_string(night) +
                    ",\"dialogue\":" + std::to_string(dialogue) + ",\"bass\":" + std::to_string(bass) + ",\"treble\":" + std::to_string(treble) +
                    ",\"downmix\":" + (downmix ? "true" : "false") + ",\"eq\":[";
    for (int i = 0; i < kBands; i++) s += (i ? "," : "") + std::to_string(eq[i]);
    return s + "]}";
  }

  // ---- what mpv gets ----

  /// The mpv "af" value; "" when no filter is needed. Same chain, same order as Android.
  std::string FilterChain() const {
    std::vector<std::string> f;
    if (dialogue == 1) { f.push_back("equalizer=f=1000:t=q:w=1:g=2"); f.push_back("equalizer=f=2500:t=q:w=1:g=3"); }
    if (dialogue == 2) { f.push_back("equalizer=f=1000:t=q:w=1:g=4"); f.push_back("equalizer=f=2500:t=q:w=1:g=6"); }
    int eqMax = 0;
    for (int i = 0; i < kBands; i++) {
      if (eq[i] != 0) f.push_back("equalizer=f=" + std::to_string(kFreqs[i]) + ":t=o:w=1:g=" + std::to_string(eq[i]));
      if (eq[i] > eqMax) eqMax = eq[i];
    }
    // Boosted bands would clip the loudest parts: turn everything down by the biggest boost (Volume boost gets it back).
    if (eqMax > 0) f.push_back("volume=volume=-" + std::to_string(eqMax) + "dB");
    if (bass != 0) f.push_back("bass=g=" + std::to_string(bass));
    if (treble != 0) f.push_back("treble=g=" + std::to_string(treble));
    // Night mode last: it evens out what the other filters did.
    if (night == 1) f.push_back("acompressor=threshold=0.125:ratio=4:attack=20:release=300:makeup=2");
    if (night == 2) f.push_back("acompressor=threshold=0.063:ratio=9:attack=10:release=250:makeup=4");
    if (f.empty()) return "";
    std::string s = "lavfi=[";
    for (size_t i = 0; i < f.size(); i++) s += (i ? "," : "") + f[i];
    return s + "]";
  }

  /// mpv's audio-delay is in seconds, always with a '.' (never the system's decimal comma).
  std::string DelaySeconds() const {
    char b[32];
    std::snprintf(b, sizeof b, "%s%d.%03d", delayMs < 0 ? "-" : "", std::abs(delayMs) / 1000, std::abs(delayMs) % 1000);
    return b;
  }

  /// The mpv properties for these settings, each set on its own so one this libmpv build does not know cannot stop the others.
  std::vector<std::pair<std::string, std::string>> MpvProps() const {
    return {
        {"volume-max", "200"},
        {"volume", std::to_string(boost)},
        {"audio-delay", DelaySeconds()},
        {"audio-channels", downmix ? "stereo" : "auto-safe"},
        {"audio-normalize-downmix", downmix ? "yes" : "no"},
        {"af", FilterChain()},
    };
  }
};

}  // namespace pek
