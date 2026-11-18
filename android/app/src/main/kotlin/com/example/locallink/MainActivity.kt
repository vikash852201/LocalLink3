package com.example.locallink

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "locallink/network")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquireMulticastLock" -> {
                        try {
                            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                            if (multicastLock == null) {
                                multicastLock = wifi.createMulticastLock("LocalLinkMulticast").apply {
                                    setReferenceCounted(false)
                                }
                            }
                            if (multicastLock?.isHeld != true) multicastLock?.acquire()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("MULTICAST_LOCK", e.message, null)
                        }
                    }
                    "releaseMulticastLock" -> {
                        if (multicastLock?.isHeld == true) multicastLock?.release()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
