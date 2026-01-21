# On-Device LLM Setup Guide

This document explains how to set up and update the `llama.xcframework` for on-device LLM inference in BisonNotes.

## Overview

The on-device LLM feature uses [llama.cpp](https://github.com/ggerganov/llama.cpp) to run GGUF-format language models locally on iOS devices. This requires a pre-compiled `llama.xcframework`.

## Framework Location

**Recommended:** Keep the framework in a sibling folder to the project for easy updates:

```
BisonNotes-AI/
├── BisonNotes AI/           # Xcode project
├── Frameworks/
│   └── llama.xcframework/   # Place framework here
└── OLMoE.swift/             # Reference implementation (can be removed after setup)
```

## Initial Setup

### Step 1: Copy the Framework

Copy `llama.xcframework` from the OLMoE.swift project:

```bash
cd /Users/champ/Sources/BisonNotes-AI
mkdir -p Frameworks
cp -R OLMoE.swift/llama.xcframework Frameworks/
```

### Step 2: Add to Xcode Project

1. Open `BisonNotes AI.xcodeproj` in Xcode
2. Select the project in the navigator
3. Select the **BisonNotes AI** target
4. Go to **General** tab → **Frameworks, Libraries, and Embedded Content**
5. Click **+** → **Add Other...** → **Add Files...**
6. Navigate to `Frameworks/llama.xcframework` and select it
7. Ensure it's set to **Embed & Sign**

### Step 3: Update Build Settings (if needed)

If you encounter "module not found" errors:

1. Go to **Build Settings** tab
2. Search for "Framework Search Paths"
3. Add: `$(PROJECT_DIR)/../Frameworks` (recursive)
4. Search for "Header Search Paths"
5. Add: `$(PROJECT_DIR)/../Frameworks/llama.xcframework/Headers` (recursive)

## Updating the Framework

### Option 1: Build from Source (Recommended)

This gives you the most control and ensures you have the latest features.

```bash
# Clone llama.cpp (if not already)
git clone https://github.com/ggerganov/llama.cpp.git
cd llama.cpp

# Build the xcframework for Apple platforms
./scripts/build-xcframework.sh

# The output will be in:
# build/llama.xcframework

# Copy to your project
cp -R build/llama.xcframework /Users/champ/Sources/BisonNotes-AI/Frameworks/
```

### Option 2: Copy from OLMoE.swift Updates

If the OLMoE.swift project is updated with a newer framework:

```bash
cp -R OLMoE.swift/llama.xcframework Frameworks/
```

### After Updating

1. In Xcode, clean the build folder: **Product** → **Clean Build Folder** (⌘⇧K)
2. Delete the app from simulator/device
3. Rebuild the project

## Framework Contents

The `llama.xcframework` contains binaries for:

- **ios-arm64**: Physical iOS devices (iPhone, iPad)
- **ios-arm64_x86_64-simulator**: iOS Simulator
- **macos-arm64_x86_64**: macOS (for Mac Catalyst)

## Supported Features

The framework provides:

- GGUF model loading
- Token encoding/decoding
- GPU acceleration via Metal (on supported devices)
- Memory-efficient inference with KV cache management

## Troubleshooting

### "No such module 'llama'"

- Ensure the framework is added to the target's "Frameworks, Libraries, and Embedded Content"
- Check that "Embed & Sign" is selected
- Verify Framework Search Paths include the framework location

### Build Errors with Metal

If you see Metal-related errors on older devices:
- The framework automatically disables GPU on simulator
- Ensure `modelParams.n_gpu_layers = 0` for CPU-only inference

### Memory Issues

Large models may cause memory warnings. Recommendations:
- Use Q4_K_M quantization (good quality/size balance)
- Models under 4GB work best on iOS
- The app automatically manages memory with KV cache trimming

## Model Compatibility

The framework supports GGUF format models. Recommended quantizations:

| Quantization | Quality | Size (2.6B model) | Recommended |
|--------------|---------|-------------------|-------------|
| Q2_K         | Lower   | ~1.0 GB           | Not recommended |
| Q4_K_M       | Good    | ~1.8 GB           | ✅ Best balance |
| Q5_K_M       | Better  | ~2.2 GB           | Good for capable devices |
| Q8_0         | Best    | ~3.0 GB           | If storage permits |

## Version History

Track framework versions here for reference:

| Date | llama.cpp Version | Notes |
|------|-------------------|-------|
| 2025-01-10 | b4000+ | Initial setup from OLMoE.swift |

---

## Quick Reference

```bash
# Check framework architectures
lipo -info Frameworks/llama.xcframework/ios-arm64/llama.framework/llama

# List all binaries
find Frameworks/llama.xcframework -name "*.framework" -type d
```
