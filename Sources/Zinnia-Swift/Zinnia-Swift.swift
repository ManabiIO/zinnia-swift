//
//  Zinnia-Swift.swift
//
//
//  Created by Morten Bertz on 2019/07/18.
//

import Foundation
import zinnia


/**
 A SVM-based recognizer for handwritten characters. Reconition is based on 'strokes', which are akin to the stroke of a pen on a piece of paper. The order of these strokes is important for recognition
 */
public class Recognizer{
    
    public enum RecognizerErrors : Error, Equatable {
        case openingModelFailed(url:URL, errorMessage:String?)
        case recognizerInitializationFailed
    }
    
    /// A struct representing a twodimensional size.
    public struct Size : Equatable,Hashable{
        let width:Int
        let height:Int
        
        /// A size with no extent
        public static let zero=Size(width: 0, height: 0)
    }
    
    
    /// A recognition result
    public struct Result:Equatable, Comparable{
        ///The recognized character
        public let character:String
        /// The score of the recognzied character
        public let score:Float
        
        public static func < (lhs: Recognizer.Result, rhs: Recognizer.Result) -> Bool {
            return lhs.score < rhs.score
        }
        
    }
    
    fileprivate let modelURL:URL
    
    /** The size of the canvas that the character is drawn onto. The bounding box of the character's strokes should fall within this size.
     Ideally, this canvas should be square, but this is not required. Dimensions must
     be positive and fit in Int32. Invalid dimensions return no recognition results.
     This value has to be specified, the initial value is .zero.
     */
    public var canvasSize:Size = .zero{
        didSet{
            updateCanvasSize()
        }
    }
    
    ///The version of the underlying engine.
    public class var version:String{
        guard let versionString=zinnia_version() else { return "" }
        return String.init(cString: versionString)
    }
    
    fileprivate let _recognizer:OpaquePointer
    fileprivate let _currentCharacter:OpaquePointer
    
    fileprivate var currentStrokes=[Stroke]()
    private var hasInvalidStroke = false

    private var hasValidCanvasSize: Bool {
        return canvasSize.width > 0 && canvasSize.height > 0
            && canvasSize.width <= Int(Int32.max) && canvasSize.height <= Int(Int32.max)
    }

    private func updateCanvasSize() {
        // Do not pass negative Swift values through the unsigned native size API.
        zinnia_character_set_width(_currentCharacter, hasValidCanvasSize ? canvasSize.width : 0)
        zinnia_character_set_height(_currentCharacter, hasValidCanvasSize ? canvasSize.height : 0)
    }
    
    /**
     Initializes the recognizer.
     - parameters:
        - modelURL: The location of the model file
        - canvasSize: The size of the canvas on which the characters are drawn. This can be changed later.
     - Throws:
        * `RecognizerErrors.recognizerInitializationFailed` if the recognizer could not be initialized.
        * `RecognizerErrors.openingModelFailed` if the model file does not exist or could not be read
     */
    
    public init(modelURL:URL, canvasSize:Size = .zero)throws {
        self.modelURL=modelURL
        guard modelURL.isFileURL, !modelURL.path.contains("\0") else {
            throw RecognizerErrors.openingModelFailed(url: modelURL, errorMessage: "A local model file is required.")
        }
        
        guard let recognizer=zinnia_recognizer_new() else{
            throw RecognizerErrors.recognizerInitializationFailed
        }
        
        let character:OpaquePointer
        do{
            try self.modelURL.withUnsafeFileSystemRepresentation({path in
                guard let path = path else {
                    throw RecognizerErrors.openingModelFailed(url: modelURL, errorMessage: "Invalid model file path.")
                }
                let success=zinnia_recognizer_open(recognizer, path)
                if success != 1{
                    if let error=zinnia_recognizer_strerror(recognizer){
                        let errorString=String(cString: error)
                        throw RecognizerErrors.openingModelFailed(url: modelURL, errorMessage:  errorString)
                    }
                    else{
                        throw RecognizerErrors.openingModelFailed(url: modelURL, errorMessage: nil)
                    }
                }
            })
            guard let newCharacter=zinnia_character_new() else{
                throw RecognizerErrors.recognizerInitializationFailed
            }
            character=newCharacter
        }
        catch{
            // A throwing initializer cannot rely on deinit before its handles are stored.
            // Destroy also closes any partially opened model and its mapping.
            zinnia_recognizer_destroy(recognizer)
            throw error
        }
        
        self._recognizer = recognizer
        self._currentCharacter = character
        self.canvasSize=canvasSize
        updateCanvasSize()
    }
    
    /**
     Clears and resets the current character. To be called before a new charater is started.
     */
    public func clear(){
        zinnia_character_clear(self._currentCharacter)
        self.currentStrokes.removeAll()
        hasInvalidStroke = false
    }
    
    /**
     Adds a stroke to the current character. The order of strokes is important for recognition.
     Empty strokes are ignored. Coordinates outside the native Int32 range invalidate the
     current character; call clear() before drawing a new character.
     - parameters:
        - stroke:The stroke to be added
     */
    public func add(stroke:Stroke){
        // Empty gestures must not advance the native stroke ID: a gap creates
        // an empty native stroke and makes the whole character unrecognizable.
        guard !stroke.points.isEmpty, !hasInvalidStroke else { return }
        guard stroke.points.allSatisfy({ Int32(exactly: $0.x) != nil && Int32(exactly: $0.y) != nil }) else {
            clear()
            hasInvalidStroke = true
            return
        }
        for point in stroke.points{
            guard zinnia_character_add(
                self._currentCharacter, self.currentStrokes.count, Int32(point.x), Int32(point.y)
            ) == 1 else {
                clear()
                hasInvalidStroke = true
                return
            }
        }
        self.currentStrokes.append(stroke)
    }
    
    /**
     Classifies the strokes that have been added to the current character.
     - parameters:
        - maxResults:The maximum number of results to return. Nonpositive values return no results.
          Actually returned results can be fewer than this number.
     - Returns: An array of results, which contains the recognized characters and their confidence score. The array is already sorted with the most likely result at the beginning. If recognition fails, this array is empty.
     */
    public func classify(maxResults:Int = 10)->[Result]{
        guard maxResults > 0, hasValidCanvasSize, !hasInvalidStroke, !currentStrokes.isEmpty else { return [] }
        guard let result=zinnia_recognizer_classify(self._recognizer, self._currentCharacter, maxResults) else {return [Result]()}
        defer { zinnia_result_destroy(result) }
        
        let resultSize=zinnia_result_size(result)
        var results=[Result]()
        
        for i in 0..<resultSize{
            guard let nativeValue = zinnia_result_value(result, i),
                  let value = String(validatingUTF8: nativeValue), !value.isEmpty else { continue }
            let score=zinnia_result_score(result, i)
            guard score.isFinite else { continue }
            results.append(Result(character: value, score: score))
        }
        return results
    }
    
    /**
     A convenience function to recognize several strokes
     - parameters:
        - strokes: The strokes to recognize
        - maxResults: The maximum number of results to return
     - Returns: An array of `Result`.
     */
    public func classify(strokes:[Stroke], maxResults:Int = 10)->[Result]{
        self.clear()
        for stroke in strokes{
            self.add(stroke: stroke)
        }
        return self.classify(maxResults: maxResults)
    }
    
    
    
    deinit {
        zinnia_recognizer_close(self._recognizer)
        zinnia_recognizer_destroy(self._recognizer)
        zinnia_character_destroy(self._currentCharacter)
    }
}
