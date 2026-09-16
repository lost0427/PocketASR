package com.pocketasr.pocket_asr

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var audioDecodeChannel: AudioDecodeChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        audioDecodeChannel = AudioDecodeChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            applicationContext,
        ).also { it.install() }
    }

    override fun onDestroy() {
        audioDecodeChannel?.shutdown()
        audioDecodeChannel = null
        super.onDestroy()
    }
}
