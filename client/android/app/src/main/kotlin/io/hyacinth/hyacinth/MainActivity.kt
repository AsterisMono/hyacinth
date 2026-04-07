package io.hyacinth.hyacinth

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // M8 — foreground service control. Dart calls start() in
        // initState(); stop() in dispose(). Catches the inevitable
        // SecurityException on devices that haven't granted
        // POST_NOTIFICATIONS so the app keeps running even if the
        // foreground stub fails to attach.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "io.hyacinth/foreground_service",
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        val intent = Intent(this, WsForegroundService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    }
                    "stop" -> {
                        stopService(Intent(this, WsForegroundService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: SecurityException) {
                result.error("PERMISSION_DENIED", e.message, null)
            } catch (e: Exception) {
                result.error("ERROR", e.message, null)
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "io.hyacinth/secure_settings",
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "hasPermission" -> result.success(
                        checkSelfPermission("android.permission.WRITE_SECURE_SETTINGS")
                            == PackageManager.PERMISSION_GRANTED
                    )
                    "currentBrightness" -> result.success(
                        Settings.System.getInt(
                            contentResolver,
                            Settings.System.SCREEN_BRIGHTNESS,
                        )
                    )
                    "currentBrightnessMode" -> result.success(
                        Settings.System.getInt(
                            contentResolver,
                            Settings.System.SCREEN_BRIGHTNESS_MODE,
                        )
                    )
                    "currentScreenOffTimeout" -> result.success(
                        Settings.System.getInt(
                            contentResolver,
                            Settings.System.SCREEN_OFF_TIMEOUT,
                        )
                    )
                    "setBrightness" -> {
                        val v = (call.argument<Int>("value") ?: 0).coerceIn(0, 255)
                        Settings.System.putInt(
                            contentResolver,
                            Settings.System.SCREEN_BRIGHTNESS,
                            v,
                        )
                        result.success(null)
                    }
                    "setBrightnessMode" -> {
                        val v = call.argument<Int>("mode") ?: 0
                        Settings.System.putInt(
                            contentResolver,
                            Settings.System.SCREEN_BRIGHTNESS_MODE,
                            v,
                        )
                        result.success(null)
                    }
                    "setScreenOffTimeout" -> {
                        val v = call.argument<Int>("ms") ?: Int.MAX_VALUE
                        Settings.System.putInt(
                            contentResolver,
                            Settings.System.SCREEN_OFF_TIMEOUT,
                            v,
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: SecurityException) {
                result.error("PERMISSION_DENIED", e.message, null)
            } catch (e: Exception) {
                result.error("ERROR", e.message, null)
            }
        }
    }
}
