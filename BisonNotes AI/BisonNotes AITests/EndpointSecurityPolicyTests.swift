//
//  EndpointSecurityPolicyTests.swift
//  BisonNotes AITests
//

import XCTest
@testable import BisonNotes_AI

final class EndpointSecurityPolicyTests: XCTestCase {
    func testAllowsEncryptedPublicEndpoints() {
        XCTAssertNil(EndpointSecurityPolicy.validationMessage(for: "https://api.openai.com/v1"))
        XCTAssertNil(EndpointSecurityPolicy.validationMessage(for: "wss://example.com/socket"))
    }

    func testAllowsLocalAndPrivateHTTP() {
        XCTAssertNil(EndpointSecurityPolicy.validationMessage(for: "http://localhost:11434"))
        XCTAssertNil(EndpointSecurityPolicy.validationMessage(for: "http://127.0.0.1:9000"))
        XCTAssertNil(EndpointSecurityPolicy.validationMessage(for: "http://10.0.0.5:9000"))
        XCTAssertNil(EndpointSecurityPolicy.validationMessage(for: "http://172.16.10.5:9000"))
        XCTAssertNil(EndpointSecurityPolicy.validationMessage(for: "http://192.168.1.20:9000"))
    }

    func testBlocksPublicHTTPByDefault() {
        let message = EndpointSecurityPolicy.validationMessage(for: "http://example.com/v1")

        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("Public HTTP endpoints are blocked") == true)
    }

    func testAllowsPublicHTTPOnlyWhenDevelopmentModeIsEnabled() {
        XCTAssertNil(
            EndpointSecurityPolicy.validationMessage(
                for: "http://example.com/v1",
                allowInsecurePublicEndpoints: true
            )
        )
    }
}
