#include "pek_media.h"

#include <unknwn.h>   // before the winrt headers: lets C++/WinRT talk to classic COM interfaces

#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Web.Http.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <thread>

namespace wf = winrt::Windows::Foundation;
namespace wm = winrt::Windows::Media;
namespace ws = winrt::Windows::Storage::Streams;

namespace pek {

namespace {
wf::TimeSpan Seconds(double s) {
  if (!(s > 0)) s = 0;
  return wf::TimeSpan{static_cast<int64_t>(s * 10000000.0)};   // TimeSpan counts 100 ns
}
}  // namespace

struct MediaSession::Impl : std::enable_shared_from_this<MediaSession::Impl> {
  HWND window = nullptr;
  PostFn post;
  RemoteFn remote;

  wm::SystemMediaTransportControls smtc{nullptr};
  winrt::event_token buttonToken{}, seekToken{};
  bool failed = false;           // Windows would not give a session: do not try again
  std::string artUrl;
  std::atomic<unsigned> artGen{0};   // a newer cover request makes an older, slower one drop its result

  // Gets the session for the window the first time it is needed.
  bool Ensure() {
    if (smtc) return true;
    if (failed) return false;
    try {
      auto interop = winrt::get_activation_factory<wm::SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
      winrt::check_hresult(interop->GetForWindow(window, winrt::guid_of<wm::SystemMediaTransportControls>(), winrt::put_abi(smtc)));
      smtc.IsPlayEnabled(true);
      smtc.IsPauseEnabled(true);
      smtc.IsStopEnabled(true);
      smtc.IsNextEnabled(true);
      smtc.IsPreviousEnabled(true);
      // The handlers run on a worker thread. They hold only a copy of the callback, never this object.
      RemoteFn cb = remote;
      buttonToken = smtc.ButtonPressed([cb](wm::SystemMediaTransportControls const&, wm::SystemMediaTransportControlsButtonPressedEventArgs const& a) {
        switch (a.Button()) {
          case wm::SystemMediaTransportControlsButton::Play: cb("play", 0); break;
          case wm::SystemMediaTransportControlsButton::Pause: cb("pause", 0); break;
          case wm::SystemMediaTransportControlsButton::Stop: cb("stop", 0); break;
          case wm::SystemMediaTransportControlsButton::Next: cb("next", 0); break;
          case wm::SystemMediaTransportControlsButton::Previous: cb("prev", 0); break;
          default: break;
        }
      });
      seekToken = smtc.PlaybackPositionChangeRequested([cb](wm::SystemMediaTransportControls const&, wm::PlaybackPositionChangeRequestedEventArgs const& a) {
        cb("seek", static_cast<double>(a.RequestedPlaybackPosition().count()) / 10000000.0);
      });
      return true;
    } catch (...) {
      fprintf(stderr, "PEK media keys: Windows did not give a media session\n");
      smtc = nullptr;
      failed = true;
      return false;
    }
  }

  // The cover is fetched here (the PEK server answers on 127.0.0.1 with the access token in the address) and handed to Windows as
  // bytes: the system's own process would not be allowed to read a loopback address.
  void FetchArt(const std::string& url) {
    const unsigned gen = ++artGen;
    if (url.empty()) return;
    std::shared_ptr<Impl> self = shared_from_this();
    std::thread([self, url, gen] {
      try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        wf::Uri uri{winrt::to_hstring(url)};
        winrt::Windows::Web::Http::HttpClient http;
        ws::IBuffer buf = http.GetBufferAsync(uri).get();
        if (buf && buf.Length() > 0) {
          ws::InMemoryRandomAccessStream stream;
          stream.WriteAsync(buf).get();
          stream.FlushAsync().get();
          stream.Seek(0);
          ws::RandomAccessStreamReference ref = ws::RandomAccessStreamReference::CreateFromStream(stream);
          self->post([self, ref, gen] {
            if (gen != self->artGen || !self->smtc) return;
            try {
              auto du = self->smtc.DisplayUpdater();
              du.Thumbnail(ref);
              du.Update();
            } catch (...) {}
          });
        }
      } catch (...) {}
      winrt::uninit_apartment();
    }).detach();
  }
};

MediaSession::MediaSession(HWND window, PostFn post, RemoteFn onRemote) : impl_(std::make_shared<Impl>()) {
  impl_->window = window;
  impl_->post = std::move(post);
  impl_->remote = std::move(onRemote);
}

MediaSession::~MediaSession() {
  Impl& s = *impl_;
  ++s.artGen;
  if (!s.smtc) return;
  try {
    if (s.buttonToken) s.smtc.ButtonPressed(s.buttonToken);
    if (s.seekToken) s.smtc.PlaybackPositionChangeRequested(s.seekToken);
    s.smtc.IsEnabled(false);
  } catch (...) {}
  s.smtc = nullptr;
}

void MediaSession::Meta(const std::string& title, const std::string& artist, const std::string& album, const std::string& artUrl) {
  Impl& s = *impl_;
  if (!s.Ensure()) return;
  try {
    s.smtc.IsEnabled(true);
    s.smtc.IsPlayEnabled(true);
    s.smtc.IsPauseEnabled(true);
    s.smtc.IsStopEnabled(true);
    s.smtc.IsNextEnabled(true);       // a film switched these off (Video)
    s.smtc.IsPreviousEnabled(true);
    auto du = s.smtc.DisplayUpdater();
    du.Type(wm::MediaPlaybackType::Music);
    auto mp = du.MusicProperties();
    mp.Title(winrt::to_hstring(title));
    mp.Artist(winrt::to_hstring(artist));
    mp.AlbumTitle(winrt::to_hstring(album));
    if (artUrl != s.artUrl) {
      s.artUrl = artUrl;
      du.Thumbnail(nullptr);   // the previous song's cover must not stay while the new one downloads
      s.FetchArt(artUrl);
    }
    du.Update();
  } catch (...) {}
}

void MediaSession::Video(const std::string& title) {
  Impl& s = *impl_;
  if (!s.Ensure()) return;
  try {
    ++s.artGen;
    s.artUrl.clear();
    s.smtc.IsEnabled(true);
    s.smtc.IsPlayEnabled(true);
    s.smtc.IsPauseEnabled(true);
    s.smtc.IsStopEnabled(false);
    s.smtc.IsNextEnabled(false);
    s.smtc.IsPreviousEnabled(false);
    auto du = s.smtc.DisplayUpdater();
    du.Type(wm::MediaPlaybackType::Video);
    du.VideoProperties().Title(winrt::to_hstring(title));
    du.Thumbnail(nullptr);
    du.Update();
  } catch (...) {}
}

void MediaSession::State(bool active, bool buffering, double positionSec, double durationSec) {
  Impl& s = *impl_;
  if (!s.smtc) return;   // no song yet (Meta creates the session)
  try {
    s.smtc.PlaybackStatus(!active ? wm::MediaPlaybackStatus::Paused : buffering ? wm::MediaPlaybackStatus::Changing : wm::MediaPlaybackStatus::Playing);
    const double dur = std::max(0.0, durationSec);
    const double pos = std::min(std::max(0.0, positionSec), dur > 0 ? dur : positionSec);
    wm::SystemMediaTransportControlsTimelineProperties tp;
    tp.StartTime(Seconds(0));
    tp.MinSeekTime(Seconds(0));
    tp.EndTime(Seconds(dur));
    tp.MaxSeekTime(Seconds(dur));
    tp.Position(Seconds(pos));
    s.smtc.UpdateTimelineProperties(tp);   // Windows moves the clock by itself while it plays; Dart only corrects a seek
  } catch (...) {}
}

void MediaSession::End() {
  Impl& s = *impl_;
  ++s.artGen;
  s.artUrl.clear();
  if (!s.smtc) return;
  try {
    s.smtc.PlaybackStatus(wm::MediaPlaybackStatus::Closed);
    auto du = s.smtc.DisplayUpdater();
    du.ClearAll();
    du.Update();
    s.smtc.IsEnabled(false);   // the keys go back to whatever other player was last used
  } catch (...) {}
}

}  // namespace pek
