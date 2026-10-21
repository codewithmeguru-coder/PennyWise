package com.example.pennywise

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.provider.Telephony
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The Android half of automatic transaction detection (the Dart half is
 * lib/sms/sms_gateway.dart).
 *
 * Privacy: every SMS is checked against the sender list that Dart passes in
 * (M-Pesa / Airtel Money ids). Messages from anyone else are dropped here and
 * never reach Dart, Firestore or the logs.
 *
 * - MethodChannel "pennywise/sms": permission check/request, open Settings,
 *   read matching messages from the inbox since a given time.
 * - EventChannel "pennywise/sms_incoming": matching messages as they arrive,
 *   while the app is open.
 */
class SmsBridge(private val activity: Activity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val PERMISSION_REQUEST_CODE = 4211

        private val PERMISSIONS =
            arrayOf(Manifest.permission.READ_SMS, Manifest.permission.RECEIVE_SMS)

        /** Must match SmsParser.normalizeSender in Dart. */
        fun normalize(address: String?): String =
            (address ?: "").uppercase().replace(Regex("[^A-Z0-9]"), "")
    }

    private var pendingPermissionResult: MethodChannel.Result? = null
    private var receiver: BroadcastReceiver? = null

    init {
        MethodChannel(messenger, "pennywise/sms").setMethodCallHandler(this)
        EventChannel(messenger, "pennywise/sms_incoming").setStreamHandler(this)
    }

    // ---- Method calls --------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasPermission" -> result.success(hasPermission())
            "requestPermission" -> requestPermission(result)
            "openAppSettings" -> {
                val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(Uri.fromParts("package", activity.packageName, null))
                activity.startActivity(intent)
                result.success(null)
            }
            "readInbox" -> {
                if (!hasPermission()) {
                    result.error("NO_PERMISSION", "SMS permission not granted", null)
                    return
                }
                val senders = call.argument<List<String>>("senders")?.toSet() ?: emptySet()
                val since = call.argument<Number>("since")?.toLong() ?: 0L
                // Content queries can be slow on phones with big inboxes, so
                // run off the main thread and reply on it.
                Thread {
                    try {
                        val rows = readInbox(senders, since)
                        activity.runOnUiThread { result.success(rows) }
                    } catch (e: Exception) {
                        activity.runOnUiThread { result.error("READ_FAILED", e.message, null) }
                    }
                }.start()
            }
            else -> result.notImplemented()
        }
    }

    private fun hasPermission(): Boolean = PERMISSIONS.all {
        activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (hasPermission()) {
            result.success("granted")
            return
        }
        if (pendingPermissionResult != null) {
            result.error("BUSY", "A permission request is already open", null)
            return
        }
        pendingPermissionResult = result
        activity.requestPermissions(PERMISSIONS, PERMISSION_REQUEST_CODE)
    }

    /** Called by MainActivity when the user answers the permission dialog. */
    fun onPermissionResult(grantResults: IntArray) {
        val result = pendingPermissionResult ?: return
        pendingPermissionResult = null
        val granted = grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        val status = when {
            granted -> "granted"
            // After a denial, Android stops showing the dialog once the user
            // picked "Don't ask again" (or denied twice). It then reports
            // that no rationale should be shown: only Settings can grant it.
            PERMISSIONS.none { activity.shouldShowRequestPermissionRationale(it) } ->
                "permanentlyDenied"
            else -> "denied"
        }
        result.success(status)
    }

    /**
     * Messages from [senders] received after [since] (epoch millis), oldest
     * first. Only the sender, body and date columns are read.
     */
    private fun readInbox(senders: Set<String>, since: Long): List<Map<String, Any>> {
        val rows = mutableListOf<Map<String, Any>>()
        val cursor = activity.contentResolver.query(
            Telephony.Sms.Inbox.CONTENT_URI,
            arrayOf(Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE),
            "${Telephony.Sms.DATE} > ?",
            arrayOf(since.toString()),
            "${Telephony.Sms.DATE} ASC"
        ) ?: return rows
        cursor.use {
            while (it.moveToNext()) {
                val address = it.getString(0)
                if (normalize(address) !in senders) continue // not M-Pesa/Airtel
                rows.add(mapOf(
                    "sender" to (address ?: ""),
                    "body" to (it.getString(1) ?: ""),
                    "date" to it.getLong(2),
                ))
            }
        }
        return rows
    }

    // ---- Incoming SMS (while the app is open) --------------------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        @Suppress("UNCHECKED_CAST")
        val senders = ((arguments as? Map<String, Any?>)?.get("senders") as? List<String>)
            ?.toSet() ?: emptySet()

        stopReceiver()
        val newReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
                // A long SMS arrives in several parts; join them back up.
                val parts = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
                if (parts.isEmpty()) return
                val address = parts[0].displayOriginatingAddress
                if (normalize(address) !in senders) return // not M-Pesa/Airtel
                events.success(mapOf(
                    "sender" to (address ?: ""),
                    "body" to parts.joinToString("") { p -> p.displayMessageBody ?: "" },
                    "date" to parts[0].timestampMillis,
                ))
            }
        }
        val filter = IntentFilter(Telephony.Sms.Intents.SMS_RECEIVED_ACTION)
        // SMS_RECEIVED is a protected system broadcast, so it may be
        // registered as exported; only the system can send it.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(newReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            activity.registerReceiver(newReceiver, filter)
        }
        receiver = newReceiver
    }

    override fun onCancel(arguments: Any?) = stopReceiver()

    private fun stopReceiver() {
        receiver?.let {
            try {
                activity.unregisterReceiver(it)
            } catch (_: IllegalArgumentException) {
                // Already unregistered.
            }
        }
        receiver = null
    }

    fun dispose() = stopReceiver()
}
