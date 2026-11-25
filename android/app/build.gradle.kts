import java.io.FileInputStream
import java.util.Properties
import groovy.json.JsonSlurper

val releaseKeystoreProperties = Properties()
val releaseKeystorePropertiesFile = rootProject.file("key.properties")
if (releaseKeystorePropertiesFile.exists()) {
    releaseKeystoreProperties.load(FileInputStream(releaseKeystorePropertiesFile))
}

fun releaseSigningValue(propertyName: String, environmentName: String): String? {
    return releaseKeystoreProperties.getProperty(propertyName)
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?: System.getenv(environmentName)?.trim()?.takeIf { it.isNotEmpty() }
}

val releaseStoreFilePath = releaseSigningValue("storeFile", "BSTREAM_ANDROID_STORE_FILE")
val releaseStorePassword = releaseSigningValue("storePassword", "BSTREAM_ANDROID_STORE_PASSWORD")
val releaseKeyAlias = releaseSigningValue("keyAlias", "BSTREAM_ANDROID_KEY_ALIAS")
val releaseKeyPassword = releaseSigningValue("keyPassword", "BSTREAM_ANDROID_KEY_PASSWORD")
val hasReleaseSigning = listOf(
    releaseStoreFilePath,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { it != null }
val splitPerAbi = providers.gradleProperty("split-per-abi").orNull == "true"
val armOnly = providers.gradleProperty("bstream-arm-only").orNull == "true"

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val bstreamImpellerRepo = providers.gradleProperty("bstream-impeller-engine-repo").orNull
val bstreamImpellerMode = providers.gradleProperty("bstream-impeller-engine-mode").orElse("profile").get()
val bstreamCandidateArm64 = providers.gradleProperty("bstream-candidate-arm64").orNull == "true"

android {
    namespace = "com.bstream.bstream_music"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.bstream.bstream_music"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "com.bstream.bstream_music.WidgetLayoutInstrumentation"
        if (bstreamImpellerRepo != null || bstreamCandidateArm64) {
            ndk {
                abiFilters.clear()
                abiFilters += setOf("arm64-v8a")
            }
        } else if (!splitPerAbi) {
            ndk {
                if (armOnly) {
                    abiFilters.clear()
                    abiFilters += setOf("armeabi-v7a", "arm64-v8a")
                } else {
                    abiFilters += setOf("armeabi-v7a", "arm64-v8a", "x86_64")
                }
            }
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFilePath!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "Release signing is not configured. Create android/key.properties " +
                        "or set BSTREAM_ANDROID_* environment variables before publishing.",
                )
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
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

dependencies {
    implementation("androidx.mediarouter:mediarouter:1.8.1")
    implementation("com.google.android.gms:play-services-cast-framework:22.3.1")
    testImplementation(kotlin("test"))
}

// Optional, revision-pinned native Impeller engine for Android arm64 candidates.
// The normal Android build and release signing remain unchanged without it.
if (bstreamCandidateArm64) {
    require(providers.gradleProperty("target-platform").orNull == "android-arm64") {
        "The arm64 candidate must use an explicit android-arm64 target."
    }
}
if (bstreamImpellerRepo != null) {
    val repo = rootProject.file(bstreamImpellerRepo)
    val manifestFile = repo.resolve("bstream-engine-manifest.json")
    require(manifestFile.isFile) {
        "The prepared BStream Impeller Maven repository is missing its manifest."
    }
    require(providers.gradleProperty("target-platform").orNull == "android-arm64") {
        "The custom Impeller engine is available only for an explicit android-arm64 build."
    }
    require(bstreamImpellerMode in setOf("profile", "release")) {
        "The custom Impeller engine supports profile and release candidates only."
    }
    val requestedTasks = gradle.startParameter.taskNames
    require(requestedTasks.any { it.contains(bstreamImpellerMode, ignoreCase = true) } &&
        requestedTasks.none { task ->
            setOf("profile", "release", "debug").minus(bstreamImpellerMode).any { task.contains(it, ignoreCase = true) }
        }) {
        "The native Impeller build mode must match the requested Android build mode."
    }
    if (bstreamImpellerMode == "release") {
        require(hasReleaseSigning) { "Release Impeller candidates must use configured release signing." }
    }
    val engineRevision = "89c39edfdfae2949f6806e4a315c0c08522238b7"
    val localFlutterProperties = Properties().apply {
        rootProject.file("local.properties").inputStream().use { load(it) }
    }
    val sdkRoot = rootProject.file(requireNotNull(localFlutterProperties.getProperty("flutter.sdk")))
    require(sdkRoot.resolve("bin/internal/engine.version").readText().trim() == engineRevision) {
        "The local Impeller artifact must match the Flutter SDK engine revision."
    }
    val official = "1.0.0-$engineRevision"
    val patched = "$official-bstream-region-v2"
    val artifact = "arm64_v8a_$bstreamImpellerMode"
    val manifest = JsonSlurper().parse(manifestFile) as Map<*, *>
    require(manifest["engineRevision"] == engineRevision &&
        manifest["artifact"] == "com.bstream.engine:$artifact:$patched" &&
        (manifest["mode"] == bstreamImpellerMode || (bstreamImpellerMode == "profile" && manifest["mode"] == null))) {
        "The local Impeller Maven manifest does not match the engine revision and build mode."
    }
    require(repo.resolve("com/bstream/engine/$artifact/$patched/$artifact-$patched.jar").isFile) {
        "The BStream Impeller artifact is missing."
    }
    repositories {
        maven {
            url = uri(repo)
            content { includeGroup("com.bstream.engine") }
        }
    }
    configurations.configureEach {
        resolutionStrategy.dependencySubstitution {
            substitute(module("io.flutter:$artifact:$official"))
                .using(module("com.bstream.engine:$artifact:$patched"))
                .because("Use the exact-revision Impeller backdrop optimization candidate")
        }
    }
}
