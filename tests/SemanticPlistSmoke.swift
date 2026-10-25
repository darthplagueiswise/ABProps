import Foundation

@main
struct SemanticPlistSmoke {
    static func main() throws {
        let archive: NSDictionary = [
            "account": "Example User",
            "nested": NSArray(array: ["one", "two"])
        ]
        let archived = try NSKeyedArchiver.archivedData(
            withRootObject: archive, requiringSecureCoding: false
        )
        let json = #"{"accounts":[{"name":"Alice"},{"name":"Bob"}],"active":true,"missing":null}"#
        let source: [String: Any] = [
            "AppAEMAnonCredServerConfigs": archived,
            "FXCachingCommon.linkedAccountsData": archived.base64EncodedString(),
            "FBTabConfiguration": #"{"tabs":[{"id":"1603421209951282"}],"tracking_id":"{\"e\":[{\"r\":1}]}"}"#,
            "json_data": Data(json.utf8),
            "json_text": json,
            "json_b64": Data(json.utf8).base64EncodedString(),
            "kCompositeEventsArrayPreferenceKey": [[Int](repeating: 0, count: 150), [Int](repeating: 1, count: 200)],
            "normal_id": "1603421209951282"
        ]
        let binary = try PropertyListSerialization.data(fromPropertyList: source, format: .binary, options: 0)
        let read = try SemanticPlistEngine.open(binary)
        guard let root = read.semantic as? [String: Any] else { fatalError("root missing") }
        precondition(root.count == 8)
        precondition((root["normal_id"] as? String) == "1603421209951282", "ordinary IDs must stay strings")
        precondition(!read.text.contains("ENVELOPE_"), "No implementation envelopes visible")
        guard let tab = root["FBTabConfiguration"] as? [String: Any],
              let tabs = tab["tabs"] as? [[String:Any]] else { fatalError("tabs not decoded") }
        precondition(tabs[0]["id"] as? String == "1603421209951282")
        guard let linked = root["FXCachingCommon.linkedAccountsData"] as? [String: Any] else {
            fatalError("semantic keyed archive not flattened, value=" + String(describing: root["FXCachingCommon.linkedAccountsData"]).prefix(1200))
        }
        guard linked["account"] as? String == "Example User" else { fatalError("Archive unresolved dictionary: " + String(describing: linked).prefix(1300)) }
        let data = root["json_data"] as! [String: Any]
        precondition((data["missing"] as? [String: Bool])?["__json_null__"] == true)
        precondition(root["kCompositeEventsArrayPreferenceKey"] is [[Int]])
        // Preserve original bytes when unchanged; structural equal version acceptable for outer bplist.
        let rebuilt = try SemanticPlistEngine.save(read.text, original: binary, kind: read.kind)
        let original = try PropertyListSerialization.propertyList(from: binary, options: [], format: nil) as! [String:Any]
        let preserved = try PropertyListSerialization.propertyList(from: rebuilt, options: [], format: nil) as! [String:Any]
        precondition(original["AppAEMAnonCredServerConfigs"] as! Data == preserved["AppAEMAnonCredServerConfigs"] as! Data)
        precondition(original["FXCachingCommon.linkedAccountsData"] as! String == preserved["FXCachingCommon.linkedAccountsData"] as! String)
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
        let counts = editedRoot["kCompositeEventsArrayPreferenceKey"] as! [[Int]]
        precondition(counts.count == 2 && counts[0].count == 150 && counts[1].count == 200)
        print("PASS semantic plist: clean XML, numeric IDs intact, Base64 archives flattened, original graph patch/rearchive, all arrays preserved")
    }
}
