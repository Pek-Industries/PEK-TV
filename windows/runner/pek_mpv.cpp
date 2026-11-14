#include "pek_mpv.h"

#include <windows.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace pek {
namespace {

// ---- the small part of libmpv's C API used here (mpv/client.h, mpv/render.h), declared by hand so the build needs no mpv headers ----
struct mpv_event { int event_id; int error; uint64_t reply_userdata; void* data; };
struct mpv_event_property { const char* name; int format; void* data; };
struct mpv_event_end_file { int reason; int error; };
struct mpv_render_param { int type; void* data; };
enum { MPV_FORMAT_NONE = 0, MPV_FORMAT_STRING = 1, MPV_FORMAT_FLAG = 3, MPV_FORMAT_INT64 = 4, MPV_FORMAT_DOUBLE = 5 };
enum { EV_NONE = 0, EV_SHUTDOWN = 1, EV_END_FILE = 7, EV_FILE_LOADED = 8, EV_PROPERTY_CHANGE = 22 };
enum { RP_API_TYPE = 1, RP_SW_SIZE = 17, RP_SW_FORMAT = 18, RP_SW_STRIDE = 19, RP_SW_POINTER = 20 };
constexpr uint64_t kRenderUpdateFrame = 1;

}  // namespace

struct Mpv::Api {
  HMODULE dll = nullptr;
  void* (*create)() = nullptr;
  int (*initialize)(void*) = nullptr;
  void (*destroy)(void*) = nullptr;
  int (*set_option_string)(void*, const char*, const char*) = nullptr;
  int (*set_property_string)(void*, const char*, const char*) = nullptr;
  char* (*get_property_string)(void*, const char*) = nullptr;
  void (*free_)(void*) = nullptr;
  int (*command)(void*, const char**) = nullptr;
  int (*observe_property)(void*, uint64_t, const char*, int) = nullptr;
  mpv_event* (*wait_event)(void*, double) = nullptr;
  void (*wakeup)(void*) = nullptr;
  int (*render_create)(void**, void*, mpv_render_param*) = nullptr;
  void (*render_set_cb)(void*, void (*)(void*), void*) = nullptr;
  uint64_t (*render_update)(void*) = nullptr;
  int (*render_render)(void*, mpv_render_param*) = nullptr;
  void (*render_free)(void*) = nullptr;

  template <typename T>
  bool Bind(T& fn, const char* name) {
    fn = reinterpret_cast<T>(GetProcAddress(dll, name));
    return fn != nullptr;
  }

  bool Load(const std::wstring& dir) {
    // The exe's folder is searched for libmpv's own dependencies too.
    SetDllDirectoryW(dir.c_str());
    dll = LoadLibraryW((dir + L"\\libmpv-2.dll").c_str());
    if (!dll) dll = LoadLibraryW(L"libmpv-2.dll");
    if (!dll) return false;
    return Bind(create, "mpv_create") && Bind(initialize, "mpv_initialize") && Bind(destroy, "mpv_terminate_destroy") &&
           Bind(set_option_string, "mpv_set_option_string") && Bind(set_property_string, "mpv_set_property_string") &&
           Bind(get_property_string, "mpv_get_property_string") && Bind(free_, "mpv_free") && Bind(command, "mpv_command") &&
           Bind(observe_property, "mpv_observe_property") && Bind(wait_event, "mpv_wait_event") && Bind(wakeup, "mpv_wakeup") &&
           Bind(render_create, "mpv_render_context_create") && Bind(render_set_cb, "mpv_render_context_set_update_callback") &&
           Bind(render_update, "mpv_render_context_update") && Bind(render_render, "mpv_render_context_render") &&
           Bind(render_free, "mpv_render_context_free");
  }
};

Mpv::Mpv(flutter::TextureRegistrar* textures, PostFn post, std::wstring dllDir)
    : textures_(textures), post_(std::move(post)), dllDir_(std::move(dllDir)) {}

Mpv::~Mpv() { Shutdown(); }

int64_t Mpv::Surface() {
  if (textureId_ >= 0) return textureId_;
  api_ = std::make_unique<Api>();
  if (!api_->Load(dllDir_)) {
    api_.reset();
    return -1;
  }
  mpv_ = api_->create();
  if (!mpv_) return -1;
  api_->set_option_string(mpv_, "vo", "libmpv");
  api_->set_option_string(mpv_, "hwdec", "no");           // software rendering path: copy-back decoding gains nothing here
  api_->set_option_string(mpv_, "keep-open", "no");
  api_->set_option_string(mpv_, "idle", "yes");
  api_->set_option_string(mpv_, "osc", "no");
  api_->set_option_string(mpv_, "input-default-bindings", "no");
  api_->set_option_string(mpv_, "input-vo-keyboard", "no");
  api_->set_option_string(mpv_, "sub-auto", "no");
  api_->set_option_string(mpv_, "terminal", "no");
  api_->set_option_string(mpv_, "demuxer-max-bytes", "64MiB");
  if (api_->initialize(mpv_) < 0) return -1;

  const char* names[] = {"time-pos", "duration", "pause", "paused-for-cache", "track-list", "dwidth", "dheight"};
  const int fmts[] = {MPV_FORMAT_DOUBLE, MPV_FORMAT_DOUBLE, MPV_FORMAT_FLAG, MPV_FORMAT_FLAG, MPV_FORMAT_NONE, MPV_FORMAT_INT64, MPV_FORMAT_INT64};
  for (int i = 0; i < 7; i++) api_->observe_property(mpv_, static_cast<uint64_t>(i + 1), names[i], fmts[i]);

  mpv_render_param params[] = {{RP_API_TYPE, const_cast<char*>("sw")}, {0, nullptr}};
  if (api_->render_create(&render_, mpv_, params) < 0) return -1;
  api_->render_set_cb(render_, [](void* self) {
    auto* m = static_cast<Mpv*>(self);
    std::lock_guard<std::mutex> lock(m->wakeMutex_);
    m->frameWanted_ = true;
    m->wake_.notify_one();
  }, this);

  texture_ = std::make_unique<flutter::TextureVariant>(flutter::PixelBufferTexture([this](size_t, size_t) -> const FlutterDesktopPixelBuffer* {
    std::lock_guard<std::mutex> lock(frameMutex_);
    if (front_.empty()) return nullptr;
    pixelBuffer_.buffer = front_.data();
    pixelBuffer_.width = frameW_;
    pixelBuffer_.height = frameH_;
    pixelBuffer_.release_callback = nullptr;
    pixelBuffer_.release_context = nullptr;
    return &pixelBuffer_;
  }));
  textureId_ = textures_->RegisterTexture(texture_.get());

  eventThread_ = std::thread([this] { EventLoop(); });
  renderThread_ = std::thread([this] { RenderLoop(); });
  return textureId_;
}

std::string Mpv::GetString(const std::string& name) {
  if (!mpv_) return "";
  char* v = api_->get_property_string(mpv_, name.c_str());
  if (!v) return "";
  std::string s = v;
  api_->free_(v);
  return s;
}

std::string Mpv::Load(const std::string& url, double startSec, const std::string& title, const std::string& dvdDevice) {
  if (Surface() < 0) return "Video playback is not available in this build (libmpv-2.dll is missing).";
  loaded_ = false;
  paused_ = false;
  duration_ = 0;
  lastTimeSent_ = -1;
  videoW_ = 0;
  videoH_ = 0;
  if (!dvdDevice.empty()) api_->set_property_string(mpv_, "dvd-device", dvdDevice.c_str());
  char start[48];
  snprintf(start, sizeof start, "%.3f", startSec > 0 ? startSec : 0.0);
  api_->set_property_string(mpv_, "start", start);
  api_->set_property_string(mpv_, "pause", "no");
  api_->set_property_string(mpv_, "force-media-title", title.c_str());
  api_->set_property_string(mpv_, "sid", "auto");
  api_->set_property_string(mpv_, "aid", "auto");
  const char* cmd[] = {"loadfile", url.c_str(), "replace", nullptr};
  int rc = api_->command(mpv_, cmd);
  SendState();
  return rc < 0 ? "The file could not be opened." : "";
}

void Mpv::Command(const std::vector<std::string>& args) {
  if (!mpv_ || args.empty()) return;
  std::vector<const char*> argv;
  for (const auto& a : args) argv.push_back(a.c_str());
  argv.push_back(nullptr);
  api_->command(mpv_, argv.data());
}

void Mpv::SetProp(const std::string& name, const std::string& value) {
  if (mpv_) api_->set_property_string(mpv_, name.c_str(), value.c_str());
}

void Mpv::Stop() {
  Command({"stop"});
  std::lock_guard<std::mutex> lock(frameMutex_);
  std::fill(front_.begin(), front_.end(), 0);   // the last picture must not stay on screen
  if (textureId_ >= 0) textures_->MarkTextureFrameAvailable(textureId_);
}

void Mpv::SetSink(std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink) {
  std::lock_guard<std::mutex> lock(sinkMutex_);
  sink_ = std::move(sink);
}

void Mpv::Emit(const char* event, flutter::EncodableMap data) {
  post_([this, event = std::string(event), data = std::move(data)]() mutable {
    std::shared_ptr<flutter::EventSink<flutter::EncodableValue>> s;
    {
      std::lock_guard<std::mutex> lock(sinkMutex_);
      s = sink_;
    }
    if (!s) return;
    flutter::EncodableMap m;
    m[flutter::EncodableValue("event")] = flutter::EncodableValue(event);
    m[flutter::EncodableValue("data")] = flutter::EncodableValue(std::move(data));
    s->Success(flutter::EncodableValue(std::move(m)));
  });
}

void Mpv::SendState() {
  flutter::EncodableMap d;
  d[flutter::EncodableValue("playing")] = flutter::EncodableValue(!paused_);
  d[flutter::EncodableValue("buffering")] = flutter::EncodableValue(cacheWait_ || !loaded_);
  Emit("state", std::move(d));
}

void Mpv::SendTracks() {
  flutter::EncodableList audio, subs, chapters;
  int n = atoi(GetString("track-list/count").c_str());
  for (int i = 0; i < n; i++) {
    const std::string p = "track-list/" + std::to_string(i) + "/";
    const std::string type = GetString(p + "type");
    if (type != "audio" && type != "sub") continue;
    int id = atoi(GetString(p + "id").c_str());
    std::string label = GetString(p + "title");
    const std::string lang = GetString(p + "lang");
    if (label.empty()) label = lang.empty() ? (type == "audio" ? "Audio " : "Subtitle ") + std::to_string(id) : lang;
    else if (!lang.empty()) label += " (" + lang + ")";
    flutter::EncodableMap t;
    t[flutter::EncodableValue("id")] = flutter::EncodableValue(id);
    t[flutter::EncodableValue("label")] = flutter::EncodableValue(label);
    t[flutter::EncodableValue("selected")] = flutter::EncodableValue(GetString(p + "selected") == "yes");
    (type == "audio" ? audio : subs).push_back(flutter::EncodableValue(std::move(t)));
  }
  int nc = atoi(GetString("chapter-list/count").c_str());
  for (int i = 0; i < nc; i++) {
    const std::string p = "chapter-list/" + std::to_string(i) + "/";
    flutter::EncodableMap c;
    c[flutter::EncodableValue("title")] = flutter::EncodableValue(GetString(p + "title"));
    c[flutter::EncodableValue("time")] = flutter::EncodableValue(strtod(GetString(p + "time").c_str(), nullptr));
    chapters.push_back(flutter::EncodableValue(std::move(c)));
  }
  flutter::EncodableMap d;
  d[flutter::EncodableValue("audio")] = flutter::EncodableValue(std::move(audio));
  d[flutter::EncodableValue("subtitles")] = flutter::EncodableValue(std::move(subs));
  d[flutter::EncodableValue("chapters")] = flutter::EncodableValue(std::move(chapters));
  Emit("tracks", std::move(d));
}

void Mpv::EventLoop() {
  while (!quit_) {
    mpv_event* e = api_->wait_event(mpv_, 0.2);
    if (!e || e->event_id == EV_NONE) continue;
    if (e->event_id == EV_SHUTDOWN) break;
    if (e->event_id == EV_FILE_LOADED) {
      loaded_ = true;
      SendState();
      SendTracks();
    } else if (e->event_id == EV_END_FILE) {
      auto* ef = static_cast<mpv_event_end_file*>(e->data);
      if (ef && ef->reason == 0) Emit("ended", {});
      else if (ef && ef->reason == 4) Emit("error", {});
    } else if (e->event_id == EV_PROPERTY_CHANGE) {
      auto* p = static_cast<mpv_event_property*>(e->data);
      if (!p || !p->name) continue;
      const std::string name = p->name;
      if (name == "time-pos" && p->format == MPV_FORMAT_DOUBLE && p->data) {
        double t = *static_cast<double*>(p->data);
        if (lastTimeSent_ < 0 || t - lastTimeSent_ >= 0.25 || t < lastTimeSent_) {
          lastTimeSent_ = t;
          flutter::EncodableMap d;
          d[flutter::EncodableValue("position")] = flutter::EncodableValue(t);
          d[flutter::EncodableValue("duration")] = flutter::EncodableValue(duration_);
          Emit("time", std::move(d));
        }
      } else if (name == "duration" && p->format == MPV_FORMAT_DOUBLE && p->data) {
        duration_ = *static_cast<double*>(p->data);
      } else if (name == "pause" && p->format == MPV_FORMAT_FLAG && p->data) {
        paused_ = *static_cast<int*>(p->data) != 0;
        SendState();
      } else if (name == "paused-for-cache" && p->format == MPV_FORMAT_FLAG && p->data) {
        cacheWait_ = *static_cast<int*>(p->data) != 0;
        SendState();
      } else if (name == "track-list") {
        if (loaded_) SendTracks();
      } else if ((name == "dwidth" || name == "dheight") && p->format == MPV_FORMAT_INT64 && p->data) {
        (name == "dwidth" ? videoW_ : videoH_) = static_cast<int>(*static_cast<int64_t*>(p->data));
        if (videoW_ > 0 && videoH_ > 0) {
          flutter::EncodableMap d;
          d[flutter::EncodableValue("width")] = flutter::EncodableValue(videoW_.load());
          d[flutter::EncodableValue("height")] = flutter::EncodableValue(videoH_.load());
          Emit("size", std::move(d));
        }
      }
    }
  }
}

void Mpv::RenderLoop() {
  while (!quit_) {
    {
      std::unique_lock<std::mutex> lock(wakeMutex_);
      wake_.wait_for(lock, std::chrono::milliseconds(200), [this] { return frameWanted_ || quit_; });
      frameWanted_ = false;
    }
    if (quit_) break;
    if (!(api_->render_update(render_) & kRenderUpdateFrame)) continue;
    // Render at the picture's own size, but never bigger than 1920 x 1080: the software renderer's cost grows with the area.
    int w = videoW_ > 0 ? videoW_.load() : 1280, h = videoH_ > 0 ? videoH_.load() : 720;
    if (w > 1920 || h > 1080) {
      double k = std::min(1920.0 / w, 1080.0 / h);
      w = std::max(2, static_cast<int>(w * k));
      h = std::max(2, static_cast<int>(h * k));
    }
    w &= ~1;
    h &= ~1;
    back_.resize(static_cast<size_t>(w) * h * 4);
    int size[2] = {w, h};
    size_t stride = static_cast<size_t>(w) * 4;
    mpv_render_param rp[] = {{RP_SW_SIZE, size}, {RP_SW_FORMAT, const_cast<char*>("rgb0")}, {RP_SW_STRIDE, &stride}, {RP_SW_POINTER, back_.data()}, {0, nullptr}};
    if (api_->render_render(render_, rp) < 0) continue;
    for (size_t i = 3; i < back_.size(); i += 4) back_[i] = 0xFF;   // "rgb0" leaves the 4th byte empty; Flutter reads RGBA
    {
      std::lock_guard<std::mutex> lock(frameMutex_);
      front_.swap(back_);
      frameW_ = static_cast<size_t>(w);
      frameH_ = static_cast<size_t>(h);
    }
    textures_->MarkTextureFrameAvailable(textureId_);
  }
}

void Mpv::Shutdown() {
  if (quit_.exchange(true)) return;
  if (mpv_ && api_) api_->wakeup(mpv_);
  wake_.notify_all();
  if (eventThread_.joinable()) eventThread_.join();
  if (renderThread_.joinable()) renderThread_.join();
  if (render_ && api_) api_->render_free(render_);
  if (mpv_ && api_) api_->destroy(mpv_);
  render_ = nullptr;
  mpv_ = nullptr;
  if (textureId_ >= 0) textures_->UnregisterTexture(textureId_);
  textureId_ = -1;
}

}  // namespace pek
