import java.io.FileInputStream
import java.net.URI
import java.nio.charset.StandardCharsets
import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val requiredSigningProperties = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")

if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

val releaseSigningProblems = buildList {
    if (!keystorePropertiesFile.isFile) {
        add("android/key.properties is missing")
    } else {
        requiredSigningProperties.filter { keystoreProperties.getProperty(it).isNullOrBlank() }
            .forEach { add("android/key.properties is missing $it") }
        val storeFilePath = keystoreProperties.getProperty("storeFile")
        if (!storeFilePath.isNullOrBlank() && !rootProject.file(storeFilePath).isFile) {
            add("the configured release keystore file is missing or unreadable")
        }
    }
}
val hasCompleteReleaseSigning = releaseSigningProblems.isEmpty()

fun stagingOriginFromDartDefines(): String? {
    val encoded = project.findProperty("dart-defines")?.toString() ?: return null
    return encoded.split(',').mapNotNull { value ->
        runCatching { String(Base64.getDecoder().decode(value), StandardCharsets.UTF_8) }.getOrNull()
    }.firstOrNull { value -> value.startsWith("DAMSURE_STAGING_ORIGIN=") }
        ?.removePrefix("DAMSURE_STAGING_ORIGIN=")
}

fun flutterAppFlavorFromDartDefines(): String? {
    val encoded = project.findProperty("dart-defines")?.toString() ?: return null
    return encoded.split(',').mapNotNull { value ->
        runCatching { String(Base64.getDecoder().decode(value), StandardCharsets.UTF_8) }.getOrNull()
    }.firstOrNull { value -> value.startsWith("FLUTTER_APP_FLAVOR=") }
        ?.removePrefix("FLUTTER_APP_FLAVOR=")
}

fun requireStagingOriginAtCompileTime() {
    val origin = stagingOriginFromDartDefines()
    check(!origin.isNullOrBlank()) {
        "Staging builds require --dart-define=DAMSURE_STAGING_ORIGIN=https://staging-host"
    }
    val uri = runCatching { URI(origin) }.getOrNull()
    check(uri != null && uri.scheme == "https" && uri.host != null && uri.port == -1 &&
        (uri.path.isNullOrEmpty() || uri.path == "/") && uri.query == null && uri.fragment == null &&
        uri.userInfo == null) {
        "DAMSURE_STAGING_ORIGIN must be an HTTPS origin without path, port, credentials, query, or fragment"
    }
}

android {
    namespace = "com.dryspotuppala"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.dryspotuppala"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "environment"
    productFlavors {
        create("production") {
            dimension = "environment"
            applicationId = "com.dryspotuppala"
            resValue("string", "app_name", "DrySpot Uppala")
        }
        create("staging") {
            dimension = "environment"
            applicationId = "com.dryspotuppala.staging"
            resValue("string", "app_name", "DrySpot Uppala Staging")
        }
    }

    signingConfigs {
        if (hasCompleteReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile =
                    rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            if (hasCompleteReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

// Do not silently produce an unsigned/debug-signed release artifact.  Values
// are intentionally never included in this diagnostic.
tasks.configureEach {
    if (name.startsWith("compileFlutterBuildStaging")) {
        doFirst {
            if (flutterAppFlavorFromDartDefines() == "staging") {
                requireStagingOriginAtCompileTime()
            }
        }
    }
    if (name in setOf("assembleRelease", "bundleRelease", "packageRelease", "signReleaseBundle")) {
        doFirst {
            check(hasCompleteReleaseSigning) {
                "Release signing is not configured: ${releaseSigningProblems.joinToString("; ")}. " +
                    "See docs/current/android-release-runbook.md."
            }
        }
    }
}

flutter {
    source = "../.."
}
