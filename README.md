# Zinnia-Swift

A Swift wrapper around zinnia, a library to recognize handwritten Japanese (or Chinese) characters.

For more information about zinnia, see [https://taku910.github.io/zinnia/](https://taku910.github.io/zinnia/).

Recognition requires a model file that incorporates training data. Model files can be downloaded, for example from [https://tegaki.github.io](https://tegaki.github.io).
A model file is included for unit testing.

## Installation
Use the Swift Package Manager. Add the following to your dependencies in `Package.swift`

```swift 
dependencies: [
        .package(url: "https://github.com/shinjukunian/zinnia-swift.git", from: "0.1.0"),
    ],
```

## How to use
To get started, initialize the `Recognizer`

```swift
let url = ... //the url of your model file
let recognizer=try? Recognizer(modelURL:url)
```
Don't forget to specify the canvas size on which the characters are being drawn.

```swift
recognizer.canvasSize = Recognizer.Size(width:500, height:500)
```
Next, add strokes to the recognizer. These would typically come from a gesture recognizer on a `UIView` or the movements of a mouse. A stroke consists of all the points between `touchesBegan(:)` and `touchesEnded(:)`.

```swift
let stroke = Stroke(points: [Point(x: 50, y: 250], Point(x:450, y: 250)])
//strokes for character 一

recognizer.add(stroke:stroke)
```

The stroke order is important. To classify strokes, use

```swift
let result = recognizer.classify()

let characters = result.map({$0.character})
//the recognized characters
```

The recognizer can be reset using 

```swift
recognizer.clear()
```

to start a new character.

For a sample application, see [https://github.com/shinjukunian/KanjiLookup-SwiftUI](https://github.com/shinjukunian/KanjiLookup-SwiftUI).

## Validation and model coverage

Run the Swift ownership/input/parser regressions without a model fixture:

```sh
swift test --filter NativeOwnershipTests
bash Scripts/test-native-safety.sh
```

The full `swift test` suite also exercises the original recognition fixtures
and requires the real model at `Tests/Resources/handwriting-ja.model` (fetch
the repository's Git LFS fixture or provide the verified model locally).
The native safety script enables AddressSanitizer and UndefinedBehaviorSanitizer
by default; see its `CXX` and `ZINNIA_SANITIZERS` options when selecting a compiler.

Model labels determine what can be recognized. The shipping Manabi Japanese
model has limited kana coverage. Use the [model audit](Tools/ModelAudit/README.md)
to verify its exact weights, supported labels, missing kana, and corresponding
source/license before making coverage claims or replacing an artifact.

## To Do
- [ ] Implement training
~~- [ ] Sample application~~

## Licence

zinnia (Copyright (c) 2005-2007, Taku Kudo), is BSD-licenced.

zinnia-Swift is under the MIT licence

The various model files come with their own licence.

