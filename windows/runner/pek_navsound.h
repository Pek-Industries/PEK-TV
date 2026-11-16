// Navigation sounds on Windows (Android: NavSound.kt). A soft "tick" when the highlight moves, a two-note "select" for a click /
// the centre button, and a lower "back" when a screen or dialog closes. Same notes as Android, generated here (no audio files).
// The Dart side (nav_sound.dart) calls `navSound` on pek/host and returns at once; the sound is started on a thread of its own.
#pragma once
#include <windows.h>

#include <condition_variable>
#include <mutex>
#include <thread>

namespace pek {

class NavSound {
 public:
  NavSound();
  ~NavSound();
  NavSound(const NavSound&) = delete;
  NavSound& operator=(const NavSound&) = delete;

  // kind 0 = move, 1 = select, 2 = back; volume 0..1 (Dart already applied the Off / Low / Medium / High level).
  // Never blocks; a sound still playing is cut off by the new one, like Android's stop() + play().
  void Play(int kind, float volume);

 private:
  void Run();

  std::thread thread_;
  std::mutex m_;
  std::condition_variable cv_;
  bool quit_ = false;
  int kind_ = -1;
  float volume_ = 0.f;
};

}  // namespace pek
