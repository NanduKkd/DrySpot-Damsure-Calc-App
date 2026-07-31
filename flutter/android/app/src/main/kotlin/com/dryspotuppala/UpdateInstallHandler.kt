package com.dryspotuppala

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.StatFs
import androidx.core.content.FileProvider
import java.io.File
import java.security.MessageDigest
import java.util.Locale

/**
 * Native side of the update trust boundary. It never accepts a package name,
 * certificate, URI authority, or download location from Dart.
 */
class UpdateInstallHandler(private val context: Context) {
    fun installedPackage(): Map<String, Any> {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        return mapOf(
            "versionCode" to versionCode(info),
            "versionName" to (info.versionName ?: ""),
        )
    }

    fun availableCacheBytes(): Long = StatFs(context.cacheDir.absolutePath).availableBytes

    fun canRequestPackageInstalls(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            context.packageManager.canRequestPackageInstalls()

    fun onHostResumed() {
        // Deliberately no action: installer cancellation/denial cannot clear a
        // required policy or silently relaunch the installer.
    }

    fun verify(arguments: Any?): Map<String, Any> = verifyArtifact(arguments).toWire()

    fun launch(arguments: Any?): Map<String, Any> {
        val verified = verifyArtifact(arguments)
        if (verified != Failure.NONE) return verified.toWire()
        if (!canRequestPackageInstalls()) return Failure.PERMISSION_DENIED.toWire()
        val request = parseRequest(arguments) ?: return Failure.INVALID_REQUEST.toWire()
        val file = privateArtifact(request.path) ?: return Failure.ARTIFACT_UNAVAILABLE.toWire()
        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.update_file_provider",
            file,
        )
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        intent.clipData = android.content.ClipData.newRawUri("APK", uri)
        if (intent.resolveActivity(context.packageManager) == null) {
            return Failure.INSTALLER_UNAVAILABLE.toWire()
        }
        context.startActivity(intent)
        return Failure.NONE.toWire()
    }

    private fun verifyArtifact(arguments: Any?): Failure {
        val request = parseRequest(arguments) ?: return Failure.INVALID_REQUEST
        if (context.packageName != BuildConfig.UPDATE_EXPECTED_PACKAGE_ID ||
            request.versionCode <= installedVersionCode()) {
            return Failure.VERSION_MISMATCH
        }
        val file = privateArtifact(request.path) ?: return Failure.ARTIFACT_UNAVAILABLE
        val archive = archiveInfo(file) ?: return Failure.ARTIFACT_UNAVAILABLE
        if (archive.packageName != BuildConfig.UPDATE_EXPECTED_PACKAGE_ID) {
            return Failure.PACKAGE_MISMATCH
        }
        if (versionCode(archive) != request.versionCode ||
            archive.versionName != request.versionName) {
            return Failure.VERSION_MISMATCH
        }
        val expectedCertificate = BuildConfig.UPDATE_PINNED_CERTIFICATE_SHA256
        if (!isPinnedSingleSigner(archive, expectedCertificate)) {
            return Failure.CERTIFICATE_MISMATCH
        }
        val installed = installedInfo() ?: return Failure.CERTIFICATE_MISMATCH
        if (!isPinnedSingleSigner(installed, expectedCertificate)) {
            return Failure.CERTIFICATE_MISMATCH
        }
        return Failure.NONE
    }

    private fun installedVersionCode(): Long = installedInfo()?.let(::versionCode) ?: Long.MAX_VALUE

    @Suppress("DEPRECATION")
    private fun installedInfo(): PackageInfo? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getPackageInfo(
                context.packageName,
                PackageManager.PackageInfoFlags.of(
                    PackageManager.GET_SIGNING_CERTIFICATES.toLong(),
                ),
            )
        } else {
            context.packageManager.getPackageInfo(
                context.packageName,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    PackageManager.GET_SIGNING_CERTIFICATES
                } else {
                    PackageManager.GET_SIGNATURES
                },
            )
        }
    } catch (_: PackageManager.NameNotFoundException) {
        null
    }

    @Suppress("DEPRECATION")
    private fun archiveInfo(file: File): PackageInfo? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getPackageArchiveInfo(
                file.absolutePath,
                PackageManager.PackageInfoFlags.of(
                    PackageManager.GET_SIGNING_CERTIFICATES.toLong(),
                ),
            )
        } else {
            context.packageManager.getPackageArchiveInfo(
                file.absolutePath,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    PackageManager.GET_SIGNING_CERTIFICATES
                } else {
                    PackageManager.GET_SIGNATURES
                },
            )
        }

    @Suppress("DEPRECATION")
    private fun isPinnedSingleSigner(info: PackageInfo, expected: String): Boolean {
        val certificates = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signingInfo = info.signingInfo ?: return false
            if (signingInfo.hasMultipleSigners()) return false
            if (signingInfo.signingCertificateHistory.size != 1) return false
            signingInfo.apkContentsSigners
        } else {
            info.signatures
        }
        if (certificates == null || certificates.size != 1) return false
        return sha256(certificates.single().toByteArray()) == expected
    }

    private fun privateArtifact(rawPath: String): File? = try {
        val root = File(context.cacheDir, "updates").canonicalFile
        val file = File(rawPath).canonicalFile
        val expectedName = Regex("damsure-[1-9][0-9]*\\.apk")
        if (file.parentFile != root || !expectedName.matches(file.name) || !file.isFile) {
            null
        } else {
            file
        }
    } catch (_: Exception) {
        null
    }

    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()

    private fun sha256(value: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(value)
        .joinToString("") { byte -> String.format(Locale.US, "%02X", byte) }

    private fun Failure.toWire(): Map<String, Any> =
        if (this == Failure.NONE) mapOf("ok" to true) else mapOf("ok" to false, "failure" to wireName)

    private data class Request(val path: String, val versionCode: Long, val versionName: String)

    private fun parseRequest(arguments: Any?): Request? {
        val map = arguments as? Map<*, *> ?: return null
        val path = map["path"] as? String ?: return null
        val code = (map["versionCode"] as? Number)?.toLong() ?: return null
        val name = map["versionName"] as? String ?: return null
        return if (path.isBlank() || code <= 0 || name.isBlank()) null else Request(path, code, name)
    }

    private enum class Failure(val wireName: String) {
        NONE(""),
        INVALID_REQUEST("invalidRequest"),
        PACKAGE_MISMATCH("packageMismatch"),
        VERSION_MISMATCH("versionMismatch"),
        CERTIFICATE_MISMATCH("certificateMismatch"),
        ARTIFACT_UNAVAILABLE("artifactUnavailable"),
        INSTALLER_UNAVAILABLE("installerUnavailable"),
        PERMISSION_DENIED("permissionDenied"),
    }
}
