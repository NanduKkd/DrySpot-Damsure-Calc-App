import java.io.FileInputStream
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
