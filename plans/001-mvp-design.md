# 不想背单词 MVP 设计文档

> Mac 专属智能背单词应用 — 让单词采集回归阅读流

**版本:** v0.4  
**更新:** 2026-03-08  
**状态:** 设计完成，准备实现

---

## 📋 目录

1. [产品概述](#产品概述)
2. [核心痛点](#核心痛点)
3. [设计原则](#设计原则)
4. [用户流程](#用户流程)
5. [技术架构](#技术架构)
6. [数据模型](#数据模型)
7. [AI 设计](#ai-设计)
8. [UI 设计](#ui-设计)
9. [错误处理与可观测性](#错误处理与可观测性)
10. [技术风险与原型验证](#技术风险与原型验证)
11. [开发计划](#开发计划)
12. [未来扩展](#未来扩展)

---

## 产品概述

**不想背单词** 是一款 Mac 专属的智能背单词应用，专注于解决单词采集流程繁琐、上下文丢失的问题。

**核心理念：**
- 在阅读的地方采集，不打断心流
- 保留原文语境，作为记忆锚点
- AI 自动处理释义，无需手动制卡

**目标用户：** 在 Mac 上进行大量英文阅读的用户

**平台：** macOS 14.0+ (Sonoma)

---

## 核心痛点

| 痛点 | 现状 | 影响 |
|------|------|------|
| 流程断裂 | 阅读 → 查词典 → 继续阅读 → 几天后导出 → 导入 Anki | 操作繁琐，容易放弃 |
| Context 丢失 | 词典只记录单词本身 | 复习时不知道当时在哪看到的 |
| 顺序丢失 | 批量导出后单词顺序打乱 | 失去阅读进度的关联感 |
| 制卡手动 | Anki 需要手动填写释义、例句 | 耗时且质量参差 |
| 多来源碎片化 | 同一单词可能在不同文章遇到 | 无法聚合多个语境 |

---

## 设计原则

### 🎯 核心原则：稳定采集 > 智能处理

基于工程 review，我们确立以下原则：

1. **输入侧保守，处理侧渐进**
   - 不假设能自动获取上下文
   - 用户负责选择完整内容
   - 系统只承诺稳定接收和存储

2. **异步可恢复管线**
   - 采集立即落库（pending 状态）
   - AI 处理异步进行
   - 失败可重试，不丢数据

3. **失败是常态，成功是增强**
   - URL/title 是增强信息，可空
   - AI 结果需要标记置信度
   - 所有步骤记录状态

4. **可调试优先**
   - 保留原始输入
   - 记录处理链路
   - 区分"没有"和"获取失败"

---

## 用户流程

### 采集流程（全局快捷键 + 选词弹窗）

> **设计变更 v0.4:** 放弃 NSServices 方案（注册不稳定、用户认知成本高），改用全局快捷键 + 弹窗选词。

**核心交互：**
1. 用户选中整句话 → `Cmd+C` 复制
2. 按 `Cmd+Shift+D` 触发快捷键
3. 弹出选词窗口，显示句子，点击选择生词
4. 按回车确认，选中的词全部添加

```
用户正在阅读文章
        │
        ▼
选中包含生词的整句话
        │
        ▼
Cmd+C 复制到剪贴板
        │
        ▼
Cmd+Shift+D 触发采集
        │
        ▼
┌──────────────────────────────────────────┐
│  📝 不想背单词                     ✕    │
├──────────────────────────────────────────┤
│                                          │
│  点击选择生词：                          │
│                                          │
│  ┌────────────────────────────────────┐  │
│  │ The [ephemeral] nature of cherry  │  │
│  │ [blossoms] has [inspired] poets   │  │
│  │ for centuries.                    │  │
│  └────────────────────────────────────┘  │
│                                          │
│  已选 (2): ephemeral, blossoms           │
│                                          │
│  ─────────────────────────────────────   │
│  📍 Safari · nytimes.com/article/...     │
│                                          │
│          [取消]    [添加 2 个词 ⏎]       │
└──────────────────────────────────────────┘
        │
        ▼ 用户点击词 + 按回车
        │
┌───────────────────────────────────────┐
│  为每个选中的词创建 capture_job      │
│  • word: 用户点击的词                │
│  • sentence: 整句话                  │
│  • source_app / url: 来源信息        │
│  • status: pending                   │
└─────────────────┬─────────────────────┘
                  │
                  ▼
        弹窗关闭，用户继续阅读 📖
                  │
        ─ ─ ─ ─ ─│─ ─ ─ ─ ─ (异步)
                  │
                  ▼
┌─────────────────────────────────────┐
│         AI 异步处理                 │
│  • 识别单词原形 (lemma)             │
│  • 生成音标、释义                   │
│  • 翻译句子                         │
│  • 标记 needs_review                │
└─────────────────┬───────────────────┘
                  │
         ┌───────┴───────┐
         ▼               ▼
    [成功]            [失败]
         │               │
         ▼               ▼
 status: completed   status: failed
 写入 words +        保留 pending
 word_sources        可重试
```

### 选词弹窗交互细节

```
┌──────────────────────────────────────────┐
│  📝 不想背单词                     ✕    │
├──────────────────────────────────────────┤
│                                          │
│  点击选择生词：                          │
│                                          │
│  ┌────────────────────────────────────┐  │
│  │                                    │  │
│  │  The  ephemeral  nature  of       │  │
│  │       ─────────                    │  │
│  │       [已选 ✓]                     │  │
│  │                                    │  │
│  │  cherry  blossoms  has  inspired  │  │
│  │          ────────      ────────    │  │
│  │          [已选 ✓]      [点击选]    │  │
│  │                                    │  │
│  │  poets  for  centuries.           │  │
│  │                                    │  │
│  └────────────────────────────────────┘  │
│                                          │
│  已选: ephemeral, blossoms               │
│  [全部取消选择]                          │
│                                          │
│  ─────────────────────────────────────   │
│  📍 来源: Safari                         │
│  🔗 nytimes.com/2026/03/08/cherry...     │
│                                          │
│          [取消 Esc]  [添加 2 个词 ⏎]     │
└──────────────────────────────────────────┘

交互规则：
• 点击单词 → 切换选中状态
• 已选中的词显示下划线 + 高亮
• 双击单词 → 选中并直接提交（快速添加单个词）
• Esc → 取消关闭
• Enter → 确认添加所有选中词
• 句子为空 → 显示"请先复制文字"提示
```

### 来源检测（快捷键触发时）

```
快捷键触发后，立即获取来源信息：

┌─────────────────────────────────────┐
│       SourceMetadataProvider        │
├─────────────────────────────────────┤
│                                     │
│  1. source_app ──────── 必定成功 ✓  │
│     NSWorkspace.frontmostApp        │
│     （快捷键触发前的活跃 App）       │
│                                     │
│  2. bundle_id ───────── 必定成功 ✓  │
│                                     │
│  3. source_url ──────── 可能失败    │
│     Safari: AppleScript             │
│     Chrome: AppleScript             │
│     其他浏览器: 尝试通用脚本        │
│                                     │
│  4. source_title ────── 可能失败    │
│     依赖浏览器 AppleScript          │
│                                     │
└─────────────────────────────────────┘
                  │
                  ▼
        记录 source_status:
        • resolved: 全部获取成功
        • partial: 部分获取成功（URL 失败）
        • failed: 仅有 app 信息

注意：
• 快捷键触发时，不想背单词 会变成前台 App
• 所以必须在显示弹窗前先记录来源 App
• 使用 NSWorkspace 获取「之前」的活跃 App
```

---

## 技术架构

### 整体架构

```
┌─────────────────────────────────────────────────────────────────┐
│                        macOS System                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐       │
│  │   Safari     │    │   Chrome     │    │  Books/PDF   │       │
│  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘       │
│         │                   │                   │                │
│         └───────────────────┼───────────────────┘                │
│                             │                                    │
│           用户选中文字 → Cmd+C → Cmd+Shift+D                     │
│                             │                                    │
│  ┌──────────────────────────┴──────────────────────────┐        │
│  │                    不想背单词.app                   │        │
│  │                                                      │        │
│  │  ┌────────────────────────────────────────────────┐ │        │
│  │  │           Global Hotkey Handler                 │ │        │
│  │  │         (Cmd+Shift+D 全局快捷键)                │ │        │
│  │  │  • 读取剪贴板                                   │ │        │
│  │  │  • 获取来源 App（触发前的活跃 App）             │ │        │
│  │  │  • 弹出选词面板                                 │ │        │
│  │  └──────────────────────┬─────────────────────────┘ │        │
│  │                         │                           │        │
│  │  ┌──────────────────────┴─────────────────────────┐ │        │
│  │  │           WordPickerPanel (弹窗)                │ │        │
│  │  │  • 显示句子，词可点击                           │ │        │
│  │  │  • 用户选择生词                                 │ │        │
│  │  │  • 确认后提交                                   │ │        │
│  │  └──────────────────────┬─────────────────────────┘ │        │
│  │                         │                           │        │
│  │  ┌──────────────────────┴─────────────────────────┐ │        │
│  │  │            CaptureCoordinator                   │ │        │
│  │  │  ┌─────────────┐  ┌─────────────┐              │ │        │
│  │  │  │   Source    │  │  Tokenizer  │              │ │        │
│  │  │  │  Metadata   │  │  (分词)     │              │ │        │
│  │  │  └──────┬──────┘  └──────┬──────┘              │ │        │
│  │  │         └────────┬───────┘                      │ │        │
│  │  │                  ▼                              │ │        │
│  │  │         ┌─────────────┐                         │ │        │
│  │  │         │  Repository │ ◀─── SQLite             │ │        │
│  │  │         └──────┬──────┘                         │ │        │
│  │  │                │                                │ │        │
│  │  │         ┌──────┴──────┐                         │ │        │
│  │  │         │     AI      │ ◀─── Async Queue        │ │        │
│  │  │         │  Processor  │                         │ │        │
│  │  │         └─────────────┘                         │ │        │
│  │  └────────────────────────────────────────────────┘ │        │
│  │                         │                           │        │
│  │  ┌──────────────────────┴─────────────────────────┐ │        │
│  │  │              SwiftUI Views                      │ │        │
│  │  │  • 主窗口（单词列表）  • 选词弹窗              │ │        │
│  │  └─────────────────────────────────────────────────┘ │        │
│  └─────────────────────────────────────────────────────┘        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
                    ┌───────────────────────┐
                    │   AI API (云端)       │
                    │   OpenAI / Claude     │
                    └───────────────────────┘
```

### 模块职责

| 模块 | 职责 | 边界 |
|------|------|------|
| **HotkeyHandler** | 监听全局快捷键 Cmd+Shift+D | 触发后读取剪贴板，弹出选词面板 |
| **WordPickerPanel** | 选词弹窗 UI | 显示句子、处理点击选词、提交 |
| **Tokenizer** | 分词 | 将句子拆分为可点击的词 |
| **SourceMetadataProvider** | 获取来源信息 | 容忍失败，返回 partial |
| **CaptureCoordinator** | 编排采集流程 | 协调各模块，管理状态 |
| **Repository** | 数据持久化 | 只管 CRUD，不含业务逻辑 |
| **AIProcessor** | AI 处理队列 | 异步，可重试，记录指标 |
| **ViewModels** | UI 状态管理 | 只面向 UI，调用 Coordinator |

### 技术栈

| 层级 | 技术选型 | 说明 |
|------|----------|------|
| 语言 | Swift 5.9+ | 原生 macOS 开发 |
| UI | SwiftUI | 现代声明式 UI |
| 采集入口 | KeyboardShortcuts | 全局快捷键 Cmd+Shift+D |
| 分词 | NLTokenizer | Apple 原生 NLP 分词 |
| 来源检测 | NSWorkspace + AppleScript | App 必成功，URL best effort |
| 网络 | URLSession / async-await | AI API 调用 |
| 存储 | SQLite (GRDB.swift) | 本地数据库 |
| 异步 | Swift Concurrency | Actor 隔离 AI 处理 |
| 通知 | UserNotifications | 采集状态提示 |

---

## 数据模型

### ER 图

```
┌─────────────────────────┐
│     capture_jobs        │  ◀── 采集任务（异步管线核心）
├─────────────────────────┤
│ id: INTEGER PK          │
│ selected_text: TEXT     │  ◀── 用户原始选中
│ normalized_text: TEXT   │  ◀── 标准化后
│ source_app: TEXT        │
│ bundle_id: TEXT         │
│ source_url: TEXT?       │
│ source_title: TEXT?     │
│ source_status: TEXT     │  ◀── resolved/partial/failed
│ capture_method: TEXT    │  ◀── hotkey（当前唯一入口）
│ status: TEXT            │  ◀── pending/processing/completed/failed
│ error_message: TEXT?    │
│ retry_count: INTEGER    │
│ created_at: DATETIME    │
│ processed_at: DATETIME? │
└───────────┬─────────────┘
            │ 处理成功后写入 ↓
            │
┌───────────┴─────────────┐         ┌─────────────────────────┐
│        words            │         │     word_sources        │
├─────────────────────────┤         ├─────────────────────────┤
│ id: INTEGER PK          │────┐    │ id: INTEGER PK          │
│ lemma: TEXT UNIQUE      │    │    │ word_id: INTEGER FK     │◀───┐
│ phonetic: TEXT          │    │    │ surface_form: TEXT      │    │
│ definition: TEXT        │    └───▶│ sentence: TEXT          │    │
│ created_at: DATETIME    │         │ sentence_translation: TEXT   │
│ updated_at: DATETIME    │         │ sentence_source: TEXT   │◀── selected/extracted/reconstructed
│ review_count: INTEGER   │         │ source_app: TEXT        │
│ next_review_at: DATE?   │         │ bundle_id: TEXT         │
│ familiarity: INTEGER    │         │ source_url: TEXT?       │
└─────────────────────────┘         │ source_title: TEXT?     │
                                    │ source_status: TEXT     │
                                    │ capture_job_id: INTEGER │◀── 关联原始任务
                                    │ ai_model: TEXT          │
                                    │ ai_latency_ms: INTEGER  │
                                    │ needs_review: BOOLEAN   │◀── AI 不确定时标记
                                    │ captured_at: DATETIME   │
                                    └─────────────────────────┘
                                                │
┌───────────────────────────────────────────────┘
│
│   ┌─────────────────────────┐
│   │    review_history       │
│   ├─────────────────────────┤
└──▶│ id: INTEGER PK          │
    │ word_id: INTEGER FK     │
    │ source_id: INTEGER FK?  │
    │ reviewed_at: DATETIME   │
    │ result: TEXT            │  (remembered/forgot/hard)
    └─────────────────────────┘
```

### SQLite Schema

```sql
-- 采集任务表（异步管线核心）
CREATE TABLE capture_jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    
    -- 输入
    selected_text TEXT NOT NULL,
    normalized_text TEXT NOT NULL,
    
    -- 来源
    source_app TEXT NOT NULL,
    bundle_id TEXT NOT NULL,
    source_url TEXT,
    source_title TEXT,
    source_status TEXT NOT NULL DEFAULT 'partial',  -- resolved/partial/failed
    capture_method TEXT NOT NULL DEFAULT 'service', -- service/clipboard
    
    -- 状态
    status TEXT NOT NULL DEFAULT 'pending',  -- pending/processing/completed/failed
    error_message TEXT,
    error_category TEXT,  -- input/permission/ai/db
    retry_count INTEGER DEFAULT 0,
    
    -- 时间
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    processed_at DATETIME
);

-- 单词主表
CREATE TABLE words (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    lemma TEXT NOT NULL UNIQUE COLLATE NOCASE,  -- 单词原形
    phonetic TEXT,
    definition TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    review_count INTEGER DEFAULT 0,
    next_review_at DATETIME,
    familiarity INTEGER DEFAULT 0  -- 0-5
);

-- 来源表（一词多源）
CREATE TABLE word_sources (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    word_id INTEGER NOT NULL,
    capture_job_id INTEGER,  -- 关联原始任务
    
    -- 词形
    surface_form TEXT NOT NULL,  -- 用户看到的原始形式 (running/ran/runs)
    
    -- 句子
    sentence TEXT NOT NULL,
    sentence_translation TEXT,
    sentence_source TEXT NOT NULL,  -- selected/extracted/reconstructed
    
    -- 来源
    source_app TEXT NOT NULL,
    bundle_id TEXT NOT NULL,
    source_url TEXT,
    source_title TEXT,
    source_status TEXT NOT NULL,
    
    -- AI 处理信息
    ai_model TEXT,
    ai_latency_ms INTEGER,
    needs_review BOOLEAN DEFAULT FALSE,
    
    -- 时间
    captured_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    
    FOREIGN KEY (word_id) REFERENCES words(id) ON DELETE CASCADE,
    FOREIGN KEY (capture_job_id) REFERENCES capture_jobs(id) ON DELETE SET NULL
);

-- 复习历史
CREATE TABLE review_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    word_id INTEGER NOT NULL,
    source_id INTEGER,
    reviewed_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    result TEXT NOT NULL,  -- remembered/forgot/hard
    FOREIGN KEY (word_id) REFERENCES words(id) ON DELETE CASCADE,
    FOREIGN KEY (source_id) REFERENCES word_sources(id) ON DELETE SET NULL
);

-- 索引
CREATE INDEX idx_jobs_status ON capture_jobs(status);
CREATE INDEX idx_jobs_created ON capture_jobs(created_at);
CREATE INDEX idx_words_lemma ON words(lemma);
CREATE INDEX idx_words_next_review ON words(next_review_at);
CREATE INDEX idx_sources_word_id ON word_sources(word_id);
CREATE INDEX idx_sources_needs_review ON word_sources(needs_review);
```

### Swift Models

```swift
import GRDB

// MARK: - Capture Job

struct CaptureJob: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var selectedText: String
    var normalizedText: String
    var sourceApp: String
    var bundleId: String
    var sourceUrl: String?
    var sourceTitle: String?
    var sourceStatus: SourceStatus
    var captureMethod: CaptureMethod
    var status: JobStatus
    var errorMessage: String?
    var errorCategory: ErrorCategory?
    var retryCount: Int
    var createdAt: Date
    var processedAt: Date?
    
    enum JobStatus: String, Codable {
        case pending
        case processing
        case completed
        case failed
    }
    
    enum SourceStatus: String, Codable {
        case resolved  // 全部获取成功
        case partial   // 部分获取成功
        case failed    // 仅有 app 信息
    }
    
    enum CaptureMethod: String, Codable {
        case service
        case clipboard  // 未来
    }
    
    enum ErrorCategory: String, Codable {
        case input      // 用户输入问题
        case permission // 系统权限问题
        case ai         // AI 处理失败
        case db         // 数据库失败
    }
}

// MARK: - Word

struct Word: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var lemma: String
    var phonetic: String?
    var definition: String
    var createdAt: Date
    var updatedAt: Date
    var reviewCount: Int
    var nextReviewAt: Date?
    var familiarity: Int
    
    static let sources = hasMany(WordSource.self)
}

// MARK: - Word Source

struct WordSource: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var wordId: Int64
    var captureJobId: Int64?
    var surfaceForm: String
    var sentence: String
    var sentenceTranslation: String?
    var sentenceSource: SentenceSource
    var sourceApp: String
    var bundleId: String
    var sourceUrl: String?
    var sourceTitle: String?
    var sourceStatus: CaptureJob.SourceStatus
    var aiModel: String?
    var aiLatencyMs: Int?
    var needsReview: Bool
    var capturedAt: Date
    
    enum SentenceSource: String, Codable {
        case selected      // 用户选中的就是完整句子
        case extracted     // 从上下文中提取出来
        case reconstructed // AI 补全/重建
    }
    
    static let word = belongsTo(Word.self)
}
```

---

## AI 设计

### Prompt 设计（v2 - 带真值边界）

```
System Prompt:
你是一个英语学习助手，帮助用户处理采集的英文内容。

用户会发送他们选中的文本（可能是单词、短语、或包含目标词的句子）。
你需要：
1. 识别其中的核心单词
2. 判断句子边界
3. 返回结构化结果

重要规则：
- 如果用户选中的内容已经是完整句子，sentence_source 标记为 "selected"
- 如果需要从上下文提取句子边界，标记为 "extracted"
- 如果上下文不足需要补全，标记为 "reconstructed"，并设置 needs_review = true
- 宁可标记 needs_review 也不要编造看起来真实但实际是生成的内容

User Prompt:
用户选中内容: {selected_text}

请返回 JSON：
{
  "lemma": "单词原形",
  "surface_form": "用户选中内容中的原始词形",
  "phonetic": "美式音标，如无法确定返回 null",
  "definition": "中文释义（根据上下文选择最相关义项）",
  "sentence": "包含该单词的完整句子",
  "sentence_source": "selected|extracted|reconstructed",
  "sentence_translation": "句子中文翻译",
  "needs_review": false,
  "confidence_notes": "可选，如有不确定之处在此说明"
}
```

### Response Schema（带失败路径）

```swift
struct AIResponse: Codable {
    let lemma: String
    let surfaceForm: String
    let phonetic: String?  // 可空
    let definition: String
    let sentence: String
    let sentenceSource: SentenceSource
    let sentenceTranslation: String
    let needsReview: Bool
    let confidenceNotes: String?
    
    enum SentenceSource: String, Codable {
        case selected
        case extracted
        case reconstructed
    }
}

// AI 处理结果（带状态）
enum AIProcessingResult {
    case success(AIResponse)
    case partialSuccess(AIResponse, warnings: [String])
    case failure(AIError)
}

enum AIError: Error {
    case networkError(underlying: Error)
    case rateLimited(retryAfter: TimeInterval?)
    case invalidResponse(raw: String)
    case schemaValidationFailed(field: String, reason: String)
    case contentTooShort
    case unrecognizedLanguage
}
```

### AI 处理流程

```swift
actor AIProcessor {
    private let apiKey: String
    private let model = "gpt-4o-mini"
    
    func process(job: CaptureJob) async -> AIProcessingResult {
        let startTime = Date()
        
        do {
            // 1. 构建请求
            let request = buildRequest(text: job.normalizedText)
            
            // 2. 调用 API
            let data = try await callAPI(request)
            
            // 3. 解析响应
            let decoded = try decodeResponse(data)
            
            // 4. Schema 验证
            let validated = try validateSchema(decoded)
            
            // 5. 记录指标
            let latency = Date().timeIntervalSince(startTime)
            Logger.ai.info("Processed in \(latency)s, needs_review: \(validated.needsReview)")
            
            return .success(validated)
            
        } catch let error as AIError {
            return .failure(error)
        } catch {
            return .failure(.networkError(underlying: error))
        }
    }
    
    private func validateSchema(_ response: AIResponse) throws -> AIResponse {
        // 验证必填字段非空
        guard !response.lemma.isEmpty else {
            throw AIError.schemaValidationFailed(field: "lemma", reason: "empty")
        }
        guard !response.sentence.isEmpty else {
            throw AIError.schemaValidationFailed(field: "sentence", reason: "empty")
        }
        // ... 更多验证
        return response
    }
}
```

### 成本估算

- 每个单词约 200-300 tokens（输入+输出）
- GPT-4o-mini: ~$0.00015/单词
- 每天采集 50 个单词: ~$0.0075/天 ≈ $0.23/月

---

## UI 设计

### 界面结构

```
┌────────────────────────────────────────────────────────────────┐
│  不想背单词                                    ─  □  ×        │
├────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌────────────────────────────────────────┐ │
│  │              │  │                                        │ │
│  │  📚 全部单词  │  │   ephemeral  /ɪˈfem(ə)rəl/            │ │
│  │  ⏳ 处理中(2) │  │                                        │ │
│  │  ⚠️ 待确认(1) │  │   短暂的；转瞬即逝的                   │ │
│  │  📅 今日采集  │  │                                        │ │
│  │  🔄 待复习   │  │   ────────────────────────────────     │ │
│  │              │  │                                        │ │
│  │  ──────────  │  │   📍 来源 1  ·  Safari  ·  03-08       │ │
│  │              │  │   "The ephemeral nature of cherry      │ │
│  │  ❌ 失败(0)  │  │    blossoms has inspired poets..."     │ │
│  │              │  │   樱花转瞬即逝的特性启发了诗人...      │ │
│  │              │  │   🏷️ AI 提取                           │ │
│  │              │  │                                        │ │
│  └──────────────┘  └────────────────────────────────────────┘ │
│                                                                │
│  ┌────────────────────────────────────────────────────────┐   │
│  │ 🔍 搜索单词...                              ⌘K         │   │
│  └────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────┘

新增视图：
- ⏳ 处理中：显示 pending/processing 状态的任务
- ⚠️ 待确认：needs_review = true 的条目
- ❌ 失败：status = failed，可重试
```

### 菜单栏图标

```
┌─────────────────────────┐
│  📖 不想背单词         │
├─────────────────────────┤
│  最近采集                │
│  ─────────────────────  │
│  ✓ ephemeral   刚刚     │
│  ⏳ ubiquitous  处理中   │
│  ─────────────────────  │
│  📊 今日: 12 个          │
│  ⚠️ 待确认: 1 个         │
│  ❌ 失败: 0 个           │
│  ─────────────────────  │
│  打开主窗口...    ⌘O    │
│  ─────────────────────  │
│  设置...          ⌘,    │
│  退出             ⌘Q    │
└─────────────────────────┘
```

---

## 错误处理与可观测性

### 日志分层

```swift
import OSLog

extension Logger {
    static let capture = Logger(subsystem: "com.blackkingbar.buxiangbeidanci", category: "capture")
    static let source = Logger(subsystem: "com.blackkingbar.buxiangbeidanci", category: "source")
    static let ai = Logger(subsystem: "com.blackkingbar.buxiangbeidanci", category: "ai")
    static let db = Logger(subsystem: "com.blackkingbar.buxiangbeidanci", category: "db")
}

// 使用示例
Logger.capture.info("Received text: \(text.prefix(50))...")
Logger.source.warning("Failed to get URL for \(bundleId)")
Logger.ai.error("API failed: \(error)")
```

### 指标追踪

```swift
struct Metrics {
    // 采集
    var captureTotal: Int = 0
    var captureSuccess: Int = 0
    var captureFailed: Int = 0
    
    // 来源检测
    var sourceResolved: Int = 0
    var sourcePartial: Int = 0
    var sourceFailed: Int = 0
    
    // AI 处理
    var aiSuccess: Int = 0
    var aiFailed: Int = 0
    var aiNeedsReview: Int = 0
    var aiAverageLatencyMs: Double = 0
    
    // 计算属性
    var captureSuccessRate: Double {
        guard captureTotal > 0 else { return 0 }
        return Double(captureSuccess) / Double(captureTotal)
    }
    
    var urlSuccessRate: Double {
        let total = sourceResolved + sourcePartial + sourceFailed
        guard total > 0 else { return 0 }
        return Double(sourceResolved) / Double(total)
    }
}
```

### 错误分类

| 类别 | 示例 | 处理 |
|------|------|------|
| **input** | 空文本、纯符号、过长 | 拒绝，提示用户 |
| **permission** | 无辅助功能权限、无自动化权限 | 引导授权 |
| **source** | 浏览器 URL 获取失败 | 降级，继续处理 |
| **ai** | API 超时、限流、响应异常 | 重试，达上限后标记失败 |
| **db** | 写入失败、约束冲突 | 重试，记录日志 |

### 隐私考量

```
需要明确告知用户：
1. 哪些内容会发送到云端（选中文本 → AI API）
2. 本地存储位置（~/Library/Application Support/不想背单词/）
3. 设置选项：
   - [ ] 发送句子上下文到 AI（默认开）
   - [ ] 保留原始选中内容（默认开）
   - [ ] 采集来源 URL（默认开）
```

---

## 技术风险与原型验证

> **v0.4 更新：** 放弃 NSServices 方案，改用全局快捷键 + 弹窗选词。风险点相应调整。

### ✅ 已验证：NSServices（已放弃）

**原方案问题：**
- 注册不稳定，不同 App 支持程度不一
- 用户需要知道去 Services 子菜单找，认知成本高
- 调试困难，需要放到 /Applications 目录

**结论：** 改用全局快捷键方案，风险更低，用户体验更好。

---

### 🟢 P0 核心：全局快捷键 + 选词弹窗

**方案优势：**
- 使用 KeyboardShortcuts 库，稳定可靠
- 用户自定义快捷键，无冲突问题
- 不依赖系统服务机制，100% 可控

**实现要点：**

```swift
import KeyboardShortcuts

// 定义快捷键
extension KeyboardShortcuts.Name {
    static let captureWords = Self("captureWords", default: .init(.d, modifiers: [.command, .shift]))
}

// 监听快捷键
KeyboardShortcuts.onKeyUp(for: .captureWords) {
    // 1. 记录当前活跃 App（快捷键触发前的 App）
    let previousApp = NSWorkspace.shared.frontmostApplication
    
    // 2. 读取剪贴板
    let clipboard = NSPasteboard.general.string(forType: .string)
    
    // 3. 获取来源信息
    let source = SourceDetector.detect(from: previousApp)
    
    // 4. 弹出选词面板
    WordPickerPanel.show(text: clipboard, source: source)
}
```

**关键细节：**
- 快捷键触发后，不想背单词 变成前台 App
- 所以必须**先**记录 previousApp，再弹窗
- 来源 URL 获取也要在弹窗前完成

**验证目标：**
- [x] 快捷键全局触发
- [ ] 剪贴板读取
- [ ] 来源 App 正确识别
- [ ] 弹窗显示

---

### 🟢 P1 核心：选词弹窗 UI

**分词方案：** 使用 Apple 原生 `NLTokenizer`

```swift
import NaturalLanguage

func tokenize(_ text: String) -> [String] {
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    
    var tokens: [String] = []
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
        tokens.append(String(text[range]))
        return true
    }
    return tokens
}

// "The ephemeral nature" → ["The", "ephemeral", "nature"]
```

**弹窗交互：**
- 词以 Token 形式展示，可点击切换选中
- 选中的词高亮显示
- 支持多选
- Enter 确认，Esc 取消

**验证目标：**
- [ ] 分词准确
- [ ] 点击选词交互顺畅
- [ ] 多选正常工作
- [ ] 键盘快捷键（Enter/Esc）

---

### 🟡 P2 风险：AppleScript 获取浏览器 URL

**问题描述：**
AppleScript 是整个技术栈中最脆弱的环节。浏览器任何一次大版本更新都可能导致脚本失效。

**解决方案：**

```swift
// 沙盒应用需要添加 entitlements
// 不想背单词.entitlements:
// com.apple.security.scripting-targets:
//   com.apple.Safari: [com.apple.Safari.window]
//   com.google.Chrome: [com.google.Chrome.window]

func getBrowserURL(bundleId: String) -> (url: String?, title: String?, error: BrowserError?) {
    let script: String
    
    switch bundleId {
    case "com.apple.Safari":
        script = """
        tell application "Safari"
            if (count of windows) > 0 then
                set currentTab to current tab of front window
                return {URL of currentTab, name of currentTab}
            end if
        end tell
        """
    case "com.google.Chrome":
        script = """
        tell application "Google Chrome"
            if (count of windows) > 0 then
                set activeTab to active tab of front window
                return {URL of activeTab, title of activeTab}
            end if
        end tell
        """
    default:
        return (nil, nil, .unsupportedBrowser)
    }
    
    guard let appleScript = NSAppleScript(source: script) else {
        return (nil, nil, .scriptCreationFailed)
    }
    
    var errorDict: NSDictionary?
    let result = appleScript.executeAndReturnError(&errorDict)
    
    if let error = errorDict {
        Logger.source.error("AppleScript failed: \(error)")
        return (nil, nil, .executionFailed(error))
    }
    
    // 解析返回的列表
    guard result.numberOfItems == 2 else {
        return (nil, nil, .unexpectedResult)
    }
    
    let url = result.atIndex(1)?.stringValue
    let title = result.atIndex(2)?.stringValue
    
    return (url, title, nil)
}

enum BrowserError: Error {
    case unsupportedBrowser
    case scriptCreationFailed
    case executionFailed(NSDictionary)
    case unexpectedResult
    case permissionDenied
}
```

**降级策略：**
- AppleScript 失败时，`source_url` 记为 `nil`
- `source_status` 标记为 `partial`
- UI 正常显示，只是没有 URL 链接
- 不阻塞采集流程

**支持的浏览器：**
| 浏览器 | 支持度 | 备注 |
|--------|--------|------|
| Safari | ✅ 完整 | 原生支持 |
| Chrome | ✅ 完整 | 需要授权 |
| Arc | ⚠️ 部分 | 基于 Chrome，可能需要调整 |
| Firefox | ❌ 不支持 | AppleScript 支持有限 |
| Edge | ⚠️ 未测试 | 基于 Chrome，理论可行 |

**原型验证目标：**
- [ ] Safari URL 获取成功率 >95%
- [ ] Chrome URL 获取成功率 >95%
- [ ] 权限拒绝时优雅降级

---

### 🟡 P1 风险：Accessibility API 上下文抓取

**问题描述：**
要获取选中文本周围的上下文，需要使用 Accessibility API。这需要用户授权，且不同 App 的实现质量参差不齐。

**解决方案：**

```swift
import ApplicationServices

class ContextProvider {
    
    /// 检查辅助功能权限
    static func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    
    /// 获取当前选中文本的上下文
    static func getContext(around selectedText: String) -> String? {
        guard checkAccessibilityPermission() else {
            Logger.source.warning("Accessibility permission not granted")
            return nil
        }
        
        // 获取当前焦点应用
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let pid = frontApp.processIdentifier as pid_t? else {
            return nil
        }
        
        let appElement = AXUIElementCreateApplication(pid)
        
        // 获取焦点元素
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return nil
        }
        
        // 尝试获取文本内容
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXValueAttribute as CFString, &value) == .success,
              let fullText = value as? String else {
            return nil
        }
        
        // 找到选中文本在全文中的位置，提取上下文
        guard let range = fullText.range(of: selectedText) else {
            return nil
        }
        
        // 提取前后各 100 个字符
        let contextStart = fullText.index(range.lowerBound, offsetBy: -100, limitedBy: fullText.startIndex) ?? fullText.startIndex
        let contextEnd = fullText.index(range.upperBound, offsetBy: 100, limitedBy: fullText.endIndex) ?? fullText.endIndex
        
        return String(fullText[contextStart..<contextEnd])
    }
}
```

**权限引导流程：**
1. 首次启动检测权限
2. 未授权时显示友好提示
3. 提供「打开系统设置」按钮
4. 授权后自动启用上下文功能

**降级策略：**
- MVP 阶段：不强依赖 AX API，用户负责选择完整句子
- Phase 2：AX API 作为增强功能，失败时回退到用户选择

**原型验证目标：**
- [ ] 权限引导流程顺畅
- [ ] Safari 中能获取上下文
- [ ] VS Code 等常用 App 的兼容性

---

### 🟢 P2 优化：数据层最佳实践

**DatabasePool + WAL 模式：**

```swift
import GRDB

class Database {
    static let shared = Database()
    
    private var dbPool: DatabasePool!
    
    func setup() throws {
        let databaseURL = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("不想背单词")
            .appendingPathComponent("buxiangbeidanci.sqlite")
        
        // 创建目录
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        
        // 使用 DatabasePool（自动启用 WAL 模式）
        dbPool = try DatabasePool(path: databaseURL.path)
        
        // 运行迁移
        try migrator.migrate(dbPool)
    }
    
    var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        
        // v1: 初始 schema
        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "capture_jobs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("selected_text", .text).notNull()
                t.column("normalized_text", .text).notNull()
                t.column("source_app", .text).notNull()
                t.column("bundle_id", .text).notNull()
                t.column("source_url", .text)
                t.column("source_title", .text)
                t.column("source_status", .text).notNull().defaults(to: "partial")
                t.column("capture_method", .text).notNull().defaults(to: "service")
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("error_message", .text)
                t.column("error_category", .text)
                t.column("retry_count", .integer).defaults(to: 0)
                t.column("created_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
                t.column("processed_at", .datetime)
            }
            
            try db.create(table: "words") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("lemma", .text).notNull().unique(onConflict: .ignore).collate(.nocase)
                t.column("phonetic", .text)
                t.column("definition", .text).notNull()
                t.column("created_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
                t.column("updated_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
                t.column("review_count", .integer).defaults(to: 0)
                t.column("next_review_at", .datetime)
                t.column("familiarity", .integer).defaults(to: 0)
            }
            
            try db.create(table: "word_sources") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("word_id", .integer).notNull().references("words", onDelete: .cascade)
                t.column("capture_job_id", .integer).references("capture_jobs", onDelete: .setNull)
                t.column("surface_form", .text).notNull()
                t.column("sentence", .text).notNull()
                t.column("sentence_translation", .text)
                t.column("sentence_source", .text).notNull()
                t.column("source_app", .text).notNull()
                t.column("bundle_id", .text).notNull()
                t.column("source_url", .text)
                t.column("source_title", .text)
                t.column("source_status", .text).notNull()
                t.column("ai_model", .text)
                t.column("ai_latency_ms", .integer)
                t.column("needs_review", .boolean).defaults(to: false)
                t.column("captured_at", .datetime).defaults(sql: "CURRENT_TIMESTAMP")
            }
            
            // 索引
            try db.create(index: "idx_jobs_status", on: "capture_jobs", columns: ["status"])
            try db.create(index: "idx_sources_word_id", on: "word_sources", columns: ["word_id"])
            try db.create(index: "idx_sources_needs_review", on: "word_sources", columns: ["needs_review"])
        }
        
        // 未来的迁移在这里添加
        // migrator.registerMigration("v2_xxx") { db in ... }
        
        return migrator
    }
}
```

**Model Sendable 遵循：**

```swift
// 所有模型都遵循 Sendable，确保并发安全
struct CaptureJob: Codable, FetchableRecord, PersistableRecord, Sendable {
    // ...
}

struct Word: Codable, FetchableRecord, PersistableRecord, Sendable {
    // ...
}

struct WordSource: Codable, FetchableRecord, PersistableRecord, Sendable {
    // ...
}
```

---

### 🟢 P2 优化：快捷键库选择

推荐使用 **sindresorhus/KeyboardShortcuts** 而非直接用 HotKey 或 Carbon API：

```swift
import KeyboardShortcuts

// 定义快捷键名称
extension KeyboardShortcuts.Name {
    static let captureWord = Self("captureWord")
}

// 在设置中提供自定义 UI
struct SettingsView: View {
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Capture shortcut:", name: .captureWord)
        }
    }
}

// 监听快捷键
KeyboardShortcuts.onKeyUp(for: .captureWord) {
    CaptureCoordinator.shared.captureFromClipboard()
}
```

**优势：**
- SwiftUI 原生支持
- 用户可自定义快捷键
- 沙盒兼容，App Store 友好
- 自动处理快捷键冲突

---

### 原型验证计划

用 **2 天** 验证核心功能：

| 天 | 验证目标 | 成功标准 |
|----|----------|----------|
| D1 | 全局快捷键 Cmd+Shift+D | 任意 App 中触发，弹出选词面板 |
| D1 | 剪贴板读取 + 分词 | 正确读取并拆分为可点击的词 |
| D1 | 来源检测 | 正确识别触发前的 App |
| D2 | 选词交互 | 点击选词、多选、Enter 确认 |
| D2 | 浏览器 URL | Safari/Chrome URL 获取 |
| D2 | 落库验证 | 选中的词正确存入数据库 |

**已完成：**
- [x] 项目骨架（Xcode + GRDB + KeyboardShortcuts）
- [x] 数据库迁移
- [x] 基础 UI 框架

---

### 参考资料

1. [KeyboardShortcuts by sindresorhus](https://github.com/sindresorhus/KeyboardShortcuts)
2. [NLTokenizer - Apple Developer](https://developer.apple.com/documentation/naturallanguage/nltokenizer)
3. [GRDB Documentation: Database Pools](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/databasepool)

---

## 开发计划

### Phase 0: 原型验证（Day 1-2）✅ 开发验收已完成

**目标：** 验证快捷键 + 选词弹窗核心流程

| 天 | 验证目标 | 状态 |
|----|----------|------|
| D1 | 全局快捷键 Cmd+Shift+D 触发 | ✅ 已实现 |
| D1 | 剪贴板读取 + NLTokenizer 分词 | ✅ 已实现 |
| D1 | 来源 App 检测 | ✅ 已实现 |
| D2 | 选词弹窗 UI + 交互 | ✅ 已实现 |
| D2 | 浏览器 URL 获取 | ⏸ 延后（当前不做） |
| D2 | 落库验证 | ✅ 已实现 |

**已完成：**
- [x] 项目骨架（Xcode + GRDB + KeyboardShortcuts）
- [x] 数据库迁移
- [x] 基础 UI 框架
- [x] NSServices 验证（已放弃该方案）

---

### Phase 1: 核心采集（Week 1）✅ 开发验收已完成

**目标：** 跑通 快捷键 → 选词 → 落库 → 展示

| 天 | 任务 | 交付物 |
|----|------|--------|
| D1-2 | 全局快捷键 + 选词弹窗 UI | Cmd+Shift+D 弹出选词面板 |
| D3-4 | 分词 + 选词交互 | 点击选词、多选、确认 |
| D5-6 | 来源检测（App） | 来源 App 正确记录 |
| D7 | 落库 + 列表展示 | 选中的词出现在主界面 |

**验收标准：**
- [x] 任意 App 中 Cmd+Shift+D 弹出选词面板
- [x] 复制的句子正确分词显示
- [x] 点击选词，Enter 确认
- [x] 选中的词存入数据库并显示在列表

### Phase 2: AI 链路（Week 3）🚧 进行中

**目标：** 异步 AI 处理 + 状态流转

**当前进展（2026-03-13）：**
- [x] AIProcessor 接入 OpenAI Chat Completions
- [x] 响应解析 + Schema 校验 + 错误分类
- [x] 处理结果落地到 words / word_sources
- [x] 设置页持久化 API Key 与模型
- [x] needs_review 在侧栏与列表中可见

| 天 | 任务 | 交付物 |
|----|------|--------|
| D1-2 | AIProcessor Actor：API 调用、响应解析 | 能调通 OpenAI |
| D3-4 | Schema 验证、错误分类、重试逻辑 | 异常可恢复 |
| D5-6 | 状态流转：pending → processing → completed/failed | 完整管线 |
| D7 | 详情页 UI、needs_review 标记展示 | 能查看处理结果 |

**验收标准：**
- [ ] AI 处理成功率 >95%
- [ ] 失败任务可手动重试
- [ ] needs_review 条目有明显标记

### Phase 3: 体验完善（Week 4）

| 天 | 任务 |
|----|------|
| D1-2 | 菜单栏图标 + 状态展示 |
| D3-4 | 通知系统（采集成功/失败） |
| D5-6 | 设置页面（API Key、隐私选项） |
| D7 | Bug 修复、性能优化 |

### 未来 Phases

- **Phase 4:** 复习功能（间隔重复算法）
- **Phase 5:** 全局快捷键（考虑清楚语义再做）
- **Phase 6:** 导入/导出、Anki 兼容
- **Phase 7:** iCloud 同步（如有需求）

---

## 未来扩展

### 可能方向

1. **iOS 配套 App** — iCloud 同步后在手机上复习
2. **浏览器扩展** — 更丰富的网页采集体验
3. **本地 LLM** — 支持 Ollama，完全离线
4. **多语言** — 日语、法语等
5. **整句模式** — 用户选整句，在 App 内点击单词

### 明确不做

- 不做词典 App — 专注采集和复习
- 不做社交功能 — 个人工具
- 不做游戏化 — 简洁实用优先

---

## 附录

### A. 输入标准化规则

```swift
struct CaptureInputNormalizer {
    static let maxLength = 500
    static let minLength = 1
    
    enum ValidationError: Error {
        case empty
        case tooLong
        case onlySymbols
        case onlyWhitespace
    }
    
    static func normalize(_ input: String) throws -> String {
        // 1. Trim whitespace
        var result = input.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 2. Check empty
        guard !result.isEmpty else {
            throw ValidationError.empty
        }
        
        // 3. Check length
        guard result.count <= maxLength else {
            throw ValidationError.tooLong
        }
        
        // 4. Normalize quotes
        result = result
            .replacingOccurrences(of: """, with: "\"")
            .replacingOccurrences(of: """, with: "\"")
            .replacingOccurrences(of: "'", with: "'")
            .replacingOccurrences(of: "'", with: "'")
        
        // 5. Collapse multiple spaces
        result = result.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        
        // 6. Check not only symbols
        let letters = result.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else {
            throw ValidationError.onlySymbols
        }
        
        return result
    }
}
```

### B. AppleScript for Browser URL

```swift
func getSafariURL() -> String? {
    let script = """
    tell application "Safari"
        if (count of windows) > 0 then
            return URL of current tab of front window
        end if
    end tell
    """
    return runAppleScript(script)
}

func getChromeURL() -> String? {
    let script = """
    tell application "Google Chrome"
        if (count of windows) > 0 then
            return URL of active tab of front window
        end if
    end tell
    """
    return runAppleScript(script)
}

func runAppleScript(_ source: String) -> String? {
    var error: NSDictionary?
    guard let script = NSAppleScript(source: source) else { return nil }
    let result = script.executeAndReturnError(&error)
    if error != nil { return nil }
    return result.stringValue
}
```

---

*文档版本: v0.3*  
*最后更新: 2026-03-08*  
*作者: Fiona 🦊*  
*Review by: 技术评审 (Manus AI)*
