package com.example.pennywise

import android.os.Build
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// A FragmentActivity (not FlutterActivity) because the fingerprint prompt
// used by App Lock (local_auth / BiometricPrompt) needs one. SmsBridge only
// needs an Activity, which this still is.
class MainActivity : FlutterFragmentActivity() {
    /** Automatic transaction detection from M-Pesa / Airtel SMS. */
    private var smsBridge: SmsBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        smsBridge = SmsBridge(this, flutterEngine.dartExecutor.binaryMessenger)

        // App Lock: hide PennyWise's preview in the recent-apps screen, and
        // report the Android version (biometrics are offered on 9+ only).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pennywise/privacy")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hideRecentsPreview" -> {
                        val hide = call.arguments as? Boolean ?: false
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            // Android 13+: the preview is blank, screenshots
                            // inside the app still work.
                            setRecentsScreenshotEnabled(!hide)
                        }
                        result.success(null)
                    }
                    "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Still delivered for Activity.requestPermissions, used by SmsBridge")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == SmsBridge.PERMISSION_REQUEST_CODE) {
            smsBridge?.onPermissionResult(grantResults)
        }
    }

    override fun onDestroy() {
        smsBridge?.dispose()
        smsBridge = null
        super.onDestroy()
    }
}
