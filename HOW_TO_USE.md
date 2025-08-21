# Audio Journal — Full User Guide

Quick links: [Quick Start](USAGE.md) • [Architecture](README.md#architecture) • [Build & Test](README.md#build-and-test)

This guide explains how to use the app end to end. For a minimal quick start, see USAGE.md. For technical architecture, see README.md.

## Getting Started
- Install the app and open it once on iPhone (and watch if using the companion).
- Permissions: allow Microphone; Location is optional and can be changed later in Settings.
- Migration: on first launch, legacy recordings are imported into Core Data automatically.

## Recording
- Start/stop: tap the microphone. Background recording is supported when enabled in Settings.
- Inputs: built‑in mic, Bluetooth, or USB audio. Mixed audio lets you record without stopping system audio.
- Import: use “Import Audio Files” to add existing recordings.
- Location: auto‑capture can be enabled; you can edit/add locations later.

## Transcription & Summaries
- Choose engine: Settings → Transcription Settings (Apple on‑device, Whisper/Wyoming local, or cloud engines).
- Run transcription: select a recording and transcribe; progress appears inline. Large files are chunked and processed in the background.
- Summaries: open a recording under Summaries to view AI summary, tasks, and reminders. Regenerate with different engines from AI Settings.
 - See also: [AI Engines (Setup)](#ai-engines-setup) and [Architecture](README.md#architecture) for module layout.

## AI Engines (Setup)
- Apple (on‑device): no configuration; fully local.
- OpenAI (cloud): get an API key at platform.openai.com → Settings → AI Settings → OpenAI → enter key and pick a model.
- Google AI Studio (cloud): get a key at aistudio.google.com → Settings → AI Settings → Google → select Gemini model.
- Whisper (local server):
  ```bash
  docker run -d -p 9000:9000 \
    -e ASR_MODEL=base -e ASR_ENGINE=openai_whisper \
    onerahmet/openai-whisper-asr-webservice:latest
  ```
  Then set URL/port in Settings → Transcription Settings → Whisper.
- Wyoming (local streaming):
  ```bash
  docker run -d -p 10300:10300 rhasspy/wyoming-whisper:latest
  ```
  Then select “Whisper (Wyoming)” and configure host/port.
- Ollama (local LLM): install from ollama.com, `ollama pull mistral`; set URL/port under AI Settings → Ollama.
- AWS Bedrock / Transcribe (cloud): create IAM user, enable service, enter keys/region under AI or Transcription Settings and select a model.

## Editing Metadata
- Title: open a summary → Titles → Edit or select an AI suggestion.
- Date/Time: Summary → Recording Date & Time → Set Custom.
- Location: Summary → Location → Add/Edit (current location, pick on map, or enter coordinates).

## Playback
- Open the Recordings tab → select a recording.
- Controls: play/pause, 15‑second skip, and scrubbing. Background playback is supported and handles interruptions.

## Settings & Background Processing
- Audio: quality (64/128/256 kbps), input selection, mixed audio, background recording.
- AI: pick engines/models and test connections; batch regenerate summaries if needed.
- Background jobs: long tasks queue automatically with retries, timeouts, and recovery. Keep the app available for very large files.

## Troubleshooting
- No audio: verify Microphone permission and input device.
- Cloud errors/timeouts: check network and API keys, or use a local engine.
- Large files slow: they process in chunks; allow background time or keep the app foregrounded.
- Sync issues (watch): open both apps; connectivity recovers automatically when the phone becomes reachable.

## Privacy & Security
- API keys are entered only in‑app and are not committed to the repository.
- On‑device engines (Apple, local Whisper/Ollama) keep data local; cloud engines send audio/text to the provider.

## Resources & Support
- Docs: README.md (architecture), USAGE.md (quick start).
- Services: OpenAI, Google AI Studio, AWS Bedrock/Transcribe, Whisper ASR, Wyoming, Ollama.
- Help: open a GitHub issue with device, iOS version, and steps to reproduce.
