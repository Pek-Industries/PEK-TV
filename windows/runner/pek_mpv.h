// The Windows side of the pek/mpv channel: libmpv (libmpv-2.dll next to the exe, loaded at run time) draws each frame in software
// into a pixel buffer that Flutter shows as a texture (Dart: PekVideoSurface). On Android the same engine draws on a surface behind
// Flutter (MpvController.kt); the Dart player screens do not know the difference.
#pragma once
#include <flutter/encodable_value.h>
#include <flutter/event_sink.h>
#include <flutter/texture_registrar.h>

#include "pek_audiofx.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

namespace pek {

using PostFn = std::function<void(std::function<void()>)>;   // runs a function on the UI (platform) thread

class Mpv {
 public:
  Mpv(flutter::TextureRegistrar* textures, PostFn post, std::wstring dllDir);
  ~Mpv();

  // Starts libmpv and registers the Flutter texture (once). Returns the texture id, or -1 when libmpv could not be loaded.
  int64_t Surface();
  // "" = started, otherwise a message fit to show.
  std::string Load(const std::string& url, double startSec, const std::string& title, const std::string& dvdDevice);
  void Command(const std::vector<std::string>& args);
  void SetMpvProp(const std::string& name, const std::string& value);
  void Stop();
  void SetSink(std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink);
  void Shutdown();

  // Refresh-rate matching. [fn] is called with the frame rate of the video as soon as mpv knows it (container-fps), and with 0 when
  // the file ends or is stopped. Called on mpv's event thread: the receiver hands the work to the UI thread. Set it before Surface().
  // Audio-only files (and a song's embedded cover) never report a rate.
  void SetFpsCallback(std::function<void(double)> fn) { onFps_ = std::move(fn); }

  // Media keys for a film. [fn](playing, buffering, positionSec, durationSec) is called when play / pause / buffering changes and when the
  // position jumps (a seek); between those Windows moves the tile's clock by itself. Called on mpv's event thread or the UI thread:
  // the receiver hands the work to the UI thread. Set it before Surface().
  void SetMediaCallback(std::function<void(bool, bool, double, double)> fn) { onMedia_ = std::move(fn); }

  // HDR. The picture reaches Flutter as an 8-bit texture, so HDR10 / HLG / PQ video cannot go to the screen untouched like on Android:
  // with this on, HDR video is tone-mapped to SDR (otherwise it looks grey and dull). Applies at once, also to the video now playing.
  void SetHdr(bool on);
  bool Hdr() const { return hdrOn_; }
  // Does Windows report an HDR-capable screen? (DisplayConfig "advanced colour" support; informational.)
  static bool DisplayHdr();

  // Rendering. false = the processor draws every frame (libmpv "sw" renderer, software decoding). true = the graphics card draws it
  // (libmpv OpenGL renderer on a hidden WGL context, hardware decoding with copy-back, mpv's own shader tone mapping); the finished
  // frame is read back into the pixel buffer Flutter shows. Applies to the next video. If the GPU renderer cannot start, the processor
  // is used and GpuNote() says why.
  void SetRenderer(bool gpu);
  bool WantGpu() const { return wantGpu_; }
  bool ActiveGpu() const { return activeGpu_; }
  std::string GpuNote();
  // Biggest picture handed to Flutter. 0 = Auto (the size of the screen the window is on, never more than the video itself; on the CPU
  // renderer never more than 1920 x 1080), 1 = 1080p, 2 = 1440p, 3 = 4K. A video is only ever scaled down to it, never up.
  void SetMaxSize(int mode);
  int MaxSize() const { return maxMode_; }
  void SetScreen(int w, int h);   // the screen the window is on, for Auto (the host calls it before each video)
  void SetGlFlip(bool flip) { glFlip_ = flip ? 1 : 0; }   // escape hatch if a driver shows the GPU picture upside down

  // Sound settings (Settings > Playback > Sound / Equalizer): audio delay, volume boost, night mode, dialogue boost, bass / treble,
  // the ten-band equalizer and a stereo downmix, as the JSON audio_fx.dart sends. Kept here (the host saves AudioFxJson() between runs)
  // and applied to mpv at once, also to what is playing now; before libmpv is started they are applied when it starts.
  void SetAudioFx(const std::string& json);
  std::string AudioFxJson();

  // Audio output (Settings > Audio output): codecs ("ac3", "eac3", "dts", "dts-hd", "truehd") sent untouched to a receiver. Windows only
  // does this in WASAPI exclusive mode, so exclusive mode is switched on while any codec is on. Applies to the next video.
  // Unknown codec names are dropped. Sound settings do not change passthrough audio (it is not decoded here).
  void SetPassthrough(const std::set<std::string>& codecs);
  std::set<std::string> Passthrough();

 private:
  struct Api;
  void EventLoop();
  void RenderMain(bool wantGpu, std::shared_ptr<std::promise<bool>> ready);
  bool StartRender(bool gpu);
  void StopRender();
  void Emit(const char* event, flutter::EncodableMap data);
  void SendTracks();
  void SendState();
  std::string GetString(const std::string& name);
  void ApplyAudioFx();
  void ApplyPassthrough();
  void ApplyHdr();
  void RefreshToneMap();
  void Cap(bool gpu, int& capW, int& capH) const;
  bool CanToneMap();

  flutter::TextureRegistrar* textures_;
  PostFn post_;
  std::wstring dllDir_;
  std::unique_ptr<Api> api_;
  void* mpv_ = nullptr;
  void* render_ = nullptr;

  std::unique_ptr<flutter::TextureVariant> texture_;
  int64_t textureId_ = -1;
  std::mutex frameMutex_;
  std::vector<uint8_t> front_, back_;
  size_t frameW_ = 0, frameH_ = 0;
  FlutterDesktopPixelBuffer pixelBuffer_{};

  std::atomic<bool> quit_{false};
  std::atomic<int> videoW_{0}, videoH_{0};
  std::mutex wakeMutex_;
  std::condition_variable wake_;
  bool frameWanted_ = false;
  std::thread eventThread_, renderThread_;
  std::function<void(double)> onFps_;
  std::function<void(bool, bool, double, double)> onMedia_;
  void PushMedia();
  std::mutex mediaMutex_;
  double mediaPos_ = 0;                                  // latest time-pos
  double pushedPos_ = 0;                                 // what the tile was last told
  bool pushedPlaying_ = false;
  std::chrono::steady_clock::time_point pushedAt_{};

  std::mutex sinkMutex_;
  std::shared_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
  bool paused_ = false, cacheWait_ = false, loaded_ = false;
  double lastTimeSent_ = -1;
  double duration_ = 0;

  std::atomic<bool> wantGpu_{false}, activeGpu_{false}, renderStop_{false}, gpuFailed_{false};
  std::atomic<int> glFlip_{0};
  std::atomic<int> maxMode_{0}, screenW_{0}, screenH_{0};
  std::mutex noteMutex_;
  std::string gpuNote_;

  std::mutex fxMutex_;
  AudioFx fx_;
  std::set<std::string> passthrough_;

  std::atomic<bool> hdrOn_{true};
  std::mutex hdrMutex_;
  std::string gamma_;                 // video-params/gamma of the file now loaded ("pq" / "hlg" = HDR)
  std::atomic<bool> toneMapActive_{false}; // our tone-map filter chain is set on mpv
  bool toneMapBroken_ = false;        // it did not produce a picture for this file: left off until the next file
  int toneMapCapable_ = -1;           // -1 unknown, 0 libmpv has no zscale / tonemap filter, 1 it has
  std::chrono::steady_clock::time_point toneMapSince_{};
};

}  // namespace pek
