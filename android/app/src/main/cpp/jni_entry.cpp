// Android replacement for main() in core.cpp (core.cpp itself is NOT
// compiled into the app yet because it embeds Python).
#include <jni.h>
#include <android/log.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <atomic>
#include <string>
#include <thread>
#include <vector>
#include "httplib.h"
#include "server.h"
#include "media_scanner.h"
#include "vfs.h"
#include "torrent_routes.h"

static MediaScanner* g_scanner = nullptr;
static std::atomic<bool> g_started{false};

// The C++ server prints with std::cout. Android drops that, so it is sent into a pipe here and a thread copies every line to
// the system log (tag PEKServer, see `logcat`) and to <root>/backend.log, which the developer console in the app shows
// (flutter_ui/lib/src/dev_console.dart). The file starts over at each launch and again when it passes 2 MB.
static void captureStdio(const std::string& file) {
    int fds[2];
    if (pipe(fds) != 0) return;
    setvbuf(stdout, nullptr, _IOLBF, 0);
    setvbuf(stderr, nullptr, _IONBF, 0);
    if (dup2(fds[1], STDOUT_FILENO) < 0 || dup2(fds[1], STDERR_FILENO) < 0) { close(fds[0]); close(fds[1]); return; }
    close(fds[1]);
    const int rd = fds[0];
    std::thread([rd, file]() {
        FILE* out = fopen(file.c_str(), "w");
        size_t written = 0;
        std::string line;
        char buf[2048];
        ssize_t n;
        while ((n = read(rd, buf, sizeof buf)) > 0) {
            for (ssize_t i = 0; i < n; i++) {
                if (buf[i] != '\n') { line += buf[i]; continue; }
                __android_log_write(ANDROID_LOG_INFO, "PEKServer", line.c_str());
                if (out) {
                    fputs(line.c_str(), out);
                    fputc('\n', out);
                    fflush(out);
                    written += line.size() + 1;
                    if (written > 2u * 1024 * 1024) { fclose(out); out = fopen(file.c_str(), "w"); written = 0; }
                }
                line.clear();
            }
        }
    }).detach();
}

extern "C" JNIEXPORT void JNICALL
Java_com_pektv_app_NativeBridge_startServer(JNIEnv* env, jclass, jstring jRoot, jstring jToken) {
    if (g_started.exchange(true)) return;   // only start once per process

    // Tell OpenSSL where Android keeps its trusted HTTPS certificates,
    // otherwise every https:// request (TMDb) fails verification.
    setenv("SSL_CERT_DIR", "/system/etc/security/cacerts", 1);

    const char* c = env->GetStringUTFChars(jRoot, nullptr);
    std::string root(c);
    env->ReleaseStringUTFChars(jRoot, c);

    // The per-launch token every request to the local server must carry (see PekServer::start). Kept in a local string:
    // it is never put in the environment, where plugin code or a child process could read it.
    std::string token;
    if (jToken) {
        const char* t = env->GetStringUTFChars(jToken, nullptr);
        token = t;
        env->ReleaseStringUTFChars(jToken, t);
    }

    // Bundled Mozilla CA list (downloaded by the workflow). Works on any
    // Android version, even if the device's own certificate store is old.
    // Only point at the bundle if it was actually shipped; otherwise a missing file breaks every HTTPS call.
    {
        std::string pem = root + "/cacert.pem";
        if (access(pem.c_str(), R_OK) == 0) setenv("SSL_CERT_FILE", pem.c_str(), 1);
    }

    captureStdio(root + "/backend.log");   // before anything prints

    std::string plugins = root + "/plugins";
    std::string skins   = root + "/skins";

    // SMB logins: app-private storage, one line per host.
    vfs::init(root + "/net_credentials.tsv");
    setTorrentDataDir(root);   // torrent.json + temporary torrent cache (app-private)

    g_scanner = new MediaScanner(root + "/sources.tsv", root + "/media_cache.tsv");
    g_scanner->loadFromDisk();
    g_scanner->setShowResolver(PekServer::resolveShowName);
    std::thread([]() { g_scanner->scan(); }).detach();

    std::thread([plugins, skins, token]() {
        PekServer::start(8080, plugins, skins,
            []() { return std::vector<std::string>(); },   // Python plugin list: later step
            g_scanner, token);
    }).detach();
}

// A pass for starting one torrent (see torrent_routes.h). The app asks for it only when a plugin is playing something.
extern "C" JNIEXPORT jstring JNICALL
Java_com_pektv_app_NativeBridge_mintTorrentGrant(JNIEnv* env, jclass) {
    return env->NewStringUTF(mintTorrentGrant().c_str());
}

// TEMPORARY DIAGNOSTIC: tries the TMDb proxy three ways and reports what
// happened, so we can see why HTTPS fails. Remove once TMDb works.
extern "C" JNIEXPORT jstring JNICALL
Java_com_pektv_app_NativeBridge_tlsDiag(JNIEnv* env, jclass) {
    auto probe = [](int mode) -> std::string {
        httplib::Client cli("https://tmdb.pekindustries.com");
        cli.set_connection_timeout(8);
        cli.set_read_timeout(8);
        if (mode == 1) cli.set_ca_cert_path("", "/system/etc/security/cacerts");
        if (mode == 2) cli.enable_server_certificate_verification(false);
        if (mode == 3) {
            const char* f = getenv("SSL_CERT_FILE");
            cli.set_ca_cert_path(f ? f : "", "");
        }
        auto r = cli.Get("/search/tv?query=friends");
        if (!r) return httplib::to_string(r.error());
        return "HTTP " + std::to_string(r->status);
    };
    std::string out = "default: " + probe(0) +
                      "\ncacerts dir: " + probe(1) +
                      "\nbundled file: " + probe(3) +
                      "\nno verify: " + probe(2);
    return env->NewStringUTF(out.c_str());
}
