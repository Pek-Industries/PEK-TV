// Media keys and the now-playing tile on Windows (Android: MusicService + MediaSession, glued by FlutterMusic.kt).
// A SystemMediaTransportControls (SMTC) session for the PEK window: the play / pause / next / previous / stop keys of the keyboard or
// headset, the media tile in the volume flyout and on the lock screen show the song and cover and send the buttons here.
// Everything is best-effort: if Windows will not hand out a session, the music still plays, only without the keys.
#pragma once
#include <windows.h>

#include <functional>
#include <memory>
#include <string>

namespace pek {

class MediaSession {
 public:
  // A button was pressed. action is "play", "pause", "stop", "next", "prev" or "seek" (seconds = the new position).
  // Called on a Windows worker thread, not the UI thread: the receiver must hand the work over (the host does, through [post]).
  using RemoteFn = std::function<void(const std::string& action, double seconds)>;
  // Runs a function on the UI thread (the host's Post).
  using PostFn = std::function<void(std::function<void()>)>;

  MediaSession(HWND window, PostFn post, RemoteFn onRemote);
  ~MediaSession();

  // The three calls mirror pek/music from Dart (music_session.dart). UI thread only.
  void Meta(const std::string& title, const std::string& artist, const std::string& album, const std::string& artUrl);
  void State(bool active, bool buffering, double positionSec, double durationSec);
  void End();

 private:
  struct Impl;
  std::shared_ptr<Impl> impl_;
};

}  // namespace pek
