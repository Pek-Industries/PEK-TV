// The Windows side of the pek/mpv channel: libmpv (libmpv-2.dll next to the exe, loaded at run time) draws each frame in software
// into a pixel buffer that Flutter shows as a texture (Dart: PekVideoSurface). On Android the same engine draws on a surface behind
// Flutter (MpvController.kt); the Dart player screens do not know the difference.
#pragma once
#include <flutter/encodable_value.h>
#include <flutter/event_sink.h>
#include <flutter/texture_registrar.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
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

 private:
  struct Api;
  void EventLoop();
  void RenderLoop();
  void Emit(const char* event, flutter::EncodableMap data);
  void SendTracks();
  void SendState();
  std::string GetString(const std::string& name);

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

  std::mutex sinkMutex_;
  std::shared_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
  bool paused_ = false, cacheWait_ = false, loaded_ = false;
  double lastTimeSent_ = -1;
  double duration_ = 0;
};

}  // namespace pek
