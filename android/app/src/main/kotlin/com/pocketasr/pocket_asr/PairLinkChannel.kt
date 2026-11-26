package com.pocketasr.pocket_asr

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class PairLinkChannel(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    companion object {
        const val NAME = "pocket_asr/pair_link"
    }

    private val channel = MethodChannel(messenger, NAME)
    private var pending: String? = null
    private var installed = false

    fun install() {
        channel.setMethodCallHandler(this)
        installed = true
    }

    fun shutdown() {
        installed = false
        pending = null
        channel.setMethodCallHandler(null)
    }

    fun deliver(uri: String) {
        if (installed) {
            channel.invokeMethod("pairLink", uri)
        } else {
            pending = uri
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "pendingPairLink") {
            result.success(pending)
            pending = null
        } else {
            result.notImplemented()
        }
    }
}
