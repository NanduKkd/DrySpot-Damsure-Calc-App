package com.dryspotuppala

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val installer by lazy { UpdateInstallHandler(this) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.dryspotuppala/update_installer",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "installedPackage" -> result.success(installer.installedPackage())
                "availableCacheBytes" -> result.success(installer.availableCacheBytes())
                "canRequestPackageInstalls" -> result.success(installer.canRequestPackageInstalls())
                "openUnknownSourcesSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            ),
                        )
                    }
                    result.success(null)
                }
                "verifyArtifact" -> result.success(installer.verify(call.arguments))
                "launchInstaller" -> result.success(installer.launch(call.arguments))
                else -> result.notImplemented()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // Dart re-reads installed metadata on its next launch. This explicit
        // re-entry hook intentionally performs no implicit installation or
        // policy clearing after the installer/settings activity returns.
        installer.onHostResumed()
    }
}
