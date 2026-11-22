plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.tv.watch_tube"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.tv.watch_tube"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Production signing (audit fix 01).
    // Credentials come from android/key.properties (git-ignored) or from the
    // environment variables VXTUBE_KEYSTORE_PATH / VXTUBE_KEYSTORE_PASSWORD /
    // VXTUBE_KEY_ALIAS / VXTUBE_KEY_PASSWORD (CI secrets). No keystore or
    // password is ever committed. See docs/RELEASE_SIGNING.md.
    val keystorePropertiesFile = rootProject.file("key.properties")
    val envKeystore = System.getenv("VXTUBE_KEYSTORE_PATH")
    val hasProductionSigning = keystorePropertiesFile.exists() || !envKeystore.isNullOrBlank()
    if (hasProductionSigning) {
        signingConfigs {
            create("release") {
                if (keystorePropertiesFile.exists()) {
                    val props = java.util.Properties()
                    keystorePropertiesFile.inputStream().use { props.load(it) }
                    storeFile = file(props.getProperty("storeFile"))
                    storePassword = props.getProperty("storePassword")
                    keyAlias = props.getProperty("keyAlias")
                    keyPassword = props.getProperty("keyPassword")
                } else {
                    storeFile = file(envKeystore!!)
                    storePassword = System.getenv("VXTUBE_KEYSTORE_PASSWORD")
                    keyAlias = System.getenv("VXTUBE_KEY_ALIAS")
                    keyPassword = System.getenv("VXTUBE_KEY_PASSWORD")
                }
            }
        }
    }

    buildTypes {
        release {
            if (hasProductionSigning) {
                signingConfig = signingConfigs.getByName("release")
            } else if (gradle.startParameter.taskNames.any { it.contains("Release") }) {
                throw GradleException(
                    "Release signing is not configured. Create android/key.properties " +
                    "or set the VXTUBE_KEYSTORE_* environment variables. " +
                    "Release builds are NEVER signed with the debug key."
                )
            }
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
