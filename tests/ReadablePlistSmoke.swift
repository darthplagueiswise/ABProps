import Foundation

@main
struct ReadablePlistSmoke {
    static func main() throws {
        let numbers = (0..<4096).map { NSNumber(value: $0) }
        let inner: [String: Any] = [
            "nested": ["employee": false, "query_hash": "not_available"],
            "arrays": numbers,
            "flag": true
        ]
        let binaryInner = try PropertyListSerialization.data(fromPropertyList: inner, format: .binary, options: 0)
        let xmlInner = try PropertyListSerialization.data(fromPropertyList: inner, format: .xml, options: 0)
        let jsonInner = Data(#"{"enabled":false,"flags":[1,2,3,4],"message":"hello base64 JSON"}"#.utf8)
        let archive = try NSKeyedArchiver.archivedData(
            withRootObject: NSDictionary(dictionary: ["account": "sample", "value": 42]),
            requiringSecureCoding: false
        )
        let source: [String: Any] = [
            "kCompositeEventsArrayPreferenceKey": [numbers, numbers, numbers],
            "embeddedBinary": binaryInner,
            "embeddedXML": String(decoding: xmlInner, as: UTF8.self),
            "encodedString": binaryInner.base64EncodedString(),
            "encodedJSON": jsonInner.base64EncodedString(),
            "plainJSON": String(decoding: jsonInner, as: UTF8.self),
            "archivedObjects": archive,
            "unaltered": ["bool": true, "date": Date(timeIntervalSince1970: 123456)]
        ]
        let raw = try PropertyListSerialization.data(fromPropertyList: source, format: .binary, options: 0)
        let output = try ReadablePlistEngine.open(raw)

        precondition(output.statistics.arrayItems >= 12288, "No elements of huge arrays are removed")
        precondition(output.statistics.decodedContainers >= 5, "Binary, XML, JSON, Base64 and NSKeyedArchiver decoded")
        precondition(output.xml.contains("hello base64 JSON"), "Embedded Base64 JSON becomes readable")
        precondition(output.xml.contains("query_hash"), "Embedded binary plist becomes readable")
        precondition(output.xml.contains("$archiver"), "NSKeyedArchiver structural representation becomes readable")

        // Unedited original: byte-for-byte integrity.
        let untouched = try ReadablePlistEngine.reconstruct(output.xml, originalFormat: output.encoding, originalBytes: raw)
        let old = try PropertyListSerialization.propertyList(from: raw, options: [], format: nil) as! [String: Any]
        let again = try PropertyListSerialization.propertyList(from: untouched, options: [], format: nil) as! [String: Any]
        precondition((old["embeddedBinary"] as! Data) == (again["embeddedBinary"] as! Data))
        precondition((old["encodedString"] as! String) == (again["encodedString"] as! String))

        // Edit actual decoded element in XML, then recode into embedded Base64 and the outer original bplist.
        let changedXML = output.xml.replacingOccurrences(of: "hello base64 JSON", with: "edited Base64 JSON")
        let edited = try ReadablePlistEngine.reconstruct(changedXML, originalFormat: output.encoding, originalBytes: raw)
        let editedRoot = try PropertyListSerialization.propertyList(from: edited, options: [], format: nil) as! [String: Any]
        let reBase64 = editedRoot["encodedJSON"] as! String
        let decoded = Data(base64Encoded: reBase64)!
        let text = String(decoding: decoded, as: UTF8.self)
        precondition(text.contains("edited Base64 JSON"), "Edited text is reencoded in original Base64 field")
        let arrays = editedRoot["kCompositeEventsArrayPreferenceKey"] as! [[NSNumber]]
        precondition(arrays.count == 3 && arrays.allSatisfy { $0.count == 4096 })
        precondition((editedRoot["embeddedBinary"] as! Data) == binaryInner)
        precondition((editedRoot["archivedObjects"] as! Data) == archive,
                     "Untouched NSKeyedArchiver binary remains exact")

        let b64Outer = Data(raw.base64EncodedString().utf8)
        let viaBase64 = try ReadablePlistEngine.open(b64Outer)
        guard case .base64 = viaBase64.encoding else { fatalError("Outer Base64 lost") }
        let b64Edited = try ReadablePlistEngine.reconstruct(
            viaBase64.xml.replacingOccurrences(of: "hello base64 JSON", with: "Base64 twice edited"),
            originalFormat: viaBase64.encoding, originalBytes: b64Outer
        )
        precondition(String(decoding: b64Edited, as: UTF8.self).hasPrefix("YnBsaXN0"),
                     "Bplist wrapped as Base64 remains wrapped")

        print("PASS reversible XML editor: 12288 array elements, binary and Base64 plists, Base64 JSON, NSKeyedArchiver.")
    }
}
