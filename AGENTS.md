# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Overview

不想背单词 (BuXiangBeiDanCi) — a macOS-native vocabulary capture app. Users select text in any app, copy it, press a global hotkey (Cmd+Shift+D), then pick words from a floating panel. Captured words are stored with their sentence context and source info, queued for AI processing (OpenAI GPT-4o-mini for phonetics/definitions/translations).

**Status**: Phase 1 MVP, in active development. AI processing is stubbed out (see `CaptureCoordinator.processJob`).

## Build & Run

Project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) with `project.yml` at root.

```bash
# Regenerate Xcode project after changing project.yml
xcodegen generate

# Build from command line
xcodebuild -project BuXiangBeiDanCi.xcodeproj -scheme BuXiangBeiDanCi -configuration Debug build

# Open in Xcode (preferred for running/debugging)
open BuXiangBeiDanCi.xcodeproj
```

No tests exist yet. No linter configured.

## Tech Stack

- **Swift 5.9 / SwiftUI** — macOS 14.0+ (Sonoma)
- **GRDB.swift 6.24+** — SQLite via DatabasePool (WAL mode)
- **KeyboardShortcuts 2.0+** — sindresorhus's library for global hotkeys
- **NaturalLanguage** — Apple framework for tokenization and lemmatization
- **App Sandbox disabled** — required for AppleScript browser URL extraction and clipboard access

## Architecture

### Capture Flow (the core pipeline)

1. **HotkeyHandler** (singleton) — registers global Cmd+Shift+D, reads clipboard, detects source app, shows picker panel
2. **WordPickerPanel** — floating NSPanel with tokenized sentence; user clicks words to select
3. **Tokenizer** — uses `NLTokenizer` to split sentence into clickable word tokens; `NLTagger` for lemmatization
4. **SourceDetector** — identifies frontmost app; extracts browser URL/title via AppleScript for Safari/Chrome/Edge/Arc/Firefox
5. **CaptureCoordinator** (singleton) — receives confirmed words, creates `CaptureJob`, saves to DB, triggers async processing
6. **Database** (singleton) — GRDB DatabasePool wrapper with migration system

### Data Model (3 tables)

- **capture_jobs** — processing queue (pending → processing → completed/failed)
- **words** — deduplicated vocabulary (lemma is unique, case-insensitive)
- **word_sources** — one word has many sources (same word encountered in different contexts)

### Key Singletons

All services use shared singletons accessed via `.shared`: `HotkeyHandler`, `CaptureCoordinator`, `Database`.

### AppDelegate

The `AppDelegate` manages the floating `NSPanel` lifecycle by observing `HotkeyHandler.isShowingPicker`. The panel is created/destroyed on each show/hide cycle (not reused).

## Important Details

- **No app sandbox**: The entitlements file explicitly disables sandboxing. This is intentional — AppleScript automation requires it.
- **DEBUG migrations**: In debug builds, `eraseDatabaseOnSchemaChange = true` — the DB is wiped when schema changes. Don't rely on persisted data during development.
- **DB location**: `~/Library/Application Support/BuXiangBeiDanCi/buxiangbeidanci.sqlite`
- **Clipboard-based capture**: The app reads from `NSPasteboard.general`, not from selection directly. User must Cmd+C before Cmd+Shift+D.
- **FlowLayout**: Custom SwiftUI `Layout` in `WordPickerPanel.swift` for word-wrap token display.
- **UI language**: Chinese (Simplified) for all user-facing strings.
