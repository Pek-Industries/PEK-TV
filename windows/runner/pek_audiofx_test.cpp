// Checks pek_audiofx.h. Build and run anywhere:  g++ -std=c++17 -Wall -Wextra pek_audiofx_test.cpp -o audiofx_test && ./audiofx_test
#include "pek_audiofx.h"

#include <cstdio>

static int fails = 0;
#define CHECK_EQ(a, b) do { const std::string x = (a), y = (b); if (x != y) { ++fails; std::printf("FAIL line %d:\n  got  %s\n  want %s\n", __LINE__, x.c_str(), y.c_str()); } } while (0)

int main() {
  using pek::AudioFx;

  // defaults: nothing to filter, normal values
  AudioFx d;
  CHECK_EQ(d.FilterChain(), "");
  CHECK_EQ(d.DelaySeconds(), "0.000");
  CHECK_EQ(d.ToJson(), "{\"delayMs\":0,\"boost\":100,\"night\":0,\"dialogue\":0,\"bass\":0,\"treble\":0,\"downmix\":false,\"eq\":[0,0,0,0,0,0,0,0,0,0]}");

  // empty / garbage input falls back to defaults (never throws)
  CHECK_EQ(AudioFx::FromJson("").ToJson(), d.ToJson());
  CHECK_EQ(AudioFx::FromJson("not json at all").ToJson(), d.ToJson());
  CHECK_EQ(AudioFx::FromJson("{}").ToJson(), d.ToJson());

  // exactly what audio_fx.dart's toJson() sends (Rock preset, plus the other controls)
  const std::string dart = "{\"delayMs\":-250,\"boost\":150,\"night\":2,\"dialogue\":1,\"bass\":3,\"treble\":-2,\"downmix\":true,\"eq\":[5,4,3,1,-1,-1,1,3,4,5]}";
  AudioFx f = AudioFx::FromJson(dart);
  CHECK_EQ(f.ToJson(), dart);   // round trip
  CHECK_EQ(f.DelaySeconds(), "-0.250");
  CHECK_EQ(f.FilterChain(),
           "lavfi=[equalizer=f=1000:t=q:w=1:g=2,equalizer=f=2500:t=q:w=1:g=3,"
           "equalizer=f=31:t=o:w=1:g=5,equalizer=f=62:t=o:w=1:g=4,equalizer=f=125:t=o:w=1:g=3,equalizer=f=250:t=o:w=1:g=1,"
           "equalizer=f=500:t=o:w=1:g=-1,equalizer=f=1000:t=o:w=1:g=-1,equalizer=f=2000:t=o:w=1:g=1,equalizer=f=4000:t=o:w=1:g=3,"
           "equalizer=f=8000:t=o:w=1:g=4,equalizer=f=16000:t=o:w=1:g=5,volume=volume=-5dB,bass=g=3,treble=g=-2,"
           "acompressor=threshold=0.063:ratio=9:attack=10:release=250:makeup=4]");
  auto props = f.MpvProps();
  CHECK_EQ(props[1].second, "150");
  CHECK_EQ(props[3].second, "stereo");
  CHECK_EQ(props[4].second, "yes");

  // cuts only: no makeup attenuation; boost only on one band
  AudioFx cut = AudioFx::FromJson("{\"eq\":[0,0,0,0,-4,0,0,0,0,0]}");
  CHECK_EQ(cut.FilterChain(), "lavfi=[equalizer=f=500:t=o:w=1:g=-4]");
  AudioFx one = AudioFx::FromJson("{\"eq\":[0,0,0,0,0,0,0,0,0,7]}");
  CHECK_EQ(one.FilterChain(), "lavfi=[equalizer=f=16000:t=o:w=1:g=7,volume=volume=-7dB]");

  // out-of-range values are clamped, like the Dart side
  AudioFx c = AudioFx::FromJson("{\"delayMs\":99999,\"boost\":5,\"night\":9,\"dialogue\":-1,\"bass\":50,\"treble\":-50,\"eq\":[99,-99,0,0,0,0,0,0,0,0]}");
  CHECK_EQ(c.ToJson(), "{\"delayMs\":3000,\"boost\":100,\"night\":2,\"dialogue\":0,\"bass\":10,\"treble\":-10,\"downmix\":false,\"eq\":[12,-12,0,0,0,0,0,0,0,0]}");

  // a wrong number of bands is ignored (flat), whitespace and decimals are tolerated
  CHECK_EQ(AudioFx::FromJson("{\"eq\":[1,2,3]}").FilterChain(), "");
  AudioFx w = AudioFx::FromJson("{ \"delayMs\" : 1500 , \"downmix\" : true, \"eq\" : [ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0.4 ] }");
  CHECK_EQ(w.DelaySeconds(), "1.500");
  CHECK_EQ(w.downmix ? "y" : "n", "y");
  CHECK_EQ(w.FilterChain(), "lavfi=[equalizer=f=31:t=o:w=1:g=1,volume=volume=-1dB]");

  // small delays keep their zero padding
  CHECK_EQ(AudioFx::FromJson("{\"delayMs\":50}").DelaySeconds(), "0.050");
  CHECK_EQ(AudioFx::FromJson("{\"delayMs\":-5}").DelaySeconds(), "-0.005");

  if (fails) { std::printf("%d check(s) failed\n", fails); return 1; }
  std::printf("pek_audiofx: all checks passed\n");
  return 0;
}
