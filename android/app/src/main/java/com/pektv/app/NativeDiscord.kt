package com.pektv.app

/**
 * The Discord Social SDK side of Rich Presence (discord_presence.cpp). Without the SDK files in android/discord_social_sdk
 * (DISCORD.md) the native functions still exist: [available] says false and the rest do nothing.
 */
object NativeDiscord {
    init { System.loadLibrary("pek") }
    @JvmStatic external fun available(): Boolean
    @JvmStatic external fun connect(appId: String, token: String)
    @JvmStatic external fun update(details: String, state: String, startMs: Long, endMs: Long)
    @JvmStatic external fun clear()
    @JvmStatic external fun disconnect()
    /** 0 off, 1 connecting, 2 ready, 3 error */
    @JvmStatic external fun status(): Int
}
