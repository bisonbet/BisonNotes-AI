# Repository Guidelines

## Project Structure & Module Organization
- Primary app code lives in `BisonNotes AI/` with feature folders such as `Models/`, `Views/`, `OpenAI/`, `AWS/`, `Wyoming/`, and `ViewModels/`.
- Watch companion sources are under `BisonNotes AI Watch App Watch App/`; keep shared logic in clear, reusable files.
- Unit and UI tests sit in `BisonNotes AITests/` and `BisonNotes AIUITests/`; watch-specific tests mirror the target folders.
- Assets live in `BisonNotes AI/Assets.xcassets`; app capabilities and settings are in `Info.plist` and `.entitlements`.

## Build, Test, and Development Commands

**CRITICAL: DO NOT BUILD, TEST, OR RUN WITHOUT EXPLICIT USER REQUEST**

Never execute build, test, or run commands unless the user explicitly asks you to do so. This includes:
- Do NOT run `xcodebuild` to verify fixes
- Do NOT compile to check for errors
- Do NOT run tests automatically
- Do NOT execute the app to verify functionality
- Do NOT open Xcode programmatically

If you make code changes, explain what you fixed and let the user verify by building themselves.

When explicitly requested by the user, these commands are available:
- `open "BisonNotes AI/BisonNotes AI.xcodeproj"` launches the workspace in Xcode.
- `xcodebuild -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" -configuration Debug build` performs a Debug build of the iOS app.
- `xcodebuild test -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" -destination 'platform=iOS Simulator,name=iPhone 15'` runs the iOS test suite.
- Use the corresponding watchOS scheme in Xcode to validate watch targets before merging.

## Coding Style & Naming Conventions
- Follow 4-space indentation with lines under 120 characters; keep one primary type per file.
- Use `UpperCamelCase` for types and files, `lowerCamelCase` for properties/functions, and enum cases in `lowerCamelCase`.
- Append `View`, `ViewModel`, `Manager`, or `Service` where applicable; align folder names with features.
- Prefer succinct comments explaining non-obvious logic; avoid redundant narration.

## Testing Guidelines
- XCTest powers unit and UI coverage; prioritize models, services, error paths, and integration seams.
- Mirror source names in test files, e.g., `SummaryManagerTests.swift`; group flows under `...UITests`.
- Run `xcodebuild test` before PRs and document any simulator or device caveats in the PR template.

## Commit & Pull Request Guidelines
- Use Conventional Commit prefixes (`feat:`, `fix:`, `chore:`) with imperative, scoped messages.
- PRs should summarize changes, link issues via `Closes #123`, note simulator targets, and attach UI screenshots when applicable.
- Confirm the app builds for both iOS and watchOS schemes; include test evidence or rationale if coverage is deferred.

## Security & Configuration Tips
- Never commit API keys; rely on in-app settings for OpenAI and AWS credentials stored securely at runtime.
- Keep `Info.plist` and entitlements minimal and aligned with required capabilities (iCloud, Background Modes, Microphone).
- When adjusting background audio or sync, verify behavior on paired iOS and watchOS devices to avoid runtime regressions.
