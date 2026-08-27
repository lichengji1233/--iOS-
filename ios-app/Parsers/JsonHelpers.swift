import Foundation

// 兼容大小写/驼峰与下划线两种键名
func obj(_ d: [String: Any]?, _ keys: String...) -> [String: Any]? {
    guard let d = d else { return nil }
    for k in keys {
        if let v = d[k] as? [String: Any] { return v }
    }
    return nil
}

func arr(_ d: [String: Any]?, _ keys: String...) -> [Any]? {
    guard let d = d else { return nil }
    for k in keys {
        if let v = d[k] as? [Any] { return v }
    }
    return nil
}

func str(_ d: [String: Any]?, _ keys: String...) -> String {
    guard let d = d else { return "" }
    for k in keys {
        if let v = d[k] as? String { return v }
    }
    return ""
}

func int(_ d: [String: Any]?, _ keys: String...) -> Int {
    guard let d = d else { return 0 }
    for k in keys {
        if let v = d[k] as? Int { return v }
        if let v = d[k] as? String, let n = Int(v) { return n }
    }
    return 0
}

func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ParseError("返回数据格式异常")
    }
    return obj
}

func jsonObject(_ string: String) -> [String: Any]? {
    guard let data = string.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func safeName(_ s: String, fallback: String) -> String {
    let clean = s.replacingOccurrences(
        of: #"[\\/:*?"<>|\s]+"#,
        with: "_",
        options: .regularExpression
    ).prefix(40).trimmingCharacters(in: CharacterSet(charactersIn: "_."))
    return clean.isEmpty ? fallback : String(clean)
}

func fixUrl(_ s: String) -> String {
    var u = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if u.hasPrefix("//") { u = "https:" + u }
    else if u.hasPrefix("http://") { u = "https://" + u.dropFirst(7) }
    return u
}
