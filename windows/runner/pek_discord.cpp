#include "pek_discord.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <thread>

namespace pek {
namespace discord {

// 0 off, 1 connecting, 2 ready, 3 error
static std::atomic<int> g_status{0};

#ifdef PEK_DISCORD_SDK   // set by pek_runner.cmake when windows/discord/ holds the Social SDK

#define DISCORDPP_IMPLEMENTATION
#include "discordpp.h"

namespace {
// One lock for every SDK call, the callback pump included. Recursive because the SDK's callbacks (run by the pump while it holds
// the lock) call back into the client.
std::recursive_mutex g_mu;
std::shared_ptr<discordpp::Client> g_client;
std::atomic<bool> g_pumpOn{false};

void StartPump() {
  if (g_pumpOn.exchange(true)) return;
  std::thread([] {
    while (g_pumpOn.load()) {
      {
        std::lock_guard<std::recursive_mutex> lk(g_mu);
        discordpp::RunCallbacks();   // the SDK delivers its callbacks only when this is called
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
  }).detach();
}

// The activity Dart last asked for, kept until clear / disconnect. An update that arrives while the SDK is still connecting (first play
// right after the link, or a reconnect after a token refresh) is not lost: it is sent the moment the status becomes Ready.
struct LastActivity {
  bool has = false;
  std::string details, state;
  int64_t startMs = 0, endMs = 0;
};
LastActivity g_last;

// Caller holds g_mu and has checked that the client is Ready.
void SendActivity(const LastActivity& a) {
  discordpp::Activity activity;
  activity.SetType(discordpp::ActivityTypes::Watching);
  activity.SetDetails(a.details);
  if (!a.state.empty()) activity.SetState(a.state);
  if (a.startMs > 0) {
    discordpp::ActivityTimestamps ts;
    ts.SetStart(static_cast<uint64_t>(a.startMs));   // milliseconds since the Unix epoch, as on Android
    if (a.endMs > a.startMs) ts.SetEnd(static_cast<uint64_t>(a.endMs));
    activity.SetTimestamps(ts);
  }
  g_client->UpdateRichPresence(activity, [](discordpp::ClientResult result) {
    if (!result.Successful()) fprintf(stderr, "PEK Discord: presence update failed\n");
  });
}
}  // namespace

bool Available() { return true; }

void Connect(const std::string& appId, const std::string& token) {
  std::lock_guard<std::recursive_mutex> lk(g_mu);
  const uint64_t id = std::strtoull(appId.c_str(), nullptr, 10);
  if (id == 0 || token.empty()) { g_status = 3; return; }
  if (!g_client) {
    g_client = std::make_shared<discordpp::Client>();
    g_client->SetStatusChangedCallback([](discordpp::Client::Status status, discordpp::Client::Error error, int32_t /*detail*/) {
      if (status == discordpp::Client::Status::Ready) {
        g_status = 2;
        if (g_client && g_last.has) SendActivity(g_last);   // an update that came in while connecting
      }
      else if (status == discordpp::Client::Status::Disconnected) g_status = (error == discordpp::Client::Error::None) ? 0 : 3;
      else g_status = 1;
      fprintf(stderr, "PEK Discord: status %d\n", g_status.load());
    });
  }
  g_status = 1;
  g_client->SetApplicationId(id);
  g_client->UpdateToken(discordpp::AuthorizationTokenType::Bearer, token, [](discordpp::ClientResult result) {
    if (result.Successful()) {
      std::lock_guard<std::recursive_mutex> lk2(g_mu);
      if (g_client) g_client->Connect();
    } else {
      g_status = 3;
      fprintf(stderr, "PEK Discord: token rejected\n");
    }
  });
  StartPump();
}

void Update(const std::string& details, const std::string& state, int64_t startMs, int64_t endMs) {
  std::lock_guard<std::recursive_mutex> lk(g_mu);
  const int st = g_status.load();
  if (!g_client || (st != 1 && st != 2)) return;   // never connected, or in error: nothing to show
  g_last.has = true;
  g_last.details = details;
  g_last.state = state;
  g_last.startMs = startMs;
  g_last.endMs = endMs;
  if (st == 2) SendActivity(g_last);               // connecting (1): sent by the Ready callback
}

void Clear() {
  std::lock_guard<std::recursive_mutex> lk(g_mu);
  g_last.has = false;
  if (g_client && g_status.load() == 2) g_client->ClearRichPresence();
}

void Disconnect() {
  std::lock_guard<std::recursive_mutex> lk(g_mu);
  g_last.has = false;
  if (g_client) {
    if (g_status.load() == 2) g_client->ClearRichPresence();
    g_client->Disconnect();
  }
  g_status = 0;
}

#else   // no Social SDK in this build

bool Available() { return false; }
void Connect(const std::string&, const std::string&) {}
void Update(const std::string&, const std::string&, int64_t, int64_t) {}
void Clear() {}
void Disconnect() {}

#endif

int Status() { return g_status.load(); }

}  // namespace discord
}  // namespace pek
