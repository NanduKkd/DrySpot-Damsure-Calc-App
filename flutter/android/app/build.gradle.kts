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
val stagingKeystoreProperties = Properties()
val stagingKeystorePropertiesFile = rootProject.file("staging-key.properties")
val requiredSigningProperties = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")

if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}
if (stagingKeystorePropertiesFile.exists()) {
    FileInputStream(stagingKeystorePropertiesFile).use { stagingKeystoreProperties.load(it) }
}

fun signingProblems(propertiesFile: java.io.File, properties: Properties, label: String): List<String> = buildList {
    if (!propertiesFile.isFile) {
        add("$label signing properties are missing")
    } else {
        requiredSigningProperties.filter { properties.getProperty(it).isNullOrBlank() }
            .forEach { add("$label signing properties are missing $it") }
        val storeFilePath = properties.getProperty("storeFile")
        if (!storeFilePath.isNullOrBlank() && !rootProject.file(storeFilePath).isFile) {
            add("the configured $label keystore file is missing or unreadable")
        }
    }
}
val productionSigningProblems = signingProblems(keystorePropertiesFile, keystoreProperties, "production")
val stagingSigningProblems = signingProblems(stagingKeystorePropertiesFile, stagingKeystoreProperties, "staging")
val hasCompleteProductionSigning = productionSigningProblems.isEmpty()
val hasCompleteStagingSigning = stagingSigningProblems.isEmpty()
val signingIdentitiesDistinct = !hasCompleteProductionSigning && !hasCompleteStagingSigning ||
    keystoreProperties.getProperty("keyAlias") != stagingKeystoreProperties.getProperty("keyAlias") ||
    keystoreProperties.getProperty("storeFile") != stagingKeystoreProperties.getProperty("storeFile")

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

    signingConfigs {
        if (hasCompleteProductionSigning) {
            create("productionRelease") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
        if (hasCompleteStagingSigning) {
            create("stagingRelease") {
                keyAlias = stagingKeystoreProperties.getProperty("keyAlias")
                keyPassword = stagingKeystoreProperties.getProperty("keyPassword")
                storeFile = rootProject.file(stagingKeystoreProperties.getProperty("storeFile"))
                storePassword = stagingKeystoreProperties.getProperty("storePassword")
            }
        }
    }

    flavorDimensions += "environment"
    productFlavors {
        create("production") {
            dimension = "environment"
            applicationId = "com.dryspotuppala"
            resValue("string", "app_name", "DrySpot Uppala")
            if (hasCompleteProductionSigning) signingConfig = signingConfigs.getByName("productionRelease")
        }
        create("staging") {
            dimension = "environment"
            applicationId = "com.dryspotuppala.staging"
            resValue("string", "app_name", "DrySpot Uppala Staging")
            if (hasCompleteStagingSigning) signingConfig = signingConfigs.getByName("stagingRelease")
        }
    }

    buildTypes {
        release {
            // Flavor-specific signing configs above prevent staging/production key reuse.
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
    if (Regex("(?i)^(assemble|bundle|package|sign).*release").containsMatchIn(name)) {
        doFirst {
            val problems = when {
                name.contains("staging", ignoreCase = true) -> stagingSigningProblems
                name.contains("production", ignoreCase = true) -> productionSigningProblems
                else -> productionSigningProblems + stagingSigningProblems
            }
            check(problems.isEmpty() && signingIdentitiesDistinct) {
                "Release signing is not configured or identities are not distinct: ${problems.joinToString("; ")}. " +
                    "See docs/current/android-release-runbook.md."
            }
        }
    }
}

flutter {
    source = "../.."
}
