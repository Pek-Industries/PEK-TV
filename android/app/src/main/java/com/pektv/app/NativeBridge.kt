package com.pektv.app

object NativeBridge {
    init { System.loadLibrary("pek") }
    @JvmStatic external fun startServer(rootDir: String, token: String)   // token: every request to 127.0.0.1:8080 must carry it (Boot makes a new one per launch)
    @JvmStatic external fun tlsDiag(): String   // temporary diagnostic
    @JvmStatic external fun mintTorrentGrant(): String   // a pass for starting one torrent: the server refuses /api/torrent/start without it
}
