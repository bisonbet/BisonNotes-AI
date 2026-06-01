//
//  EndpointSecurityPolicy.swift
//  BisonNotes AI
//
//  Validates user-configurable AI endpoint URLs before recordings,
//  transcripts, or summaries are sent over the network.
//

import Foundation

enum EndpointSecurityPolicy {
    static let allowInsecurePublicEndpointsKey = "allowInsecurePublicAIEndpoints"

    static func validationMessage(
        for endpoint: String,
        allowInsecurePublicEndpoints: Bool = UserDefaults.standard.bool(forKey: allowInsecurePublicEndpointsKey)
    ) -> String? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              let host = url.host else {
            return "Enter a valid endpoint URL."
        }

        if scheme == "https" || scheme == "wss" {
            return nil
        }

        guard scheme == "http" || scheme == "ws" else {
            return "Use HTTPS, WSS, HTTP, or WS for endpoint URLs."
        }

        if isLocalOrPrivateHost(host) {
            return nil
        }

        if allowInsecurePublicEndpoints {
            return nil
        }

        return "Public HTTP endpoints are blocked because audio and transcripts would be sent in cleartext. Use HTTPS, localhost, or a private IP address."
    }

    static func isAllowed(
        endpoint: String,
        allowInsecurePublicEndpoints: Bool = UserDefaults.standard.bool(forKey: allowInsecurePublicEndpointsKey)
    ) -> Bool {
        validationMessage(for: endpoint, allowInsecurePublicEndpoints: allowInsecurePublicEndpoints) == nil
    }

    static func warningMessage(for endpoint: String) -> String? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              let host = url.host else {
            return nil
        }

        guard scheme == "http" || scheme == "ws" else {
            return nil
        }

        if isLocalOrPrivateHost(host) {
            return "This endpoint uses HTTP. Only use it with services you control on localhost or a private network."
        }

        return "This endpoint uses public HTTP. Audio, transcripts, and summaries can be read or modified on the network unless Development Mode is enabled."
    }

    private static func isLocalOrPrivateHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()

        if normalized == "localhost" || normalized.hasSuffix(".localhost") || normalized == "::1" {
            return true
        }

        if let ipv4 = parseIPv4(normalized) {
            return isPrivateIPv4(ipv4)
        }

        return normalized.hasPrefix("fc") || normalized.hasPrefix("fd") || normalized.hasPrefix("fe80:")
    }

    private static func parseIPv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }

        let octets = parts.compactMap { part -> Int? in
            guard let value = Int(part), value >= 0, value <= 255 else { return nil }
            return value
        }

        return octets.count == 4 ? octets : nil
    }

    private static func isPrivateIPv4(_ octets: [Int]) -> Bool {
        let first = octets[0]
        let second = octets[1]

        return first == 10
            || first == 127
            || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
            || (first == 169 && second == 254)
    }
}
