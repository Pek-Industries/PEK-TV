// Discord Rich Presence on Windows (Android: NativeDiscord.kt + discord_presence.cpp; see DISCORD.md and flutter_ui/lib/src/discord.dart).
// Dart owns the tokens and decides what to show; this connects to Discord as the linked person with the Discord Social SDK and sets
// the "Watching ..." activity. The SDK comes from the Discord developer portal and is NOT committed with the code: put its Windows files
// in windows/discord/ (DISCORD.md). Without them everything here is a no-op and Available() is false, so the app builds and runs as
// before and Settings says Discord is not supported in this build.
#pragma once
#include <cstdint>
#include <string>

namespace pek {
namespace discord {

bool Available();
void Connect(const std::string& appId, const std::string& token);
void Update(const std::string& details, const std::string& state, int64_t startMs, int64_t endMs);
void Clear();
void Disconnect();
// 0 off, 1 connecting, 2 ready, 3 error
int Status();

}  // namespace discord
}  // namespace pek
