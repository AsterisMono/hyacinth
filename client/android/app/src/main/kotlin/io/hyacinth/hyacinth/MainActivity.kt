package io.hyacinth.hyacinth

import android.app.KeyguardManager
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/// Hardcoded application id. Used by the root grant strings so we never
/// build them from arbitrary input — this keeps `runAsRoot` calls audited
/// and shell-injection-free. Must match `applicationId` in
/// `app/build.gradle.kts`.
private const val PACKAGE_NAME = "io.hyacinth.hyacinth"

private data class RootResult(
    val ok: Boolean,
    val stdout: String,
    val stderr: String,
    val exit: Int,
)

class MainActivity : FlutterActivity() {
    // M9 — cached ComponentName for the device admin receiver. Built once
    // per activity and reused across every `screen_power` channel call.
    private val adminComponent: ComponentName by lazy {
        ComponentName(this, HyacinthDeviceAdminReceiver::class.java)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        configureForegroundServiceChannel(messenger)
        configureSecureSettingsChannel(messenger)
        configureRootChannel(messenger)
        configureScreenPowerChannel(messenger)
    }

    // M8 — foreground service control. Dart calls start() in
    // initState(); stop() in dispose(). Catches the inevitable
    // SecurityException on devices that haven't granted
    // POST_NOTIFICATIONS so the app keeps running even if the
    // foreground stub fails to attach.
    private fun configureForegroundServiceChannel(messenger: BinaryMessenger) {
        MethodChannel(messenger, "io.hyacinth/foreground_service")
            .setMethodCallHandler { call, result ->
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
    }

    private fun configureSecureSettingsChannel(messenger: BinaryMessenger) {
        MethodChannel(messenger, "io.hyacinth/secure_settings")
            .setMethodCallHandler { call, result ->
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

    // M8.1 — root-based self-grant. Each method runs ONE hardcoded
    // command via `su -c`. We deliberately do NOT expose a generic
    // runAsRoot(cmd) over the channel: keeping the grant strings on the
    // Kotlin side eliminates any shell-injection footgun even from our
    // own Dart code.
    //
    // These methods MUST only be called in response to explicit user
    // action (onboarding step or HealthCheck Fix button). Each `su`
    // call triggers a Magisk/KernelSU consent dialog on first use; the
    // four onboarding calls run back-to-back so the user only sees
    // the prompt once.
    private fun configureRootChannel(messenger: BinaryMessenger) {
        MethodChannel(messenger, "io.hyacinth/root")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasRoot" -> {
                        val r = runAsRoot("id", 3_000)
                        result.success(r.ok && r.stdout.contains("uid=0"))
                    }
                    "grantWriteSecureSettings" -> {
                        val r = runAsRoot(
                            "pm grant $PACKAGE_NAME android.permission.WRITE_SECURE_SETTINGS"
                        )
                        result.success(r.ok)
                    }
                    "grantPostNotifications" -> {
                        val r = runAsRoot(
                            "pm grant $PACKAGE_NAME android.permission.POST_NOTIFICATIONS"
                        )
                        result.success(r.ok)
                    }
                    "whitelistBatteryOpt" -> {
                        val r = runAsRoot(
                            "dumpsys deviceidle whitelist +$PACKAGE_NAME"
                        )
                        result.success(r.ok)
                    }
                    "sleepScreen" -> {
                        val r = runAsRoot("input keyevent 223")
                        result.success(r.ok)
                    }
                    "wakeScreen" -> {
                        val r = runAsRoot("input keyevent 224")
                        result.success(r.ok)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // M9 — screen_power orchestrator. Two-tier strategy:
    //   1. `su -c "input keyevent 223|224"` (preferred, real panel power).
    //   2. `DevicePolicyManager.lockNow()` / `KeyguardManager.requestDismissKeyguard`
    //      when device admin is active.
    // A no-op short-circuit fires when `PowerManager.isInteractive` already
    // matches the target state so the operator can harmlessly flip the
    // toggle at any time.
    private fun configureScreenPowerChannel(messenger: BinaryMessenger) {
        MethodChannel(messenger, "io.hyacinth/screen_power")
            .setMethodCallHandler { call, result ->
                try {
                    val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE)
                        as DevicePolicyManager
                    val pm = getSystemService(Context.POWER_SERVICE)
                        as PowerManager
                    when (call.method) {
                        "isInteractive" -> result.success(pm.isInteractive)
                        "isAdminActive" -> result.success(
                            dpm.isAdminActive(adminComponent)
                        )
                        "requestAdmin" -> {
                            val intent = Intent(
                                DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN
                            ).putExtra(
                                DevicePolicyManager.EXTRA_DEVICE_ADMIN,
                                adminComponent,
                            )
                            // Fire and forget — caller re-checks isAdminActive
                            // after the system dialog closes.
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(null)
                        }
                        "setScreenOn" -> {
                            val on = call.argument<Boolean>("on") ?: true
                            // No-op when already in the target state.
                            if (pm.isInteractive == on) {
                                result.success("noop")
                                return@setMethodCallHandler
                            }
                            // Tier 1: root.
                            val rootCmd = if (on) {
                                "input keyevent 224"
                            } else {
                                "input keyevent 223"
                            }
                            val rr = runAsRoot(rootCmd, 5_000)
                            if (rr.ok) {
                                result.success("root")
                                return@setMethodCallHandler
                            }
                            // Tier 2: device admin.
                            if (dpm.isAdminActive(adminComponent)) {
                                if (on) {
                                    val kg = getSystemService(Context.KEYGUARD_SERVICE)
                                        as KeyguardManager
                                    kg.requestDismissKeyguard(this, null)
                                    result.success("admin")
                                } else {
                                    dpm.lockNow()
                                    result.success("admin")
                                }
                                return@setMethodCallHandler
                            }
                            // Neither tier available.
                            result.error(
                                "no_capability",
                                "Neither root nor device admin is available",
                                null,
                            )
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

    private fun runAsRoot(cmd: String, timeoutMs: Long = 5_000): RootResult {
        return try {
            val process = Runtime.getRuntime().exec(arrayOf("su", "-c", cmd))
            val finished = process.waitFor(
                timeoutMs,
                java.util.concurrent.TimeUnit.MILLISECONDS,
            )
            if (!finished) {
                process.destroyForcibly()
                return RootResult(false, "", "timeout", -1)
            }
            val stdout = process.inputStream.bufferedReader().readText()
            val stderr = process.errorStream.bufferedReader().readText()
            RootResult(process.exitValue() == 0, stdout, stderr, process.exitValue())
        } catch (e: Exception) {
            RootResult(false, "", e.message ?: "error", -1)
        }
    }
}
