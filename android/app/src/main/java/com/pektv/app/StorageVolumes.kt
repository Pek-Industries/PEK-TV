package com.pektv.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.storage.StorageManager
import android.os.storage.StorageVolume
import android.system.Os
import android.util.Log
import java.io.File

/**
 * Keeps a small file up to date with every mounted storage volume (internal storage, USB drives, SD cards): one line per volume,
 * "label<TAB>path". The C++ server reads it (PEK_VOLUMES_FILE) to fill the folder picker, because Android does not let an app list
 * /storage, so a USB drive at /storage/XXXX-XXXX can only be found through StorageManager. Reading the folder itself still needs
 * "All files access" (MANAGE_EXTERNAL_STORAGE), which PEK TV already declares.
 */
object StorageVolumes {
    private const val FILE_NAME = "volumes.txt"
    @Volatile private var receiver: BroadcastReceiver? = null

    /** Call before the server starts: tells it where the file is. */
    fun init(ctx: Context, root: File) {
        val f = File(root, FILE_NAME)
        try { Os.setenv("PEK_VOLUMES_FILE", f.absolutePath, true) } catch (e: Throwable) { Log.w("PEK", "PEK_VOLUMES_FILE not set", e) }
        refresh(ctx, root)
        register(ctx, root)
    }

    fun refresh(ctx: Context, root: File) {
        try {
            val lines = LinkedHashMap<String, String>() // path -> label
            val sm = ctx.getSystemService(Context.STORAGE_SERVICE) as? StorageManager
            sm?.storageVolumes?.forEach { v ->
                if (v.state != android.os.Environment.MEDIA_MOUNTED && v.state != android.os.Environment.MEDIA_MOUNTED_READ_ONLY) return@forEach
                val dir = volumeDir(v) ?: return@forEach
                val label = if (v.isPrimary) "Internal storage" else (v.getDescription(ctx)?.takeIf { it.isNotBlank() } ?: "USB / SD")
                lines[dir.absolutePath] = label
            }
            // Fallback for odd firmware: app-specific dirs on each volume ("/storage/XXXX-XXXX/Android/data/<pkg>/files") reveal the root.
            ctx.getExternalFilesDirs(null).forEach { d ->
                val p = d?.absolutePath ?: return@forEach
                val i = p.indexOf("/Android/")
                if (i > 0) lines.putIfAbsent(p.substring(0, i), if (p.startsWith("/storage/emulated")) "Internal storage" else "USB / SD")
            }
            File(root, FILE_NAME).writeText(lines.entries.joinToString("\n") { "${it.value}\t${it.key}" } + "\n")
        } catch (e: Throwable) {
            Log.w("PEK", "storage volumes not listed", e)
        }
    }

    private fun volumeDir(v: StorageVolume): File? {
        if (Build.VERSION.SDK_INT >= 30) return v.directory
        return try { (StorageVolume::class.java.getMethod("getPath").invoke(v) as? String)?.let { File(it) } } catch (e: Throwable) { null }
    }

    // A drive plugged in (or taken out) while the app runs: rewrite the file so the picker shows it at once.
    private fun register(ctx: Context, root: File) {
        if (receiver != null) return
        val app = ctx.applicationContext
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) { refresh(app, root) }
        }
        val f = IntentFilter().apply {
            addAction(Intent.ACTION_MEDIA_MOUNTED); addAction(Intent.ACTION_MEDIA_UNMOUNTED); addAction(Intent.ACTION_MEDIA_EJECT)
            addAction(Intent.ACTION_MEDIA_REMOVED); addAction(Intent.ACTION_MEDIA_BAD_REMOVAL); addAction(Intent.ACTION_MEDIA_CHECKING)
            addDataScheme("file")
        }
        try {
            if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(r, f, Context.RECEIVER_EXPORTED) else app.registerReceiver(r, f)
            receiver = r
        } catch (e: Throwable) { Log.w("PEK", "storage receiver not registered", e) }
    }
}
