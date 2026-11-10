package com.pektv.app.flutter

import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.graphics.drawable.Icon
import android.util.Rational
import android.app.UiModeManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.net.Uri
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.InputDevice
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import com.pektv.app.AppUpdater
import com.pektv.app.MediaPermissions
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import com.pektv.app.MpvController
import com.pektv.app.NativeBridge
import com.pektv.app.NavSound
import com.pektv.app.Boot
import com.pektv.app.R
import com.pektv.app.SplashGate
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.android.RenderMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

/**
 * Hosts the Flutter UI (flutter_ui/). MainActivity has already copied the assets, started the C++ server on
 * 127.0.0.1:8080 and the Python plugins by the time this opens, so the Flutter side only talks HTTP to that server
 * (exactly like the web UI did) and drives libmpv through the channels below.
 *
 * Video: the same MpvController as the web UI. Its SurfaceView sits BEHIND the (transparent) Flutter surface, so the
 * Flutter player screen simply draws its controls over a transparent background.
 *
 * Channels
 *   pek/mpv         (MethodChannel)  load, play, pause, seek, setAudio, setSubtitle, addSubtitle, setMiniRect,
 *                                    fullscreen, destroy
 *   pek/mpv/events  (EventChannel)   {event: time|state|tracks|ended|error, data: {...}}  - same payloads the web UI got; "error" = the file never loaded
 *   pek/host        (MethodChannel)  exit, isPhone, setMulticast, volume, dirs, navSound(kind, volume), sendKey(k)
 *   pek/pip         (MethodChannel)  Picture in picture: supported, set(allowed, playing), enter  /  host -> Dart: state, toggle
 *   pek/update      (MethodChannel)  info, install(path), openInstallSettings -> AppUpdater (app_update.dart: the "new version" screen);
 *                                    status {status, message} comes back from the installer
 *   pek/output      (MethodChannel)  Settings > Video / Audio output: video, setMatchRate, setHdr, audio, setPassthrough, audioFx, setAudioFx
 *   pek/music       (MethodChannel)  meta, state, end -> FlutterMusic (background play, lock-screen controls);
 *                                    remote {action} comes back the other way (next, prev, stop)
 *   pek/plugins     (MethodChannel)  call(json) -> json: a plugin's Python screen (plugins/<id>/screen.py, run by
 *                                    python/pek_flutter.py through Chaquopy); openUrl(url): an https link in the
 *                                    YouTube app or the browser; openApp({packages, url}): a streaming app. See FLUTTER_PLUGINS.md.
 *                                    pickFile({ext}): Android's own file picker for a plugin .PEK (ext "pek") or a skin .zip (ext "zip"; no storage permission needed);
 *                                    answers {name, bytes}, null when cancelled, or the error "no_picker" on a TV with no picker.
 */
class FlutterHostActivity : FlutterActivity() {

    private companion object {
        const val REQ_MIC = 4718                // request code of the microphone prompt (voice search)
        const val PICK_FILE = 4717              // request code of the .PEK / .zip file picker
        const val MAX_PICK_BYTES = 16 * 1024 * 1024 // a plugin is at most 8 MB, a skin 6 MB
    }

    // Splash: SplashActivity plays the PEK video on its own and opens this screen when the video is over. Until Flutter has drawn its
    // first frame this window stays see-through, so the video's last frame (SplashActivity, below) is not replaced by a flash of
    // colour; the "splashReady" call below then lets SplashActivity close. See SplashGate.kt.
    private var fromSplash = false
    private var permissionsAsked = false

    private var mpv: MpvController? = null
    private var navSound: NavSound? = null     // the tick / select / back sounds (nav_sound.dart)
    private var events: EventChannel.EventSink? = null
    private var music: FlutterMusic? = null
    private var musicChannel: MethodChannel? = null
    private var updateChannel: MethodChannel? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    // pektv://account?... from the website (after creating an account): handed to Dart (deep_link.dart) once it asks, or pushed when it is running.
    private var hostChannel: MethodChannel? = null
    private var pendingLink: String? = null

    private fun linkOf(i: Intent?): String? {
        val d = i?.dataString
        return if (d != null && d.startsWith("pektv://")) d else null
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val l = linkOf(intent) ?: return
        val ch = hostChannel
        if (ch != null) ch.invokeMethod("link", l) else pendingLink = l
    }

    // Plugin screens: each call can wait on the network inside Python, so they never run on the UI thread.
    private val pluginPool = Executors.newCachedThreadPool()

    // Install from .PEK (plugins) or .zip (skins): the system file picker (Storage Access Framework). The person picks the file
    // and Android hands this app just that one file, so no storage permission is needed and "All files access" is not required.
    private var pickResult: MethodChannel.Result? = null
    private var pickExt = "pek"

    private fun pickFile(ext: String, result: MethodChannel.Result) {
        if (pickResult != null) {
            result.error("busy", "A file is already being chosen.", null)
            return
        }
        pickExt = if (ext == "zip") "zip" else "pek"
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            // Zips come with several types depending on the app that saved them; octet-stream is what many downloads get.
            // Android has no type for .PEK, so a plugin picker shows every file: the app checks the name and the contents.
            if (pickExt == "zip") {
                putExtra(
                    Intent.EXTRA_MIME_TYPES,
                    arrayOf("application/zip", "application/x-zip-compressed", "application/x-zip", "multipart/x-zip", "application/octet-stream"),
                )
            }
        }
        pickResult = result
        try {
            startActivityForResult(intent, PICK_FILE)
        } catch (e: ActivityNotFoundException) {
            pickResult = null
            result.error("no_picker", "This device has no file picker.", null)
        } catch (e: Exception) {
            pickResult = null
            result.error("pick_failed", e.message ?: "The file picker could not be opened.", null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PICK_FILE) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pickResult ?: return
        pickResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null) // cancelled
            return
        }
        pluginPool.execute {
            try {
                var name = if (pickExt == "zip") "plugin.zip" else "plugin.PEK"
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                    if (c.moveToFirst()) c.getString(0)?.let { if (it.isNotBlank()) name = it }
                }
                val out = ByteArrayOutputStream()
                val buf = ByteArray(64 * 1024)
                contentResolver.openInputStream(uri)?.use { input ->
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        if (out.size() > MAX_PICK_BYTES) throw IllegalStateException("That file is too big to be a plugin or a skin.")
                    }
                } ?: throw IllegalStateException("The file could not be opened.")
                val bytes = out.toByteArray()
                runOnUiThread { result.success(mapOf("name" to name, "bytes" to bytes)) }
            } catch (e: Exception) {
                runOnUiThread { result.error("read_failed", e.message ?: "The file could not be read.", null) }
            }
        }
    }

    private fun pythonCall(json: String): String = try {
        // MainActivity starts Python on its own thread at boot; start it here too if that has not happened yet.
        synchronized(Python::class.java) {
            if (!Python.isStarted()) {
                try { Python.start(AndroidPlatform(applicationContext)) } catch (e: IllegalStateException) { /* started meanwhile */ }
            }
        }
        val req = JSONObject(json)
        if (!req.has("pluginsDir")) req.put("pluginsDir", File(File(filesDir, "hesper"), "plugins").absolutePath)
        Python.getInstance().getModule("pek_flutter").callAttr("call", req.toString()).toString()
    } catch (t: Throwable) {
        android.util.Log.w("PEK", "plugin call failed", t)
        JSONObject().put("ok", false).put("error", "Python is not ready: ${t.message}").toString()
    }

    // Streaming apps a plugin's "Watch on ..." button may open. Generated from tools/providers.json by tools/sync_providers.js
    // (the same list as MainActivity.streamingPackages and the manifest <queries>).
    private val streamingPackages = setOf(
        // PKGS-START
        "air.com.vudu.air.DownloaderTablet",
        "com.amazon.amazonvideo.livingroom",
        "com.amazon.avod.thirdpartyclient",
        "com.amazon.imdb.tv.android.app",
        "com.apple.atve.androidtv.appletv",
        "com.bydeluxe.d3.android.program.starz",
        "com.cbs.app",
        "com.cbs.ott",
        "com.criterionchannel",
        "com.crunchyroll.crunchyroid",
        "com.disney.disneyplus",
        "com.google.android.videos",
        "com.google.android.youtube",
        "com.google.android.youtube.tv",
        "com.hbo.hbonow",
        "com.hoopladigital.android",
        "com.hulu.livingroomplus",
        "com.hulu.plus",
        "com.kanopy",
        "com.mubi",
        "com.netflix.mediaclient",
        "com.netflix.ninja",
        "com.peacocktv.peacockandroid",
        "com.plexapp.android",
        "com.roku.web.trc",
        "com.showtime.standalone",
        "com.tubitv",
        "com.wbd.stream",
        "tv.pluto.android"
        // PKGS-END
    )

    private fun tryStart(intent: Intent): Boolean = try {
        startActivity(intent); true
    } catch (e: ActivityNotFoundException) { false }
    catch (e: Throwable) { android.util.Log.w("PEK", "could not open app", e); false }

    /**
     * A streaming app: first on the title's page (the app's own handler for [url]), else just the app itself, else
     * (not installed) the website. [packagesCsv] is a comma list of candidates; only allow-listed packages are used.
     */
    private fun openStreamingApp(packagesCsv: String, url: String): Boolean {
        val web = url.takeIf { it.length <= 2000 && it.startsWith("https://") }
        val pkgs = packagesCsv.split(',').map { it.trim() }.filter { it in streamingPackages }
        for (pkg in pkgs) {
            if (web != null && tryStart(Intent(Intent.ACTION_VIEW, Uri.parse(web)).setPackage(pkg))) return true
            val launch = packageManager.getLeanbackLaunchIntentForPackage(pkg) ?: packageManager.getLaunchIntentForPackage(pkg)
            if (launch != null && tryStart(launch)) return true
        }
        return web != null && openUrl(web)
    }

    // https links only (a plugin never supplies the address of an app, and file:/intent: links are refused).
    private fun openUrl(url: String): Boolean {
        if (url.length > 2000 || !url.startsWith("https://")) return false
        return try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: Throwable) {
            android.util.Log.w("PEK", "could not open link", e)
            false
        }
    }

    // Wi-Fi drops multicast packets unless Android is told to let them through; held only while searching the network.
    /** One key press (down, then up 40 ms later) fed into this window exactly like a button on a real remote. */
    private fun pressRemoteKey(name: String): Boolean {
        val code = when (name) {
            "up" -> KeyEvent.KEYCODE_DPAD_UP
            "down" -> KeyEvent.KEYCODE_DPAD_DOWN
            "left" -> KeyEvent.KEYCODE_DPAD_LEFT
            "right" -> KeyEvent.KEYCODE_DPAD_RIGHT
            "ok" -> KeyEvent.KEYCODE_DPAD_CENTER
            "menu" -> KeyEvent.KEYCODE_MENU
            else -> return false
        }
        val source = InputDevice.SOURCE_KEYBOARD or InputDevice.SOURCE_DPAD
        val down = SystemClock.uptimeMillis()
        dispatchKeyEvent(KeyEvent(down, down, KeyEvent.ACTION_DOWN, code, 0, 0, KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, source))
        Handler(Looper.getMainLooper()).postDelayed({
            dispatchKeyEvent(KeyEvent(down, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, code, 0, 0, KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, source))
        }, 40)
        return true
    }

    private fun setMulticast(on: Boolean) {
        try {
            if (on) {
                if (multicastLock == null) {
                    val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                    multicastLock = wifi?.createMulticastLock("pek-discovery")?.apply { setReferenceCounted(false) }
                }
                multicastLock?.let { if (!it.isHeld) it.acquire() }
            } else {
                multicastLock?.let { if (it.isHeld) it.release() }
            }
        } catch (e: Exception) {
            android.util.Log.w("PEK", "multicast lock failed", e)   // the port scan still finds hosts without it
        }
    }

    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent

    // A transparent Flutter activity defaults to a TextureView, which costs frames on weak TV boxes. A SurfaceView
    // (drawn above mpv's surface, transparent where nothing is painted) is the fast path.
    override fun getRenderMode(): RenderMode = RenderMode.surface

    // (Flutter 3.4x removed the embedding's SplashScreen / DrawableSplashScreen API, so provideSplashScreen() is gone.
    // Until Flutter's first frame the launch theme's windowBackground / Android 12 splash colour (pek_splash_bg) covers
    // the screen instead, and onFlutterUiDisplayed() below swaps it for black.)

    // Behind the app the window is black (mpv's surface shows through where the Flutter surface is transparent).
    // It turns black only once Flutter is on screen; the launch theme's splash colour stays until then.
    override fun onFlutterUiDisplayed() {
        super.onFlutterUiDisplayed()
        window.setBackgroundDrawable(ColorDrawable(Color.BLACK))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        fromSplash = intent.getBooleanExtra("pek_from_splash", false)
        pendingLink = linkOf(intent)
        // The server and the plugins normally started while the splash video played; this is a no-op then.
        Boot.ensureStarted(applicationContext)
        super.onCreate(savedInstanceState)
        // Not opened by the splash (a widget or notification tap): brand colour until Flutter's first frame, then black. Behind the
        // splash the window stays see-through (the theme's transparent background) so the video's last frame shows until then.
        if (!fromSplash) window.setBackgroundDrawable(ColorDrawable(getColor(R.color.pek_splash_bg)))
        val surface = SurfaceView(this)
        surface.visibility = View.GONE
        surface.isFocusable = false
        surface.isFocusableInTouchMode = false
        addContentView(surface, FrameLayout.LayoutParams(-1, -1))

        val c = MpvController(this, surface, null)
        c.eventSink = { event, data ->
            events?.success(mapOf("event" to event, "data" to data.toMap()))
        }
        mpv = c
        navSound = NavSound()
        music = FlutterMusic(this, c) { name, args ->
            runOnUiThread { musicChannel?.invokeMethod(name, args) }
        }
        hideSystemBars()
        // MainActivity's own prompt never runs when it hands over to this screen, so ask here: video + audio, once.
        // After the splash it waits for "splashReady": a permission dialog must not appear over the video's last frame.
        if (!fromSplash) askMediaPermissionsOnce()
    }

    private var pendingMic: MethodChannel.Result? = null

    // ---- The phone's own speech recognizer (the engine behind the Google keyboard's mic) for voice search (voice.dart) ----
    // Live partial words, no model to ship. Where the device has none (some TV boxes) or it errors, Dart falls back to the bundled model.
    private var voiceChannel: MethodChannel? = null
    private var sysRecognizer: android.speech.SpeechRecognizer? = null
    private var sysReply: ((String?, String?) -> Unit)? = null

    private fun setupSystemVoice(messenger: io.flutter.plugin.common.BinaryMessenger) {
        val ch = MethodChannel(messenger, "pek/voice")
        voiceChannel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(android.speech.SpeechRecognizer.isRecognitionAvailable(this))
                "start" -> startSystemListen(call.argument<List<String>>("bias") ?: emptyList(), result)
                "stop" -> { runOnUiThread { try { sysRecognizer?.stopListening() } catch (_: Exception) {} }; result.success(null) }
                "cancel" -> { runOnUiThread { sysReply?.invoke("", null); releaseSystemListen() }; result.success(null) }
                "speak" -> speakSystem(call.argument<String>("text") ?: "", result)
                "stopSpeak" -> { runOnUiThread { try { tts?.stop() } catch (_: Exception) {} }; result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    // The phone's own text-to-speech: lets the app talk back with nothing to download. Replies true when it finished speaking.
    private var tts: android.speech.tts.TextToSpeech? = null
    private var ttsReady = false

    private fun speakSystem(text: String, result: MethodChannel.Result) {
        runOnUiThread {
            fun go(t: android.speech.tts.TextToSpeech) {
                val id = "pek-" + System.nanoTime()
                t.setOnUtteranceProgressListener(object : android.speech.tts.UtteranceProgressListener() {
                    override fun onStart(u: String?) {}
                    override fun onDone(u: String?) { if (u == id) runOnUiThread { result.success(true) } }
                    @Deprecated("Replaced by onError(String, Int)")
                    override fun onError(u: String?) { if (u == id) runOnUiThread { result.success(false) } }
                    override fun onError(u: String?, code: Int) { if (u == id) runOnUiThread { result.success(false) } }
                })
                if (t.speak(text, android.speech.tts.TextToSpeech.QUEUE_FLUSH, null, id) != android.speech.tts.TextToSpeech.SUCCESS) result.success(false)
            }
            val existing = tts
            if (existing != null) {
                if (ttsReady) go(existing) else result.success(false) // still starting up: skip this one
                return@runOnUiThread
            }
            tts = android.speech.tts.TextToSpeech(this) { status ->
                val t = tts
                if (status == android.speech.tts.TextToSpeech.SUCCESS && t != null) {
                    ttsReady = true
                    go(t)
                } else {
                    tts = null // no speech engine on this device: stay silent, try again next time
                    result.success(false)
                }
            }
        }
    }

    private fun releaseSystemListen() {
        sysReply = null
        try { sysRecognizer?.cancel() } catch (_: Exception) {}
        try { sysRecognizer?.destroy() } catch (_: Exception) {}
        sysRecognizer = null
    }

    private fun startSystemListen(bias: List<String>, result: MethodChannel.Result) {
        runOnUiThread {
            releaseSystemListen()
            if (!android.speech.SpeechRecognizer.isRecognitionAvailable(this)) {
                result.error("unavailable", "No speech recognizer on this device", null)
                return@runOnUiThread
            }
            var replied = false
            val reply: (String?, String?) -> Unit = { text, code ->
                if (!replied) {
                    replied = true
                    if (code != null) result.error(code, "speech recognizer error $code", null) else result.success(text ?: "")
                    android.os.Handler(mainLooper).post { releaseSystemListen() }
                }
            }
            sysReply = reply
            val r = android.speech.SpeechRecognizer.createSpeechRecognizer(this)
            sysRecognizer = r
            r.setRecognitionListener(object : android.speech.RecognitionListener {
                override fun onReadyForSpeech(p: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rms: Float) {
                    voiceChannel?.invokeMethod("level", ((rms + 2f) / 12f).coerceIn(0f, 1f).toDouble())
                }
                override fun onBufferReceived(b: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onError(error: Int) {
                    // 6 = nothing said, 7 = nothing matched: a normal "did not hear". Anything else is an engine problem, so Dart uses the bundled model.
                    if (error == 6 || error == 7) reply("", null) else reply(null, "sr_$error")
                }
                override fun onResults(b: Bundle?) {
                    reply(b?.getStringArrayList(android.speech.SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: "", null)
                }
                override fun onPartialResults(b: Bundle?) {
                    val t = b?.getStringArrayList(android.speech.SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: return
                    if (t.isNotBlank()) voiceChannel?.invokeMethod("partial", t)
                }
                override fun onEvent(type: Int, p: Bundle?) {}
            })
            val i = android.content.Intent(android.speech.RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                .putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE_MODEL, android.speech.RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(android.speech.RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                .putExtra(android.speech.RecognizerIntent.EXTRA_MAX_RESULTS, 1)
                .putExtra(android.speech.RecognizerIntent.EXTRA_CALLING_PACKAGE, packageName)
                .putExtra(android.speech.RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 700L)
                .putExtra(android.speech.RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 500L)
            // Titles to expect (Android 13+): helps it hear "Oppenheimer" instead of "open her mer".
            if (android.os.Build.VERSION.SDK_INT >= 33 && bias.isNotEmpty()) {
                i.putStringArrayListExtra(android.speech.RecognizerIntent.EXTRA_BIASING_STRINGS, ArrayList(bias))
            }
            try { r.startListening(i) } catch (e: Exception) { reply(null, "start_failed") }
        }
    }

    /**
     * Copies the bundled speech model (the voice/stt folder in the APK assets, from the repo folder assets/bundled) into [out]/stt so sherpa-onnx can open it by path.
     * Skips the copy when [out]/stt-ready.json already names [version]. Returns false when the model is not in this build.
     * Files are written as *.part and renamed, so a killed copy never leaves a half file behind.
     */
    private fun copyBundledVoice(out: java.io.File, version: String): Boolean {
        val names = assets.list("voice/stt") ?: return false
        if (names.isEmpty()) return false
        val marker = java.io.File(out, "stt-ready.json")
        val dst = java.io.File(out, "stt")
        if (marker.exists() && marker.readText().contains(version) && names.all { java.io.File(dst, it).length() > 0 }) return true
        dst.mkdirs()
        marker.delete()
        for (n in names) {
            val part = java.io.File(dst, "$n.part")
            assets.open("voice/stt/$n").use { input -> part.outputStream().use { input.copyTo(it, 256 * 1024) } }
            val target = java.io.File(dst, n)
            target.delete()
            if (!part.renameTo(target)) return false
        }
        marker.writeText("{\"version\":\"$version\"}")
        return true
    }

    private fun askMediaPermissionsOnce() {
        if (permissionsAsked) return
        permissionsAsked = true
        MediaPermissions.askOnce(this)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_MIC) {
            pendingMic?.success(grantResults.any { it == PackageManager.PERMISSION_GRANTED })
            pendingMic = null
            return
        }
        // Scans that ran before the permission was given found no files: scan again so Movies and Music fill in.
        if (requestCode == MediaPermissions.REQUEST && grantResults.any { it == PackageManager.PERMISSION_GRANTED }) {
            MediaPermissions.rescan()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        FlutterDiscord(this).register(messenger) // Discord Rich Presence (discord.dart)

        MethodChannel(messenger, "pek/mpv").setMethodCallHandler { call, result ->
            val c = mpv
            if (c == null) {
                result.error("no_player", "The player is not ready yet", null)
                return@setMethodCallHandler
            }
            try {
                when (call.method) {
                    "load" -> {
                        c.setDvdDevice(call.argument<String>("dvdDevice"))     // a disc (dvd://...) or null
                        c.load(
                            call.argument<String>("url") ?: "",
                            call.argument<Number>("startSec")?.toDouble() ?: 0.0,
                            call.argument<String>("title") ?: "",
                            "{}"
                        )
                    }
                    "play" -> c.play()
                    "pause" -> c.pause()
                    "seek" -> c.seek(call.argument<Number>("sec")?.toDouble() ?: 0.0)
                    "setAudio" -> c.setAudio(call.argument<Number>("id")?.toInt() ?: 0)
                    "setSubtitle" -> c.setSubtitle(call.argument<Number>("id")?.toInt() ?: -1)
                    "addSubtitle" -> c.addSubtitle(call.argument<String>("url") ?: "", call.argument<String>("label") ?: "")
                    "setMiniRect" -> c.setMiniRect(
                        call.argument<Number>("left")?.toDouble() ?: 0.0,
                        call.argument<Number>("top")?.toDouble() ?: 0.0,
                        call.argument<Number>("width")?.toDouble() ?: 1.0,
                        call.argument<Number>("height")?.toDouble() ?: 1.0
                    )
                    "fullscreen" -> c.setFullscreen()
                    "destroy" -> c.destroy()
                    else -> { result.notImplemented(); return@setMethodCallHandler }
                }
                result.success(null)
            } catch (t: Throwable) {
                result.error("mpv_error", t.message, null)
            }
        }

        // Settings > Video output / Audio output: the same MpvController switches the web UI's PekAndroid.mpv* methods used.
        MethodChannel(messenger, "pek/output").setMethodCallHandler { call, result ->
            val c = mpv
            if (c == null) {
                result.error("no_player", "The player is not ready yet", null)
                return@setMethodCallHandler
            }
            try {
                when (call.method) {
                    "video" -> result.success(mapOf(
                        "matchRate" to c.isMatchRate(),
                        "hdr" to c.isHdrOut(),
                        "displayHdr" to c.displayHdr()
                    ))
                    "setMatchRate" -> { c.setMatchRate(call.argument<Boolean>("on") ?: false); result.success(null) }
                    "setHdr" -> { c.setHdr(call.argument<Boolean>("on") ?: false); result.success(null) }
                    "audio" -> {
                        val support = JSONObject(c.passthroughSupportJson())
                        result.success(mapOf(
                            "on" to toPlain(JSONArray(c.passthroughJson())),
                            "known" to support.optBoolean("known", false),
                            "formats" to toPlain(support.optJSONArray("formats") ?: JSONArray())
                        ))
                    }
                    "audioFx" -> result.success(c.audioFxJson())
                    "setAudioFx" -> { c.setAudioFx(call.argument<String>("json") ?: "{}"); result.success(null) }
                    "setPassthrough" -> {
                        c.setPassthrough(call.argument<String>("codec") ?: "", call.argument<Boolean>("on") ?: false)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                result.error("output_error", t.message, null)
            }
        }

        musicChannel = MethodChannel(messenger, "pek/music").also { ch ->
            ch.setMethodCallHandler { call, result ->
                val m = music
                if (m == null) { result.success(null); return@setMethodCallHandler }
                try {
                    when (call.method) {
                        "meta" -> m.meta(
                            call.argument<String>("title") ?: "",
                            call.argument<String>("artist") ?: "",
                            call.argument<String>("album") ?: "",
                            call.argument<String>("art") ?: ""
                        )
                        "state" -> m.state(
                            call.argument<Boolean>("active") ?: false,
                            call.argument<Boolean>("buffering") ?: false,
                            call.argument<Number>("positionMs")?.toLong() ?: 0L,
                            call.argument<Number>("durationMs")?.toLong() ?: 0L
                        )
                        "end" -> m.end()
                        else -> { result.notImplemented(); return@setMethodCallHandler }
                    }
                    result.success(null)
                } catch (t: Throwable) {
                    result.error("music_error", t.message, null)
                }
            }
        }

        MethodChannel(messenger, "pek/plugins").setMethodCallHandler { call, result ->
            when (call.method) {
                "call" -> {
                    val json = call.arguments as? String ?: "{}"
                    pluginPool.execute {
                        val answer = pythonCall(json)
                        runOnUiThread { result.success(answer) }
                    }
                }
                "deviceProfile" -> pluginPool.execute {          // listing the decoders takes a moment
                    val profile = com.pektv.app.DeviceProfile.read(applicationContext)
                    runOnUiThread { result.success(profile) }
                }
                "pickFile" -> pickFile(call.argument<String>("ext") ?: "pek", result)
                "openUrl" -> result.success(openUrl(call.arguments as? String ?: ""))
                "openApp" -> result.success(openStreamingApp(call.argument<String>("packages") ?: "", call.argument<String>("url") ?: ""))
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "pek/mpv/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) { events = sink }
            override fun onCancel(arguments: Any?) { events = null }
        })

        // "New version available" screen (app_update.dart). The apk is copied into a PackageInstaller session, which can take a
        // moment for a large file, so install() runs on the worker pool and answers later.
        updateChannel = MethodChannel(messenger, "pek/update").also { ch ->
            AppUpdater.onStatus = { status, message ->
                runOnUiThread { ch.invokeMethod("status", mapOf("status" to status, "message" to message)) }
            }
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "info" -> result.success(AppUpdater.info(applicationContext))
                    "openInstallSettings" -> result.success(AppUpdater.openInstallSettings(this))
                    "install" -> {
                        val path = call.argument<String>("path") ?: ""
                        pluginPool.execute {
                            val err = AppUpdater.install(applicationContext, path)
                            runOnUiThread { result.success(err) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        pipChannel = MethodChannel(messenger, "pek/pip").also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "supported" -> result.success(pipSupported())
                    "set" -> {
                        pipAllowed = call.argument<Boolean>("allowed") ?: false
                        pipPlaying = call.argument<Boolean>("playing") ?: false
                        updatePipParams()
                        result.success(null)
                    }
                    "enter" -> result.success(enterPip())
                    else -> result.notImplemented()
                }
            }
        }
        setupSystemVoice(messenger)
        hostChannel = MethodChannel(messenger, "pek/host")
        MethodChannel(messenger, "pek/host").setMethodCallHandler { call, result ->
            when (call.method) {
                // Microphone for voice search (voice.dart): true when allowed, asks once if not.
                "micPermission" -> {
                    if (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                        result.success(true)
                    } else if (pendingMic != null) {
                        result.success(false)
                    } else {
                        pendingMic = result
                        requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), REQ_MIC)
                    }
                }
                // Bundled speech model (voice.dart / voice_models.dart): copy the bundled voice/stt assets into the app's voice folder, off the UI thread.
                "installVoice" -> {
                    val dir = call.argument<String>("dir")
                    val version = call.argument<String>("version")
                    if (dir == null || version == null) {
                        result.success(false)
                    } else {
                        Thread {
                            val ok = try { copyBundledVoice(java.io.File(dir), version) } catch (_: Exception) { false }
                            runOnUiThread { result.success(ok) }
                        }.start()
                    }
                }
                "initialLink" -> {
                    result.success(pendingLink)
                    pendingLink = null
                }
                // The same test as MainActivity.phone: false on Android TV / leanback boxes (html.pek-tv in the web UI).
                "isPhone" -> {
                    val ui = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
                    val isTv = ui?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
                        packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
                    result.success(!isTv && packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN))
                }
                // What this device is and what it is called: shown in the sign-in email and on the website's verify page
                // ("Android TV" / "Living room TV"). The name is the one the owner gave the device in Android's settings, if any.
                "deviceInfo" -> {
                    val ui = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
                    val isTv = ui?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
                        packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
                    val type = if (isTv) "Android TV" else if (resources.configuration.smallestScreenWidthDp >= 600) "Android tablet" else "Android phone"
                    val given = try { Settings.Global.getString(contentResolver, "device_name") } catch (e: Exception) { null }
                    val model = listOf(Build.MANUFACTURER ?: "", Build.MODEL ?: "").filter { it.isNotBlank() }
                        .let { if (it.size == 2 && it[1].startsWith(it[0], ignoreCase = true)) it[1] else it.joinToString(" ") }
                    result.success(mapOf("type" to type, "name" to (given?.takeIf { it.isNotBlank() } ?: model.ifBlank { "Android device" })))
                }
                // A pass the torrent server asks for before it starts a stream (backend/torrent_routes.cpp). Dart only asks for one
                // after a plugin has handed it a release (torrent.dart), so nothing else on the device can start a torrent.
                "torrentGrant" -> result.success(NativeBridge.mintTorrentGrant())
                "apiToken" -> result.success(com.pektv.app.Boot.token)   // the local server's per-launch token (api.dart sends it on every request)
                // "All files access" (Android 11+): needed to open folders on a USB drive / SD card. Older Android has no such switch (true).
                "allFilesAccess" -> result.success(Build.VERSION.SDK_INT < Build.VERSION_CODES.R || android.os.Environment.isExternalStorageManager())
                // Opens Android's switch for PEK TV; if a box has no such screen, the next best settings page.
                "openAllFilesAccess" -> {
                    val pkg = Uri.parse("package:$packageName")
                    val tries = ArrayList<Intent>()
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        tries.add(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, pkg))
                        tries.add(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                    }
                    tries.add(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkg))
                    var opened = false
                    for (i in tries) {
                        try { startActivity(i); opened = true; break } catch (e: Exception) { /* try the next one */ }
                    }
                    result.success(opened)
                }
                "setMulticast" -> {
                    setMulticast(call.argument<Boolean>("on") ?: false)
                    result.success(null)
                }
                // The phone remote (remote_host.dart): k = up | down | left | right | ok | menu. A real Android key press, so it takes the
                // same road as a button on the TV's own remote. false = unknown key (Dart then falls back to its own injection).
                "sendKey" -> result.success(pressRemoteKey(call.argument<String>("k") ?: ""))
                // Navigation sounds (nav_sound.dart): kind 0 = move, 1 = select, 2 = back; volume 0..1. NavSound plays on its own
                // thread, so this returns at once. A device where the sound could not be set up just stays silent.
                "navSound" -> {
                    navSound?.play(call.argument<Int>("kind") ?: 0, (call.argument<Number>("volume") ?: 1.0).toFloat())
                    result.success(null)
                }
                // The phone remote (remote_host.dart): dir 1 = louder, -1 = quieter, 0 = mute / unmute. Moves the system music volume.
                "volume" -> {
                    val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val dir = call.argument<Int>("dir") ?: 0
                    val action = when {
                        dir > 0 -> AudioManager.ADJUST_RAISE
                        dir < 0 -> AudioManager.ADJUST_LOWER
                        else -> AudioManager.ADJUST_TOGGLE_MUTE
                    }
                    am.adjustStreamVolume(AudioManager.STREAM_MUSIC, action, AudioManager.FLAG_SHOW_UI)
                    result.success(null)
                }
                // Where the Flutter side keeps its artwork / title cache (art_cache.dart): files = kept, cache = may be cleared by Android.
                "dirs" -> result.success(mapOf("files" to filesDir.absolutePath, "cache" to cacheDir.absolutePath))
                // The app has loaded (server up, update check done, first real screen built): the splash video may lift once it has ended.
                "splashReady" -> {
                    SplashGate.appReady()
                    askMediaPermissionsOnce()   // no-op unless the splash was in front until now
                    result.success(null)
                }
                "exit" -> {
                    mpv?.destroy()
                    result.success(null)
                    finishAndRemoveTask()
                    // The server and the Python plugins run on their own threads; ending the process stops them.
                    Handler(Looper.getMainLooper()).postDelayed({ Process.killProcess(Process.myPid()) }, 300)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onStop() {
        mpv?.onActivityStop()   // also when the small window is closed with its X: the video stops
        super.onStop()
    }

    // ---------------- Picture in picture ----------------
    // Home (or the player's top bar button) shrinks the activity into a small floating window; mpv's surface is part of it, so the
    // picture keeps playing. Dart (pip.dart) says when a player screen wants this and whether the video is playing; in the small
    // window the player draws nothing but the picture.
    private var pipChannel: MethodChannel? = null
    private var pipAllowed = false
    private var pipPlaying = false
    private var pipReceiver: BroadcastReceiver? = null
    private val pipToggleAction = "com.pektv.app.PIP_TOGGLE"

    private fun isTvBox(): Boolean {
        val ui = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        return ui?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION || packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    }

    private fun pipSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !isTvBox() && packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    /** The window takes the film's shape, within what Android allows (between 1:2.39 and 2.39:1). */
    private fun pipRatio(): Rational {
        val shape = mpv?.videoShape() ?: return Rational(16, 9)
        val r = shape.first.toDouble() / shape.second.toDouble()
        return when {
            r > 2.39 -> Rational(239, 100)
            r < 1 / 2.39 -> Rational(100, 239)
            else -> Rational(shape.first, shape.second)
        }
    }

    private fun pipParams(): PictureInPictureParams {
        val b = PictureInPictureParams.Builder().setAspectRatio(pipRatio())
        val label = if (pipPlaying) "Pause" else "Play"
        val icon = Icon.createWithResource("android", if (pipPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play)
        val tap = PendingIntent.getBroadcast(this, 1, Intent(pipToggleAction).setPackage(packageName), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        b.setActions(listOf(RemoteAction(icon, label, label, tap)))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            b.setAutoEnterEnabled(pipAllowed && pipPlaying)   // Home / the gesture shrinks the app smoothly, no onUserLeaveHint needed
            b.setSeamlessResizeEnabled(false)                  // video: no stretched frames while the window resizes
        }
        return b.build()
    }

    private fun updatePipParams() {
        if (!pipSupported()) return
        try { setPictureInPictureParams(pipParams()) } catch (t: Throwable) { /* not allowed right now: the next update sets it */ }
    }

    private fun enterPip(): Boolean {
        if (!pipSupported() || isInPictureInPictureMode) return false
        return try { enterPictureInPictureMode(pipParams()) } catch (t: Throwable) { false }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Android 12+ already did it through setAutoEnterEnabled; this covers Android 8 - 11.
        if (pipAllowed && pipPlaying && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) enterPip()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (isInPictureInPictureMode) {
            val r = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) { pipChannel?.invokeMethod("toggle", null) }
            }
            pipReceiver = r
            val filter = IntentFilter(pipToggleAction)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED) else registerReceiver(r, filter)
        } else {
            unregisterPipReceiver()
            hideSystemBars()
        }
        pipChannel?.invokeMethod("state", isInPictureInPictureMode)
    }

    private fun unregisterPipReceiver() {
        pipReceiver?.let { try { unregisterReceiver(it) } catch (e: Exception) { /* already gone */ } }
        pipReceiver = null
    }

    override fun onResume() {
        super.onResume()
        // Closing the small window with its X, or coming back after it was closed, leaves Dart with a stale "small window" flag.
        pipChannel?.invokeMethod("state", isInPictureInPictureMode)
    }

    override fun onDestroy() {
        releaseSystemListen()
        try { tts?.shutdown() } catch (_: Exception) {}
        tts = null
        unregisterPipReceiver()
        pipChannel = null
        pluginPool.shutdown()
        AppUpdater.onStatus = null
        updateChannel = null
        events = null
        setMulticast(false)
        music?.destroy()          // also stops MusicService: without this activity there is no queue to control
        music = null
        navSound?.release()
        navSound = null
        mpv?.destroy()
        super.onDestroy()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    @Suppress("DEPRECATION")
    private fun hideSystemBars() {
        window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_FULLSCREEN
            or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY)
    }
}

// JSONObject -> plain Map / List for the Flutter standard codec.
private fun JSONObject.toMap(): Map<String, Any?> {
    val out = HashMap<String, Any?>()
    for (k in keys()) out[k] = toPlain(opt(k))
    return out
}

private fun toPlain(v: Any?): Any? = when {
    v == null || v === JSONObject.NULL -> null
    v is JSONObject -> v.toMap()
    v is JSONArray -> (0 until v.length()).map { toPlain(v.opt(it)) }
    else -> v
}
