// Adapted from the retained historical experiment predictor.
import Foundation
import CoreML
import Vision
import ImageIO

guard CommandLine.arguments.count == 5 else { fatalError("predict <model.mlmodel> <experiment-root> <output.json> <prepared|original>") }
let args = CommandLine.arguments
let root = URL(fileURLWithPath: args[2], isDirectory: true)
let original = args[4] == "original"
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as! [String: Any]
let requestedSplit = ProcessInfo.processInfo.environment["DICETOWER_EVAL_SPLIT"]
let rows = (manifest["rows"] as! [[String: Any]]).filter {
    let split = $0["split"] as! String
    if requestedSplit == "all" { return true }
    return split != "train" && (requestedSplit == nil || split == requestedSplit!)
}
let start = Date()
let compiled = try MLModel.compileModel(at: URL(fileURLWithPath: args[1]))
let config = MLModelConfiguration()
config.computeUnits = .all
let model = try MLModel(contentsOf: compiled, configuration: config)
let visionModel = try VNCoreMLModel(for: model)
let request = VNCoreMLRequest(model: visionModel)
request.imageCropAndScaleOption = .scaleFill
let features = model.modelDescription.inputDescriptionsByName
var overrides: [String: Any] = [:]
if features["confidenceThreshold"] != nil { overrides["confidenceThreshold"] = 0.01 }
if features["iouThreshold"] != nil { overrides["iouThreshold"] = 0.30 }
if !overrides.isEmpty { visionModel.featureProvider = try MLDictionaryFeatureProvider(dictionary: overrides) }
var outputs: [[String: Any]] = []
for (i,row) in rows.enumerated() {
    let ident = row["id"] as! String
    let split = row["split"] as! String
    let image = original ? root.appendingPathComponent("originals/\(ident).png") : root.appendingPathComponent("data/\(split)/\(ident)-r0.png")
    let handler = VNImageRequestHandler(url: image, orientation: .up, options: [:])
    if i == 0 { try handler.perform([request]) }
    let t = Date()
    try handler.perform([request])
    let ms = Date().timeIntervalSince(t)*1000
    guard let observations = request.results as? [VNRecognizedObjectObservation] else {
        fatalError("Expected Vision recognized-object observations, got \(String(describing: request.results))")
    }
    let trans = row["transform"] as! [String: Any]
    let width = original ? Double(row["width"] as! Int) : 416.0
    let height = original ? Double(row["height"] as! Int) : 416.0
    var predictions: [[String: Any]] = []
    for o in observations {
        guard let label = o.labels.first else { continue }
        let b = o.boundingBox
        var x = Double(b.minX)*width
        var y = (1-Double(b.maxY))*height
        var w = Double(b.width)*width
        var h = Double(b.height)*height
        if !original {
            x = (x-(trans["offsetX"] as! Double))/(trans["scaleX"] as! Double) + (trans["cropX"] as? Double ?? 0)
            y = (y-(trans["offsetY"] as! Double))/(trans["scaleY"] as! Double) + (trans["cropY"] as? Double ?? 0)
            w /= trans["scaleX"] as! Double; h /= trans["scaleY"] as! Double
        }
        // Vision exposes objectness on the observation and normalized class
        // confidence on its label. Their product matches the Core ML detector's
        // joint class score; class confidence alone keeps near-certain labels
        // on boxes whose objectness is almost zero.
        predictions.append(["label": label.identifier, "score": Double(label.confidence) * Double(o.confidence), "objectConfidence": Double(o.confidence), "classConfidence": Double(label.confidence), "box": [x,y,w,h]])
    }
    outputs.append(["id":ident,"split":split,"source":row["source"]!,"milliseconds":ms,"predictions":predictions])
    if (i+1)%10 == 0 { print("Predicted \(i+1)/\(rows.count)"); fflush(stdout) }
}
let result: [String: Any] = ["modelPath":args[1],"inputDescriptions":features.mapValues { $0.description },"outputDescriptions":model.modelDescription.outputDescriptionsByName.mapValues { $0.description }, "metadata": String(describing:model.modelDescription.metadata), "scoreDefinition":"Vision observation confidence multiplied by top-label confidence", "confidenceFloor":0.01,"nmsIoU":0.30,"preprocessing":original ? "original RGB image, Vision scaleFill (historical baseline)" : "manifest aspect-fit/pad then Vision scaleFill", "coordinateSystem":"original-image top-left pixels, xywh", "elapsedSeconds": Date().timeIntervalSince(start), "rows": outputs]
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:args[3]))
print("Saved \(args[3])")
