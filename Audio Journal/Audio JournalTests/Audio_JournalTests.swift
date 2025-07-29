//
//  Audio_JournalTests.swift
//  Audio JournalTests
//
//  Created by Tim Champ on 7/26/25.
//

import Testing
@testable import Audio_Journal

struct Audio_JournalTests {

    /// Ensures that chunkText splits a small sample into the
    /// correct number of chunks when a low maxTokens value is used.
    @Test func chunkTextSplitsSmallSample() async throws {
        let sample = "Hello world. This is a test. Short sentence."

        let chunks = TokenManager.chunkText(sample, maxTokens: 4)

        #expect(chunks.count == 3)
        #expect(chunks[0] == "Hello world.")
        #expect(chunks[1] == "This is a test.")
        #expect(chunks[2] == "Short sentence.")
    }

}
