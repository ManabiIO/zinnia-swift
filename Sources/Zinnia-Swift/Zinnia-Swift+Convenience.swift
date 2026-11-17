//
//  Zinnia-Swift+Convenience.swift
//  
//
//  Created by Morten Bertz on 2019/07/18.
//

import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

public extension Point{
    init(cgPoint:CGPoint) {
        // Preserve the existing truncation for finite coordinates. An unrepresentable
        // value stays invalid so the recognizer rejects the character instead of
        // silently moving a point to the origin or trapping during conversion.
        self.x = Int(exactly: cgPoint.x.rounded(.towardZero)) ?? Int.max
        self.y = Int(exactly: cgPoint.y.rounded(.towardZero)) ?? Int.max
    }
    
    var cgPoint:CGPoint{
        return CGPoint(x: self.x, y: self.y)
    }
}

public extension Recognizer.Size{
    init(cgSize:CGSize) {
        self.width = Int(exactly: cgSize.width.rounded(.towardZero)) ?? 0
        self.height = Int(exactly: cgSize.height.rounded(.towardZero)) ?? 0
    }
    
    var cgSize:CGSize{
        return CGSize(width: self.width, height: self.height)
    }
}

public extension Stroke{
    mutating func add(point:CGPoint){
        self.add(point: Point(cgPoint: point))
    }
}
