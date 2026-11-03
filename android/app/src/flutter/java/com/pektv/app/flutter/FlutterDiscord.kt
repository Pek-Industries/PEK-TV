package com.pektv.app.flutter

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import com.pektv.app.NativeDiscord
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The `pek/discord` channel (discord.dart): Discord Rich Presence. Dart owns the tokens and decides what to show; this only passes
 * it on to the Discord Social SDK and opens the approval link on a phone.
 */
class FlutterDiscord(private val activity: Activity) {
    fun register(messenger: BinaryMessenger) {
        // Discord's Android SDK wants the activity once before its first Client (DiscordSocialSdkInit.setEngineActivity, from its
        // setup guide). Reflection, so the app still compiles when the SDK's .aar is not there.
        try {
            Class.forName("com.discord.socialsdk.DiscordSocialSdkInit").methods.firstOrNull { it.name == "setEngineActivity" }?.invoke(null, activity)
        } catch (t: Throwable) { /* no SDK in this build */ }
        MethodChannel(messenger, "pek/discord").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "available" -> result.success(try { NativeDiscord.available() } catch (t: Throwable) { false })
                    "connect" -> {
                        NativeDiscord.connect(call.argument<String>("appId") ?: "", call.argument<String>("token") ?: "")
                        result.success(null)
                    }
                    "update" -> {
                        NativeDiscord.update(
                            call.argument<String>("details") ?: "",
                            call.argument<String>("state") ?: "",
                            call.argument<Number>("startMs")?.toLong() ?: 0L,
                            call.argument<Number>("endMs")?.toLong() ?: 0L
                        )
                        result.success(null)
                    }
                    "clear" -> { NativeDiscord.clear(); result.success(null) }
                    "disconnect" -> { NativeDiscord.disconnect(); result.success(null) }
                    "status" -> result.success(
                        when (NativeDiscord.status()) { 1 -> "connecting"; 2 -> "ready"; 3 -> "error"; else -> "off" }
                    )
                    "openUrl" -> {
                        // only https links (the PEK cloud's /v1/discord/go), never anything else
                        val url = call.argument<String>("url") ?: ""
                        if (!url.startsWith("https://")) { result.success(false); return@setMethodCallHandler }
                        try {
                            activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE))
                            result.success(true)
                        } catch (e: ActivityNotFoundException) {
                            result.success(false) // no browser on this device
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                result.error("discord_error", t.message, null)
            }
        }
    }
}
