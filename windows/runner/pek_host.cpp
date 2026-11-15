#include "pek_host.h"

#include <bcrypt.h>
#include <commdlg.h>
#include <shellapi.h>
#include <sapi.h>

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <iterator>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "pek_mpv.h"

namespace fs = std::filesystem;
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Call = flutter::MethodCall<EncodableValue>;
using Result = flutter::MethodResult<EncodableValue>;

namespace pek {
namespace {

constexpr UINT kRunMsg = WM_APP + 41;

// When LoadLibrary fails with "module not found" (126) the error does not say WHICH dependency is missing. Map the DLL without
// resolving its imports, walk its import table and try each name: the ones that do not load are what the person (or CI) must ship.
std::string MissingImports(const fs::path& dll) {
  std::string out;
  HMODULE m = LoadLibraryExW(dll.c_str(), nullptr, DONT_RESOLVE_DLL_REFERENCES);
  if (!m) return out;
  auto base = reinterpret_cast<BYTE*>(reinterpret_cast<uintptr_t>(m) & ~static_cast<uintptr_t>(3));
  auto dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
  if (dos->e_magic == IMAGE_DOS_SIGNATURE) {
    auto nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    const IMAGE_DATA_DIRECTORY& dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (dir.VirtualAddress) {
      for (auto d = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(base + dir.VirtualAddress); d->Name; ++d) {
        const char* name = reinterpret_cast<const char*>(base + d->Name);
        HMODULE h = LoadLibraryA(name);
        if (h) FreeLibrary(h);
        else out += (out.empty() ? "" : ", ") + std::string(name);
      }
    }
  }
  FreeLibrary(m);
  return out;
}

// ---------------------------------------------------------------- small helpers
std::string Utf8(const std::wstring& w) {
  if (w.empty()) return "";
  int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
  std::string s(static_cast<size_t>(n), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), &s[0], n, nullptr, nullptr);
  return s;
}

std::wstring Wide(const std::string& s) {
  if (s.empty()) return L"";
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), &w[0], n);
  return w;
}

std::wstring EnvW(const wchar_t* name) {
  wchar_t buf[2048];
  DWORD n = GetEnvironmentVariableW(name, buf, 2048);
  return (n > 0 && n < 2048) ? std::wstring(buf, n) : L"";
}

const EncodableMap* Args(const Call& c) { return std::get_if<EncodableMap>(c.arguments()); }

std::string Str(const EncodableMap* m, const char* key) {
  if (!m) return "";
  auto it = m->find(EncodableValue(key));
  if (it == m->end()) return "";
  const auto* s = std::get_if<std::string>(&it->second);
  return s ? *s : "";
}

double Num(const EncodableMap* m, const char* key, double dflt = 0) {
  if (!m) return dflt;
  auto it = m->find(EncodableValue(key));
  if (it == m->end()) return dflt;
  if (const auto* i = std::get_if<int32_t>(&it->second)) return *i;
  if (const auto* l = std::get_if<int64_t>(&it->second)) return static_cast<double>(*l);
  if (const auto* d = std::get_if<double>(&it->second)) return *d;
  return dflt;
}

bool Flag(const EncodableMap* m, const char* key, bool dflt = false) {
  if (!m) return dflt;
  auto it = m->find(EncodableValue(key));
  if (it == m->end()) return dflt;
  const auto* b = std::get_if<bool>(&it->second);
  return b ? *b : dflt;
}

EncodableValue Null() { return EncodableValue(); }

// Only web pages and e-mail addresses are ever handed to the system (never a file path or a program).
bool OpenWithSystem(const std::string& url, bool allowMailto) {
  const bool ok = url.rfind("https://", 0) == 0 || (allowMailto && url.rfind("mailto:", 0) == 0);
  if (!ok || url.size() > 4096) return false;
  return reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", Wide(url).c_str(), nullptr, nullptr, SW_SHOWNORMAL)) > 32;
}

std::string RandomHex(size_t bytes) {
  std::vector<unsigned char> b(bytes);
  if (BCryptGenRandom(nullptr, b.data(), static_cast<ULONG>(b.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
    for (auto& x : b) x = static_cast<unsigned char>(rand());
  }
  static const char* d = "0123456789abcdef";
  std::string s;
  for (unsigned char c : b) { s += d[c >> 4]; s += d[c & 15]; }
  return s;
}

std::vector<int> VersionParts(const std::string& v) {
  std::vector<int> out;
  size_t i = 0;
  while (i < v.size() && (v[i] == 'v' || v[i] == 'V')) i++;
  while (i < v.size()) {
    int n = 0;
    while (i < v.size() && isdigit(static_cast<unsigned char>(v[i]))) n = n * 10 + (v[i++] - '0');
    out.push_back(n);
    while (i < v.size() && !isdigit(static_cast<unsigned char>(v[i]))) i++;
  }
  return out;
}

bool NewerThan(const std::string& a, const std::string& b) {
  auto x = VersionParts(a), y = VersionParts(b);
  for (size_t i = 0; i < std::max(x.size(), y.size()); i++) {
    int d = (i < x.size() ? x[i] : 0) - (i < y.size() ? y[i] : 0);
    if (d != 0) return d > 0;
  }
  return false;
}

std::string ManifestVersion(const fs::path& manifest) {
  std::ifstream in(manifest, std::ios::binary);
  std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  size_t k = text.find("\"version\"");
  if (k == std::string::npos) return "";
  size_t q1 = text.find('"', text.find(':', k) + 1);
  size_t q2 = q1 == std::string::npos ? q1 : text.find('"', q1 + 1);
  return q2 == std::string::npos ? "" : text.substr(q1 + 1, q2 - q1 - 1);
}

std::string ReadSmall(const fs::path& p) {
  std::ifstream in(p, std::ios::binary);
  std::string s((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  while (!s.empty() && (s.back() == '\n' || s.back() == '\r' || s.back() == ' ')) s.pop_back();
  return s;
}

// ---------------------------------------------------------------- the host
class Host {
 public:
  Host(flutter::PluginRegistrarWindows* reg, HWND top) : reg_(reg), top_(top) {}

  void Start();
  void Stop();

 private:
  // --- thread hop ---
  void Post(std::function<void()> fn) {
    {
      std::lock_guard<std::mutex> l(qMutex_);
      queue_.push_back(std::move(fn));
    }
    PostMessageW(msgWnd_, kRunMsg, 0, 0);
  }
  static LRESULT CALLBACK MsgProc(HWND h, UINT m, WPARAM w, LPARAM l);
  void Drain() {
    for (;;) {
      std::function<void()> fn;
      {
        std::lock_guard<std::mutex> l(qMutex_);
        if (queue_.empty()) return;
        fn = std::move(queue_.front());
        queue_.pop_front();
      }
      fn();
    }
  }

  // --- start-up work (Boot.kt) ---
  void Boot();
  void BootFail(const std::string& why);
  void CopyBuiltIns();
  void StartPython();
  void PythonReader();
  void PythonCall(const std::string& json, std::shared_ptr<Result> result);

  // --- channels ---
  void RegisterHost();
  void RegisterPlugins();
  void RegisterMpv();
  void LoadOutputPrefs();
  void SaveOutputPrefs();
  void RegisterMisc();
  void Speak(const std::string& text, std::shared_ptr<Result> result);
  bool MicAllowed();
  void InstallVoice(const std::string& dir, const std::string& version, std::shared_ptr<Result> result);
  EncodableValue PickFile(const std::string& ext);
  std::string InstallUpdate(const std::string& path);

  template <typename F>
  void Handle(const char* name, F fn) {
    auto ch = std::make_unique<flutter::MethodChannel<EncodableValue>>(reg_->messenger(), name, &flutter::StandardMethodCodec::GetInstance());
    ch->SetMethodCallHandler(fn);
    channels_.push_back(std::move(ch));
  }

  flutter::PluginRegistrarWindows* reg_;
  HWND top_;
  HWND msgWnd_ = nullptr;
  std::mutex qMutex_;
  std::deque<std::function<void()>> queue_;
  std::vector<std::unique_ptr<flutter::MethodChannel<EncodableValue>>> channels_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> events_;
  std::unique_ptr<Mpv> mpv_;

  fs::path exeDir_, root_, cache_;
  std::string token_;
  HMODULE server_ = nullptr;
  const char* (*mintGrant_)() = nullptr;
  std::string audioFx_ = "{}";
  fs::path prefsFile_;   // small settings kept between runs (HDR on / off)
  std::mutex bootMutex_;
  std::string bootError_;   // why the server did not start ("" = fine / not known yet); read by pek/host bootStatus

  // python host
  HANDLE pyProc_ = nullptr, pyIn_ = nullptr, pyOut_ = nullptr;
  std::mutex pyMutex_;
  std::map<long, std::shared_ptr<Result>> pending_;
  std::atomic<long> nextId_{1};
  std::atomic<bool> pyReady_{false};
};

Host* g_host = nullptr;

LRESULT CALLBACK Host::MsgProc(HWND h, UINT m, WPARAM w, LPARAM l) {
  if (m == kRunMsg && g_host) {
    g_host->Drain();
    return 0;
  }
  return DefWindowProcW(h, m, w, l);
}

void Host::Start() {
  g_host = this;
  WNDCLASSW wc{};
  wc.lpfnWndProc = MsgProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"PekHostMsg";
  RegisterClassW(&wc);
  msgWnd_ = CreateWindowExW(0, L"PekHostMsg", L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, wc.hInstance, nullptr);

  wchar_t exe[MAX_PATH];
  GetModuleFileNameW(nullptr, exe, MAX_PATH);
  exeDir_ = fs::path(exe).parent_path();
  std::wstring local = EnvW(L"LOCALAPPDATA");
  fs::path base = (local.empty() ? exeDir_ : fs::path(local)) / L"PEK TV";
  root_ = base / L"hesper";
  cache_ = base / L"cache";
  std::error_code ec;
  fs::create_directories(root_, ec);
  fs::create_directories(cache_, ec);
  token_ = RandomHex(32);

  mpv_ = std::make_unique<Mpv>(reg_->texture_registrar(), [this](std::function<void()> fn) { Post(std::move(fn)); }, exeDir_.wstring());

  prefsFile_ = base / L"output.ini";
  LoadOutputPrefs();

  RegisterHost();
  RegisterPlugins();
  RegisterMpv();
  RegisterMisc();

  std::thread([this] { Boot(); }).detach();   // while the first Flutter frame loads, like Boot.kt behind the splash video
}

void Host::Stop() {
  if (pyProc_) {
    TerminateProcess(pyProc_, 0);
    CloseHandle(pyProc_);
    pyProc_ = nullptr;
  }
  if (mpv_) mpv_->Shutdown();
}

// ---------------------------------------------------------------- Boot: built-in files, server, plugins
void Host::CopyBuiltIns() {
  const fs::path src = exeDir_ / "hesper";
  std::error_code ec;
  if (!fs::is_directory(src, ec)) return;
  const std::string stamp = ReadSmall(src / ".build_stamp");
  const fs::path marker = root_ / ".assets_stamp";
  if (!stamp.empty() && ReadSmall(marker) == stamp && fs::is_directory(root_ / "plugins", ec)) return;

  // A built-in plugin that the PEK Store updated to a NEWER version is left alone (same rule as Boot.kt).
  static const char* stock[] = {"weather", "tmdb-discover", "skin-maker"};
  fs::create_directories(root_ / "plugins", ec);
  for (const auto& e : fs::directory_iterator(src / "plugins", ec)) {
    const std::string id = e.path().filename().string();
    const fs::path dst = root_ / "plugins" / id;
    bool isStock = false;
    for (const char* s : stock) isStock = isStock || id == s;
    if (isStock && fs::is_directory(dst, ec) && NewerThan(ManifestVersion(dst / "plugin.json"), ManifestVersion(e.path() / "plugin.json"))) continue;
    fs::copy(e.path(), dst, fs::copy_options::recursive | fs::copy_options::overwrite_existing, ec);
  }
  fs::copy(src / "skins", root_ / "skins", fs::copy_options::recursive | fs::copy_options::overwrite_existing, ec);
  fs::copy_file(src / "cacert.pem", root_ / "cacert.pem", fs::copy_options::overwrite_existing, ec);
  if (!stamp.empty()) { std::ofstream(marker, std::ios::trunc) << stamp; }
}

void Host::BootFail(const std::string& why) {
  {
    std::lock_guard<std::mutex> l(bootMutex_);
    bootError_ = why;
  }
  std::ofstream(root_ / "boot.log", std::ios::app) << why << "\r\n";
}

void Host::Boot() {
  std::error_code ec;
  fs::remove(root_ / "boot.log", ec);
  CopyBuiltIns();

  // The server DLL and everything it needs sit next to the exe; look there first, whatever the working directory is.
  SetDllDirectoryW(exeDir_.c_str());
  const fs::path dll = exeDir_ / "pek_server.dll";
  if (!fs::exists(dll, ec)) {
    BootFail("pek_server.dll is not next to pek_tv.exe (" + Utf8(dll.wstring()) + "). The install is incomplete, or antivirus removed it.");
    return;
  }
  server_ = LoadLibraryExW(dll.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
  if (!server_) {
    const DWORD err = GetLastError();
    const std::string missing = MissingImports(dll);
    std::string why = "Windows could not load pek_server.dll (error " + std::to_string(err) + ").";
    if (!missing.empty()) why += " It needs these files, which are missing: " + missing + ".";
    else if (err == 193) why += " It was built for a different CPU type than this app.";
    BootFail(why);
    return;
  }
  using StartFn = int (*)(const char*, const char*, const char*);
  auto start = reinterpret_cast<StartFn>(GetProcAddress(server_, "pek_start"));
  mintGrant_ = reinterpret_cast<const char* (*)()>(GetProcAddress(server_, "pek_mint_grant"));
  if (!start) {
    BootFail("pek_server.dll loaded but has no pek_start function (wrong or damaged DLL).");
    return;
  }
  fs::path ffprobe = exeDir_ / "ffprobe.exe";
  const std::string rootUtf8 = Utf8(root_.generic_wstring());
  const std::string ffprobeUtf8 = fs::exists(ffprobe, ec) ? Utf8(ffprobe.wstring()) : std::string();
  const int rc = start(rootUtf8.c_str(), token_.c_str(), ffprobeUtf8.c_str());
  if (rc < 0) {
    BootFail("Port 8080 is already in use (or reserved by Windows), so the PEK TV server cannot start. Close the program that uses it (a second PEK TV, a dev server, Docker) and try again.");
    return;
  }
  SetEnvironmentVariableW(L"PEK_PORT", L"8080");
  StartPython();
}

void Host::StartPython() {
  std::error_code ec;
  const fs::path py = exeDir_ / "python" / "python.exe";
  const fs::path script = exeDir_ / "python" / "pek" / "pek_host.py";
  if (!fs::exists(py, ec) || !fs::exists(script, ec)) return;

  SECURITY_ATTRIBUTES sa{sizeof sa, nullptr, TRUE};
  HANDLE inR = nullptr, inW = nullptr, outR = nullptr, outW = nullptr;
  if (!CreatePipe(&inR, &inW, &sa, 0) || !CreatePipe(&outR, &outW, &sa, 0)) return;
  SetHandleInformation(inW, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(outR, HANDLE_FLAG_INHERIT, 0);
  HANDLE log = CreateFileW((root_ / "python.log").c_str(), GENERIC_WRITE, FILE_SHARE_READ, &sa, CREATE_ALWAYS, 0, nullptr);

  STARTUPINFOW si{};
  si.cb = sizeof si;
  si.dwFlags = STARTF_USESTDHANDLES;
  si.hStdInput = inR;
  si.hStdOutput = outW;
  si.hStdError = log != INVALID_HANDLE_VALUE ? log : outW;
  std::wstring cmd = L"\"" + py.wstring() + L"\" -u -X utf8 \"" + script.wstring() + L"\" \"" + (root_ / "plugins").wstring() + L"\"";
  PROCESS_INFORMATION pi{};
  BOOL ok = CreateProcessW(nullptr, &cmd[0], nullptr, nullptr, TRUE, CREATE_NO_WINDOW, nullptr, exeDir_.c_str(), &si, &pi);
  CloseHandle(inR);
  CloseHandle(outW);
  if (log != INVALID_HANDLE_VALUE) CloseHandle(log);
  if (!ok) { CloseHandle(inW); CloseHandle(outR); return; }
  CloseHandle(pi.hThread);
  pyProc_ = pi.hProcess;
  pyIn_ = inW;
  pyOut_ = outR;
  // The per-launch token goes to Python through the pipe, never through the environment (plugin code could read that).
  const std::string hello = "T " + token_ + "\n";
  DWORD w = 0;
  WriteFile(pyIn_, hello.data(), static_cast<DWORD>(hello.size()), &w, nullptr);
  pyReady_ = true;
  std::thread([this] { PythonReader(); }).detach();
}

// Python answers with "R <id> <len>\n<len bytes of UTF-8 JSON>".
void Host::PythonReader() {
  std::string buf;
  char chunk[8192];
  DWORD got = 0;
  for (;;) {
    for (;;) {
      size_t nl = buf.find('\n');
      if (nl == std::string::npos) break;
      long id = 0;
      size_t len = 0;
      if (sscanf(buf.c_str(), "R %ld %zu", &id, &len) != 2) { buf.erase(0, nl + 1); continue; }
      if (buf.size() < nl + 1 + len) break;
      std::string body = buf.substr(nl + 1, len);
      buf.erase(0, nl + 1 + len);
      std::shared_ptr<Result> r;
      {
        std::lock_guard<std::mutex> l(pyMutex_);
        auto it = pending_.find(id);
        if (it != pending_.end()) { r = it->second; pending_.erase(it); }
      }
      if (r) Post([r, body]() { r->Success(EncodableValue(body)); });
    }
    if (!ReadFile(pyOut_, chunk, sizeof chunk, &got, nullptr) || got == 0) break;
    buf.append(chunk, got);
  }
  pyReady_ = false;
  std::vector<std::shared_ptr<Result>> lost;
  {
    std::lock_guard<std::mutex> l(pyMutex_);
    for (auto& kv : pending_) lost.push_back(kv.second);
    pending_.clear();
  }
  for (auto& r : lost) Post([r]() { r->Success(EncodableValue(std::string("{\"ok\":false,\"error\":\"The plugin host stopped.\"}"))); });
}

void Host::PythonCall(const std::string& json, std::shared_ptr<Result> result) {
  if (!pyReady_) {
    Post([result]() { result->Success(EncodableValue(std::string("{\"ok\":false,\"error\":\"Plugins are not available: Python did not start.\"}"))); });
    return;
  }
  const long id = nextId_++;
  {
    std::lock_guard<std::mutex> l(pyMutex_);
    pending_[id] = result;
  }
  const std::string msg = "C " + std::to_string(id) + " " + std::to_string(json.size()) + "\n" + json;
  DWORD w = 0;
  std::lock_guard<std::mutex> l(pyMutex_);
  if (!WriteFile(pyIn_, msg.data(), static_cast<DWORD>(msg.size()), &w, nullptr)) {
    auto it = pending_.find(id);
    if (it != pending_.end()) { pending_.erase(it); Post([result]() { result->Success(EncodableValue(std::string("{\"ok\":false,\"error\":\"The plugin host stopped.\"}"))); }); }
  }
}

// ---------------------------------------------------------------- pek/host
bool Host::MicAllowed() {
  // Windows asks nothing at run time for a desktop app: it only lets the person switch the microphone off in
  // Settings > Privacy & security > Microphone. Respect that switch (and tell voice.dart, which then explains it).
  const wchar_t* key = L"Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone";
  for (HKEY root : {HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER}) {
    wchar_t v[32] = {0};
    DWORD size = sizeof v;
    if (RegGetValueW(root, key, L"Value", RRF_RT_REG_SZ, nullptr, v, &size) == ERROR_SUCCESS && _wcsicmp(v, L"Deny") == 0) return false;
  }
  return true;
}

void Host::InstallVoice(const std::string& dir, const std::string& version, std::shared_ptr<Result> result) {
  std::thread([this, dir, version, result] {
    bool ok = false;
    std::error_code ec;
    const fs::path src = exeDir_ / "voice" / "stt";
    const fs::path out = fs::u8path(dir);
    if (fs::is_directory(src, ec)) {
      ok = true;
      const fs::path marker = out / "stt-ready.json";
      fs::create_directories(out / "stt", ec);
      fs::remove(marker, ec);
      for (const auto& e : fs::directory_iterator(src, ec)) {
        const fs::path part = out / "stt" / (e.path().filename().string() + ".part");
        fs::copy_file(e.path(), part, fs::copy_options::overwrite_existing, ec);
        fs::rename(part, out / "stt" / e.path().filename(), ec);
        if (ec) ok = false;
      }
      if (ok) std::ofstream(marker, std::ios::trunc) << "{\"version\":\"" << version << "\"}";
    }
    Post([result, ok]() { result->Success(EncodableValue(ok)); });
  }).detach();
}

void Host::RegisterHost() {
  Handle("pek/host", [this](const Call& c, std::unique_ptr<Result> r) {
    const std::string& m = c.method_name();
    const EncodableMap* a = Args(c);
    if (m == "micPermission") r->Success(EncodableValue(MicAllowed()));
    else if (m == "installVoice") InstallVoice(Str(a, "dir"), Str(a, "version"), std::shared_ptr<Result>(std::move(r)));
    else if (m == "initialLink") r->Success(Null());
    else if (m == "isPhone") r->Success(EncodableValue(false));
    else if (m == "deviceInfo") {
      wchar_t name[256] = L"";
      DWORD n = 256;
      GetComputerNameExW(ComputerNameDnsHostname, name, &n);
      EncodableMap d;
      d[EncodableValue("type")] = EncodableValue("Windows PC");
      d[EncodableValue("name")] = EncodableValue(n ? Utf8(name) : std::string("Windows PC"));
      r->Success(EncodableValue(d));
    }
    else if (m == "torrentGrant") r->Success(mintGrant_ ? EncodableValue(std::string(mintGrant_())) : Null());
    else if (m == "apiToken") r->Success(EncodableValue(token_));
    else if (m == "bootStatus") {
      std::lock_guard<std::mutex> l(bootMutex_);
      r->Success(EncodableValue(bootError_));
    }
    else if (m == "retryBoot") {   // "Try again" on the server-did-not-start screen
      bool again = false;
      {
        std::lock_guard<std::mutex> l(bootMutex_);
        again = !bootError_.empty();
        bootError_.clear();
      }
      if (again) std::thread([this] { Boot(); }).detach();
      r->Success(Null());
    }
    else if (m == "allFilesAccess") r->Success(EncodableValue(true));   // a desktop app can open any folder the person can
    else if (m == "openAllFilesAccess") r->Success(EncodableValue(true));
    else if (m == "setMulticast") r->Success(Null());
    else if (m == "sendKey") r->Success(EncodableValue(false));
    else if (m == "navSound") r->Success(Null());
    else if (m == "volume") {
      const int dir = static_cast<int>(Num(a, "dir"));
      const BYTE vk = dir > 0 ? VK_VOLUME_UP : dir < 0 ? VK_VOLUME_DOWN : VK_VOLUME_MUTE;
      keybd_event(vk, 0, 0, 0);
      keybd_event(vk, 0, KEYEVENTF_KEYUP, 0);
      r->Success(Null());
    }
    else if (m == "dirs") {
      EncodableMap d;
      d[EncodableValue("files")] = EncodableValue(Utf8(root_.wstring()));
      d[EncodableValue("cache")] = EncodableValue(Utf8(cache_.wstring()));
      r->Success(EncodableValue(d));
    }
    else if (m == "splashReady") r->Success(Null());
    else if (m == "exit") {
      r->Success(Null());
      Stop();
      PostMessageW(top_, WM_CLOSE, 0, 0);
      std::thread([] { Sleep(1500); ExitProcess(0); }).detach();
    }
    else r->NotImplemented();
  });
}

// ---------------------------------------------------------------- pek/plugins
EncodableValue Host::PickFile(const std::string& ext) {
  wchar_t file[MAX_PATH] = L"";
  const std::wstring e = Wide(ext.empty() ? "pek" : ext);
  std::wstring filter = L"*." + e + L";*.zip";
  filter.push_back(L'\0');
  std::wstring spec = L"PEK files (*." + e + L", *.zip)";
  spec.push_back(L'\0');
  std::wstring f = spec + filter + L"All files\0*.*\0";
  f.push_back(L'\0');
  OPENFILENAMEW o{};
  o.lStructSize = sizeof o;
  o.hwndOwner = top_;
  o.lpstrFilter = f.c_str();
  o.lpstrFile = file;
  o.nMaxFile = MAX_PATH;
  o.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
  if (!GetOpenFileNameW(&o)) return Null();
  std::ifstream in(fs::path(file), std::ios::binary);
  std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  EncodableMap d;
  d[EncodableValue("name")] = EncodableValue(Utf8(fs::path(file).filename().wstring()));
  d[EncodableValue("bytes")] = EncodableValue(std::move(bytes));
  return EncodableValue(std::move(d));
}

void Host::RegisterPlugins() {
  Handle("pek/plugins", [this](const Call& c, std::unique_ptr<Result> r) {
    const std::string& m = c.method_name();
    const EncodableMap* a = Args(c);
    if (m == "call") {
      const auto* json = std::get_if<std::string>(c.arguments());
      auto res = std::shared_ptr<Result>(std::move(r));
      std::string body = json ? *json : "{}";
      std::thread([this, body, res] { PythonCall(body, res); }).detach();
    }
    else if (m == "deviceProfile") {
      EncodableMap d;   // nothing known about decoders: plugins then change nothing (same as an unreadable Android profile)
      d[EncodableValue("v")] = EncodableValue(1);
      d[EncodableValue("unknown")] = EncodableValue(true);
      r->Success(EncodableValue(d));
    }
    else if (m == "pickFile") r->Success(PickFile(Str(a, "ext")));
    else if (m == "openUrl") {
      const auto* url = std::get_if<std::string>(c.arguments());
      r->Success(EncodableValue(url ? OpenWithSystem(*url, true) : false));
    }
    else if (m == "openApp") r->Success(EncodableValue(OpenWithSystem(Str(a, "url"), false)));   // no streaming apps to pick: the web page opens
    else r->NotImplemented();
  });
}

// ---------------------------------------------------------------- saved output settings
// false: new installs start on the CPU renderer (the proven path) until GPU rendering has been tried on real PCs. Flip to true to make the
// GPU renderer the default; it still falls back to the CPU by itself on a PC that cannot run it.
constexpr bool kDefaultGpu = false;

void Host::LoadOutputPrefs() {
  bool hdr = true;   // on unless the person switched it off (same default as Android)
  bool gpu = kDefaultGpu, flip = false;
  int maxSize = 0;   // Auto
  std::ifstream in(prefsFile_);
  std::string line;
  while (std::getline(in, line)) {
    if (line.rfind("hdr=", 0) == 0) hdr = line.size() > 4 && line[4] == '1';
    else if (line.rfind("renderer=", 0) == 0) gpu = line.substr(9) == "gpu";
    else if (line.rfind("maxsize=", 0) == 0) {
      const std::string v = line.substr(8);
      maxSize = v == "1080" ? 1 : v == "1440" ? 2 : v == "2160" ? 3 : 0;
    }
    else if (line.rfind("glflip=", 0) == 0) flip = line.size() > 7 && line[7] == '1';   // hand-edited: GPU picture upside down on some driver
  }
  if (mpv_) {
    mpv_->SetHdr(hdr);
    mpv_->SetRenderer(gpu);
    mpv_->SetGlFlip(flip);
    mpv_->SetMaxSize(maxSize);
  }
}

void Host::SaveOutputPrefs() {
  std::vector<std::string> keep;   // lines this code does not own (glflip=...) survive a save
  {
    std::ifstream in(prefsFile_);
    std::string line;
    while (std::getline(in, line))
      if (!line.empty() && line.rfind("hdr=", 0) != 0 && line.rfind("renderer=", 0) != 0 && line.rfind("maxsize=", 0) != 0) keep.push_back(line);
  }
  std::ofstream out(prefsFile_, std::ios::trunc);
  if (!out) return;
  out << "hdr=" << (mpv_ && mpv_->Hdr() ? 1 : 0) << "\n";
  out << "renderer=" << (mpv_ && mpv_->WantGpu() ? "gpu" : "cpu") << "\n";
  static const char* const kSizes[] = {"auto", "1080", "1440", "2160"};
  out << "maxsize=" << kSizes[mpv_ ? mpv_->MaxSize() : 0] << "\n";
  for (const auto& l : keep) out << l << "\n";
}

// ---------------------------------------------------------------- pek/mpv, pek/output
void Host::RegisterMpv() {
  Handle("pek/mpv", [this](const Call& c, std::unique_ptr<Result> r) {
    const std::string& m = c.method_name();
    const EncodableMap* a = Args(c);
    if (m == "surface") {
      int64_t id = mpv_->Surface();
      if (id < 0) r->Error("no_player", "The player could not start (libmpv-2.dll is missing).");
      else r->Success(EncodableValue(id));
      return;
    }
    if (m == "load") {
      {
        // the screen the window is on, for "Maximum picture size: Auto"
        MONITORINFO mi{};
        mi.cbSize = sizeof mi;
        if (GetMonitorInfoW(MonitorFromWindow(top_, MONITOR_DEFAULTTONEAREST), &mi))
          mpv_->SetScreen(mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top);
      }
      std::string err = mpv_->Load(Str(a, "url"), Num(a, "startSec"), Str(a, "title"), Str(a, "dvdDevice"));
      if (!err.empty()) { r->Error("mpv_error", err); return; }
    }
    else if (m == "play") mpv_->SetMpvProp("pause", "no");
    else if (m == "pause") mpv_->SetMpvProp("pause", "yes");
    else if (m == "seek") mpv_->Command({"seek", std::to_string(Num(a, "sec")), "absolute"});
    else if (m == "setAudio") mpv_->SetMpvProp("aid", std::to_string(static_cast<int>(Num(a, "id"))));
    else if (m == "setSubtitle") {
      int id = static_cast<int>(Num(a, "id", -1));
      mpv_->SetMpvProp("sid", id < 0 ? "no" : std::to_string(id));
    }
    else if (m == "addSubtitle") mpv_->Command({"sub-add", Str(a, "url"), "select", Str(a, "label")});
    else if (m == "setMiniRect" || m == "fullscreen") {}   // Dart moves the texture itself (video_surface.dart)
    else if (m == "destroy") mpv_->Stop();
    else { r->NotImplemented(); return; }
    r->Success(Null());
  });

  events_ = std::make_unique<flutter::EventChannel<EncodableValue>>(reg_->messenger(), "pek/mpv/events", &flutter::StandardMethodCodec::GetInstance());
  events_->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
      [this](const EncodableValue*, std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink) -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        mpv_->SetSink(std::move(sink));
        return nullptr;
      },
      [this](const EncodableValue*) -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        mpv_->SetSink(nullptr);
        return nullptr;
      }));

  Handle("pek/output", [this](const Call& c, std::unique_ptr<Result> r) {
    const std::string& m = c.method_name();
    const EncodableMap* a = Args(c);
    if (m == "video") {
      EncodableMap d;
      d[EncodableValue("matchRate")] = EncodableValue(false);
      d[EncodableValue("hdr")] = EncodableValue(mpv_->Hdr());
      d[EncodableValue("displayHdr")] = EncodableValue(Mpv::DisplayHdr());
      d[EncodableValue("renderer")] = EncodableValue(std::string(mpv_->WantGpu() ? "gpu" : "cpu"));        // what the person chose
      d[EncodableValue("rendererActive")] = EncodableValue(std::string(mpv_->ActiveGpu() ? "gpu" : "cpu"));   // what the last video used
      static const char* const kSizes[] = {"auto", "1080", "1440", "2160"};
      d[EncodableValue("maxSize")] = EncodableValue(std::string(kSizes[mpv_->MaxSize()]));
      d[EncodableValue("rendererNote")] = EncodableValue(mpv_->GpuNote());                                    // why the GPU was not used, if so
      d[EncodableValue("hdrMode")] = EncodableValue(std::string("tonemap"));   // Windows shows video as an SDR texture: HDR is tone-mapped, not passed through
      d[EncodableValue("subOverlay")] = EncodableValue(true);
      r->Success(EncodableValue(d));
    }
    else if (m == "audio") {
      EncodableMap d;
      d[EncodableValue("on")] = EncodableValue(EncodableList{});
      d[EncodableValue("known")] = EncodableValue(false);
      d[EncodableValue("formats")] = EncodableValue(EncodableList{});
      r->Success(EncodableValue(d));
    }
    else if (m == "audioFx") r->Success(EncodableValue(audioFx_));
    else if (m == "setAudioFx") { audioFx_ = Str(a, "json"); r->Success(Null()); }
    else if (m == "setHdr") {
      mpv_->SetHdr(Flag(a, "on", true));
      SaveOutputPrefs();
      r->Success(Null());
    }
    else if (m == "setMaxSize") {
      const std::string v = Str(a, "size");
      mpv_->SetMaxSize(v == "1080" ? 1 : v == "1440" ? 2 : v == "2160" ? 3 : 0);
      SaveOutputPrefs();
      r->Success(Null());
    }
    else if (m == "setRenderer") {
      mpv_->SetRenderer(Flag(a, "on", false));
      SaveOutputPrefs();
      r->Success(Null());
    }
    else if (m == "setMatchRate" || m == "setSubOverlay" || m == "setPassthrough") r->Success(Null());
    else r->NotImplemented();
  });
}

// ---------------------------------------------------------------- pek/voice, pek/music, pek/pip, pek/update, pek/discord
void Host::Speak(const std::string& text, std::shared_ptr<Result> result) {
  std::thread([this, text, result] {
    bool ok = false;
    if (SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) {
      ISpVoice* voice = nullptr;
      if (SUCCEEDED(CoCreateInstance(CLSID_SpVoice, nullptr, CLSCTX_ALL, IID_ISpVoice, reinterpret_cast<void**>(&voice))) && voice) {
        ok = SUCCEEDED(voice->Speak(Wide(text).c_str(), SPF_DEFAULT, nullptr));   // returns when it has finished talking
        voice->Release();
      }
      CoUninitialize();
    }
    Post([result, ok]() { result->Success(EncodableValue(ok)); });
  }).detach();
}

std::string Host::InstallUpdate(const std::string& path) {
  std::error_code ec;
  const fs::path zip = fs::weakly_canonical(fs::u8path(path), ec);
  const fs::path cache = fs::weakly_canonical(cache_, ec);
  if (ec || zip.parent_path() != cache || !fs::is_regular_file(zip, ec)) return "The downloaded update file is missing.";
  const fs::path dir = cache / "update";
  fs::remove_all(dir, ec);
  fs::create_directories(dir, ec);
  // Windows 10+ ships tar.exe, which reads zip files. The script waits for this process to end, copies the new files over the
  // install folder and starts the app again.
  const fs::path script = cache / "apply_update.cmd";
  // An installer (PEK-TV-<v>-windows-<arch>-setup.exe) upgrades the installed copy itself; a zip (portable copy) is unpacked
  // and copied over the folder. Either way the script first waits for this process to end. chcp 65001 + UTF-8 paths keep a
  // user name with accents working.
  const bool isSetup = _wcsicmp(zip.extension().c_str(), L".exe") == 0;
  {
    std::ofstream s(script, std::ios::trunc | std::ios::binary);
    s << "@echo off\r\nchcp 65001 >nul\r\n";
    if (!isSetup) s << "tar -xf \"" << Utf8(zip.wstring()) << "\" -C \"" << Utf8(dir.wstring()) << "\"\r\n";
    s << ":wait\r\ntasklist /FI \"PID eq " << GetCurrentProcessId() << "\" 2>nul | find \"" << GetCurrentProcessId() << "\" >nul\r\n"
      << "if not errorlevel 1 (timeout /t 1 /nobreak >nul & goto wait)\r\n";
    if (isSetup) {
      s << "\"" << Utf8(zip.wstring()) << "\" /SILENT /SUPPRESSMSGBOXES /NOCANCEL /NORESTART /relaunch=1\r\n";
    } else {
      s << "robocopy \"" << Utf8(dir.wstring()) << "\" \"" << Utf8(exeDir_.wstring()) << "\" /E /NFL /NDL /NJH /NJS /NP >nul\r\n"
        << "start \"\" \"" << Utf8((exeDir_ / "pek_tv.exe").wstring()) << "\"\r\n";
    }
  }
  STARTUPINFOW si{};
  si.cb = sizeof si;
  PROCESS_INFORMATION pi{};
  std::wstring cmd = L"cmd.exe /c \"\"" + script.wstring() + L"\"\"";
  if (!CreateProcessW(nullptr, &cmd[0], nullptr, nullptr, FALSE, CREATE_NO_WINDOW | DETACHED_PROCESS, nullptr, cache.c_str(), &si, &pi)) return "The updater could not be started.";
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return "";
}

void Host::RegisterMisc() {
  Handle("pek/voice", [this](const Call& c, std::unique_ptr<Result> r) {
    const std::string& m = c.method_name();
    if (m == "available") r->Success(EncodableValue(false));   // no phone recognizer here: voice.dart uses the bundled model
    else if (m == "speak") Speak(Str(Args(c), "text"), std::shared_ptr<Result>(std::move(r)));
    else if (m == "stopSpeak") r->Success(Null());
    else r->NotImplemented();
  });
  Handle("pek/music", [](const Call&, std::unique_ptr<Result> r) { r->Success(Null()); });   // no media notification or widget on the desktop yet
  Handle("pek/pip", [](const Call& c, std::unique_ptr<Result> r) {
    if (c.method_name() == "supported" || c.method_name() == "enter") r->Success(EncodableValue(false));
    else r->Success(Null());
  });
  Handle("pek/update", [this](const Call& c, std::unique_ptr<Result> r) {
    const std::string& m = c.method_name();
    if (m == "info") {
      std::string v = ReadSmall(exeDir_ / "version.txt");
      EncodableMap d;
      d[EncodableValue("versionName")] = EncodableValue(v.empty() ? std::string("0.0.0-dev.local") : v);
      d[EncodableValue("versionCode")] = EncodableValue(0);
      d[EncodableValue("debuggable")] = EncodableValue(false);
      std::error_code ue;
      d[EncodableValue("windowsInstaller")] = EncodableValue(fs::exists(exeDir_ / "unins000.exe", ue));   // made by the Inno Setup installer
#if defined(_M_ARM64)
      d[EncodableValue("windowsArch")] = EncodableValue("arm64");
#else
      d[EncodableValue("windowsArch")] = EncodableValue("x64");
#endif
      r->Success(EncodableValue(d));
    }
    else if (m == "install") {
      std::string err = InstallUpdate(Str(Args(c), "path"));
      if (err.empty()) {
        r->Success(Null());
        PostMessageW(top_, WM_CLOSE, 0, 0);
      } else r->Success(EncodableValue(err));
    }
    else r->Success(Null());
  });
  Handle("pek/discord", [](const Call& c, std::unique_ptr<Result> r) {
    const std::string& m = c.method_name();
    if (m == "available") r->Success(EncodableValue(false));   // the Discord Social SDK build is Android only for now
    else if (m == "openUrl") r->Success(EncodableValue(OpenWithSystem(Str(Args(c), "url"), false)));
    else r->Success(Null());
  });
}

}  // namespace

static std::unique_ptr<Host> g_owner;

void StartHost(flutter::PluginRegistrarWindows* registrar, HWND top) {
  g_owner = std::make_unique<Host>(registrar, top);
  g_owner->Start();
}

void StopHost() {
  if (g_owner) g_owner->Stop();
}

}  // namespace pek
