plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.pocketasr.pocket_asr"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.pocketasr.pocket_asr"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // PocketASR ships native ASR/embedding libraries for arm64 only.
        // They are BUILT FROM PINNED SOURCE by CI (scripts/ci/build_native_android.sh,
        // see native/README.md) — never fetched or committed. This also filters
        // plugin AARs (sherpa-onnx, dartjni, onnxruntime) down to arm64 —
        // `--target-platform` alone does not.
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    // Gradle 9 / AGP 9: built-in Kotlin ignores `ndk.abiFilters` for jniLibs
    // merging, so enforce arm64-only packaging here. Without it, plugin AARs
    // re-add armeabi-v7a/x86_64 and the APK grows ~65MB.
    packaging {
        jniLibs {
            excludes += setOf("lib/armeabi-v7a/**", "lib/x86/**", "lib/x86_64/**")
        }
    }

    // Keep the CI-built libcrispasr.so / libcrispembed.so loadable by
    // DynamicLibrary.open at runtime; app jniLibs are `src/main/jniLibs/<abi>/`
    // by default, where scripts/ci/build_native_android.sh stages them.
    // useLegacyPackaging=false keeps them STORED so zipalign/16KB checks pass.
    packaging {
        jniLibs {
            useLegacyPackaging = false
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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

// The crispembed 0.16.1 plugin's fetchCrispembedLibs task calls the
// Project.exec() API removed in Gradle 9, and its prebuilt target is a 4KB
// -aligned lib that DT_NEEDEDs ggml siblings it never unpacked. Disable the
// task; CI builds and stages the library from pinned source instead
// (scripts/ci/build_native_android.sh). Keep the plugin's jniLibs source set.
gradle.projectsEvaluated {
    project(":crispembed").tasks.matching {
        it.name == "fetchCrispembedLibs"
    }.configureEach {
        enabled = false
    }
}
