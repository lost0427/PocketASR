package com.pocketasr.pocket_asr

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var audioDecodeChannel: AudioDecodeChannel? = null
    private var audioPickerChannel: AudioPickerChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        audioDecodeChannel = AudioDecodeChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            applicationContext,
        ).also { it.install() }
        audioPickerChannel = AudioPickerChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            this,
        ).also { it.install() }
    }

    @Deprecated("Deprecated in Android; required by the SAF result bridge")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (audioPickerChannel?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        audioPickerChannel?.shutdown()
        audioPickerChannel = null
        audioDecodeChannel?.shutdown()
        audioDecodeChannel = null
        super.onDestroy()
    }
}
