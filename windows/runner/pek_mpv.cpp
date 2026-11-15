#include "pek_mpv.h"

#include <windows.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iterator>

namespace pek {
namespace {

// ---- the small part of libmpv's C API used here (mpv/client.h, mpv/render.h), declared by hand so the build needs no mpv headers ----
struct mpv_event { int event_id; int error; uint64_t reply_userdata; void* data; };
struct mpv_event_property { const char* name; int format; void* data; };
struct mpv_event_end_file { int reason; int error; };
struct mpv_render_param { int type; void* data; };
enum { MPV_FORMAT_NONE = 0, MPV_FORMAT_STRING = 1, MPV_FORMAT_FLAG = 3, MPV_FORMAT_INT64 = 4, MPV_FORMAT_DOUBLE = 5 };
enum { EV_NONE = 0, EV_SHUTDOWN = 1, EV_END_FILE = 7, EV_FILE_LOADED = 8, EV_PROPERTY_CHANGE = 22 };
struct mpv_opengl_init_params { void* (*get_proc_address)(void* ctx, const char* name); void* ctx; };
struct mpv_opengl_fbo { int fbo; int w; int h; int internal_format; };
enum { RP_OPENGL_INIT_PARAMS = 2, RP_OPENGL_FBO = 3, RP_FLIP_Y = 4, RP_BLOCK_FOR_TARGET_TIME = 12 };
enum { RP_API_TYPE = 1, RP_SW_SIZE = 17, RP_SW_FORMAT = 18, RP_SW_STRIDE = 19, RP_SW_POINTER = 20 };
constexpr uint64_t kRenderUpdateFrame = 1;


// ---- OpenGL for the GPU renderer: a hidden window + WGL context made on the render thread. The GL entry points are loaded by name so
// the build needs no GL headers or import libraries beyond opengl32 / gdi32 (see windows/pek_runner.cmake). ----
using GLenum = unsigned int; using GLuint = unsigned int; using GLint = int; using GLsizei = int;
constexpr GLenum kTex2D = 0x0DE1, kRgb8 = 0x8051, kRgb = 0x1907, kRgba = 0x1908, kUByte = 0x1401, kFramebuffer = 0x8D40,
                 kColor0 = 0x8CE0, kPackAlign = 0x0D05, kFbComplete = 0x8CD5, kMinFilter = 0x2801, kMagFilter = 0x2800, kNearest = 0x2600,
                 kVendor = 0x1F00, kRenderer = 0x1F01, kVersion = 0x1F02;

void* GlProc(void*, const char* name) {
  void* p = reinterpret_cast<void*>(wglGetProcAddress(name));
  const uintptr_t v = reinterpret_cast<uintptr_t>(p);
  if (v <= 3 || v == ~static_cast<uintptr_t>(0)) {   // 1.1 functions are exported by opengl32.dll itself, not by wglGetProcAddress
    static HMODULE gl = LoadLibraryW(L"opengl32.dll");
    p = gl ? reinterpret_cast<void*>(GetProcAddress(gl, name)) : nullptr;
  }
  return p;
}

struct GlFns {
  void (APIENTRY* GenTextures)(GLsizei, GLuint*) = nullptr;
  void (APIENTRY* DeleteTextures)(GLsizei, const GLuint*) = nullptr;
  void (APIENTRY* BindTexture)(GLenum, GLuint) = nullptr;
  void (APIENTRY* TexImage2D)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void*) = nullptr;
  void (APIENTRY* TexParameteri)(GLenum, GLenum, GLint) = nullptr;
  void (APIENTRY* GenFramebuffers)(GLsizei, GLuint*) = nullptr;
  void (APIENTRY* DeleteFramebuffers)(GLsizei, const GLuint*) = nullptr;
  void (APIENTRY* BindFramebuffer)(GLenum, GLuint) = nullptr;
  void (APIENTRY* FramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint) = nullptr;
  GLenum (APIENTRY* CheckFramebufferStatus)(GLenum) = nullptr;
  void (APIENTRY* PixelStorei)(GLenum, GLint) = nullptr;
  void (APIENTRY* ReadPixels)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void*) = nullptr;
  const unsigned char* (APIENTRY* GetString)(GLenum) = nullptr;

  template <typename T>
  bool Bind(T& fn, const char* name) { fn = reinterpret_cast<T>(GlProc(nullptr, name)); return fn != nullptr; }
  bool Load() {
    return Bind(GenTextures, "glGenTextures") && Bind(DeleteTextures, "glDeleteTextures") && Bind(BindTexture, "glBindTexture") &&
           Bind(TexImage2D, "glTexImage2D") && Bind(TexParameteri, "glTexParameteri") && Bind(GenFramebuffers, "glGenFramebuffers") &&
           Bind(DeleteFramebuffers, "glDeleteFramebuffers") && Bind(BindFramebuffer, "glBindFramebuffer") &&
           Bind(FramebufferTexture2D, "glFramebufferTexture2D") && Bind(CheckFramebufferStatus, "glCheckFramebufferStatus") &&
           Bind(PixelStorei, "glPixelStorei") && Bind(ReadPixels, "glReadPixels") && Bind(GetString, "glGetString");
  }
};

struct GlContext {
  HWND wnd = nullptr;
  HDC dc = nullptr;
  HGLRC rc = nullptr;

  // Makes a core-profile context (4.3 for compute shaders, else 3.3) current on this thread. false + a reason when the PC cannot.
  bool Create(std::string& err) {
    static const wchar_t* kClass = L"PekGlHidden";
    WNDCLASSW wc{};
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = kClass;
    RegisterClassW(&wc);   // already registered the second time: fine
    wnd = CreateWindowExW(0, kClass, L"", WS_POPUP, 0, 0, 16, 16, nullptr, nullptr, wc.hInstance, nullptr);
    if (!wnd) { err = "could not create the hidden OpenGL window"; return false; }
    dc = GetDC(wnd);
    PIXELFORMATDESCRIPTOR pfd{};
    pfd.nSize = sizeof pfd;
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    const int pf = ChoosePixelFormat(dc, &pfd);
    if (!pf || !SetPixelFormat(dc, pf, &pfd)) { err = "no usable pixel format"; Destroy(); return false; }
    HGLRC legacy = wglCreateContext(dc);
    if (!legacy || !wglMakeCurrent(dc, legacy)) { err = "the graphics driver has no OpenGL"; if (legacy) wglDeleteContext(legacy); Destroy(); return false; }
    using CreateAttribs = HGLRC(WINAPI*)(HDC, HGLRC, const int*);
    auto createAttribs = reinterpret_cast<CreateAttribs>(wglGetProcAddress("wglCreateContextAttribsARB"));
    if (createAttribs) {
      const int versions[2][2] = {{4, 3}, {3, 3}};
      for (const auto& v : versions) {
        const int attribs[] = {0x2091, v[0], 0x2092, v[1], 0x9126, 0x1, 0};   // major, minor, core profile
        rc = createAttribs(dc, nullptr, attribs);
        if (rc) break;
      }
    }
    wglMakeCurrent(nullptr, nullptr);
    wglDeleteContext(legacy);
    if (!rc) { err = "the graphics driver offers no OpenGL 3.3 (on ARM64 Windows install the \"OpenCL, OpenGL and Vulkan Compatibility Pack\")"; Destroy(); return false; }
    if (!wglMakeCurrent(dc, rc)) { err = "could not use the OpenGL context"; Destroy(); return false; }
    GlFns fn;
    if (fn.Load()) {
      const char* renderer = reinterpret_cast<const char*>(fn.GetString(kRenderer));
      const char* vendor = reinterpret_cast<const char*>(fn.GetString(kVendor));
      const char* version = reinterpret_cast<const char*>(fn.GetString(kVersion));
      fprintf(stderr, "PEK gpu: OpenGL %s / %s / %s\n", version ? version : "?", vendor ? vendor : "?", renderer ? renderer : "?");
      if (renderer && strstr(renderer, "GDI Generic")) { err = "Windows only offers its software OpenGL 1.1 here (no graphics driver)"; Destroy(); return false; }
    }
    return true;
  }

  void Destroy() {
    if (rc) { wglMakeCurrent(nullptr, nullptr); wglDeleteContext(rc); rc = nullptr; }
    if (dc && wnd) ReleaseDC(wnd, dc);
    dc = nullptr;
    if (wnd) DestroyWindow(wnd);
    wnd = nullptr;
  }
};

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

  const char* names[] = {"time-pos", "duration", "pause", "paused-for-cache", "track-list", "dwidth", "dheight", "video-params/gamma"};
  const int fmts[] = {MPV_FORMAT_DOUBLE, MPV_FORMAT_DOUBLE, MPV_FORMAT_FLAG, MPV_FORMAT_FLAG, MPV_FORMAT_NONE, MPV_FORMAT_INT64, MPV_FORMAT_INT64, MPV_FORMAT_STRING};
  for (int i = 0; i < 8; i++) api_->observe_property(mpv_, static_cast<uint64_t>(i + 1), names[i], fmts[i]);

  if (!StartRender(wantGpu_ && !gpuFailed_)) return -1;   // the renderer lives on its own thread (a GL context belongs to one thread)

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
  // The CPU / GPU choice applies to the next video: switch the renderer now, before the file opens.
  const bool wantGpu = wantGpu_ && !gpuFailed_;
  if (wantGpu != activeGpu_) {
    StopRender();
    if (!StartRender(wantGpu)) return "The video renderer could not be restarted.";
  }
  loaded_ = false;
  paused_ = false;
  duration_ = 0;
  lastTimeSent_ = -1;
  videoW_ = 0;
  videoH_ = 0;
  {
    std::lock_guard<std::mutex> lock(hdrMutex_);
    gamma_.clear();
    toneMapBroken_ = false;   // a new file gets a fresh try
  }
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

void Mpv::SetMpvProp(const std::string& name, const std::string& value) {
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
    // Safety net: if the tone-map chain was set but no picture ever came out, take it off again (the file then plays untouched).
    if (toneMapActive_ && !cacheWait_ && std::chrono::steady_clock::now() - toneMapSince_ > std::chrono::seconds(8) &&
        GetString("vo-configured") != "yes") {
      fprintf(stderr, "PEK hdr: tone-map chain produced no picture, switching it off for this file\n");
      {
        std::lock_guard<std::mutex> lock(hdrMutex_);
        toneMapBroken_ = true;
      }
      ApplyHdr();
    }
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
      } else if (name == "video-params/gamma") {
        {
          std::lock_guard<std::mutex> lock(hdrMutex_);
          gamma_ = (p->format == MPV_FORMAT_STRING && p->data && *static_cast<char**>(p->data)) ? *static_cast<char**>(p->data) : "";
        }
        ApplyHdr();
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

void Mpv::SetRenderer(bool gpu) {
  wantGpu_ = gpu;
  gpuFailed_ = false;
  std::lock_guard<std::mutex> lock(noteMutex_);
  gpuNote_.clear();
}

std::string Mpv::GpuNote() {
  std::lock_guard<std::mutex> lock(noteMutex_);
  return gpuNote_;
}

bool Mpv::StartRender(bool gpu) {
  auto ready = std::make_shared<std::promise<bool>>();
  std::future<bool> ok = ready->get_future();
  renderStop_ = false;
  renderThread_ = std::thread([this, gpu, ready] { RenderMain(gpu, ready); });
  const bool started = ok.get();
  if (!started && renderThread_.joinable()) renderThread_.join();
  return started;
}

void Mpv::StopRender() {
  if (!renderThread_.joinable()) return;
  renderStop_ = true;
  {
    std::lock_guard<std::mutex> lock(wakeMutex_);
    wake_.notify_all();
  }
  renderThread_.join();
  renderStop_ = false;
}

// Owns one renderer from creation to teardown. Runs on its own thread because a GL context is current on one thread only, and
// mpv_render_context_create / _render / _free all need it. Asked for the GPU and unable: falls back to the processor and says why.
void Mpv::RenderMain(bool wantGpu, std::shared_ptr<std::promise<bool>> ready) {
  GlContext gl;
  GlFns fn;
  bool gpu = false;
  render_ = nullptr;
  if (wantGpu) {
    std::string err;
    if (gl.Create(err) && fn.Load()) {
      mpv_opengl_init_params init{GlProc, nullptr};
      mpv_render_param params[] = {{RP_API_TYPE, const_cast<char*>("opengl")}, {RP_OPENGL_INIT_PARAMS, &init}, {0, nullptr}};
      if (api_->render_create(&render_, mpv_, params) >= 0) gpu = true;
      else { render_ = nullptr; err = "libmpv-2.dll has no OpenGL renderer"; }
    } else if (err.empty()) {
      err = "the OpenGL driver is missing functions";
    }
    if (!gpu) {
      gl.Destroy();
      gpuFailed_ = true;
      std::lock_guard<std::mutex> lock(noteMutex_);
      gpuNote_ = err;
      fprintf(stderr, "PEK gpu: not available (%s), using the processor\n", err.c_str());
    }
  }
  if (!gpu) {
    mpv_render_param params[] = {{RP_API_TYPE, const_cast<char*>("sw")}, {0, nullptr}};
    if (api_->render_create(&render_, mpv_, params) < 0) {
      render_ = nullptr;
      ready->set_value(false);
      return;
    }
  }
  api_->render_set_cb(render_, [](void* self) {
    auto* m = static_cast<Mpv*>(self);
    std::lock_guard<std::mutex> lock(m->wakeMutex_);
    m->frameWanted_ = true;
    m->wake_.notify_one();
  }, this);
  activeGpu_ = gpu;
  // Copy-back hardware decoding (d3d11va-copy, nvdec-copy ...) needs no GL / D3D interop, so it works on any driver. mpv drops to software
  // decoding by itself for a codec the card cannot do.
  api_->set_property_string(mpv_, "hwdec", gpu ? "auto-copy" : "no");
  fprintf(stderr, "PEK video: %s renderer\n", gpu ? "GPU" : "CPU");
  ApplyHdr();
  ready->set_value(true);

  GLuint fbo = 0, tex = 0;
  int fboW = 0, fboH = 0;
  if (gpu) {
    fn.GenTextures(1, &tex);
    fn.GenFramebuffers(1, &fbo);
  }
  while (!quit_ && !renderStop_) {
    {
      std::unique_lock<std::mutex> lock(wakeMutex_);
      wake_.wait_for(lock, std::chrono::milliseconds(200), [this] { return frameWanted_ || quit_ || renderStop_; });
      frameWanted_ = false;
    }
    if (quit_ || renderStop_) break;
    if (!(api_->render_update(render_) & kRenderUpdateFrame)) continue;
    // Render at the picture's own size, but never bigger than the chosen maximum (Settings > Video output > Maximum picture size):
    // reading the frame back and handing it to Flutter costs more the bigger it is (and on the CPU renderer the drawing itself does too).
    int w = videoW_ > 0 ? videoW_.load() : 1280, h = videoH_ > 0 ? videoH_.load() : 720;
    int capW, capH;
    Cap(gpu, capW, capH);
    if (w > capW || h > capH) {
      double k = std::min(static_cast<double>(capW) / w, static_cast<double>(capH) / h);
      w = std::max(2, static_cast<int>(w * k));
      h = std::max(2, static_cast<int>(h * k));
    }
    w &= ~1;
    h &= ~1;
    back_.resize(static_cast<size_t>(w) * h * 4);
    if (gpu) {
      if (w != fboW || h != fboH) {
        fn.BindTexture(kTex2D, tex);
        fn.TexImage2D(kTex2D, 0, kRgb8, w, h, 0, kRgb, kUByte, nullptr);   // RGB: reading it back as RGBA gives alpha = 255
        fn.TexParameteri(kTex2D, kMinFilter, kNearest);
        fn.TexParameteri(kTex2D, kMagFilter, kNearest);
        fn.BindFramebuffer(kFramebuffer, fbo);
        fn.FramebufferTexture2D(kFramebuffer, kColor0, kTex2D, tex, 0);
        if (fn.CheckFramebufferStatus(kFramebuffer) != kFbComplete) fprintf(stderr, "PEK gpu: framebuffer incomplete at %dx%d\n", w, h);
        fboW = w;
        fboH = h;
      }
      fn.BindFramebuffer(kFramebuffer, fbo);
      mpv_opengl_fbo target{static_cast<int>(fbo), w, h, static_cast<int>(kRgb8)};
      int flip = glFlip_.load(), noBlock = 0;
      mpv_render_param rp[] = {{RP_OPENGL_FBO, &target}, {RP_FLIP_Y, &flip}, {RP_BLOCK_FOR_TARGET_TIME, &noBlock}, {0, nullptr}};
      if (api_->render_render(render_, rp) < 0) continue;
      fn.BindFramebuffer(kFramebuffer, fbo);
      fn.PixelStorei(kPackAlign, 1);
      fn.ReadPixels(0, 0, w, h, kRgba, kUByte, back_.data());
    } else {
      int size[2] = {w, h};
      size_t stride = static_cast<size_t>(w) * 4;
      mpv_render_param rp[] = {{RP_SW_SIZE, size}, {RP_SW_FORMAT, const_cast<char*>("rgb0")}, {RP_SW_STRIDE, &stride}, {RP_SW_POINTER, back_.data()}, {0, nullptr}};
      if (api_->render_render(render_, rp) < 0) continue;
      for (size_t i = 3; i < back_.size(); i += 4) back_[i] = 0xFF;   // "rgb0" leaves the 4th byte empty; Flutter reads RGBA
    }
    {
      std::lock_guard<std::mutex> lock(frameMutex_);
      front_.swap(back_);
      frameW_ = static_cast<size_t>(w);
      frameH_ = static_cast<size_t>(h);
    }
    textures_->MarkTextureFrameAvailable(textureId_);
  }

  api_->render_set_cb(render_, nullptr, nullptr);
  if (gpu) {
    fn.BindFramebuffer(kFramebuffer, 0);
    fn.DeleteFramebuffers(1, &fbo);
    fn.DeleteTextures(1, &tex);
  }
  api_->render_free(render_);   // with the GL context still current
  render_ = nullptr;
  gl.Destroy();
}

// ---------------------------------------------------------------- maximum picture size
void Mpv::Cap(bool gpu, int& capW, int& capH) const {
  switch (maxMode_) {
    case 1: capW = 1920; capH = 1080; return;
    case 2: capW = 2560; capH = 1440; return;
    case 3: capW = 3840; capH = 2160; return;
    default: break;
  }
  // Auto: the screen the window is on (1920 x 1080 when it is not known), but not below 1280 x 720 ...
  capW = screenW_ > 0 ? std::max(1280, screenW_.load()) : 1920;
  capH = screenH_ > 0 ? std::max(720, screenH_.load()) : 1080;
  // ... and the CPU renderer is not asked for more than 1080p on its own: software drawing of a bigger picture does not keep up.
  if (!gpu) {
    capW = std::min(capW, 1920);
    capH = std::min(capH, 1080);
  }
}

void Mpv::RefreshToneMap() {
  if (!toneMapActive_) return;
  toneMapActive_ = false;   // the filter chain holds the old width: build it again
  ApplyHdr();
}

void Mpv::SetMaxSize(int mode) {
  maxMode_ = (mode >= 0 && mode <= 3) ? mode : 0;
  if (mpv_) RefreshToneMap();
}

void Mpv::SetScreen(int w, int h) {
  const bool changed = screenW_ != w || screenH_ != h;
  screenW_ = w;
  screenH_ = h;
  if (changed && mpv_ && maxMode_ == 0) RefreshToneMap();
}

// ---------------------------------------------------------------- HDR
namespace {

// Does libmpv-2.dll contain ffmpeg's zscale (libzimg) and tonemap filters? Read from the file itself: a filter that is not there would
// leave the video without a picture, and mpv offers no way to ask for one filter by name.
bool DllHasString(const std::wstring& path, const char* needle) {
  HANDLE f = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f == INVALID_HANDLE_VALUE) return false;
  HANDLE map = CreateFileMappingW(f, nullptr, PAGE_READONLY, 0, 0, nullptr);
  bool found = false;
  if (map) {
    LARGE_INTEGER size{};
    GetFileSizeEx(f, &size);
    const char* data = static_cast<const char*>(MapViewOfFile(map, FILE_MAP_READ, 0, 0, 0));
    if (data) {
      const char* end = data + size.QuadPart;
      std::boyer_moore_horspool_searcher<const char*> searcher(needle, needle + strlen(needle));
      found = std::search(data, end, searcher) != end;
      UnmapViewOfFile(data);
    }
    CloseHandle(map);
  }
  CloseHandle(f);
  return found;
}

}  // namespace

bool Mpv::CanToneMap() {
  if (toneMapCapable_ < 0) {
    const std::wstring dll = dllDir_ + L"\\libmpv-2.dll";
    toneMapCapable_ = (DllHasString(dll, "zscale") && DllHasString(dll, "tonemap")) ? 1 : 0;
    fprintf(stderr, "PEK hdr: libmpv tone-map filters %s\n", toneMapCapable_ ? "present" : "missing");
  }
  return toneMapCapable_ == 1;
}

void Mpv::SetHdr(bool on) {
  hdrOn_ = on;
  if (mpv_) ApplyHdr();
}

// HDR10 / HLG video -> SDR. The software renderer has no tone mapping of its own and would show the PQ / HLG signal as if it were SDR
// (grey, flat). So HDR video gets an ffmpeg filter chain: scale down to the maximum picture width first (the picture is shown no bigger than that
// anyway, and tone mapping in float is expensive), linear light, hable tone map, BT.709 SDR out.
void Mpv::ApplyHdr() {
  if (!mpv_ || !api_) return;
  std::lock_guard<std::mutex> lock(hdrMutex_);   // called from the event thread and from the UI thread (SetHdr)
  if (activeGpu_) {
    // The GPU renderer tone-maps in shaders by itself: no filter chain. "clip" is the untouched look for the switch-off case.
    if (toneMapActive_) { api_->set_property_string(mpv_, "vf", ""); toneMapActive_ = false; }
    api_->set_property_string(mpv_, "tone-mapping", hdrOn_ ? "bt.2390" : "clip");
    return;
  }
  const bool hdrVideo = gamma_ == "pq" || gamma_ == "hlg";
  const bool want = hdrOn_ && hdrVideo && !toneMapBroken_ && CanToneMap();
  if (want == toneMapActive_) return;
  toneMapActive_ = want;
  if (want) {
    int capW, capH;
    Cap(false, capW, capH);
    api_->set_property_string(mpv_, "vf",
        ("lavfi=[scale=w='min(" + std::to_string(capW) + ",iw)':h=-2,zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,"
         "tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p]").c_str());
    toneMapSince_ = std::chrono::steady_clock::now();
  } else {
    api_->set_property_string(mpv_, "vf", "");
  }
  fprintf(stderr, "PEK hdr: gamma=%s tonemap=%s\n", gamma_.c_str(), want ? "on" : "off");
}

// Windows' own answer to "can this screen show HDR": advanced colour support on any active display.
bool Mpv::DisplayHdr() {
  UINT32 np = 0, nm = 0;
  if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &np, &nm) != ERROR_SUCCESS || np == 0) return false;
  std::vector<DISPLAYCONFIG_PATH_INFO> paths(np);
  std::vector<DISPLAYCONFIG_MODE_INFO> modes(nm);
  if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &np, paths.data(), &nm, modes.data(), nullptr) != ERROR_SUCCESS) return false;
  for (UINT32 i = 0; i < np; i++) {
    DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO info{};
    info.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO;
    info.header.size = sizeof(info);
    info.header.adapterId = paths[i].targetInfo.adapterId;
    info.header.id = paths[i].targetInfo.id;
    if (DisplayConfigGetDeviceInfo(&info.header) == ERROR_SUCCESS && info.advancedColorSupported) return true;
  }
  return false;
}

void Mpv::Shutdown() {
  if (quit_.exchange(true)) return;
  if (mpv_ && api_) api_->wakeup(mpv_);
  wake_.notify_all();
  if (eventThread_.joinable()) eventThread_.join();
  if (renderThread_.joinable()) renderThread_.join();   // the render thread frees its own renderer
  if (mpv_ && api_) api_->destroy(mpv_);
  mpv_ = nullptr;
  if (textureId_ >= 0) textures_->UnregisterTexture(textureId_);
  textureId_ = -1;
}

}  // namespace pek
