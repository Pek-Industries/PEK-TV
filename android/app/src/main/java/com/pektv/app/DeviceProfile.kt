package com.pektv.app

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build
import android.view.Display
import android.view.WindowManager

/**
 * What this device can decode in hardware and show, for plugins that choose a release (Stream Media): the tallest picture
 * (480 / 720 / 1080 / 2160) each hardware decoder handles, the screen's short side in pixels, TV or not, HDR10 / Dolby Vision.
 * A plugin only receives it when plugin.json asks for "device": true (pek_ui.ctx()). Nothing here names the person or the phone.
 */
object DeviceProfile {
    private var cached: Map<String, Any>? = null

    // Tallest first: the first size a decoder accepts is its best.
    private val SIZES = listOf(3840 to 2160, 1920 to 1080, 1280 to 720, 854 to 480)

    // MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10 / Main10HDR10 / Main10HDR10Plus (the last two need newer SDKs to name).
    private val HEVC_10_BIT = setOf(2, 4096, 8192)

    @Synchronized
    fun read(context: Context): Map<String, Any> {
        cached?.let { return it }
        return try {
            build(context).also { cached = it }
        } catch (t: Throwable) {
            mapOf("v" to 1, "unknown" to true)           // the plugin then ranks as it always did
        }
    }

    private fun isHardware(info: MediaCodecInfo): Boolean {
        if (info.isEncoder) return false
        if (Build.VERSION.SDK_INT >= 29) return info.isHardwareAccelerated && !info.isSoftwareOnly
        val n = info.name.lowercase()
        return !n.startsWith("omx.google.") && !n.startsWith("c2.android.") && !n.contains(".sw.")
    }

    private fun build(c: Context): Map<String, Any> {
        val decoders = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.filter { isHardware(it) }

        fun height(mime: String, tenBit: Boolean = false): Int {
            var best = 0
            for (info in decoders) {
                if (info.supportedTypes.none { it.equals(mime, ignoreCase = true) }) continue
                val caps = try { info.getCapabilitiesForType(mime) } catch (_: Throwable) { continue }
                if (tenBit && caps.profileLevels.none { it.profile in HEVC_10_BIT }) continue
                val video = caps.videoCapabilities ?: continue
                for ((w, h) in SIZES) {
                    if (video.areSizeAndRateSupported(w, h, 30.0)) { if (h > best) best = h; break }
                }
            }
            return best
        }

        val dm = c.resources.displayMetrics
        val tv = (c.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager)?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            c.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)

        var hdr = false
        var dv = false
        try {
            val wm = c.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            @Suppress("DEPRECATION") val display = wm.defaultDisplay
            @Suppress("DEPRECATION") val types = display.hdrCapabilities?.supportedHdrTypes ?: IntArray(0)
            hdr = types.contains(Display.HdrCapabilities.HDR_TYPE_HDR10)
            dv = types.contains(Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION)
        } catch (_: Throwable) {
        }

        return mapOf(
            "v" to 1,
            "h264" to height("video/avc"),
            "hevc" to height("video/hevc"),
            "hevc10" to height("video/hevc", tenBit = true),
            "av1" to height("video/av01"),
            "screenShort" to minOf(dm.widthPixels, dm.heightPixels),
            "tv" to tv,
            "hdr" to hdr,
            "dv" to dv,
        )
    }
}
