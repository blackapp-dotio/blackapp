// UserWriteNormalization.swift
import Foundation

/// Normalize fields the server can index for fast, case-insensitive search.
func normalizeUserFieldsForSearch(_ dict: inout [String: Any]) {
    if let name = (dict["name"] as? String) ?? (dict["displayName"] as? String) {
        dict["nameLower"] = name.lowercased()
    }
    if let username = (dict["username"] as? String) ?? (dict["handle"] as? String) {
        dict["usernameLower"] = username.replacingOccurrences(of: " ", with: "").lowercased()
    }
}
