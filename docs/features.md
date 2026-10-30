# BisonNotes AI features and usage

This page covers how to use BisonNotes AI 3.0. For the illustrated guide, see the
[full user guide](https://www.bisonnetworking.com/bisonnotes-ai/). For release-by-release changes, see
[release history](release-history.md).

- [Recording](#recording)
- [Transcription](#transcription)
- [Summaries and AI engines](#summaries-and-ai-engines)
- [Beta features](#beta-features)
- [Importing](#importing)
- [Working with recordings](#working-with-recordings)
- [iCloud sync](#icloud-sync)
- [Audio archive](#audio-archive)
- [Privacy and security](#privacy-and-security)

## Recording

- **iPhone and iPad**: record with pause and resume. Recording continues in the
  background and survives calls and screen locks. After an interruption, the
  completed segment is kept and recording recovers once.
- **Apple Watch**: a single large button starts and stops recording, and mute
  pauses and resumes the same file. The watch records on its own and sends the
  finished file to the phone, even after going offline or relaunching.
  Watch-face complications show the recording state.
- **Mac**: pick any Core Audio input. **Record Meeting Audio** can also capture
  system audio through ScreenCaptureKit and mix it with your microphone. The app
  walks you through the Screen & System Audio Recording permission, including
  the required quit and reopen. If the microphone disconnects, the recording
  falls back to another input and keeps the system-audio track.
- **Control Center**: start or stop a recording from the Controls widget
  (iOS 18+). Mac desktop widgets open the app and start a new recording.
- **Live Transcription**: optional on-device speech-to-text while you record. The
  transcript is saved when you stop.

### iPhone Action Button

On iPhones with an Action Button:

1. Open **Settings › Action Button**.
2. Choose **Shortcut**, then **Start Recording** from BisonNotes AI.

Pressing the button opens the app on the Recordings tab and starts recording
right away, even when the phone is locked.

## Transcription

| Engine | Description | Requirements |
| --- | --- | --- |
| **On Device (Parakeet)** | Default. NVIDIA Parakeet models run locally through FluidAudio. Supports optional Local Speaker Labels. | iOS 18.5+ or macOS 15+, one-time model download |
| **Mistral AI** | Cloud transcription with Voxtral Mini (`voxtral-mini-latest`), with optional speaker diarization | API key, internet |
| **Whisper (local server)** | Your own Whisper server over REST or the Wyoming protocol | A running Whisper server |

### On Device (Parakeet)

- **Models**: Parakeet v2 for English, or Parakeet v3 for 25 European languages.
- **Setup**: download the model from **Setup › Transcription Settings › On
  Device**. After that, it works offline.
- **Privacy**: audio never leaves the device.

### Local Speaker Labels

Speaker labels are optional and off by default. After a Parakeet transcript
finishes, a local speaker model runs once over the whole recording. Labels work
for new recordings, imports, and transcript re-runs, but never during Live
Transcription.

| Method | Status | Notes |
| --- | --- | --- |
| **Offline VBx** | Recommended | Estimates the number of speakers. Works for any group size. |
| **Nemotron 3** | Experimental | NVIDIA's Nemotron 3 Diarization model, run on the Neural Engine. Supports up to 8 speakers; a ninth voice is merged into another speaker. |
| **LS-EEND** | Experimental | Supports up to 10 speakers, but labels can be over-segmented. Limited to recordings up to one hour. |

- Choose a method, then download its model from On Device settings. Turning
  labels on never starts a download during transcription.
- Each model downloads, unloads, and deletes on its own; removing one leaves the
  others and Parakeet in place.
- If labelling fails, you keep the full unlabeled transcript and see a warning.
  There is no cloud fallback.
- To rename a speaker, open the transcript's speaker controls, rename, and save.
  The new name is used in the transcript and the summary.

### Mistral AI transcription

- About $0.003 per minute of audio.
- Detects the language automatically, or you can set a language code (`en`,
  `fr`, `es`).
- Accepts MP3, MP4, M4A, WAV, FLAC, OGG, and WebM. Files over 24 MB or about
  22 minutes are split into chunks automatically.
- Uses the same API key as Mistral summaries. Set it in **Setup › AI Settings ›
  Mistral AI**, then choose Mistral AI in Transcription Settings.

### Audio Cleanup

Optional processing before transcription: a high-pass filter, noise gate,
dynamic normalization, and peak limiting.

## Summaries and AI engines

Each summary includes a narrative summary, tasks, reminders, and suggested
titles. Tasks and reminders can be sent to Apple Reminders, Apple Calendar, or
Google Calendar.

| Engine | Description | Requirements |
| --- | --- | --- |
| **On Device AI** | Default. MLX Swift with Ternary Bonsai models. | 4 GB+ RAM, model download |
| **Apple Native** | Apple Intelligence (Foundation Models), fully on-device | iOS 26+ on an Apple Intelligence-capable device |
| **Mistral AI** | Mistral Large (25.12), Medium (25.08), Small 4 (26.03), Medium 3.5, Magistral Medium (25.09) | API key, internet |
| **Google AI Studio** | Gemini 3.7 Flash (default), Gemini 3.5 Flash Lite | API key, internet |
| **Compatible API** | Any OpenAI-compatible chat-completions server (Nebius, Groq, LiteLLM, a llama.cpp server) | Endpoint, usually an API key |
| **Ollama** | A local Ollama server, on native macOS only | Ollama running on the Mac |

### On Device AI models

| Model | Size | Minimum RAM |
| --- | --- | --- |
| Ternary Bonsai 1.7B | ~470 MB | 4 GB |
| Ternary Bonsai 4B (default) | ~1.1 GB | 6 GB |
| Ternary Bonsai 8B | ~2.3 GB | 8 GB |
| Ternary Bonsai 27B (Mac only) | ~8.5 GB | 16 GB |

Models download from Hugging Face over Wi-Fi by default; cellular downloads are
optional. The context window is 16K tokens.

### Mistral AI free tier

Mistral's free Experiment tier needs no credit card. The in-app setup wizard
walks you through creating an account and an API key in about two minutes. See
the [Mistral AI free setup guide](mistral-free-setup.md).

### Summary options

- **Summary Detail**: Brief, Balanced, or Detailed.
- **Thinking**: Off or Light, on models that support a thinking control. The
  model's reasoning never appears in the summary.
- **Comedy Mode**: an optional tone, such as snarky, for engines that use custom
  prompts.
- **Attachments**: attach text, PDF, or other documents to a summary and
  preview them inline.
- **PDF export**: a report with metadata, local and regional maps, and separate
  task and reminder sections.

## Beta features

Open **Settings › Beta Features** (the Beta tab in Mac Settings) and turn on
Beta Features, then each feature you want. Turning the master switch off goes
back to standard behavior but keeps each feature's own settings.

### Summary Prompt

Choose the default prompt for new summaries: Default, Business Meeting, Personal
Notes, or up to five custom prompts.

- Under **Edit prompts**, you can reword Business Meeting and Personal Notes (and
  restore the original), and give each custom prompt a name, wording, and a
  recording type: Auto-detect, Meeting, or Personal Notes.
- A prompt only changes the summary. Tasks, reminders, and titles keep their
  standard prompts.
- Each summary remembers its prompt. **Regenerate** lets you pick a different
  one and always uses the prompt's current wording.
- A custom prompt replaces Summary Detail and Comedy Mode.

### Transcript Cleanup

Turn on **Clean up transcripts automatically (English only)** to run S1-mini by
Superwhisper on completed file transcripts. It works on Apple silicon Macs and
physical iPhones and iPads. Download S1-mini first, from the Beta Features page
or the transcript editor; turning the setting on never downloads it.

- The original transcript, timing, and speaker labels are always kept. The
  editor lets you switch between **Original** and **Cleaned** and opens on the
  version you saved. A completed cleanup saves Cleaned.
- Summaries, copy, share, and text export use the version you saved.
- The raw transcript is saved first. Cleanup then runs while the app is in the
  foreground, pauses when it goes to the background, and picks up where it left
  off. The editor shows progress, such as "Cleaning… 12 of 40 passages".
- If a passage can't be cleaned, it keeps its original text and the rest is
  still cleaned.
- **Clean up English transcript** in the editor runs a one-time cleanup,
  including on imported text, without turning on automatic cleanup.

## Importing

### Share menu

Share files into BisonNotes AI from Voice Memos, Files, Finder, or other apps on
iPhone, iPad, and Mac.

- **Audio**: M4A, MP3, WAV, CAF, AIFF, AIF
- **Transcripts and documents**: TXT, MD, VTT, SRT, PDF, DOC, DOCX

If another import is already running, the new file waits and is imported on a
later launch rather than being discarded.

### Import From Link

Tap **Import From Link** on the Recordings screen, or choose **File › Import
From Link…** on Mac.

- **Audio and video links**: M4A, MP3, WAV, CAF, AIFF, AIF, MP4, MOV, M4V, AVI,
  and MKV. The audio is extracted from video to M4A.
- **Transcript links**: TXT, MD, VTT, SRT, PDF, DOC, and DOCX. Imported
  transcripts can be summarized without audio.
- **YouTube links**: public captions are imported as a transcript; the video
  itself is not downloaded. If YouTube blocks the request, the app shows steps
  to open the video, copy its transcript, and paste it in.
- Links must use HTTPS, localhost, or a private-network address.

### Video files

Imported video files have their audio extracted to M4A automatically.

## Working with recordings

### Search and date filters

Search Recordings (by name), Transcripts (text and name), and Summaries
(content, tasks, reminders, titles, and recording names). Results update as you
type and ignore case.

To filter by date, tap the filter icon, choose a start and end date, and tap
**Apply**. Both dates include the whole day. A banner shows the active filter;
tap its **X** to clear it. Filters and search can be combined.

### Trim Recording

Choose a start and end point and save the clip as a new recording. The original
is left unchanged.

### Combine Recordings

1. On the Recordings tab, enter selection mode and select two recordings.
2. Tap **Combine**, choose which recording goes first, and check the combined
   length.
3. Tap **Combine Recordings**. You can delete the originals afterwards.

Both recordings must have no transcripts or summaries. Delete those first, and
generate new ones for the combined file.

### Editing and sharing

- Edit a recording's title from the audio player or transcript editor. The
  summary also offers AI-suggested titles.
- Share any recording as an audio file from the share sheet.

## iCloud sync

iCloud sync is off until you turn it on. When you turn it on, the app shows a
notice that BisonNotes AI and its iCloud uploads are **not HIPAA-compliant**.

- Recordings, transcripts, summaries, and selected settings sync to your private
  iCloud account. Sync runs when the app launches or becomes active.
- **Include audio files in backup** controls whether audio is uploaded and
  restored.
- **Keep on This Device**, from a recording row or the audio player, keeps that
  recording, its transcript, and its summary out of iCloud, and removes the
  copies the app already uploaded.
- Deleting a recording or summary leaves a deletion marker, so other devices
  delete it too instead of uploading it again. Deletions made offline are sent
  when iCloud becomes available.
- When two devices edit the same item, the newest edit wins.
- Older cloud-only items that can't be confirmed as active wait in **Settings ›
  iCloud Sync › Review iCloud Items**, where you can restore or delete them.
- API keys are never included in iCloud settings backups.

**Erase All iCloud Data**, under Advanced Troubleshooting, deletes everything the
app stored in iCloud and leaves the data on your devices alone.

Your devices must use the same Apple ID. A Debug build from Xcode uses the
CloudKit development environment, so it can't see data from TestFlight or App
Store builds.

## Audio archive

Archiving moves a recording's audio to iCloud Drive, and can remove the local
copy. It isn't a deletion: the recording, transcript, summary, tasks, and
reminders stay in the app. You can archive selected recordings or everything
older than a chosen age.

An archived recording shows its iCloud Drive location and a download button.
Restoring copies the audio back, checks that it plays, and removes the iCloud
Drive copy. If the app can't save a location it can track, it keeps the local
audio and doesn't mark the recording archived.

Only iCloud Drive is supported as a destination. Dropbox, Google Drive, Proton
Drive, and other file providers haven't been reliable enough for archive and
restore.

## Privacy and security

- With On Device transcription and On Device AI, no audio or text leaves the
  device. Cloud engines are used only if you choose them.
- API keys are stored in the Keychain and never written to disk in plain text.
- Recordings, transcripts, notes, attachments, and the database use iOS file
  protection.
- Public `http://` and `ws://` endpoints are blocked for Compatible API, Ollama,
  and Whisper. `localhost` and private-network IP addresses are allowed.
  **Development Mode: Allow Public HTTP** (one setting shared by all three)
  unblocks any other HTTP address, including hostnames and Tailscale
  `100.x` addresses.

> **Not HIPAA compliant.** BisonNotes AI is a personal productivity app and does
> not provide Business Associate Agreements. Don't use it to record or process
> protected health information.
