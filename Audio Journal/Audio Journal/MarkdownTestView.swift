import SwiftUI

struct MarkdownTestView: View {
    let testMarkdown = """
    # Test Markdown
    
    This is a **bold text** and this is *italic text*.
    
    ## Bullet Points
    - First item
    - Second item
    - Third item
    
    ## Numbered List
    1. First item
    2. Second item
    3. Third item
    
    ## Summary Example
    **Meeting Summary:**
    
    - The meeting discussed important topics including project timeline and budget considerations
    - Key decisions were made about extending the deadline and increasing the budget
    - Team assignments were finalized with John leading the project
    """
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Markdown Test")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Original Markdown:")
                        .font(.headline)
                    
                    Text(testMarkdown)
                        .font(.caption)
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                    
                    Text("Rendered Markdown:")
                        .font(.headline)
                    
                    markdownText(testMarkdown)
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                }
                .padding()
            }
            .navigationTitle("Markdown Test")
        }
    }
}

#Preview {
    MarkdownTestView()
} 