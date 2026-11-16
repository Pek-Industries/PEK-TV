#include "pek_navsound.h"

#include <mmsystem.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace pek {
namespace {

constexpr int kRate = 48000;
constexpr double kPi = 3.14159265358979323846;

// A sine that glides from f0 to f1 Hz. gain is its level (0..1); a higher curve makes the decay snappier.
struct Note {
  double f0, f1, start, dur, gain, curve;
};

// Enveloped sine sweeps: a 3 ms attack (no click from a hard start) and a power-curve decay. Same maths as NavSound.kt.
std::vector<int16_t> Render(const std::vector<Note>& notes, double total) {
  const int n = static_cast<int>(std::ceil(kRate * total));
  std::vector<float> d(static_cast<size_t>(n), 0.f);
  for (const Note& nt : notes) {
    const int s0 = static_cast<int>(nt.start * kRate);
    const int len = static_cast<int>(nt.dur * kRate);
    double ph = 0.0;
    for (int i = 0; i < len && s0 + i < n; ++i) {
      const double p = static_cast<double>(i) / len;
      const double f = nt.f0 * std::pow(nt.f1 / nt.f0, p);
      ph += 2 * kPi * f / kRate;
      const double env = std::min(1.0, i / (kRate * 0.003)) * std::pow(1 - p, nt.curve);
      d[static_cast<size_t>(s0 + i)] += static_cast<float>(std::sin(ph) * env * nt.gain);
    }
  }
  std::vector<int16_t> out(static_cast<size_t>(n));
  for (int i = 0; i < n; ++i) out[static_cast<size_t>(i)] = static_cast<int16_t>(std::clamp(d[static_cast<size_t>(i)], -1.f, 1.f) * 32000.f);
  return out;
}

}  // namespace

NavSound::NavSound() : thread_([this] { Run(); }) {}

NavSound::~NavSound() {
  {
    std::lock_guard<std::mutex> l(m_);
    quit_ = true;
  }
  cv_.notify_all();
  if (thread_.joinable()) thread_.join();
}

void NavSound::Play(int kind, float volume) {
  if (kind < 0 || kind > 2 || volume <= 0.f) return;
  {
    std::lock_guard<std::mutex> l(m_);
    kind_ = kind;
    volume_ = std::min(1.f, volume);
  }
  cv_.notify_one();
}

void NavSound::Run() {
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);

  // 0 = move (tick), 1 = select, 2 = back: the same notes as NavSound.kt.
  std::vector<int16_t> pcm[3];
  pcm[0] = Render({{1500.0, 1050.0, 0.0, 0.050, 0.55, 3.0}}, 0.06);                                              // a short, soft tick that falls a little
  pcm[1] = Render({{784.0, 784.0, 0.0, 0.065, 0.60, 2.5}, {1175.0, 1175.0, 0.045, 0.110, 0.50, 2.5}}, 0.17);    // G5 then D6
  pcm[2] = Render({{1000.0, 680.0, 0.0, 0.085, 0.55, 2.5}}, 0.10);                                               // one lower note that glides down

  WAVEFORMATEX fmt{};
  fmt.wFormatTag = WAVE_FORMAT_PCM;
  fmt.nChannels = 1;
  fmt.nSamplesPerSec = kRate;
  fmt.wBitsPerSample = 16;
  fmt.nBlockAlign = 2;
  fmt.nAvgBytesPerSec = kRate * 2;

  HWAVEOUT hwo = nullptr;
  if (waveOutOpen(&hwo, WAVE_MAPPER, &fmt, 0, 0, CALLBACK_NULL) != MMSYSERR_NOERROR) hwo = nullptr;   // no sound device: stay silent

  std::vector<int16_t> buf;
  WAVEHDR hdr{};
  bool prepared = false;

  auto submit = [&](const std::vector<int16_t>& src, float volume) {
    if (!hwo) return;
    waveOutReset(hwo);   // cuts off a sound still playing and returns its buffer
    if (prepared) {
      waveOutUnprepareHeader(hwo, &hdr, sizeof(hdr));
      prepared = false;
    }
    buf.resize(src.size());
    for (size_t i = 0; i < src.size(); ++i) buf[i] = static_cast<int16_t>(src[i] * volume);
    hdr = WAVEHDR{};
    hdr.lpData = reinterpret_cast<LPSTR>(buf.data());
    hdr.dwBufferLength = static_cast<DWORD>(buf.size() * sizeof(int16_t));
    if (waveOutPrepareHeader(hwo, &hdr, sizeof(hdr)) != MMSYSERR_NOERROR) return;
    prepared = true;
    waveOutWrite(hwo, &hdr, sizeof(hdr));
  };

  // One silent play wakes the audio path so the very first real tick is not late.
  submit(std::vector<int16_t>(static_cast<size_t>(kRate / 20), 0), 0.f);

  for (;;) {
    int kind;
    float vol;
    {
      std::unique_lock<std::mutex> l(m_);
      cv_.wait(l, [this] { return quit_ || kind_ >= 0; });
      if (quit_) break;
      kind = kind_;
      vol = volume_;
      kind_ = -1;
    }
    submit(pcm[kind], vol);
  }

  if (hwo) {
    waveOutReset(hwo);
    if (prepared) waveOutUnprepareHeader(hwo, &hdr, sizeof(hdr));
    waveOutClose(hwo);
  }
}

}  // namespace pek
