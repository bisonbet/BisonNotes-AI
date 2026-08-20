# llama.cpp removal migration

This document is the compatibility matrix for the removal of the embedded
llama.cpp engine. It describes the one-time migration that runs before the
legacy engine and its settings are no longer available.

## Eligibility history

The v2.3 legacy engine gate is 6 GB of RAM or more, with no experimental
override. Older pre-v2.0 builds could persist a legacy selection through an
experimental setting on devices below that threshold. Those values are stale
compatibility state, not a supported llama.cpp runtime in v2.3.

## Device matrix

All MLX rows assume a supported Apple-Silicon target. iPhone and iPad use
the 1.7B/4B/8B catalog; the native macOS target is Apple-Silicon-only and
adds the 27B option at 16 GB or more. The migration never silently upgrades a
legacy selection to the Mac-only 27B model.

| Device memory | MLX models available | Migration behavior |
| --- | --- | --- |
| Under 4 GB | None | A stale legacy selection uses the existing Mistral AI fallback. |
| 4 GB to under 6 GB | Ternary Bonsai 1.7B | Every legacy model maps to 1.7B. |
| 6 GB to under 8 GB | Ternary Bonsai 1.7B and 4B | Small legacy models map to 1.7B; medium and large models are clamped to 4B. |
| 8 GB to under 16 GB | Ternary Bonsai 1.7B, 4B, and 8B | Small models map to 1.7B, medium models to 4B, and Granite H Tiny to 8B. |
| Native macOS with 16 GB or more | Adds Ternary Bonsai 27B | Legacy models keep their closest 1.7B/4B/8B equivalent. |

The MLX model picker exposes every model that fits the device. The removed
legacy experimental toggle no longer gates MLX model selection.

## Legacy model matrix

| Legacy model ID | Status in the old catalog | MLX destination |
| --- | --- | --- |
| `lfm-2.5-1.2b` | Historical standard model | 1.7B |
| `qwen3-1.7b` | Historical model removed from the catalog | 1.7B |
| `gemma-3n-e2b` | Standard, 6 GB+ | 1.7B |
| `qwen3.5-2b` | Experimental, 6 GB+ | 1.7B |
| `ministral-3b` | Experimental, 6 GB+ | 4B, clamped by device RAM |
| `granite-4.0-micro` | Standard, 6 GB+ | 4B, clamped by device RAM |
| `phi4-mini` | Historical model | 4B, clamped by device RAM |
| `gemma-3n-e4b` | Standard, 8 GB+ | 4B, clamped by device RAM |
| `qwen3-4b` | Historical model | 4B, clamped by device RAM |
| `qwen3.5-4b` | Experimental, 8 GB+ | 4B, clamped by device RAM |
| `granite-4.0-h-tiny` | Experimental, 8 GB+ | 8B, clamped by device RAM |

Missing or unknown legacy IDs use the normal MLX default for the device tier.

## Disk and settings cleanup

The migration removes known legacy model files from the old
`Application Support/OnDeviceLLMModels` directory, including the historical
LFM, Qwen 3, Phi, Gemma, Ministral, and Granite GGUF names. It removes the
directory only if it is empty afterward and preserves unknown files.

It also removes the old enable, selected-model, sampling, experimental, and
download-progress UserDefaults keys. Future iCloud settings backups no longer
include those keys, and older backups cannot restore the removed engine or its
settings.

The app's Compatible API remains able to connect to an external
llama.cpp-compatible server. That is a user-configured external endpoint, not
the embedded engine being removed here.
