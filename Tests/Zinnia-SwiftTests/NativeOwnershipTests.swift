import Foundation
import XCTest
@testable import Zinnia_Swift

final class NativeOwnershipTests: XCTestCase {
    // Repetition makes native leaks visible when this suite runs under a leak checker.
    // The tiny model exercises ownership without depending on the Git LFS fixture.
    func testRepeatedRecognitionReturnsOwnedSwiftValues() throws {
        try withModel { modelURL in
            let expected = [
                Recognizer.Result(character: "一", score: 2),
                Recognizer.Result(character: "中", score: 1)
            ]
            let results: [Recognizer.Result] = try {
                let recognizer = try Recognizer(
                    modelURL: modelURL,
                    canvasSize: Recognizer.Size(width: 500, height: 500)
                )
                let strokes = [Stroke(points: [Point(x: 50, y: 250), Point(x: 450, y: 250)])]
                for _ in 0..<1_000 {
                    XCTAssertEqual(recognizer.classify(strokes: strokes), expected)
                }
                return recognizer.classify()
            }()

            // Strings must remain valid after both the native result and recognizer die.
            XCTAssertEqual(results, expected)
        }
    }

    func testNoNativeResultIsSafe() throws {
        try withModel { modelURL in
            let recognizer = try Recognizer(
                modelURL: modelURL,
                canvasSize: Recognizer.Size(width: 500, height: 500)
            )
            XCTAssertEqual(recognizer.classify(), [])
            recognizer.add(stroke: Stroke(points: [Point(x: 50, y: 250), Point(x: 450, y: 250)]))
            XCTAssertEqual(recognizer.classify(maxResults: 0), [])
        }
    }

    func testRepeatedModelFailuresPreserveErrorAfterNativeCleanup() throws {
        // A valid model plus a trailing byte reaches the C parser's final failure path,
        // which leaves its mapping open until the recognizer is destroyed.
        try withModel(trailingByte: true) { modelURL in
            let missingURL = modelURL.appendingPathExtension("missing")
            for _ in 0..<1_000 {
                for url in [modelURL, missingURL] {
                    XCTAssertThrowsError(try Recognizer(modelURL: url)) { error in
                        guard case Recognizer.RecognizerErrors.openingModelFailed(let failedURL, let message) = error else {
                            return XCTFail("Unexpected error: \(error)")
                        }
                        XCTAssertEqual(failedURL, url)
                        XCTAssertFalse(message?.isEmpty ?? true)
                        if url == modelURL {
                            XCTAssertTrue(message?.contains("size of model file is invalid") == true)
                        }
                    }
                }
            }
        }
    }

    private func withModel<T>(trailingByte: Bool = false, _ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZinniaOwnership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Zinnia's binary format: magic, version, count, then 16-byte UTF-8 label,
        // bias, and a sentinel feature node for each candidate. Bias-only candidates
        // give deterministic scores for every nonempty character.
        var payload = Data()
        append(1, to: &payload)
        append(2, to: &payload)
        for (label, score) in [("一", Float(2)), ("中", Float(1))] {
            let utf8 = Array(label.utf8)
            payload.append(contentsOf: utf8)
            payload.append(contentsOf: repeatElement(UInt8(0), count: 16 - utf8.count))
            append(score.bitPattern, to: &payload)
            append(UInt32.max, to: &payload)
            append(0, to: &payload)
        }
        if trailingByte { payload.append(0) }
        var model = Data()
        append(UInt32(payload.count + 4) ^ 0x0ef71821, to: &model)
        model.append(payload)

        let modelURL = directory.appendingPathComponent("ownership.model")
        try model.write(to: modelURL)
        return try body(modelURL)
    }

    private func append(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
