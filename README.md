# 🎙️ BisonNotes AI

**Private voice recording, transcription, and AI summaries for iPhone, iPad, Apple Watch, and Mac.**

<div align="center">

![Version](https://img.shields.io/badge/Version-3.0-success?style=for-the-badge)
![iOS](https://img.shields.io/badge/iOS%20%7C%20iPadOS-18.5+-blue?style=for-the-badge&logo=apple)
![macOS](https://img.shields.io/badge/macOS-15+-lightgrey?style=for-the-badge&logo=apple)
![watchOS](https://img.shields.io/badge/watchOS-11.5+-black?style=for-the-badge&logo=apple)
![Swift](https://img.shields.io/badge/Swift-6-orange?style=for-the-badge&logo=swift)
![Xcode](https://img.shields.io/badge/Xcode-26.6+-147EFB?style=for-the-badge&logo=xcode)
![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)

[![Download on the App Store](https://img.shields.io/badge/Download_on_the-App_Store-0D96F6?style=for-the-badge&logo=appstore&logoColor=white)](https://apps.apple.com/us/app/bisonnotes-ai-voice-notes/id6749189425)
[![Buy me a coffee](https://img.shields.io/badge/Buy_me_a_coffee-FFDD00?style=for-the-badge&logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/Bisonnetworking)

</div>

BisonNotes AI records audio, transcribes it, and turns it into summaries,
tasks, and reminders. By default everything runs on your device: Parakeet
transcribes and MLX Swift summarizes. Cloud engines are used only if you
choose them.

## Features

- 🎙️ **Record anywhere**: iPhone, iPad, Apple Watch, and Mac, with pause and
  resume, a Control Center widget, and Action Button support.
- ⌚️ **Independent Watch recorder**: records on its own and sends complete files
  to the phone, even after going offline.
- 🖥️ **Mac meeting capture**: mix system audio with your microphone, with
  automatic recovery when a device drops.
- 🔒 **On-device by default**: Parakeet transcription, optional local speaker
  labels, and Ternary Bonsai summaries, all without sending audio anywhere.
- 🤖 **Your choice of AI**: On Device AI, Apple Intelligence, Mistral AI, Google
  AI Studio, any OpenAI-compatible API, Whisper servers, and Ollama on Mac.
- 📝 **Summaries, tasks, and reminders**, sent to Reminders, Apple Calendar, or
  Google Calendar.
- 🧪 **Beta features**: custom Summary Prompts and on-device English Transcript
  Cleanup.
- 🔗 **Import anything**: the Share menu, direct links, video files, transcript
  documents, and YouTube captions.
- ☁️ **iCloud sync** with per-recording **Keep on This Device** and iCloud Drive
  audio archiving.
- ♿️ **Accessible**: VoiceOver, Voice Control, Dynamic Type, Reduce Motion, and
  Full Keyboard Access.

> **⚠️ Not HIPAA compliant.** BisonNotes AI is a personal productivity app and
> does not provide Business Associate Agreements. Don't use it to record or
> process protected health information.

## Documentation

| | |
| --- | --- |
| [Features and usage](docs/features.md) | Recording, transcription engines, speaker labels, AI engines, beta features, importing, iCloud sync, and archiving |
| [User guide](https://www.bisonnetworking.com/bisonnotes-ai/) | The complete guide for the current release ([sources and older versions](docs/user-guide/README.md)) |
| [Release history](docs/release-history.md) | What changed in each release |
| [Mistral AI free setup](docs/mistral-free-setup.md) | Free cloud transcription and summaries with no credit card |
| [Development](docs/development.md) | Requirements, build and test, architecture, and configuration |
| [Testing regimen](docs/testing-regimen.md) | Release validation |
| [Accessibility](docs/accessibility-matrix.md) | Accessibility support by feature |
| [Documentation index](docs/README.md) | Everything else in `docs/` |

## Quick start for developers

You need Xcode 26.6 or later on an Apple silicon Mac.

```bash
git clone https://github.com/bisonbet/BisonNotes-AI.git
```

```bash
open "BisonNotes-AI/BisonNotes AI/BisonNotes AI.xcodeproj"
```

Choose the **BisonNotes AI** scheme for iPhone and iPad, or **BisonNotes AI
macOS** for the Mac, then build and run. Swift packages resolve automatically.
See [Development](docs/development.md) for command-line builds, tests, and
architecture, and [`CLAUDE.md`](CLAUDE.md) for the rules the codebase follows.

To contribute, open a pull request from a feature branch with your build and
test results, plus screenshots for UI changes.

## Acknowledgments

BisonNotes AI is built on these open-source projects:

| Project | Used for | License |
| --- | --- | --- |
| [Textual](https://github.com/gonzalezreal/Textual) | Rendering AI summaries and transcripts | MIT |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Parakeet transcription and local speaker labels | Apache 2.0 |
| [MLX Swift](https://github.com/ml-explore/mlx-swift) and [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) | On-device summaries | MIT |
| [Swift Transformers](https://github.com/huggingface/swift-transformers) | Tokenizers for local models | Apache 2.0 |

These bring in further packages from Apple, Hugging Face, Point-Free, and
others. [`Package.resolved`](<BisonNotes AI/BisonNotes AI.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved>)
lists them all; see each project for its license.

Downloaded speaker models have their own terms:

- **Offline VBx**: [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml), CC BY 4.0 for the parent Pyannote material.
- **Nemotron 3**: [FluidInference/nemotron-3-diarization-coreml](https://huggingface.co/FluidInference/nemotron-3-diarization-coreml), converted from [nvidia/Nemotron-3-Diarization](https://huggingface.co/nvidia/Nemotron-3-Diarization) under the OpenMDW License 1.1, which permits commercial use.
- **LS-EEND DIHARD3**: [FluidInference/ls-eend-coreml](https://huggingface.co/FluidInference/ls-eend-coreml), MIT; the upstream dataset terms also apply.

## Support

If BisonNotes AI saves you time, you can [buy me a coffee](https://buymeacoffee.com/Bisonnetworking).
Thank you!

## License

MIT. See [LICENSE](LICENSE).
