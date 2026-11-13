import XCTest

#if !canImport(ObjectiveC)
public func allTests() -> [XCTestCaseEntry] {
    return [
        testCase([
            ("testVersion", Zinnia_SwiftTests.testVersion),
            ("testInitialization", Zinnia_SwiftTests.testInitialization),
            ("testInitializationFailure", Zinnia_SwiftTests.testInitializationFailure),
            ("testRecognize一", Zinnia_SwiftTests.testRecognize一),
            ("testRecognize中", Zinnia_SwiftTests.testRecognize中)
        ]),
        testCase([
            ("testRepeatedRecognitionReturnsOwnedSwiftValues",
                NativeOwnershipTests.testRepeatedRecognitionReturnsOwnedSwiftValues),
            ("testNoNativeResultIsSafe", NativeOwnershipTests.testNoNativeResultIsSafe),
            ("testResultLimitsDoNotWrapToUnsignedCounts",
                NativeOwnershipTests.testResultLimitsDoNotWrapToUnsignedCounts),
            ("testInvalidCanvasSizesFailUntilValidSizeIsRestored",
                NativeOwnershipTests.testInvalidCanvasSizesFailUntilValidSizeIsRestored),
            ("testInvalidCoordinatesInvalidateTheWholeCharacterUntilClear",
                NativeOwnershipTests.testInvalidCoordinatesInvalidateTheWholeCharacterUntilClear),
            ("testCoreGraphicsConversionsRejectNonfiniteAndUnrepresentableValues",
                NativeOwnershipTests.testCoreGraphicsConversionsRejectNonfiniteAndUnrepresentableValues),
            ("testNonFileModelURLsFailWithoutEnteringTheNativeLoader",
                NativeOwnershipTests.testNonFileModelURLsFailWithoutEnteringTheNativeLoader),
            ("testEmptyStrokesDoNotPoisonFollowingRecognition",
                NativeOwnershipTests.testEmptyStrokesDoNotPoisonFollowingRecognition),
            ("testRepeatedModelFailuresPreserveErrorAfterNativeCleanup",
                NativeOwnershipTests.testRepeatedModelFailuresPreserveErrorAfterNativeCleanup),
            ("testTruncatedAndMalformedModelsFailCleanly",
                NativeOwnershipTests.testTruncatedAndMalformedModelsFailCleanly),
            ("testNonfiniteCoefficientsAndInvalidFeatureOrderingFailCleanly",
                NativeOwnershipTests.testNonfiniteCoefficientsAndInvalidFeatureOrderingFailCleanly)
        ])
    ]
}
#endif
