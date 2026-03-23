# Antiki (BuXiangBeiDanCi)

> A macOS-native vocabulary capture app — collect words naturally while reading.

## Features

- **Seamless capture** — Global hotkey (Cmd+Shift+D) to pick words from any app
- **Context-aware** — Automatically captures the source sentence as a memory anchor
- **AI-powered** — Auto-generates phonetics, definitions, and sentence translations
- **Multi-source** — Same word encountered in different contexts? All sources preserved

## Status

Under active development — Phase 1 MVP.

## Tech Stack

- **Language:** Swift 5.9+
- **UI:** SwiftUI
- **Storage:** SQLite (GRDB.swift)
- **AI:** OpenAI API (GPT-4o-mini)
- **Platform:** macOS 14.0+ (Sonoma)

## Project Structure

```
antiki/
├── README.md
├── plans/                      # Design docs and plans
│   └── 001-mvp-design.md       # MVP design doc v0.2
├── BuXiangBeiDanCi/            # Xcode project source
│   ├── App/                    # Main app
│   ├── Services/               # Core services
│   ├── Models/                 # Data models
│   ├── Views/                  # SwiftUI views
│   └── Resources/              # Resources
└── project.yml                 # XcodeGen config
```

## Build

```bash
# Regenerate Xcode project
xcodegen generate

# Build from command line
xcodebuild -project BuXiangBeiDanCi.xcodeproj -scheme BuXiangBeiDanCi -configuration Debug build

# Or open in Xcode
open BuXiangBeiDanCi.xcodeproj
```

## License

Private
