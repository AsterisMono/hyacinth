# Flutter embedding — plugins access these via reflection / JNI, so R8
# strips them by default and produces a runtime ClassNotFoundException
# (e.g. path_provider_android calling io.flutter.util.PathUtils).
# Keep the whole io.flutter tree.
-keep class io.flutter.** { *; }
-keep interface io.flutter.** { *; }
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.embedding.**

# AndroidX / Kotlin standard
-keep class kotlin.Metadata { *; }
-dontwarn kotlin.**
-dontwarn kotlinx.**

# Hyacinth — keep MainActivity and any reflectively-loaded classes
-keep class io.hyacinth.hyacinth.** { *; }
