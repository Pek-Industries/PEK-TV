# PEK TV release keep rules (R8).

# JNI: libpek.so registers/looks up these by name, so they and their native methods must keep their names.
-keep class com.pektv.app.NativeBridge { *; }
-keep class com.pektv.app.NativeDiscord { *; }
-keepclasseswithmembernames class * { native <methods>; }

# App code is small and is reached by Class.forName (FlutterHostActivity) and the manifest; keep it whole.
-keep class com.pektv.app.** { *; }

# libmpv calls back into MPVLib from native code.
-keep class dev.jdtech.mpv.** { *; }

# Looked up by name with Class.forName.
-keep class io.flutter.FlutterInjector { *; }
-keep class com.discord.socialsdk.** { *; }

# Embedded Python: plugins call Java through Chaquopy by name.
-keep class com.chaquo.python.** { *; }

# Speech-to-text (sherpa-onnx) native bindings.
-keep class com.k2fsa.sherpa.onnx.** { *; }

# Flutter engine (its own consumer rules cover most of this; belt and braces).
-keep class io.flutter.** { *; }
-dontwarn io.flutter.embedding.**
-dontwarn com.google.android.play.core.**
