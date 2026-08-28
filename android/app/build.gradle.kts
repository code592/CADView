plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "org.cadview.cad_view"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        resValues = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "org.cadview.cad_view"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 8+ keeps the native Vulkan/FFI baseline consistent across devices.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "distribution"
    productFlavors {
        create("community") {
            dimension = "distribution"
            applicationIdSuffix = ".community"
            resValue("string", "app_name", "CADView Community")
        }
        create("globalStore") {
            dimension = "distribution"
            applicationIdSuffix = ".global"
            resValue("string", "app_name", "CADView")
            val admobAppId = providers.gradleProperty("CADVIEW_ADMOB_APP_ID")
                .getOrElse("ca-app-pub-3940256099942544~3347511713")
            val admobBannerId = providers.gradleProperty("CADVIEW_ADMOB_BANNER_ID")
                .getOrElse("ca-app-pub-3940256099942544/6300978111")
            resValue("string", "admob_app_id", admobAppId)
            buildConfigField("String", "CADVIEW_ADMOB_BANNER_ID", "\"$admobBannerId\"")
        }
        create("cnViewer") {
            dimension = "distribution"
            applicationIdSuffix = ".cn.viewer"
            resValue("string", "app_name", "CADView Viewer")
        }
        create("cnPro") {
            dimension = "distribution"
            applicationIdSuffix = ".cn.pro"
            resValue("string", "app_name", "CADView Pro")
        }
    }

    val releaseSigningValues = mapOf(
        "store file" to providers.environmentVariable("CADVIEW_ANDROID_KEYSTORE_FILE").orNull,
        "store password" to providers
            .environmentVariable("CADVIEW_ANDROID_KEYSTORE_PASSWORD")
            .orNull,
        "key alias" to providers.environmentVariable("CADVIEW_ANDROID_KEY_ALIAS").orNull,
        "key password" to providers.environmentVariable("CADVIEW_ANDROID_KEY_PASSWORD").orNull,
    )
    val suppliedReleaseSigningValues = releaseSigningValues.filterValues { !it.isNullOrBlank() }
    if (
        suppliedReleaseSigningValues.isNotEmpty() &&
        suppliedReleaseSigningValues.size != releaseSigningValues.size
    ) {
        val missing = releaseSigningValues.filterValues { it.isNullOrBlank() }.keys.joinToString()
        throw GradleException("Incomplete Android release signing configuration; missing: $missing")
    }
    val externalReleaseSigning = if (suppliedReleaseSigningValues.isNotEmpty()) {
        signingConfigs.create("externalRelease") {
            storeFile = file(requireNotNull(releaseSigningValues["store file"]))
            storePassword = releaseSigningValues["store password"]
            keyAlias = releaseSigningValues["key alias"]
            keyPassword = releaseSigningValues["key password"]
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
        }
    } else {
        null
    }

    buildTypes {
        release {
            // Signing material stays outside the repository. Release/publishing
            // scripts inject all four CADVIEW_ANDROID_* environment variables.
            signingConfig = externalReleaseSigning
        }
    }
}

dependencies {
    // Only the globalStore classpath and APK contain Google's proprietary SDK.
    // community/cnViewer/cnPro remain SDK-free and keep no-INTERNET manifests.
    add("globalStoreImplementation", "com.google.android.gms:play-services-ads:25.4.0")
}

tasks.matching { it.name == "preGlobalStoreReleaseBuild" }.configureEach {
    doFirst {
        val appId = providers.gradleProperty("CADVIEW_ADMOB_APP_ID").orNull
        val bannerId = providers.gradleProperty("CADVIEW_ADMOB_BANNER_ID").orNull
        if (appId.isNullOrBlank() || bannerId.isNullOrBlank()) {
            throw GradleException(
                "globalStore release requires CADVIEW_ADMOB_APP_ID and " +
                    "CADVIEW_ADMOB_BANNER_ID Gradle properties; test IDs must never ship.",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
