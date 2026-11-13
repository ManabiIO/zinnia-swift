import Foundation
import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
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

    func testResultLimitsDoNotWrapToUnsignedCounts() throws {
        try withModel { modelURL in
            let recognizer = try Recognizer(
                modelURL: modelURL,
                canvasSize: Recognizer.Size(width: 500, height: 500)
            )
            recognizer.add(stroke: Stroke(points: [Point(x: 50, y: 250), Point(x: 450, y: 250)]))
            for limit in [Int.min, -1, 0] {
                XCTAssertEqual(recognizer.classify(maxResults: limit), [])
            }
            XCTAssertEqual(recognizer.classify(maxResults: 1).map { $0.character }, ["一"])
            XCTAssertEqual(recognizer.classify(maxResults: Int.max).map { $0.character }, ["一", "中"])
        }
    }

    func testInvalidCanvasSizesFailUntilValidSizeIsRestored() throws {
        try withModel { modelURL in
            let recognizer = try Recognizer(modelURL: modelURL)
            recognizer.add(stroke: Stroke(points: [Point(x: 50, y: 250), Point(x: 450, y: 250)]))
            let validSize = Recognizer.Size(width: 500, height: 500)
            let invalidSizes = [
                Recognizer.Size.zero,
                Recognizer.Size(width: -1, height: 500),
                Recognizer.Size(width: 500, height: -1),
                Recognizer.Size(width: Int.max, height: 500),
                Recognizer.Size(width: 500, height: Int.max)
            ]
            for size in invalidSizes {
                recognizer.canvasSize = size
                XCTAssertEqual(recognizer.classify(), [])
                recognizer.canvasSize = validSize
                XCTAssertEqual(recognizer.classify().map { $0.character }, ["一", "中"])
            }
        }
    }

    func testInvalidCoordinatesInvalidateTheWholeCharacterUntilClear() throws {
        try withModel { modelURL in
            let recognizer = try Recognizer(
                modelURL: modelURL,
                canvasSize: Recognizer.Size(width: 500, height: 500)
            )
            let validStroke = Stroke(points: [Point(x: 50, y: 250), Point(x: 450, y: 250)])
            let expected = recognizer.classify(strokes: [validStroke])
            XCTAssertFalse(expected.isEmpty)
            let invalidPoints = [
                Point(x: Int.max, y: 1), Point(x: Int.min, y: 1),
                Point(x: 1, y: Int.max), Point(x: 1, y: Int.min)
            ]
            for point in invalidPoints {
                recognizer.clear()
                recognizer.add(stroke: validStroke)
                recognizer.add(stroke: Stroke(points: [Point(x: 1, y: 1), point]))
                XCTAssertEqual(recognizer.classify(), [])
                recognizer.add(stroke: validStroke)
                XCTAssertEqual(recognizer.classify(), [])
                recognizer.clear()
                recognizer.add(stroke: validStroke)
                XCTAssertEqual(recognizer.classify(), expected)
            }
            let boundaryStroke = Stroke(points: [
                Point(x: Int(Int32.min), y: Int(Int32.min)),
                Point(x: Int(Int32.max), y: Int(Int32.max))
            ])
            XCTAssertEqual(recognizer.classify(strokes: [boundaryStroke]), expected)
        }
    }

    func testCoreGraphicsConversionsRejectNonfiniteAndUnrepresentableValues() throws {
        let finitePoint = Point(cgPoint: CGPoint(x: 10.9, y: -10.9))
        XCTAssertEqual(finitePoint.x, 10)
        XCTAssertEqual(finitePoint.y, -10)
        let finiteSize = Recognizer.Size(cgSize: CGSize(width: 500.9, height: 500.9))
        XCTAssertEqual(finiteSize, Recognizer.Size(width: 500, height: 500))

        try withModel { modelURL in
            let recognizer = try Recognizer(modelURL: modelURL, canvasSize: finiteSize)
            let invalidValues: [CGFloat] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude]
            for value in invalidValues {
                for point in [CGPoint(x: value, y: 1), CGPoint(x: 1, y: value)] {
                    XCTAssertEqual(recognizer.classify(strokes: [Stroke(start: Point(cgPoint: point))]), [])
                }
                for size in [CGSize(width: value, height: 500), CGSize(width: 500, height: value)] {
                    recognizer.canvasSize = Recognizer.Size(cgSize: size)
                    XCTAssertEqual(recognizer.classify(strokes: [Stroke(start: Point(x: 1, y: 1))]), [])
                }
                recognizer.canvasSize = finiteSize
            }
        }
    }

    func testNonFileModelURLsFailWithoutEnteringTheNativeLoader() throws {
        let modelURL = try XCTUnwrap(URL(string: "https://example.invalid/handwriting.model"))
        XCTAssertThrowsError(try Recognizer(modelURL: modelURL)) { error in
            guard case Recognizer.RecognizerErrors.openingModelFailed(let failedURL, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(failedURL, modelURL)
        }
    }

    func testEmptyStrokesDoNotPoisonFollowingRecognition() throws {
        try withModel { modelURL in
            let recognizer = try Recognizer(
                modelURL: modelURL,
                canvasSize: Recognizer.Size(width: 500, height: 500)
            )
            let stroke = Stroke(points: [Point(x: 50, y: 250), Point(x: 450, y: 250)])
            let expected = recognizer.classify(strokes: [stroke, stroke])
            XCTAssertFalse(expected.isEmpty)
            XCTAssertEqual(recognizer.classify(strokes: [Stroke(), stroke, Stroke(), stroke, Stroke()]), expected)
            recognizer.add(stroke: stroke)
            XCTAssertEqual(recognizer.classify(), expected)
        }
    }

    func testRepeatedModelFailuresPreserveErrorAfterNativeCleanup() throws {
        // A valid model plus a trailing byte reaches the C parser's final failure path.
        // The copied error must survive parser cleanup and recognizer destruction.
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

    func testTruncatedAndMalformedModelsFailCleanly() throws {
        try withModel { modelURL in
            let validModel = try Data(contentsOf: modelURL)
            var malformed = (0..<validModel.count).map { length -> Data in
                var data = Data(validModel.prefix(length))
                if data.count >= 4 {
                    replaceWord(UInt32(data.count) ^ 0x0ef71821, at: 0, in: &data)
                }
                return data
            }

            var excessiveCount = validModel
            replaceWord(UInt32.max, at: 8, in: &excessiveCount)
            malformed.append(excessiveCount)

            var unterminatedLabel = validModel
            unterminatedLabel.replaceSubrange(12..<28, with: repeatElement(UInt8(65), count: 16))
            malformed.append(unterminatedLabel)

            var missingSentinel = validModel
            replaceWord(1, at: missingSentinel.count - 8, in: &missingSentinel)
            malformed.append(missingSentinel)

            var partialFeature = missingSentinel
            append(0, to: &partialFeature)
            replaceWord(UInt32(partialFeature.count) ^ 0x0ef71821, at: 0, in: &partialFeature)
            malformed.append(partialFeature)

            for data in malformed {
                try data.write(to: modelURL)
                XCTAssertThrowsError(try Recognizer(modelURL: modelURL)) { error in
                    guard case Recognizer.RecognizerErrors.openingModelFailed(_, let message) = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                    XCTAssertFalse(message?.isEmpty ?? true)
                }
            }

            try validModel.write(to: modelURL)
            XCTAssertNoThrow(try Recognizer(modelURL: modelURL))
        }
    }

    func testNonfiniteCoefficientsAndInvalidFeatureOrderingFailCleanly() throws {
        try withModel(featureWeight: 1) { modelURL in
            let validModel = try Data(contentsOf: modelURL)
            var malformed = [Data]()
            for value in [Float.nan, .infinity, -.infinity] {
                for offset in [28, 36] {
                    var data = validModel
                    replaceWord(value.bitPattern, at: offset, in: &data)
                    malformed.append(data)
                }
            }
            var negativeIndex = validModel
            replaceWord(UInt32.max - 1, at: 32, in: &negativeIndex)
            malformed.append(negativeIndex)
            var duplicateIndex = validModel
            duplicateIndex.insert(contentsOf: validModel[32..<40], at: 40)
            replaceWord(UInt32(duplicateIndex.count) ^ 0x0ef71821, at: 0, in: &duplicateIndex)
            malformed.append(duplicateIndex)

            for data in malformed {
                try data.write(to: modelURL)
                XCTAssertThrowsError(try Recognizer(modelURL: modelURL))
            }
            try validModel.write(to: modelURL)
            let recognizer = try Recognizer(
                modelURL: modelURL,
                canvasSize: Recognizer.Size(width: 500, height: 500)
            )
            let result = recognizer.classify(strokes: [Stroke(start: Point(x: 250, y: 250))])
            XCTAssertEqual(result.map { $0.character }, ["一", "中"])
            XCTAssertEqual(result.map { $0.score }, [3, 2])
        }
    }

    private func withModel<T>(
        trailingByte: Bool = false,
        featureWeight: Float? = nil,
        _ body: (URL) throws -> T
    ) throws -> T {
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
            if let weight = featureWeight {
                append(0, to: &payload)
                append(weight.bitPattern, to: &payload)
            }
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

    private func replaceWord(_ value: UInt32, at offset: Int, in data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
    }
}
