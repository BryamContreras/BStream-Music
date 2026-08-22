import java.io.FileInputStream
import java.net.URI
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.Properties

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
val bundledYtDlpVersion = providers.environmentVariable("YT_DLP_VERSION")
    .orElse("2026.07.04")
val bundledYtDlpSha256 = providers.environmentVariable("YT_DLP_ANDROID_SHA256")
    .orElse("495be29ff4d9d4e9be7eabdfef225221e5d5282e77f2f505abc6dca80349f3fd")
val allowNightlyYtDlpUpdates = providers
    .gradleProperty("allow-nightly-ytdlp-updates")
    .map { value -> value.equals("true", ignoreCase = true) }
    .orElse(false)
val bundledYtDlpResDirectory = layout.buildDirectory.dir("generated/bundled-ytdlp/res")
val bundledYtDlpResource = bundledYtDlpResDirectory.map { it.file("raw/ytdlp") }

fun sha256(file: File): String {
    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().buffered().use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) {
                break
            }
            digest.update(buffer, 0, count)
        }
    }
    return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
}

val prepareBundledYtDlp by tasks.registering {
    group = "build setup"
    description = "Downloads and verifies the yt-dlp zipapp bundled in Android APKs."
    inputs.property("ytDlpVersion", bundledYtDlpVersion)
    inputs.property("ytDlpSha256", bundledYtDlpSha256)
    outputs.file(bundledYtDlpResource)

    doLast {
        val version = bundledYtDlpVersion.get()
        val expectedSha256 = bundledYtDlpSha256.get().lowercase()
        val outputFile = bundledYtDlpResource.get().asFile
        val cacheFile = File(
            gradle.gradleUserHomeDir,
            "caches/bstream-music/yt-dlp/$version/yt-dlp",
        )

        if (!cacheFile.isFile || sha256(cacheFile) != expectedSha256) {
            cacheFile.delete()
            cacheFile.parentFile.mkdirs()
            val downloadFile = temporaryDir.resolve("yt-dlp.download")
            downloadFile.delete()
            val connection = URI(
                "https://github.com/yt-dlp/yt-dlp/releases/download/$version/yt-dlp",
            ).toURL().openConnection().apply {
                connectTimeout = 20_000
                readTimeout = 120_000
                setRequestProperty("User-Agent", "BStream-Music-Android-Build")
            }
            connection.getInputStream().use { input ->
                downloadFile.outputStream().buffered().use(input::copyTo)
            }
            val downloadedSha256 = sha256(downloadFile)
            if (downloadedSha256 != expectedSha256) {
                downloadFile.delete()
                throw GradleException(
                    "yt-dlp $version checksum mismatch: " +
                        "expected $expectedSha256, got $downloadedSha256",
                )
            }
            Files.move(
                downloadFile.toPath(),
                cacheFile.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
            )
        }

        outputFile.parentFile.mkdirs()
        Files.copy(
            cacheFile.toPath(),
            outputFile.toPath(),
            StandardCopyOption.REPLACE_EXISTING,
        )
        logger.lifecycle("Bundling verified yt-dlp $version for Android")
    }
}

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

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
        buildConfigField(
            "String",
            "BUNDLED_YTDLP_VERSION",
            "\"${bundledYtDlpVersion.get()}\"",
        )
        buildConfigField(
            "String",
            "BUNDLED_YTDLP_SHA256",
            "\"${bundledYtDlpSha256.get().lowercase()}\"",
        )
        buildConfigField(
            "boolean",
            "ALLOW_NIGHTLY_YTDLP_UPDATES",
            allowNightlyYtDlpUpdates.get().toString(),
        )
        if (!splitPerAbi) {
            ndk {
                abiFilters += setOf("armeabi-v7a", "arm64-v8a", "x86_64")
            }
        }
    }

    buildFeatures {
        buildConfig = true
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

    packaging {
        jniLibs {
            useLegacyPackaging = true
            keepDebugSymbols += listOf(
                "**/libpython.zip.so",
            )
        }
    }

    sourceSets.getByName("main").res.srcDir(bundledYtDlpResDirectory)
}

tasks.named("preBuild").configure {
    dependsOn(prepareBundledYtDlp)
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
    val youtubedlAndroid = "0.18.1"

    implementation("io.github.junkfood02.youtubedl-android:library:$youtubedlAndroid")
    testImplementation(kotlin("test"))
}
