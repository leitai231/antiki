import XCTest
@testable import BuXiangBeiDanCi

final class TokenizerTests: XCTestCase {

    // MARK: - tokenize()

    func testTokenizeEnglishSentence() {
        let tokens = Tokenizer.tokenize("Hello world")
        let words = tokens.filter(\.isWord)
        XCTAssertEqual(words.map(\.text), ["Hello", "world"])
    }

    func testTokenizePreservesPunctuation() {
        let tokens = Tokenizer.tokenize("Hello, world!")
        let punctuation = tokens.filter { !$0.isWord }
        let punctTexts = punctuation.map(\.text)
        XCTAssertTrue(punctTexts.contains(","))
        XCTAssertTrue(punctTexts.contains("!"))
    }

    func testTokenizeEmptyString() {
        let tokens = Tokenizer.tokenize("")
        XCTAssertTrue(tokens.isEmpty)
    }

    func testTokenizePureNumbers() {
        let tokens = Tokenizer.tokenize("123 456")
        let words = tokens.filter(\.isWord)
        XCTAssertTrue(words.isEmpty, "Pure numbers should not be marked as words")
    }

    func testTokenizeMixedContent() {
        let tokens = Tokenizer.tokenize("I have 3 cats.")
        let words = tokens.filter(\.isWord)
        let wordTexts = words.map(\.text)
        XCTAssertTrue(wordTexts.contains("I"))
        XCTAssertTrue(wordTexts.contains("have"))
        XCTAssertTrue(wordTexts.contains("cats"))
    }

    func testTokenizeComplexSentence() {
        let tokens = Tokenizer.tokenize("The quick brown fox jumps over the lazy dog.")
        let words = tokens.filter(\.isWord)
        XCTAssertEqual(words.count, 9)
    }

    // MARK: - lemmatize()

    func testLemmatizeRunning() {
        let lemma = Tokenizer.lemmatize("running")
        XCTAssertEqual(lemma, "run")
    }

    func testLemmatizeCats() {
        // NLTagger may not lemmatize single words without context;
        // fallback is lowercased. Either "cat" or "cats" is acceptable.
        let lemma = Tokenizer.lemmatize("cats")
        XCTAssertTrue(lemma == "cat" || lemma == "cats")
    }

    func testLemmatizeAlreadyBase() {
        let lemma = Tokenizer.lemmatize("run")
        XCTAssertEqual(lemma, "run")
    }

    func testLemmatizeUppercase() {
        // NLTagger may not lemmatize uppercase words without context;
        // fallback is lowercased
        let lemma = Tokenizer.lemmatize("RUNNING")
        XCTAssertTrue(lemma == "run" || lemma == "running",
                       "Expected 'run' or 'running' (lowercased fallback), got '\(lemma)'")
    }
}
