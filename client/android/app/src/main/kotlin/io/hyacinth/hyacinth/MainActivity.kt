package io.hyacinth.hyacinth

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var homeIntentChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        homeIntentChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "io.hyacinth/home_intent",
        )
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.hasCategory(Intent.CATEGORY_HOME)) {
            homeIntentChannel?.invokeMethod("home_pressed", null)
        }
    }
}
