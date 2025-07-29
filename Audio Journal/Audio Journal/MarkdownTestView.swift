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
    
    let testOllamaResponse = """
    **President Trump's visit to Scotland** includes meetings with EU Commission President Ursula von der Leyen and UK Prime Minister Keir Starmer, amid **anti-Trump protests** and **historical ties to the UK**.  \\n- **U.S. condemnation of Hong Kong's actions**: Secretary of State Marco Rubio criticized arrest warrants targeting activists, calling them an attempt to **erode Hong Kong's autonomy** and **intimidate Americans**.  \\n- **Texas redistricting controversy**: The Justice Department labeled four districts as **unconstitutional racial gerrymanders**, urging Texas to redraw maps to better represent **Black and Latino voters**.  \\n- **Michigan stabbing incident**: A 42-year-old man stabbed 11 people at a Walmart, with investigators suggesting the attack was **random**.  \\n- **Harvard's potential deal with Trump administration**: Some alumni urge the university to follow Columbia's example in securing **federal research funding** by complying with policies on admissions and discipline.  \\n- **Thailand-Cambodia ceasefire talks**: Leaders plan to meet in Malaysia to address **border violence** that killed over 30 people.  \\n\\nKey themes include **international diplomacy tensions**, **voting rights issues**, and **domestic security concerns**.
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
                    
                    Divider()
                    
                    Text("Ollama Response Test (with \\n escape sequences):")
                        .font(.headline)
                    
                    Text(testOllamaResponse)
                        .font(.caption)
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                    
                    Text("Fixed Rendering:")
                        .font(.headline)
                    
                    markdownText(testOllamaResponse)
                        .padding()
                        .background(Color.green.opacity(0.1))
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