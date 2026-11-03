// Discord Rich Presence for PEK TV (see ../../../../../DISCORD.md and flutter_ui/lib/src/discord.dart).
//
// Dart gives this file an app id and an OAuth2 access token (obtained by the link flow in cloud/worker.js); it connects to Discord
// as that person with the Discord Social SDK and sets the "Watching ..." activity.
//
// The Social SDK is not in git: it comes from the Discord developer portal. CMakeLists.txt defines PEK_DISCORD_SDK only when
// android/discord_social_sdk/include/discordpp.h and lib/<abi>/*.so exist. Without them everything below is a no-op and
// available() is false, so the app still builds and the settings say Discord is not supported in this build.
//
// UNVERIFIED (written from Discord's public docs, never compiled against the real headers): the discordpp calls in the
// PEK_DISCORD_SDK branch. DISCORD.md lists what to check.
#include <jni.h>
#include <android/log.h>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#define PEK_DLOG(...) __android_log_print(ANDROID_LOG_INFO, "PEKDiscord", __VA_ARGS__)

static std::string jstr(JNIEnv* env, jstring s) {
    if (!s) return std::string();
    const char* c = env->GetStringUTFChars(s, nullptr);
    std::string out(c ? c : "");
    if (c) env->ReleaseStringUTFChars(s, c);
    return out;
}

// 0 off, 1 connecting, 2 ready, 3 error
static std::atomic<int> g_status{0};

#ifdef PEK_DISCORD_SDK

#define DISCORDPP_IMPLEMENTATION
#include "discordpp.h"

namespace {
// One lock for every SDK call, the callback pump included. Recursive because the SDK's callbacks (run by the pump while it holds
// the lock) call back into the client.
std::recursive_mutex g_mu;
std::shared_ptr<discordpp::Client> g_client;
std::atomic<bool> g_pumpOn{false};
std::thread g_pump;

void startPump() {
    if (g_pumpOn.exchange(true)) return;
    g_pump = std::thread([]() {
        while (g_pumpOn.load()) {
            {
                std::lock_guard<std::recursive_mutex> lk(g_mu);
                discordpp::RunCallbacks();   // the SDK delivers its callbacks only when this is called
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
    });
    g_pump.detach();
}
}  // namespace

static bool sdkAvailable() { return true; }

static void sdkConnect(const std::string& appId, const std::string& token) {
    std::lock_guard<std::recursive_mutex> lk(g_mu);
    const uint64_t id = std::strtoull(appId.c_str(), nullptr, 10);
    if (id == 0 || token.empty()) { g_status = 3; return; }
    if (!g_client) {
        // TODO(verify): Discord's Android guide may ask for extra setup here (for example handing the SDK the JavaVM or an Android
        // context) before the first Client is made.
        g_client = std::make_shared<discordpp::Client>();
        g_client->SetStatusChangedCallback([](discordpp::Client::Status status, discordpp::Client::Error error, int32_t /*detail*/) {
            if (status == discordpp::Client::Status::Ready) g_status = 2;
            else if (status == discordpp::Client::Status::Disconnected) g_status = (error == discordpp::Client::Error::None) ? 0 : 3;
            else g_status = 1;
            PEK_DLOG("status %d", g_status.load());
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
            PEK_DLOG("token rejected");
        }
    });
    startPump();
}

static void sdkUpdate(const std::string& details, const std::string& state, int64_t startMs, int64_t endMs) {
    std::lock_guard<std::recursive_mutex> lk(g_mu);
    if (!g_client || g_status.load() != 2) return;   // not connected (yet): the next event sets it
    discordpp::Activity activity;
    activity.SetType(discordpp::ActivityTypes::Watching);   // TODO(verify): fall back to Playing if the SDK has no Watching
    activity.SetDetails(details);
    if (!state.empty()) activity.SetState(state);
    if (startMs > 0) {
        discordpp::ActivityTimestamps ts;
        ts.SetStart(static_cast<uint64_t>(startMs));   // TODO(verify): milliseconds since the epoch, as in Discord's own gateway
        if (endMs > startMs) ts.SetEnd(static_cast<uint64_t>(endMs));
        activity.SetTimestamps(ts);
    }
    g_client->UpdateRichPresence(activity, [](discordpp::ClientResult result) {
        if (!result.Successful()) PEK_DLOG("presence update failed");
    });
}

static void sdkClear() {
    std::lock_guard<std::recursive_mutex> lk(g_mu);
    if (g_client && g_status.load() == 2) g_client->ClearRichPresence();
}

static void sdkDisconnect() {
    std::lock_guard<std::recursive_mutex> lk(g_mu);
    if (g_client) {
        if (g_status.load() == 2) g_client->ClearRichPresence();
        g_client->Disconnect();
    }
    g_status = 0;
}

#else   // no Social SDK in this build

static bool sdkAvailable() { return false; }
static void sdkConnect(const std::string&, const std::string&) {}
static void sdkUpdate(const std::string&, const std::string&, int64_t, int64_t) {}
static void sdkClear() {}
static void sdkDisconnect() {}

#endif

extern "C" JNIEXPORT jboolean JNICALL
Java_com_pektv_app_NativeDiscord_available(JNIEnv*, jclass) { return sdkAvailable() ? JNI_TRUE : JNI_FALSE; }

extern "C" JNIEXPORT void JNICALL
Java_com_pektv_app_NativeDiscord_connect(JNIEnv* env, jclass, jstring jAppId, jstring jToken) {
    sdkConnect(jstr(env, jAppId), jstr(env, jToken));
}

extern "C" JNIEXPORT void JNICALL
Java_com_pektv_app_NativeDiscord_update(JNIEnv* env, jclass, jstring jDetails, jstring jState, jlong startMs, jlong endMs) {
    sdkUpdate(jstr(env, jDetails), jstr(env, jState), static_cast<int64_t>(startMs), static_cast<int64_t>(endMs));
}

extern "C" JNIEXPORT void JNICALL
Java_com_pektv_app_NativeDiscord_clear(JNIEnv*, jclass) { sdkClear(); }

extern "C" JNIEXPORT void JNICALL
Java_com_pektv_app_NativeDiscord_disconnect(JNIEnv*, jclass) { sdkDisconnect(); }

extern "C" JNIEXPORT jint JNICALL
Java_com_pektv_app_NativeDiscord_status(JNIEnv*, jclass) { return static_cast<jint>(g_status.load()); }
