import XCTest
@testable import GodstoneCore

final class OracleAnswerValidatorTests: XCTestCase {
    func testExactQuantityWithCitationIsAccepted() {
        let result = OracleAnswerValidator.validate(
            answer: "Rinse the container with 500 ml of clean water [1].",
            chunks: [chunk("Rinse the container with 500 ml of clean water.")],
            retrievalAllowed: true)
        XCTAssertTrue(result.isValid, result.unsupported.joined(separator: "; "))
    }

    func testWrongUnitIsRejectedEvenWhenNumberMatches() {
        let result = OracleAnswerValidator.validate(
            answer: "Rinse the container with 500 mg of clean water [1].",
            chunks: [chunk("Rinse the container with 500 ml of clean water.")],
            retrievalAllowed: true)
        XCTAssertFalse(result.isValid)
    }

    func testDenominatorOmissionIsRejected() {
        let result = OracleAnswerValidator.validate(
            answer: "Give 5 ml of the solution [1].",
            chunks: [chunk("Give 5 ml per kg of the solution.")],
            retrievalAllowed: true)
        XCTAssertFalse(result.isValid)
    }

    func testWarningOmissionIsRejected() {
        let result = OracleAnswerValidator.validate(
            answer: "Use the medicine as directed [1].",
            chunks: [chunk("Use the medicine as directed. Do not use for children under 2.")],
            retrievalAllowed: true)
        XCTAssertFalse(result.isValid)
    }

    /// (c) 10 minutes cannot approve 10 hours: value matches, time dimension
    /// matches, but the unit differs (min vs h) -> rejected. Context terms are
    /// deliberately shared so the unit mismatch is the sole rejection reason.
    func testWrongTimeUnitIsRejectedEvenWhenNumberMatches() {
        let result = OracleAnswerValidator.validate(
            answer: "Allow the solution to rest for 10 minutes [1].",
            chunks: [chunk("Allow the solution to rest for 10 hours.")],
            retrievalAllowed: true)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.unsupported.contains { $0.contains("unsupported quantity") },
                      "expected an unsupported-quantity finding, got: \(result.unsupported)")
    }

    /// (e) An answer with no citation markers at all is rejected in full,
    /// regardless of whether the content otherwise matches a chunk.
    func testUncitedAnswerIsRejectedInFull() {
        let result = OracleAnswerValidator.validate(
            answer: "Give 500 ml of water.",
            chunks: [chunk("Give 500 ml of water.")],
            retrievalAllowed: true)
        XCTAssertFalse(result.isValid)
    }

    /// Invalid output is discarded in full: when a single cited answer carries
    /// two quantities and only one is unsupported, the entire answer is rejected
    /// (the validator never returns a partially-sanitised answer).
    func testInvalidOutputIsDiscardedInFull() {
        let result = OracleAnswerValidator.validate(
            answer: "Rinse with 500 ml of water [1], then wait 10 minutes [1].",
            chunks: [chunk("Rinse with 500 ml of water. Wait 10 hours.")],
            retrievalAllowed: true)
        XCTAssertFalse(result.isValid, "an unsupported quantity must reject the whole answer")
    }

    private func chunk(_ text: String) -> RetrievedChunk {
        RetrievedChunk(chunkId: 1, documentId: 1, documentTitle: "Reviewed source",
            section: "Procedure", domain: "medical", text: text, score: 1)
    }
}
