import SwiftUI

/// The word picker panel that appears when hotkey is triggered
struct WordPickerPanel: View {
    @ObservedObject var hotkeyHandler: HotkeyHandler
    @State private var tokens: [Token] = []
    @State private var selectedWords: Set<String> = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "text.badge.plus")
                    .foregroundStyle(.blue)
                Text("选择生词")
                    .font(.headline)
                Spacer()
                Button(action: { hotkeyHandler.cancelCapture() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            
            // Instructions
            Text("点击单词选择，可多选。按 Enter 确认。")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            // Sentence with clickable words
            ScrollView {
                FlowLayout(spacing: 4) {
                    ForEach(tokens) { token in
                        TokenView(
                            token: token,
                            isSelected: selectedWords.contains(token.text),
                            onTap: { toggleWord(token) }
                        )
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 350)
            
            Divider()
            
            // Selected words
            if !selectedWords.isEmpty {
                HStack {
                    Text("已选:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(selectedWords.sorted().joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Spacer()
                    Button("清除") {
                        selectedWords.removeAll()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }
            
            // Source info
            if let source = hotkeyHandler.currentSource {
                HStack {
                    Image(systemName: sourceAppIcon(source.app))
                    Text(source.app)
                        .font(.caption)
                    if let url = source.url, let host = URL(string: url)?.host {
                        Image(systemName: "link")
                        Text(host)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }
            
            Divider()
            
            // Action buttons
            HStack {
                Spacer()
                
                Button("取消") {
                    hotkeyHandler.cancelCapture()
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Button("添加 \(selectedWords.count) 个词") {
                    confirmSelection()
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(selectedWords.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 500)
        .onAppear {
            loadTokens()
        }
    }
    
    private func loadTokens() {
        guard let text = hotkeyHandler.capturedText else { return }
        tokens = Tokenizer.tokenize(text)
    }
    
    private func toggleWord(_ token: Token) {
        guard token.isWord else { return }
        
        if selectedWords.contains(token.text) {
            selectedWords.remove(token.text)
        } else {
            selectedWords.insert(token.text)
        }
    }
    
    private func sourceAppIcon(_ appName: String) -> String {
        let name = appName.lowercased()
        if name.contains("chrome") || name.contains("safari") || name.contains("firefox")
            || name.contains("edge") || name.contains("arc") || name.contains("brave") {
            return "globe"
        }
        switch name {
        case "finder": return "folder"
        case "不想背单词": return "character.book.closed"
        default: return "macwindow"
        }
    }

    private func confirmSelection() {
        guard let text = hotkeyHandler.capturedText,
              let source = hotkeyHandler.currentSource else { return }
        
        Task {
            await hotkeyHandler.confirmCapture(
                words: Array(selectedWords),
                sentence: text,
                source: source
            )
        }
    }
}

// MARK: - Token View

struct TokenView: View {
    let token: Token
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Text(token.text)
            .font(.body)
            .padding(.horizontal, token.isWord ? 8 : 2)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
            )
            .onTapGesture {
                if token.isWord {
                    onTap()
                }
            }
            .cursor(token.isWord ? .pointingHand : .arrow)
    }
    
    private var backgroundColor: Color {
        if isSelected {
            return Color.blue.opacity(0.2)
        } else if token.isWord {
            return Color.secondary.opacity(0.1)
        } else {
            return Color.clear
        }
    }
}

// MARK: - Cursor Extension

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Flow Layout

/// A layout that wraps content like text
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(
            in: proposal.width ?? 0,
            spacing: spacing,
            subviews: subviews
        )
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(
            in: bounds.width,
            spacing: spacing,
            subviews: subviews
        )
        
        for (index, subview) in subviews.enumerated() {
            let point = result.positions[index]
            subview.place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified
            )
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        
        init(in maxWidth: CGFloat, spacing: CGFloat, subviews: Subviews) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var lineHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                if x + size.width > maxWidth && x > 0 {
                    // Move to next line
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }
                
                positions.append(CGPoint(x: x, y: y))
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
                
                self.size.width = max(self.size.width, x)
            }
            
            self.size.height = y + lineHeight
        }
    }
}

#Preview {
    WordPickerPanel(hotkeyHandler: HotkeyHandler.shared)
}
