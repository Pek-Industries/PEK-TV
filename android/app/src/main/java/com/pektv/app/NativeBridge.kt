package com.pektv.app

object NativeBridge {
    init { System.loadLibrary("pek") }
    @JvmStatic external fun startServer(rootDir: String)
    @JvmStatic external fun tlsDiag(): String   // temporary diagnostic
    @JvmStatic external fun mintTorrentGrant(): String   // a pass for starting one torrent: the server refuses /api/torrent/start without it
}
