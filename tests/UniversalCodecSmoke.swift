import Foundation

@main
struct UniversalCodecSmoke {
    static func main() throws {
        let large = (0..<2048).map { NSNumber(value: $0) }
        let embeddedJSON = Data(#"{"nested":[{"foo":"search needle"},{"foo":"other"}]}"#.utf8)
        let input: [String: Any] = [
            "kCompositeEventsArrayPreferenceKey": [large, large],
            "embedded": embeddedJSON,
            "boolean": true,
            "meta": "unedited"
        ]
        let source = try PropertyListSerialization.data(
            fromPropertyList: input, format: .xml, options: 0
        )
        let decoded = try UniversalPlistCodec.decode(source)
        let intact = try UniversalPlistCodec.export(decoded.object, format: .original,
                                                     original: source, encoding: decoded.encoding,
                                                     dirty: false)
        precondition(intact == source, "byte-exact unmodified export")
        let array = try UniversalPlistCodec.value(decoded.object,
                                                  at: [.key("kCompositeEventsArrayPreferenceKey")])
        guard let outer = array as? [Any],
              let first = outer.first as? [Any] else {
            fatalError("array lost")
        }
        precondition(outer.count == 2 && first.count == 2048, "zero truncation")
        let location: [UniversalPathPart] = [
            .key("kCompositeEventsArrayPreferenceKey"), .index(0), .index(1023)
        ]
        let changed = try UniversalPlistCodec.replacing(decoded.object, at: location[...],
                                                        with: NSNumber(value: 5000))
        let result = try UniversalPlistCodec.encode(changed, as: .binary)
        let reparsed = try UniversalPlistCodec.decode(result)
        let newValue = try UniversalPlistCodec.value(reparsed.object, at: location) as! NSNumber
        precondition(newValue.intValue == 5000, "edit and binary roundtrip")
        let unmodifiedSibling = try UniversalPlistCodec.value(reparsed.object,
                                                               at: [.key("kCompositeEventsArrayPreferenceKey"),
                                                                    .index(1)]) as! [Any]
        precondition(unmodifiedSibling.count == 2048, "sibling array preserved")
        let nested = try UniversalPlistCodec.value(reparsed.object, at: [
            .key("embedded"), .embedded, .key("nested"), .index(0), .key("foo")
        ]) as! String
        precondition(nested == "search needle", "nested JSON decoded")
        let matches = UniversalPlistCodec.fullTextMatches(reparsed.object, query: "needle")
        precondition(matches.contains(where: { $0.id.contains("foo") }),
                     "full text inside JSON binary value")
        let base64 = try UniversalPlistCodec.encode(decoded.object, as: .base64(.xml))
        let fromBase64 = try UniversalPlistCodec.decode(base64)
        guard case .base64 = fromBase64.encoding else { fatalError("base64 envelope lost") }
        let json = try UniversalPlistCodec.encode(decoded.object, as: .json)
        let jsonRoundtrip = try UniversalPlistCodec.decode(json)
        let embedded = try UniversalPlistCodec.value(jsonRoundtrip.object, at: [.key("embedded")])
        precondition(embedded is Data, "typed JSON Data survives roundtrip")
        print("PASS: XML, binary, Base64, typed JSON, nested JSON, full text, 4096 complete array entries")
    }
}
