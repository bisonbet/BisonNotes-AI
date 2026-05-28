# AGENTS.md

## Cursor Cloud specific instructions

### Platform constraints

This is a **native iOS/watchOS Xcode project**. It requires **macOS with Xcode 15+** to build, run the iOS Simulator, and execute unit/UI tests. On a Linux Cloud Agent VM:

- **Cannot build**: `xcodebuild` is macOS-only.
- **Cannot run**: iOS Simulator requires macOS.
- **Cannot run unit/UI tests**: Tests require Xcode and the simulator.
- **Cannot resolve SPM dependencies via Xcode**: The project uses Xcode-managed SPM (no standalone `Package.swift`), and packages depend on Apple-only frameworks.

### What you CAN do on Linux

- **Lint**: Run `swiftlint lint` against Swift files (requires `LINUX_SOURCEKIT_LIB_PATH` set; see below).
- **Syntax-check**: Run `swiftc -parse <file.swift>` to validate Swift syntax (works for files without Apple framework imports).
- **Code review/editing**: Read, search, and edit all Swift source files, Core Data model XML, plists, entitlements, etc.
- **Git operations**: Full git workflow including branching, committing, and pushing.

### Environment setup (already done by update script)

- **Swift 6.3.x** installed via [Swiftly](https://swift.org/install/linux/) at `~/.local/share/swiftly/`.
- **SwiftLint 0.58.x** installed at `/usr/local/bin/swiftlint`.
- Environment variables sourced from `~/.bashrc`:
  - Swiftly env: `. "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"`
  - SourceKit path: `export LINUX_SOURCEKIT_LIB_PATH=...` (auto-computed from installed toolchain)

### Running SwiftLint

```bash
cd "BisonNotes AI/BisonNotes AI"
swiftlint lint                    # Full lint with all details
swiftlint lint --reporter summary # Summary table only
```

SwiftLint runs with default rules (no `.swiftlint.yml` exists in the repo). The codebase has ~9,000 pre-existing violations (mostly `trailing_whitespace` and `line_length`), so lint errors from these rules are expected and not introduced by agents.

### Running Swift syntax checks

```bash
swiftc -parse "BisonNotes AI/BisonNotes AI/Models/AudioModels.swift"
```

Note: `swiftc -parse` validates syntax only. Files that import Apple frameworks (SwiftUI, CoreData, AVFoundation, etc.) will parse successfully but cannot be compiled on Linux.

### Project structure quick reference

See `README.md` (Build and Test section) and `CLAUDE.md` (Architecture Overview) for full details. Key paths:

- Xcode project: `BisonNotes AI/BisonNotes AI.xcodeproj`
- iOS app source: `BisonNotes AI/BisonNotes AI/`
- Watch app: `BisonNotes AI/BisonNotes AI Watch App/`
- Unit tests: `BisonNotes AI/BisonNotes AITests/`
- UI tests: `BisonNotes AI/BisonNotes AIUITests/`
- Pre-compiled framework: `Frameworks/llama.xcframework/`
