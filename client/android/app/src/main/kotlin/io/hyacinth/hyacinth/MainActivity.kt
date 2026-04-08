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
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

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

    companion object {
        private const val TAG = "Hyacinth"
        private const val CPUFREQ_ROOT = "/sys/devices/system/cpu/cpufreq"

        // M11 — snapshot of pre-powersave cpufreq state, keyed by policy
        // directory path (e.g. "/sys/devices/system/cpu/cpufreq/policy0"),
        // each entry is (originalGovernor, originalMaxFreq). Populated on
        // enterPowersave, consumed and cleared by restore. Held in a
        // `companion object` so it survives single-activity recreation
        // within the process (config changes, backgrounding).
        private val cpuSnapshot = HashMap<String, Pair<String, String>>()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        configureForegroundServiceChannel(messenger)
        configureSecureSettingsChannel(messenger)
        configureRootChannel(messenger)
        configureScreenPowerChannel(messenger)
        configureCpuGovernorChannel(messenger)
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
                                    // The activity is paused after
                                    // lockNow() — `requestDismissKeyguard`
                                    // alone does NOT power the panel back
                                    // on. Acquire a brief wake lock with
                                    // ACQUIRE_CAUSES_WAKEUP first. These
                                    // wake-lock flags are deprecated since
                                    // API 17 but remain the only
                                    // sandboxed-app way to wake the panel
                                    // from a paused activity. The keyguard
                                    // call afterwards still matters
                                    // because the system may show the
                                    // lock screen on top of the woken
                                    // display.
                                    @Suppress("DEPRECATION")
                                    val wakeLock = pm.newWakeLock(
                                        PowerManager.FULL_WAKE_LOCK or
                                            PowerManager.ACQUIRE_CAUSES_WAKEUP or
                                            PowerManager.ON_AFTER_RELEASE,
                                        "Hyacinth:wake",
                                    )
                                    wakeLock.acquire(3_000)
                                    // Don't release immediately — let it
                                    // run its 3s timeout so the panel
                                    // actually stays on. Releasing right
                                    // away can cancel the wake on some
                                    // OEM kernels.
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

    // M11 — auto powersave CPU governor. Tied to the Flutter-side
    // DisplayPage mount/unmount lifecycle. Snapshot + write runs in two
    // phases: phase 1 reads each policy's current governor, max freq,
    // and available frequencies via a single `su -c` shell; phase 2
    // writes `powersave` plus the per-policy minimum available
    // frequency. `restore()` writes the phase-1 snapshot back.
    //
    // The Dart `isSupported()` gates this on the M8.1 cached root flag
    // so calling `enterPowersave` at display-mount time never triggers
    // a Magisk consent prompt unexpectedly. This native `isSupported`
    // only reports whether the `/sys/.../cpufreq` tree exists.
    private fun configureCpuGovernorChannel(messenger: BinaryMessenger) {
        MethodChannel(messenger, "io.hyacinth/cpu_governor")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "isSupported" -> {
                            result.success(File(CPUFREQ_ROOT).isDirectory)
                        }
                        "enterPowersave" -> result.success(enterPowersave())
                        "restore" -> result.success(restorePowersave())
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("ERROR", e.message, null)
                }
            }
    }

    private fun enterPowersave(): Map<String, Any?> {
        cpuSnapshot.clear()

        // Phase 1: read current governor/max_freq/available_frequencies
        // per policy via a single root shell. Output format per line:
        //   <policy_path>|<governor>|<max_freq>|<space-separated freqs>
        val phase1Script = """
            for p in /sys/devices/system/cpu/cpufreq/policy*; do
              [ -d "${'$'}p" ] || continue
              g=${'$'}(cat "${'$'}p/scaling_governor" 2>/dev/null || echo "")
              m=${'$'}(cat "${'$'}p/scaling_max_freq" 2>/dev/null || echo "")
              af=${'$'}(cat "${'$'}p/scaling_available_frequencies" 2>/dev/null || echo "")
              echo "${'$'}p|${'$'}g|${'$'}m|${'$'}af"
            done
        """.trimIndent()
        val r1 = runAsRoot(phase1Script)
        if (!r1.ok) {
            return mapOf(
                "ok" to false,
                "policies" to 0,
                "error" to "phase1 failed: ${r1.stderr.ifBlank { "exit=${r1.exit}" }}",
            )
        }

        // Parse + compute per-policy min freq.
        val writes = ArrayList<Triple<String, String, String>>() // path, minFreq, governor(ignored for write)
        for (rawLine in r1.stdout.lines()) {
            val line = rawLine.trim()
            if (line.isEmpty()) continue
            val parts = line.split("|", limit = 4)
            if (parts.size < 4) continue
            val path = parts[0]
            val gov = parts[1]
            val maxFreq = parts[2]
            val af = parts[3]
            if (path.isEmpty() || gov.isEmpty() || maxFreq.isEmpty()) continue
            val freqs = af.split(Regex("\\s+"))
                .mapNotNull { it.toLongOrNull() }
                .sorted()
            if (freqs.isEmpty()) {
                // No available-frequencies file (or empty): skip this
                // policy entirely so we don't leave the max_freq in an
                // undefined state. We still won't snapshot it.
                Log.w(TAG, "CpuGovernor: skipping $path (no available freqs)")
                continue
            }
            val minFreq = freqs.first().toString()
            cpuSnapshot[path] = Pair(gov, maxFreq)
            writes.add(Triple(path, minFreq, gov))
        }

        if (writes.isEmpty()) {
            return mapOf(
                "ok" to false,
                "policies" to 0,
                "error" to "no writable policies discovered",
            )
        }

        // Phase 2: write powersave + per-policy min freq. Collect
        // per-policy failures but treat the overall call as OK if at
        // least one policy was successfully written.
        val sb = StringBuilder()
        for ((path, minFreq, _) in writes) {
            sb.append("echo powersave > \"$path/scaling_governor\" && ")
            sb.append("echo $minFreq > \"$path/scaling_max_freq\" && ")
            sb.append("echo OK:$path || echo FAIL:$path\n")
        }
        val r2 = runAsRoot(sb.toString())
        var okCount = 0
        val failures = ArrayList<String>()
        for (rawLine in r2.stdout.lines()) {
            val line = rawLine.trim()
            if (line.startsWith("OK:")) okCount++
            else if (line.startsWith("FAIL:")) failures.add(line.removePrefix("FAIL:"))
        }
        if (failures.isNotEmpty()) {
            Log.w(TAG, "CpuGovernor: phase2 partial failures: $failures")
        }

        val ok = okCount > 0
        return mapOf(
            "ok" to ok,
            "policies" to okCount,
            "error" to when {
                !ok && r2.stderr.isNotBlank() -> "phase2 failed: ${r2.stderr}"
                !ok -> "phase2 wrote no policies"
                failures.isNotEmpty() -> "partial: ${failures.size} failed"
                else -> null
            },
        )
    }

    private fun restorePowersave(): Map<String, Any?> {
        if (cpuSnapshot.isEmpty()) {
            return mapOf("ok" to true, "policies" to 0, "error" to null)
        }
        val sb = StringBuilder()
        for ((path, original) in cpuSnapshot) {
            val (gov, maxFreq) = original
            sb.append("echo $gov > \"$path/scaling_governor\" && ")
            sb.append("echo $maxFreq > \"$path/scaling_max_freq\" && ")
            sb.append("echo OK:$path || echo FAIL:$path\n")
        }
        val r = runAsRoot(sb.toString())
        var okCount = 0
        val failures = ArrayList<String>()
        for (rawLine in r.stdout.lines()) {
            val line = rawLine.trim()
            if (line.startsWith("OK:")) okCount++
            else if (line.startsWith("FAIL:")) failures.add(line.removePrefix("FAIL:"))
        }
        if (failures.isNotEmpty()) {
            Log.w(TAG, "CpuGovernor: restore partial failures: $failures")
        }
        // Clear the snapshot unconditionally — a failed restore should
        // not block a subsequent enterPowersave from re-snapshotting
        // from whatever state the device is currently in.
        cpuSnapshot.clear()

        val ok = r.ok && failures.isEmpty()
        return mapOf(
            "ok" to ok,
            "policies" to okCount,
            "error" to when {
                !r.ok && r.stderr.isNotBlank() -> "restore failed: ${r.stderr}"
                failures.isNotEmpty() -> "partial: ${failures.size} failed"
                else -> null
            },
        )
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
