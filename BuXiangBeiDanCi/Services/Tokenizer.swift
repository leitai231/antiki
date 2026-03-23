import Foundation
import NaturalLanguage

/// Represents a token (word or punctuation) in a sentence
struct Token: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let range: Range<String.Index>
    let isWord: Bool
    
    /// Whether this token is currently selected by the user
    var isSelected: Bool = false
}

/// Tokenizes sentences into clickable words using Apple's NLTokenizer
class Tokenizer {
    
    /// Tokenize a sentence into words and punctuation
    static func tokenize(_ text: String) -> [Token] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        
        var tokens: [Token] = []
        var lastEnd = text.startIndex
        
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            // Add any non-word content before this token (spaces, punctuation)
            if lastEnd < range.lowerBound {
                let prefix = String(text[lastEnd..<range.lowerBound])
                // Split by characters to handle each punctuation separately
                for char in prefix {
                    let charStr = String(char)
                    if !charStr.trimmingCharacters(in: .whitespaces).isEmpty {
                        // It's punctuation
                        tokens.append(Token(
                            text: charStr,
                            range: lastEnd..<text.index(lastEnd, offsetBy: 1),
                            isWord: false
                        ))
                    }
                }
            }
            
            // Add the word token
            let word = String(text[range])
            tokens.append(Token(
                text: word,
                range: range,
                isWord: isActualWord(word)
            ))
            
            lastEnd = range.upperBound
            return true
        }
        
        // Add any trailing punctuation
        if lastEnd < text.endIndex {
            let suffix = String(text[lastEnd..<text.endIndex])
            for char in suffix {
                let charStr = String(char)
                if !charStr.trimmingCharacters(in: .whitespaces).isEmpty {
                    tokens.append(Token(
                        text: charStr,
                        range: lastEnd..<text.index(lastEnd, offsetBy: 1),
                        isWord: false
                    ))
                }
            }
        }
        
        return tokens
    }
    
    /// Check if a string is an actual word (contains letters)
    private static func isActualWord(_ text: String) -> Bool {
        // Must contain at least one letter
        let hasLetter = text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        
        // Should not be just numbers
        let isJustNumbers = text.allSatisfy { $0.isNumber }
        
        return hasLetter && !isJustNumbers
    }
    
    /// Get the lemma (base form) of a word
    static func lemmatize(_ word: String) -> String {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = word
        
        let range = word.startIndex..<word.endIndex
        if let tag = tagger.tag(at: word.startIndex, unit: .word, scheme: .lemma).0 {
            return tag.rawValue
        }
        
        // Fallback to lowercase
        return word.lowercased()
    }
}
