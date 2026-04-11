# Mistral AI Free Tier Setup Guide

Mistral AI offers a **free Experiment tier** with access to all their models -- no credit card required. BisonNotes AI includes a guided in-app wizard that walks you through setup in about 2 minutes. Paid tiers (Build, Scale) are also available for higher rate limits and production use.

## What You Get

| Feature | Details |
|---------|---------|
| **Transcription** | Voxtral Mini with speaker diarization ($0.003/min on paid tier, included in free) |
| **Summarization** | Mistral Medium -- automatic summaries, tasks, and reminders |
| **Free Tier Limits** | ~2 requests/second, 500K tokens/min, 1B tokens/month |
| **Credit Card** | Not required for free tier; required for Build/Scale paid tiers |
| **Models** | All models included (Large, Medium, Magistral) |
| **Paid Tiers** | Build (pay-as-you-go) and Scale available for higher rate limits |

## In-App Guided Setup (Recommended)

The easiest way to set up Mistral AI is the built-in onboarding wizard. You can launch it from three places:

### Option A: First-Time App Setup

1. Open BisonNotes AI for the first time
2. On the setup screen, select **"Mistral AI (Free)"**
3. Tap **"Save & Configure"**
4. The Mistral onboarding wizard opens automatically
5. Follow the 5 steps (detailed below)

### Option B: AI Settings

1. Go to **Setup** (gear icon) > **AI Settings**
2. Under "Cloud / Self-Hosted", tap **Mistral AI** (look for the orange "Free" badge)
3. Tap **"Configure Mistral AI"**
4. Tap **"Set Up Free Account"** at the top
5. Follow the wizard steps

### Option C: Mistral AI Settings (Direct)

1. Go to **Setup** > **AI Settings** > select Mistral AI > **Configure Mistral AI**
2. If no API key is configured, a **"Set Up Free Account"** banner appears at the top
3. Tap it to launch the wizard

## Wizard Step-by-Step

### Step 1: Welcome

Review what's included with the free tier. Tap **"Get Started"**.

### Step 2: Create Your Mistral Account

1. Tap **"Open Mistral Console"** -- this opens console.mistral.ai in an in-app browser
2. Sign up with your email address
3. Verify your phone number (required for the free tier)
4. Create a workspace (any name works, e.g., "Personal")
5. Close the browser and tap **"I've Created My Account"**

### Step 3: Generate an API Key

1. Tap **"Open API Keys Page"** -- this opens the API keys section of the Mistral console
2. Click **"Create new key"**
3. Name it **"BisonNotes"** (or anything you prefer)
4. **Copy the key immediately** -- Mistral only shows it once!
5. Close the browser and tap **"I've Copied My Key"**

### Step 4: Paste and Validate Your Key

1. Tap **"Paste from Clipboard"** to auto-fill your key, or type/paste it manually into the secure field
2. Tap **"Test Connection"**
3. Wait for the green "Connection successful!" confirmation
4. Tap **"Continue"**

If the test fails:
- Double-check that you copied the full key
- Make sure you're connected to the internet
- Try generating a new key if the original was lost

### Step 5: Auto-Configuration Complete

The wizard automatically configures optimal settings:

| Setting | Value |
|---------|-------|
| AI Engine | Mistral AI (selected as active) |
| Summarization Model | Mistral Medium (25.08) |
| Transcription Engine | Mistral AI (Voxtral Mini) |
| Speaker Diarization | Enabled |
| Temperature | 0.1 (focused/consistent) |
| JSON Response Format | Enabled |

Tap **"Start Using Mistral AI"** -- you're ready to record!

## Manual Setup (Alternative)

If you prefer to set things up manually instead of using the wizard:

1. Go to [console.mistral.ai](https://console.mistral.ai) in your browser
2. Create an account and verify your phone number
3. Navigate to **API Keys** and create a new key
4. In BisonNotes AI, go to **Setup > AI Settings > Mistral AI > Configure**
5. Paste your API key
6. Select your preferred model (Medium recommended)
7. Test the connection
8. Save settings
9. Go to **Transcription Settings** and select **Mistral AI** as your transcription engine

## After Setup

### Recording and Transcription

Just record as normal. When you stop recording:
1. The audio is sent to Voxtral Mini for transcription
2. The transcript is then sent to Mistral Medium for summarization
3. You get a summary with extracted tasks, reminders, and title suggestions

### Adjusting Settings Later

All settings can be changed anytime:
- **AI Settings > Mistral AI > Configure** -- change model, temperature, max tokens
- **Transcription Settings** -- switch transcription engine or toggle diarization
- The wizard is available again from settings if you need to reconfigure

### Free Tier Considerations

The free Experiment tier is generous for personal use:
- **Rate limit**: ~2 requests/second (slight delay between operations)
- **Monthly limit**: 1 billion tokens (~500+ hours of summarization)
- **No expiration**: The free tier doesn't expire

If you hit rate limits, the app automatically retries with a short delay. For heavy usage, you can upgrade to the Build tier (pay-as-you-go) at [console.mistral.ai](https://console.mistral.ai).

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Connection test fails | Check internet connection; verify key was copied completely |
| "Invalid API key" error | Generate a new key at console.mistral.ai/api-keys |
| Rate limit errors during transcription | Wait 30 seconds and retry; free tier has ~2 req/sec limit |
| Transcription takes a long time | Large files (>24MB) are automatically chunked; this is normal |
| No speaker labels in transcript | Enable diarization in Setup > Transcription Settings > Mistral AI |
