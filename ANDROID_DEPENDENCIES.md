# BisonNotes AI - Android Dependencies & Third-Party Libraries

## Complete list of dependencies for the Android port

---

## Overview

This document lists all required dependencies, third-party libraries, and tools for the BisonNotes AI Android port. Dependencies are organized by category with version numbers, licenses, and implementation details.

**Last Updated**: 2025-11-22
**Target Android SDK**: 26+ (Android 8.0 Oreo and above)
**Target SDK Version**: 34 (Android 14)

---

## Core Android Dependencies

### 1. Jetpack Core Libraries

```gradle
// Core AndroidX libraries
dependencies {
    // AndroidX Core
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("androidx.activity:activity-ktx:1.8.2")
    implementation("androidx.fragment:fragment-ktx:1.6.2")

    // Material Design 3
    implementation("com.google.android.material:material:1.11.0")

    // Constraint Layout (if needed for XML layouts)
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")

    // Collection utilities
    implementation("androidx.collection:collection-ktx:1.3.0")
}
```

**Purpose**: Core Android functionality and Material Design components
**License**: Apache 2.0

---

## UI Framework - Jetpack Compose

### 2. Compose Dependencies

```gradle
dependencies {
    // Compose BOM (Bill of Materials) for version management
    implementation(platform("androidx.compose:compose-bom:2023.10.01"))

    // Core Compose libraries
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")

    // Compose Foundation
    implementation("androidx.compose.foundation:foundation")

    // Compose Runtime
    implementation("androidx.compose.runtime:runtime")
    implementation("androidx.compose.runtime:runtime-livedata")

    // Activity Compose integration
    implementation("androidx.activity:activity-compose:1.8.2")

    // ViewModel Compose integration
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.6.2")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.6.2")

    // Compose Tooling (debug only)
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
```

**Purpose**: Modern declarative UI framework
**License**: Apache 2.0
**Why**: Direct replacement for SwiftUI with similar declarative syntax

---

## Navigation

### 3. Navigation Compose

```gradle
dependencies {
    implementation("androidx.navigation:navigation-compose:2.7.6")
    implementation("androidx.navigation:navigation-runtime-ktx:2.7.6")

    // Optional: Navigation testing
    androidTestImplementation("androidx.navigation:navigation-testing:2.7.6")
}
```

**Purpose**: Type-safe navigation between screens
**License**: Apache 2.0
**Why**: Official Compose navigation library

---

## Architecture Components

### 4. Lifecycle & ViewModel

```gradle
dependencies {
    // Lifecycle components
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.6.2")
    implementation("androidx.lifecycle:lifecycle-livedata-ktx:2.6.2")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.6.2")
    implementation("androidx.lifecycle:lifecycle-viewmodel-savedstate:2.6.2")
    implementation("androidx.lifecycle:lifecycle-common-java8:2.6.2")

    // Process lifecycle
    implementation("androidx.lifecycle:lifecycle-process:2.6.2")

    // Lifecycle compiler (annotation processor)
    kapt("androidx.lifecycle:lifecycle-compiler:2.6.2")
}
```

**Purpose**: ViewModel and lifecycle management
**License**: Apache 2.0
**Why**: Core MVVM architecture support

---

## Database - Room

### 5. Room Database

```gradle
dependencies {
    // Room dependencies
    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.room:room-ktx:2.6.1")
    kapt("androidx.room:room-compiler:2.6.1")

    // Optional: Room testing
    testImplementation("androidx.room:room-testing:2.6.1")

    // Optional: RxJava support (if using RxJava)
    // implementation("androidx.room:room-rxjava3:2.6.1")
}
```

**Purpose**: Local SQLite database with ORM
**License**: Apache 2.0
**Why**: Direct replacement for Core Data, type-safe database access

---

## Dependency Injection - Hilt

### 6. Hilt/Dagger

```gradle
dependencies {
    // Hilt dependencies
    implementation("com.google.dagger:hilt-android:2.50")
    kapt("com.google.dagger:hilt-compiler:2.50")

    // Hilt Compose integration
    implementation("androidx.hilt:hilt-navigation-compose:1.1.0")

    // Hilt WorkManager integration
    implementation("androidx.hilt:hilt-work:1.1.0")
    kapt("androidx.hilt:hilt-compiler:1.1.0")

    // Hilt testing
    androidTestImplementation("com.google.dagger:hilt-android-testing:2.50")
    kaptAndroidTest("com.google.dagger:hilt-compiler:2.50")
}

// In project-level build.gradle
buildscript {
    dependencies {
        classpath("com.google.dagger:hilt-android-gradle-plugin:2.50")
    }
}

// In app-level build.gradle
plugins {
    id("dagger.hilt.android.plugin")
}
```

**Purpose**: Compile-time dependency injection
**License**: Apache 2.0
**Why**: Industry-standard DI for Android, excellent integration with Jetpack

---

## Background Processing

### 7. WorkManager

```gradle
dependencies {
    // WorkManager
    implementation("androidx.work:work-runtime-ktx:2.9.0")

    // Optional: RxJava support
    // implementation("androidx.work:work-rxjava3:2.9.0")

    // Optional: Testing
    androidTestImplementation("androidx.work:work-testing:2.9.0")
}
```

**Purpose**: Deferrable background work
**License**: Apache 2.0
**Why**: Replaces iOS BGTaskScheduler, battery-efficient background jobs

---

## Data Storage

### 8. DataStore (Preferences)

```gradle
dependencies {
    // DataStore (replaces SharedPreferences)
    implementation("androidx.datastore:datastore-preferences:1.0.0")

    // Optional: Proto DataStore (for typed data)
    implementation("androidx.datastore:datastore:1.0.0")
}
```

**Purpose**: Modern key-value storage
**License**: Apache 2.0
**Why**: Replacement for UserDefaults, async and type-safe

---

## Networking

### 9. Retrofit & OkHttp

```gradle
dependencies {
    // Retrofit (REST API client)
    implementation("com.squareup.retrofit2:retrofit:2.9.0")
    implementation("com.squareup.retrofit2:converter-gson:2.9.0")
    implementation("com.squareup.retrofit2:converter-moshi:2.9.0")  // Alternative to Gson

    // OkHttp (HTTP client)
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")

    // Optional: MockWebServer for testing
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
}
```

**Purpose**: HTTP client and REST API integration
**License**: Apache 2.0
**Why**: Industry-standard networking library, replaces URLSession

---

### 10. JSON Parsing

```gradle
dependencies {
    // Option 1: Gson (Google's JSON library)
    implementation("com.google.code.gson:gson:2.10.1")

    // Option 2: Moshi (Square's modern JSON library)
    implementation("com.squareup.moshi:moshi:1.15.0")
    implementation("com.squareup.moshi:moshi-kotlin:1.15.0")
    kapt("com.squareup.moshi:moshi-kotlin-codegen:1.15.0")

    // Option 3: Kotlinx Serialization (Jetbrains)
    // implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.2")
}
```

**Purpose**: JSON serialization/deserialization
**License**: Apache 2.0
**Why**: Replaces Swift's Codable protocol
**Recommendation**: Use Moshi for type-safe JSON parsing

---

## AWS SDK

### 11. AWS SDK for Android

```gradle
dependencies {
    // AWS Core
    implementation("com.amazonaws:aws-android-sdk-core:2.77.0")
    implementation("com.amazonaws:aws-android-sdk-auth-core:2.77.0")

    // AWS S3 (for file uploads)
    implementation("com.amazonaws:aws-android-sdk-s3:2.77.0")

    // AWS Transcribe
    implementation("com.amazonaws:aws-android-sdk-transcribe:2.77.0")

    // AWS SDK v2 (newer, recommended for Bedrock)
    implementation(platform("aws.sdk.kotlin:bom:1.0.0"))
    implementation("aws.sdk.kotlin:bedrock")
    implementation("aws.sdk.kotlin:bedrockruntime")
}
```

**Purpose**: AWS services integration (S3, Transcribe, Bedrock)
**License**: Apache 2.0
**Why**: Access to Claude via Bedrock, cloud transcription

**Note**: AWS SDK for Android uses v1/v2 depending on service. Bedrock requires SDK v2 (Kotlin).

---

## Audio & Media

### 12. Media3 (ExoPlayer)

```gradle
dependencies {
    // ExoPlayer (modern media playback)
    implementation("androidx.media3:media3-exoplayer:1.2.1")
    implementation("androidx.media3:media3-ui:1.2.1")
    implementation("androidx.media3:media3-common:1.2.1")

    // Optional: ExoPlayer extensions
    implementation("androidx.media3:media3-session:1.2.1")

    // Optional: Specific decoders
    // implementation("androidx.media3:media3-exoplayer-dash:1.2.1")
    // implementation("androidx.media3:media3-exoplayer-hls:1.2.1")
}
```

**Purpose**: Advanced audio/video playback
**License**: Apache 2.0
**Why**: More features than MediaPlayer, handles various audio formats, replaces AVAudioPlayer

---

### 13. Oboe (Optional - Low-latency audio)

```gradle
dependencies {
    // Oboe for low-latency audio I/O
    implementation("com.google.oboe:oboe:1.8.0")
}
```

**Purpose**: Low-latency audio recording (optional)
**License**: Apache 2.0
**Why**: Better performance than MediaRecorder for real-time audio
**Note**: Requires NDK/C++ if using advanced features

---

## Markdown Rendering

### 14. Markwon

```gradle
dependencies {
    // Markwon (Markdown for Android)
    implementation("io.noties.markwon:core:4.6.2")
    implementation("io.noties.markwon:ext-tables:4.6.2")
    implementation("io.noties.markwon:ext-strikethrough:4.6.2")
    implementation("io.noties.markwon:ext-tasklist:4.6.2")
    implementation("io.noties.markwon:html:4.6.2")
    implementation("io.noties.markwon:image:4.6.2")
    implementation("io.noties.markwon:linkify:4.6.2")

    // Optional: Syntax highlighting
    implementation("io.noties.markwon:syntax-highlight:4.6.2")
}
```

**Purpose**: Render Markdown in Android
**License**: Apache 2.0
**Why**: Replaces MarkdownUI from iOS, displays AI-generated summaries

**Alternative**: [Compose-Markdown](https://github.com/jeziellago/compose-markdown) for native Compose support

---

## PDF & Document Generation

### 15. iText (PDF generation)

```gradle
dependencies {
    // iText for PDF creation
    implementation("com.itextpdf:itext7-core:7.2.5")
}
```

**Purpose**: PDF export functionality
**License**: AGPL (free for open-source) or Commercial license
**Why**: Generate PDFs from summaries and transcripts

**Alternative**: [PdfDocument](https://developer.android.com/reference/android/graphics/pdf/PdfDocument) (Android built-in, limited features)

---

### 16. Apache POI (DOCX/RTF)

```gradle
dependencies {
    // Apache POI for Office documents
    implementation("org.apache.poi:poi:5.2.5")
    implementation("org.apache.poi:poi-ooxml:5.2.5")
}
```

**Purpose**: Import DOCX transcripts, export RTF
**License**: Apache 2.0
**Why**: Parse and generate Microsoft Office documents

---

## Image Loading & Caching

### 17. Coil

```gradle
dependencies {
    // Coil (Compose-first image loading)
    implementation("io.coil-kt:coil-compose:2.5.0")
    implementation("io.coil-kt:coil-gif:2.5.0")  // Optional: GIF support
    implementation("io.coil-kt:coil-svg:2.5.0")  // Optional: SVG support
}
```

**Purpose**: Image loading and caching
**License**: Apache 2.0
**Why**: Efficient image loading for thumbnails, map snapshots

**Alternative**: Glide (more mature) or Picasso

---

## Location Services

### 18. Google Play Services - Location

```gradle
dependencies {
    // Google Play Services - Location
    implementation("com.google.android.gms:play-services-location:21.1.0")

    // Optional: Maps SDK (for map display)
    implementation("com.google.android.gms:play-services-maps:18.2.0")
}
```

**Purpose**: Location tracking and geocoding
**License**: Apache 2.0
**Why**: FusedLocationProviderClient replaces CLLocationManager

---

## Coroutines & Async

### 19. Kotlin Coroutines

```gradle
dependencies {
    // Kotlin Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")

    // Optional: Coroutines test support
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.7.3")
}
```

**Purpose**: Asynchronous programming
**License**: Apache 2.0
**Why**: Replaces Swift async/await, handles background operations

---

## Kotlin Standard Library

### 20. Kotlin Extensions

```gradle
dependencies {
    // Kotlin Standard Library
    implementation("org.jetbrains.kotlin:kotlin-stdlib:1.9.21")

    // Kotlin Reflection (if needed)
    implementation("org.jetbrains.kotlin:kotlin-reflect:1.9.21")

    // KotlinX DateTime (optional, for date manipulation)
    implementation("org.jetbrains.kotlinx:kotlinx-datetime:0.5.0")
}
```

**Purpose**: Kotlin language features
**License**: Apache 2.0

---

## Testing Dependencies

### 21. Unit Testing

```gradle
dependencies {
    // JUnit 4
    testImplementation("junit:junit:4.13.2")

    // JUnit 5 (Jupiter) - Modern alternative
    testImplementation("org.junit.jupiter:junit-jupiter-api:5.10.1")
    testRuntimeOnly("org.junit.jupiter:junit-jupiter-engine:5.10.1")

    // Kotlin Test
    testImplementation("org.jetbrains.kotlin:kotlin-test:1.9.21")

    // Truth (Google's assertion library)
    testImplementation("com.google.truth:truth:1.2.0")

    // MockK (Kotlin mocking library)
    testImplementation("io.mockk:mockk:1.13.9")

    // Turbine (Flow testing)
    testImplementation("app.cash.turbine:turbine:1.0.0")

    // Coroutines Test
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.7.3")
}
```

**Purpose**: Unit testing
**License**: Apache 2.0
**Why**: Replaces XCTest

---

### 22. UI Testing

```gradle
dependencies {
    // Compose UI Testing
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")

    // Espresso (UI testing)
    androidTestImplementation("androidx.test.espresso:espresso-core:3.5.1")
    androidTestImplementation("androidx.test.espresso:espresso-intents:3.5.1")

    // AndroidX Test
    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test:runner:1.5.2")
    androidTestImplementation("androidx.test:rules:1.5.0")

    // UI Automator (system-level UI testing)
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
}
```

**Purpose**: UI and instrumentation testing
**License**: Apache 2.0
**Why**: Replaces XCUITest

---

## Debugging & Logging

### 23. Timber

```gradle
dependencies {
    // Timber (logging)
    implementation("com.jakewharton.timber:timber:5.0.1")
}
```

**Purpose**: Better logging
**License**: Apache 2.0
**Why**: Improved logging over Android Log class

---

### 24. LeakCanary

```gradle
dependencies {
    // LeakCanary (memory leak detection)
    debugImplementation("com.squareup.leakcanary:leakcanary-android:2.12")
}
```

**Purpose**: Memory leak detection
**License**: Apache 2.0
**Why**: Catch memory leaks during development

---

### 25. Chucker (Network Inspector)

```gradle
dependencies {
    // Chucker (network debugging)
    debugImplementation("com.github.chuckerteam.chucker:library:4.0.0")
    releaseImplementation("com.github.chuckerteam.chucker:library-no-op:4.0.0")
}
```

**Purpose**: Inspect network traffic
**License**: Apache 2.0
**Why**: Debug API calls in-app

---

## Firebase (Optional)

### 26. Firebase Services

```gradle
dependencies {
    // Firebase BOM
    implementation(platform("com.google.firebase:firebase-bom:32.7.1"))

    // Firebase Crashlytics
    implementation("com.google.firebase:firebase-crashlytics-ktx")

    // Firebase Analytics
    implementation("com.google.firebase:firebase-analytics-ktx")

    // Firebase Cloud Messaging (push notifications)
    implementation("com.google.firebase:firebase-messaging-ktx")

    // Firebase Firestore (cloud database, for sync)
    implementation("com.google.firebase:firebase-firestore-ktx")

    // Firebase Auth
    implementation("com.google.firebase:firebase-auth-ktx")

    // Firebase Storage (file storage)
    implementation("com.google.firebase:firebase-storage-ktx")
}

// In project-level build.gradle
buildscript {
    dependencies {
        classpath("com.google.gms:google-services:4.4.0")
        classpath("com.google.firebase:firebase-crashlytics-gradle:2.9.9")
    }
}

// In app-level build.gradle
plugins {
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}
```

**Purpose**: Cloud services, analytics, crash reporting
**License**: Apache 2.0
**Why**: Alternative to iCloud sync, crash reporting, analytics
**Note**: Requires google-services.json file

---

## Wear OS (Optional)

### 27. Wear OS Libraries

```gradle
dependencies {
    // Wear OS Compose
    implementation("androidx.wear.compose:compose-material:1.3.0")
    implementation("androidx.wear.compose:compose-foundation:1.3.0")
    implementation("androidx.wear.compose:compose-navigation:1.3.0")

    // Wear OS Tiles (complications)
    implementation("androidx.wear.tiles:tiles:1.3.0")

    // Play Services Wearable (for data sync)
    implementation("com.google.android.gms:play-services-wearable:18.1.0")
}
```

**Purpose**: Wear OS companion app
**License**: Apache 2.0
**Why**: Replaces Apple Watch app

---

## Security

### 28. Tink (Cryptography)

```gradle
dependencies {
    // Tink (cryptography library)
    implementation("com.google.crypto.tink:tink-android:1.12.0")
}
```

**Purpose**: Encrypt sensitive data
**License**: Apache 2.0
**Why**: Secure API key storage, optional audio encryption

---

## Kotlin Compiler

### 29. Kotlin Compiler Options

```gradle
android {
    kotlinOptions {
        jvmTarget = "17"  // Java 17 target
        freeCompilerArgs += [
            "-opt-in=kotlin.RequiresOptIn",
            "-opt-in=kotlinx.coroutines.ExperimentalCoroutinesApi",
            "-opt-in=kotlinx.coroutines.FlowPreview"
        ]
    }
}
```

---

## Build Tools & Plugins

### 30. Gradle Plugins

```gradle
// project-level build.gradle.kts
plugins {
    id("com.android.application") version "8.2.1" apply false
    id("org.jetbrains.kotlin.android") version "1.9.21" apply false
    id("com.google.dagger.hilt.android") version "2.50" apply false
    id("com.google.gms.google-services") version "4.4.0" apply false
    id("com.google.firebase.crashlytics") version "2.9.9" apply false
}

// app-level build.gradle.kts
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("kotlin-kapt")
    id("dagger.hilt.android.plugin")
    id("com.google.gms.google-services")  // If using Firebase
    id("com.google.firebase.crashlytics")  // If using Crashlytics
}
```

---

## Complete build.gradle.kts Example

```gradle
// app/build.gradle.kts

plugins {
    id("com.android.application")
    kotlin("android")
    kotlin("kapt")
    id("dagger.hilt.android.plugin")
}

android {
    namespace = "com.bisonnotesai.android"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.bisonnotesai.android"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // Enable vector drawables support
        vectorDrawables.useSupportLibrary = true
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug {
            isDebuggable = true
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.7"
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    // Kotlin
    implementation("org.jetbrains.kotlin:kotlin-stdlib:1.9.21")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")

    // AndroidX Core
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.11.0")
    implementation("androidx.activity:activity-compose:1.8.2")

    // Jetpack Compose
    implementation(platform("androidx.compose:compose-bom:2023.10.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    debugImplementation("androidx.compose.ui:ui-tooling")

    // Lifecycle & ViewModel
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.6.2")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.6.2")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.6.2")

    // Navigation
    implementation("androidx.navigation:navigation-compose:2.7.6")

    // Hilt
    implementation("com.google.dagger:hilt-android:2.50")
    kapt("com.google.dagger:hilt-compiler:2.50")
    implementation("androidx.hilt:hilt-navigation-compose:1.1.0")
    implementation("androidx.hilt:hilt-work:1.1.0")
    kapt("androidx.hilt:hilt-compiler:1.1.0")

    // Room
    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.room:room-ktx:2.6.1")
    kapt("androidx.room:room-compiler:2.6.1")

    // WorkManager
    implementation("androidx.work:work-runtime-ktx:2.9.0")

    // DataStore
    implementation("androidx.datastore:datastore-preferences:1.0.0")

    // Retrofit & OkHttp
    implementation("com.squareup.retrofit2:retrofit:2.9.0")
    implementation("com.squareup.retrofit2:converter-gson:2.9.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")

    // Gson
    implementation("com.google.code.gson:gson:2.10.1")

    // AWS SDK
    implementation("com.amazonaws:aws-android-sdk-core:2.77.0")
    implementation("com.amazonaws:aws-android-sdk-s3:2.77.0")
    implementation("com.amazonaws:aws-android-sdk-transcribe:2.77.0")

    // ExoPlayer
    implementation("androidx.media3:media3-exoplayer:1.2.1")
    implementation("androidx.media3:media3-ui:1.2.1")

    // Markwon (Markdown)
    implementation("io.noties.markwon:core:4.6.2")
    implementation("io.noties.markwon:ext-tables:4.6.2")
    implementation("io.noties.markwon:ext-strikethrough:4.6.2")

    // Coil (Image loading)
    implementation("io.coil-kt:coil-compose:2.5.0")

    // Google Play Services
    implementation("com.google.android.gms:play-services-location:21.1.0")

    // Timber (Logging)
    implementation("com.jakewharton.timber:timber:5.0.1")

    // Debug tools
    debugImplementation("com.squareup.leakcanary:leakcanary-android:2.12")
    debugImplementation("com.github.chuckerteam.chucker:library:4.0.0")
    releaseImplementation("com.github.chuckerteam.chucker:library-no-op:4.0.0")

    // Testing
    testImplementation("junit:junit:4.13.2")
    testImplementation("io.mockk:mockk:1.13.9")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.7.3")
    testImplementation("com.google.truth:truth:1.2.0")

    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.5.1")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
}
```

---

## License Summary

### Apache 2.0 (Most libraries)
- Free for commercial use
- Permits modification and distribution
- Requires preservation of copyright notices
- No trademark use
- **Recommended**: ✅ Safe for commercial projects

### AGPL (iText)
- Free for open-source projects
- Requires source code disclosure for web applications
- Consider commercial license for closed-source
- **Recommendation**: Use Android PdfDocument or purchase license

### Commercial Licenses (Optional)
Some libraries offer dual licensing:
- **iText**: AGPL (free) or Commercial
- **AWS SDK**: Free tier, pay-as-you-go for usage

---

## Dependency Size Impact

Estimated APK size impact:

| Category | Size Impact |
|----------|-------------|
| Jetpack Core + Compose | ~8 MB |
| Room + Hilt + Navigation | ~2 MB |
| Retrofit + OkHttp + Gson | ~1 MB |
| AWS SDK | ~3-5 MB |
| ExoPlayer | ~2 MB |
| Markwon | ~500 KB |
| Other libraries | ~2 MB |
| **Total Estimate** | **18-20 MB** |

**Optimization**:
- Use R8/ProGuard in release builds (can reduce by 30-40%)
- Enable code shrinking
- Remove unused resources
- Use App Bundles (dynamic delivery)

---

## Version Management Strategy

### Use Version Catalogs (Recommended)

Create `gradle/libs.versions.toml`:

```toml
[versions]
kotlin = "1.9.21"
compose-bom = "2023.10.01"
hilt = "2.50"
room = "2.6.1"
retrofit = "2.9.0"

[libraries]
androidx-core = "androidx.core:core-ktx:1.12.0"
compose-bom = { module = "androidx.compose:compose-bom", version.ref = "compose-bom" }
hilt-android = { module = "com.google.dagger:hilt-android", version.ref = "hilt" }
room-runtime = { module = "androidx.room:room-runtime", version.ref = "room" }
retrofit = { module = "com.squareup.retrofit2:retrofit", version.ref = "retrofit" }

[plugins]
android-application = "com.android.application:8.2.1"
kotlin-android = "org.jetbrains.kotlin.android:1.9.21"
hilt = "com.google.dagger.hilt.android:2.50"
```

Then use in build.gradle:
```gradle
dependencies {
    implementation(libs.androidx.core)
    implementation(libs.hilt.android)
}
```

---

## Dependency Update Strategy

### Regular Updates
- **Monthly**: Check for security updates
- **Quarterly**: Update minor versions
- **Annually**: Update major versions (with testing)

### Tools
- **Dependabot**: Automated dependency updates (GitHub)
- **Renovate**: Alternative to Dependabot
- **Gradle Versions Plugin**: Check for updates manually

---

## Total Dependency Count

**Summary**:
- **Core dependencies**: ~40
- **Optional dependencies**: ~15
- **Test dependencies**: ~12
- **Debug-only dependencies**: ~5

**Total**: ~70 dependencies

---

**Document Version**: 1.0
**Last Updated**: 2025-11-22
**Next Review**: Quarterly (check for security updates)
