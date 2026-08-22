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

### Environment setup (Cloud Agent)

The Cloud Agent environment is defined by `.cursor/environment.json`, whose
`install` step runs `.cursor/install.sh`. That script is idempotent and:

- Installs the Swift OS dependencies (libcurl, libpython, etc.).
- Installs **Swift 6.3.3** via [Swiftly](https://swift.org/install/linux/) at `~/.local/share/swiftly/`.
- Installs **SwiftLint 0.58.2** at `/usr/local/bin/swiftlint`.
- Appends a guarded block to `~/.bashrc` (also picked up by login shells because
 `~/.profile` sources `~/.bashrc`) that sets:
 - Swiftly env: `. "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"`
 - SourceKit path: `export LINUX_SOURCEKIT_LIB_PATH=...` (auto-computed from the installed toolchain)

To change the pinned Swift or SwiftLint version, edit the `SWIFT_VERSION` /
`SWIFTLINT_VERSION` variables at the top of `.cursor/install.sh`.

### Running SwiftLint

```bash
cd "BisonNotes AI/BisonNotes AI"
swiftlint lint                    # Full lint with all details
swiftlint lint --reporter summary # Summary table only
```

SwiftLint runs with default rules. `BisonNotes AI/BisonNotes AI/.swiftlint.yml`
declares a committed baseline (`SwiftLintBaseline.json`) that is meant to
suppress the ~2,600 pre-existing violations (mostly `line_length` and body/type
length rules) so only newly introduced violations surface.

**Baseline portability caveat:** the committed `SwiftLintBaseline.json` was
generated on macOS and stores absolute file URLs (`file:///Users/champ/...`).
SwiftLint matches baseline entries by file path, so on a Linux checkout (or any
path other than the one it was generated on) the baseline does **not** match and
`swiftlint lint` reports the full ~2,600 pre-existing violations and exits
non-zero. Those violations are pre-existing, not introduced by agents. To get a
clean, baseline-filtered run on Linux, generate a local baseline first and lint
against it:

```bash
cd "BisonNotes AI/BisonNotes AI"
swiftlint lint --write-baseline /tmp/baseline.json   # capture current state
swiftlint lint --baseline /tmp/baseline.json         # 0 new violations => clean
```

Do not commit a Linux-generated baseline over the macOS one: per-platform rule
behavior can differ slightly, so the maintainer's macOS-generated baseline is
the source of truth for the committed file.

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
