package com.pektv.app

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

/**
 * Navigation sounds, played natively: a soft "tick" when the highlight moves, a two-note "select" for a tap / the centre
 * button, and a lower "back" when a screen or dialog closes. Tuned to feel like the Apple TV interface sounds (short, round
 * and quiet); they are generated here, no audio files are shipped.
 *
 * Playing through the Flutter / WebView audio stack goes through a big buffer and the (busy) UI thread, which is why sounds
 * trailed the highlight on TV boxes. Here the sounds are rendered once into static low-latency AudioTracks and a press only has
 * to restart one. The Dart side (nav_sound.dart) calls `navSound` on the pek/host channel and returns immediately: the actual
 * play happens on a small dedicated thread.
 */
class NavSound {
    private val sr = 48000
    private val thread = HandlerThread("pek-navsound", Process.THREAD_PRIORITY_URGENT_AUDIO).apply { start() }
    private val handler = Handler(thread.looper)
    private val tracks = arrayOfNulls<AudioTrack>(3)      // 0 = move (tick), 1 = select, 2 = back
    @Volatile private var ready = false

    init { handler.post { build() } }

    fun isReady(): Boolean = ready

    /** kind 0 = move, 1 = select, 2 = back; volume 0..1 (the Dart side already applied the Off / Low / Medium / High level). */
    fun play(kind: Int, volume: Float) {
        if (kind < 0 || kind >= tracks.size || volume <= 0f) return
        handler.postAtFrontOfQueue {
            val t = tracks[kind] ?: return@postAtFrontOfQueue
            try {
                t.stop()
                t.reloadStaticData()
                t.setVolume(min(1f, volume))
                t.play()
            } catch (e: Exception) { /* silent: a missed tick is fine */ }
        }
    }

    fun release() {
        handler.post {
            for (i in tracks.indices) { try { tracks[i]?.release() } catch (e: Exception) { }; tracks[i] = null }
            ready = false
            thread.quitSafely()
        }
    }

    /** A sine that glides from [f0] to [f1] Hz. [gain] is its level (0..1); a higher [curve] makes the decay snappier. */
    private class Note(val f0: Double, val f1: Double, val start: Double, val dur: Double, val gain: Double = 1.0, val curve: Double = 2.0)

    // Enveloped sine sweeps: a 3 ms attack (no click from a hard start) and a power-curve decay.
    private fun render(notes: List<Note>, total: Double): ShortArray {
        val n = ceil(sr * total).toInt()
        val d = FloatArray(n)
        for (nt in notes) {
            val s0 = (nt.start * sr).toInt()
            val len = (nt.dur * sr).toInt()
            var ph = 0.0
            var i = 0
            while (i < len && s0 + i < n) {
                val p = i.toDouble() / len
                val f = nt.f0 * (nt.f1 / nt.f0).pow(p)
                ph += 2 * PI * f / sr
                val env = min(1.0, i / (sr * 0.003)) * (1 - p).pow(nt.curve)
                d[s0 + i] += (sin(ph) * env * nt.gain).toFloat()
                i++
            }
        }
        val out = ShortArray(n)
        for (i in 0 until n) out[i] = (d[i].coerceIn(-1f, 1f) * 32000f).toInt().toShort()
        return out
    }

    private fun makeTrack(pcm: ShortArray): AudioTrack {
        val bytes = pcm.size * 2
        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sr)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
            )
            .setBufferSizeInBytes(bytes)
            .setTransferMode(AudioTrack.MODE_STATIC)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .build()
        t.write(pcm, 0, pcm.size)
        return t
    }

    private fun build() {
        try {
            // move: a short, soft tick that falls a little in pitch
            tracks[0] = makeTrack(render(listOf(Note(1500.0, 1050.0, 0.0, 0.050, 0.55, 3.0)), 0.06))
            // select: two quick notes, the second a fifth higher (G5 then D6)
            tracks[1] = makeTrack(render(listOf(Note(784.0, 784.0, 0.0, 0.065, 0.60, 2.5), Note(1175.0, 1175.0, 0.045, 0.110, 0.50, 2.5)), 0.17))
            // back: one lower note that glides down
            tracks[2] = makeTrack(render(listOf(Note(1000.0, 680.0, 0.0, 0.085, 0.55, 2.5)), 0.10))
            // One silent-volume play wakes the audio path so the very first real tick is not late.
            for (t in tracks) { t?.setVolume(0f); t?.play() }
            ready = true
        } catch (e: Exception) {
            ready = false      // no sound on this device; play() then does nothing
        }
    }
}
