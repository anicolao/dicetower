import AppKit
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let color = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:color,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red:0.06,green:0.15,blue:0.17,alpha:1));context.fill(CGRect(x:0,y:0,width:size,height:size))
context.setStrokeColor(CGColor(red:0.24,green:0.85,blue:0.68,alpha:1));context.setLineWidth(12)
context.addPath(CGPath(roundedRect:CGRect(x:132,y:132,width:760,height:760),cornerWidth:72,cornerHeight:72,transform:nil));context.strokePath()
context.setFillColor(CGColor(red:0.97,green:0.97,blue:0.94,alpha:1))
context.addPath(CGPath(roundedRect:CGRect(x:252,y:252,width:520,height:520),cornerWidth:92,cornerHeight:92,transform:nil));context.fillPath()
context.setFillColor(CGColor(red:0.06,green:0.15,blue:0.17,alpha:1))
for x in [380,644] { for y in [365,512,659] {context.fillEllipse(in:CGRect(x:x-37,y:y-37,width:74,height:74))} }
let image=context.makeImage()!
let url=URL(fileURLWithPath:CommandLine.arguments[1])
let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
CGImageDestinationAddImage(destination,image,nil);assert(CGImageDestinationFinalize(destination))
