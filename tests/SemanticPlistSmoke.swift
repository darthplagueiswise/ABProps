import Foundation

@main
struct SemanticPlistSmoke {
    static func main() throws {
        let key32 = Data([0xbc, 0xc4, 0xfe, 0xda, 0xa8, 0xa9, 0x8b, 0xca, 0x72, 0x27, 0x14, 0x71, 0x9b, 0xca, 0x22, 0x54, 0x81, 0x96, 0x36, 0x20, 0xe8, 0x3b, 0x83, 0xd3, 0xc9, 0xb7, 0xec, 0xb9, 0x3f, 0xb2, 0x62, 0x1f])
        let archive: NSDictionary = [
            "account": "Example User",
            "nested": NSArray(array: ["one", "two"]),
            "publicKey": key32
        ]
        let archived = try NSKeyedArchiver.archivedData(
            withRootObject: archive, requiringSecureCoding: false
        )
        let json = #"{"accounts":[{"name":"Alice"},{"name":"Bob"}],"active":true,"missing":null}"#
        let rawKey = Data([0xbc, 0xc4, 0xfe, 0xda, 0xa8, 0xa9, 0x8b, 0xca, 0x72, 0x27, 0x14, 0x71, 0x9b, 0xca, 0x22, 0x54])
        let source: [String: Any] = [
            "AppAEMAnonCredServerConfigs": archived,
            "FXCachingCommon.linkedAccountsData": archived.base64EncodedString(),
            "FBTabConfiguration": #"{"tabs":[{"id":"1603421209951282"}],"tracking_id":"{\"e\":[{\"r\":1}]}"}"#,
            "json_data": Data(json.utf8),
            "json_text": json,
            "json_b64": Data(json.utf8).base64EncodedString(),
            "kCompositeEventsArrayPreferenceKey": [[Int](repeating: 0, count: 150), [Int](repeating: 1, count: 200)],
            "normal_id": "1603421209951282",
            "publicKey": rawKey,
            "encoded_key": rawKey.base64EncodedString(),
            "text_data": Data("false".utf8),
            "ordinary_plain": "FACEBOOK12345678",
            "short_b64": "MA==",
            "bool_b64": "ZmFsc2U="
        ]
        let binary = try PropertyListSerialization.data(fromPropertyList: source, format: .binary, options: 0)
        let read = try SemanticPlistEngine.open(binary)
        guard let root = read.semantic as? [String: Any] else { fatalError("root missing") }
        precondition(root.count == 14)
        precondition((root["normal_id"] as? String) == "1603421209951282", "ordinary IDs must stay strings")
        precondition(root["publicKey"] as? String == "hex:bcc4fedaa8a98bca722714719bca2254",
                     "Raw key must display all decoded bytes")
        precondition(root["encoded_key"] as? String == "hex:bcc4fedaa8a98bca722714719bca2254",
                     "String Base64 must display decoded raw bytes")
        precondition(root["text_data"] as? String == "utf8:false",
                     "Raw UTF-8 Data decoded without converting original Data type")
        precondition(root["short_b64"] as? String == "utf8:0", "Short padded Base64 is decoded")
        precondition(root["bool_b64"] as? String == "utf8:false", "Boolean text encoded in Base64 is decoded without boolean coercion")
        precondition(root["ordinary_plain"] as? String == "FACEBOOK12345678",
                     "Ordinary strings are never guessed as Base64")
        precondition(!read.text.contains("ENVELOPE_"), "No implementation envelopes visible")
        guard let tab = root["FBTabConfiguration"] as? [String: Any],
              let tabs = tab["tabs"] as? [[String:Any]] else { fatalError("tabs not decoded") }
        precondition(tabs[0]["id"] as? String == "1603421209951282")
        guard let linked = root["FXCachingCommon.linkedAccountsData"] as? [String: Any] else {
            fatalError("semantic keyed archive not flattened, value=" + String(describing: root["FXCachingCommon.linkedAccountsData"]).prefix(1200))
        }
        guard linked["account"] as? String == "Example User" else { let graph = try! UniversalPlistCodec.decode(archived.base64EncodedString().data(using: .utf8)!).object as! [String:Any]
            fatalError("Archive unresolved: \(linked). TOP=\(String(describing: graph["$top"])) OBJECTS=\(String(describing: (graph["$objects"] as? [Any])?.prefix(8)))") }
        guard let linkedKey = linked["publicKey"] as? String else {
            fatalError("Archived NSData must appear as a readable hex value")
        }
        precondition(linkedKey == "hex:" + key32.map { String(format: "%02x", $0) }.joined(),
                     "Entire 32-byte public key must be visible as hex")
        let data = root["json_data"] as! [String: Any]
        precondition((data["missing"] as? [String: Bool])?["__json_null__"] == true)
        precondition(root["kCompositeEventsArrayPreferenceKey"] is [[Int]])
        // Preserve original bytes when unchanged; structural equal version acceptable for outer bplist.
        let rebuilt = try SemanticPlistEngine.save(read.text, original: binary, kind: read.kind)
        let original = try PropertyListSerialization.propertyList(from: binary, options: [], format: nil) as! [String:Any]
        let preserved = try PropertyListSerialization.propertyList(from: rebuilt, options: [], format: nil) as! [String:Any]
        precondition(original["AppAEMAnonCredServerConfigs"] as! Data == preserved["AppAEMAnonCredServerConfigs"] as! Data)
        precondition(original["FXCachingCommon.linkedAccountsData"] as! String == preserved["FXCachingCommon.linkedAccountsData"] as! String)
        precondition(original["publicKey"] as! Data == preserved["publicKey"] as! Data,
                     "Unedited Data exact")
        precondition(original["encoded_key"] as! String == preserved["encoded_key"] as! String,
                     "Unedited Base64 exact")
        precondition(original["text_data"] as! Data == preserved["text_data"] as! Data,
                     "Unedited UTF8 Data exact")
        let changedKeyXML = read.text.replacingOccurrences(
            of: "hex:bcc4fedaa8a98bca722714719bca2254",
            with: "hex:bcc4fedaa8a98bca722714719bca2255"
        )
        let keyChangedBytes = try SemanticPlistEngine.save(
            changedKeyXML, original: binary, kind: read.kind
        )
        let keyChangedRoot = try PropertyListSerialization.propertyList(
            from: keyChangedBytes, options: [], format: nil
        ) as! [String: Any]
        let expectedKey = Data([0xbc, 0xc4, 0xfe, 0xda, 0xa8, 0xa9, 0x8b, 0xca, 0x72, 0x27, 0x14, 0x71, 0x9b, 0xca, 0x22, 0x55])
        precondition((keyChangedRoot["publicKey"] as! Data) == expectedKey,
                     "Edited hex reconstitutes original Data carrier")
        precondition((keyChangedRoot["encoded_key"] as! String) == expectedKey.base64EncodedString(),
                     "Edited hex reconstitutes original Base64 string carrier exactly once")
        precondition(keyChangedRoot["normal_id"] as! String == source["normal_id"] as! String)
        precondition(keyChangedRoot["ordinary_plain"] as! String == source["ordinary_plain"] as! String)
        precondition((keyChangedRoot["text_data"] as! Data) == Data("false".utf8))
        precondition(keyChangedRoot["short_b64"] as! String == "MA==")
        precondition(keyChangedRoot["bool_b64"] as! String == "ZmFsc2U=")
        let shortChanged = read.text.replacingOccurrences(of: "<string>utf8:0</string>", with: "<string>utf8:1</string>")
        let shortChangedBytes = try SemanticPlistEngine.save(shortChanged, original: binary, kind: read.kind)
        let shortRoot = try PropertyListSerialization.propertyList(from: shortChangedBytes, options: [], format: nil) as! [String: Any]
        precondition(shortRoot["short_b64"] as! String == "MQ==", "Short Base64 re-encoded exactly once")
        // Apply change to an archived scalar using semantically visible XML, then unarchive it.
        let changed = read.text.replacingOccurrences(of: "<string>Example User</string>", with: "<string>Updated User</string>")
        let editedBytes = try SemanticPlistEngine.save(changed, original: binary, kind: read.kind)
        let editedRoot = try PropertyListSerialization.propertyList(from: editedBytes, options: [], format: nil) as! [String: Any]
        let archive1 = editedRoot["AppAEMAnonCredServerConfigs"] as! Data
        let archive2 = Data(base64Encoded: editedRoot["FXCachingCommon.linkedAccountsData"] as! String)!
        let unpacked1 = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(archive1) as! NSDictionary
        let unpacked2 = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(archive2) as! NSDictionary
        precondition(unpacked1["account"] as? String == "Updated User")
        precondition(unpacked2["account"] as? String == "Updated User")
        let changedArchivedKeyXML = read.text.replacingOccurrences(
            of: "hex:" + key32.map { String(format: "%02x", $0) }.joined(),
            with: "hex:" + key32.dropLast().map { String(format: "%02x", $0) }.joined() + "20"
        )
        let archivedChangedBytes = try SemanticPlistEngine.save(
            changedArchivedKeyXML, original: binary, kind: read.kind
        )
        let archivedChangedRoot = try PropertyListSerialization.propertyList(
            from: archivedChangedBytes, options: [], format: nil
        ) as! [String: Any]
        let archivedChanged = Data(base64Encoded: archivedChangedRoot["FXCachingCommon.linkedAccountsData"] as! String)!
        let archiveReopened = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(archivedChanged) as! NSDictionary
        var keyExpected = key32
        keyExpected[keyExpected.count - 1] = 0x20
        precondition((archiveReopened["publicKey"] as? Data) == keyExpected,
                     "NSKeyedArchiver NSData must keep its original binary type after editing")
        let counts = editedRoot["kCompositeEventsArrayPreferenceKey"] as! [[Int]]
        precondition(counts.count == 2 && counts[0].count == 150 && counts[1].count == 200)
        print("PASS semantic plist: clean XML, numeric IDs intact, Base64 archives flattened, original graph patch/rearchive, all arrays preserved")
    }
}
