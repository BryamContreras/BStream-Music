# Keep native downloader/audio integration APIs that may be reached from Flutter
# plugins or Android framework entry points.
-keep class com.yausername.youtubedl_android.** { *; }
-keep class com.yausername.ffmpeg.** { *; }
-keep class com.ryanheise.audioservice.** { *; }
# Commons Compress registers ZIP extra fields by class and instantiates them
# reflectively. R8 class merging makes those implementations unusable unless
# the concrete ZIP classes are preserved.
-keep class org.apache.commons.compress.archivers.zip.** { *; }

-dontwarn com.yausername.youtubedl_android.**
-dontwarn com.yausername.ffmpeg.**
