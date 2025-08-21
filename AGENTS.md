# Repository Guidelines

## Project Structure & Module Organization
- `BisonNotes AI/`: Main iOS app source (Swift + SwiftUI). Key folders: `Models/`, `Views/`, `OpenAI/`, `AWS/`, `Wyoming/`, `WatchConnectivity/`, `ViewModels/`, plus assets in `Assets.xcassets` and configuration in `Info.plist` and `.entitlements`.
- `BisonNotes AI Watch App Watch App/`: watchOS companion app sources.
- Tests: `BisonNotes AITests/` (unit), `BisonNotes AIUITests/` (UI), and watch-specific tests under the watch target folders.
- Xcode project: `BisonNotes AI/BisonNotes AI.xcodeproj`.

## Build, Test, and Development Commands
- Open in Xcode: `open "BisonNotes AI/BisonNotes AI.xcodeproj"`
- Build (iOS app): `xcodebuild -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" -configuration Debug build`
- Test (iOS): `xcodebuild test -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" -destination 'platform=iOS Simulator,name=iPhone 15'`
- Tip: Use the Xcode schemes for the iOS app and watch app to run in Simulator. SwiftPM dependencies are resolved via the workspace; no separate install step is required.

## Coding Style & Naming Conventions
- Indentation: 4 spaces; keep lines <120 chars.
- Swift naming: `UpperCamelCase` for types/files, `lowerCamelCase` for vars/functions, enum cases `lowerCamelCase`.
- Suffixes: `View` for SwiftUI views, `Manager`/`Service` for coordinators and integrations, `ViewModel` for state containers.
- Organize by feature folder (e.g., `OpenAI/`, `AWS/`) and keep one primary type per file.

## Testing Guidelines
- Framework: XCTest for unit and UI tests.
- Naming: Mirror source types (e.g., `SummaryManagerTests.swift`). Group UI flows in `...UITests`.
- Run: use the `xcodebuild test` example above or run tests per target in Xcode. Aim for meaningful coverage of models, services, and error paths.

## Commit & Pull Request Guidelines
- Commits: Prefer Conventional Commits (e.g., `feat:`, `fix:`, `chore:`). Keep messages imperative and scoped.
- PRs: Include a clear summary, linked issues (e.g., `Closes #123`), test plan/Simulator target, and screenshots for UI changes. Ensure all tests pass and the app builds for both iOS and watchOS targets.

## Security & Configuration Tips
- Do not commit secrets. API keys are entered via app settings views (e.g., OpenAI/AWS settings) and stored securely at runtime.
- Keep entitlements and `Info.plist` minimal and in sync with capabilities used (iCloud, Background Modes, Microphone).
- When touching background processing, audio, or sync, test on device and watch pairs where possible.

