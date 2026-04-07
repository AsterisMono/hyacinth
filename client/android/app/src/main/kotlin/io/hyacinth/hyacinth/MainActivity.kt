package io.hyacinth.hyacinth

import android.content.pm.PackageManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
