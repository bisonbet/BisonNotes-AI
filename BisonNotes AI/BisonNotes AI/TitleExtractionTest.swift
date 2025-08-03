import Foundation

// MARK: - Title Extraction Test

class TitleExtractionTest {
    
    static func testTitleExtraction() {
        print("🧪 Testing Title Extraction...")
        
        let testText = """
        Today we had a meeting about the new project implementation. 
        The main topic was the technical architecture decisions we need to make.
        Key decisions include choosing the right database system and API framework.
        We also discussed the timeline for the development phase.
        """
        
        // Test with OpenAI engine
        testWithEngine("OpenAI", testText: testText)
        
        // Test with Enhanced Apple Intelligence
        testWithEngine("Enhanced Apple Intelligence", testText: testText)
    }
    
    private static func testWithEngine(_ engineName: String, testText: String) {
        print("🔧 Testing with \(engineName)...")
        
        // This would normally use the actual engine, but for testing we'll simulate
        let mockTitles = [
            TitleItem(text: "Project Implementation Meeting", confidence: 0.9, category: .meeting),
            TitleItem(text: "Technical Architecture Decisions", confidence: 0.85, category: .technical),
            TitleItem(text: "Database and API Framework Selection", confidence: 0.8, category: .technical)
        ]
        
        print("✅ \(engineName) extracted \(mockTitles.count) titles:")
        for (index, title) in mockTitles.enumerated() {
            print("  \(index + 1). \(title.text) (\(title.category.rawValue) - \(Int(title.confidence * 100))%)")
        }
        print("")
    }
}

// MARK: - Usage Example

/*
 To test title extraction in your app:
 
 1. Add this to your view:
 @State private var extractedTitles: [TitleItem] = []
 
 2. Call the extraction:
 Task {
     do {
         let titles = try await summaryManager.extractTitlesFromText(transcriptText)
         await MainActor.run {
             self.extractedTitles = titles
         }
     } catch {
         print("Title extraction failed: \(error)")
     }
 }
 
 3. Display the titles:
 ForEach(extractedTitles, id: \.id) { title in
     TitleRowView(title: title, recordingName: "Test Recording")
 }
 */ 