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
    
    let testGoogleAIContent = """
    NPR News Briefing: Global Diplomacy, Domestic Issues, and Public Safety Updates This news briefing covers a range of current events, including international diplomatic engagements, domestic political and legal challenges, and public safety incidents.
    ### International Diplomacy and Relations
    • President Trump's UK Visit: President Trump is currently in Scotland, where he is meeting with Ursula von der Leyen, President of the European Commission, to discuss *trade*. He is scheduled to meet with British Prime Minister Keir Starmer tomorrow. George
    """
    
    let testAsteriskFormatting = """
    ### Test Asterisk Formatting
    
    This is a test of *italic text* formatting with asterisks.
    
    • First bullet point with *emphasis* on key terms
    • Second bullet point with *multiple* *asterisks* in *one* line
    • Third bullet point with no asterisks
    
    Regular paragraph with *italic emphasis* and more *text* to demonstrate the formatting.
    """
    
    let testUnstructuredContent = """
    ## NPR News Briefing
    This news briefing covers several key domestic and international developments:
    ### Economic & Trade News
    • The **European Union** has agreed to **President Trump's new trade terms**, which will impose a 15% tax rate on EU goods. This is half the rate initially threatened by the US, set to take effect this Friday for many countries. Ernie Tadaski, Director of Economics at the Budget Lab at Yale University, explained that these tariffs are expected to raise costs for American consumers and businesses. Economic research suggests foreign producers are not absorbing these tariffs, meaning the burden falls on US entities.
    ### International Affairs & Humanitarian Concerns
    President Trump announced the trade deal during a trip to his golf resort in Scotland. While there, he addressed questions about starvation in Gaza, stating he had seen TV footage and that it was "real starvation stuff." He indicated the US and other countries would become more involved in setting up food centers. UK Prime Minister Keir Starmer, speaking alongside Trump, also expressed that he finds images of starving children "revolting."
    ### Domestic Policy & Government Operations
    The **Government Accountability Office (GAO)** reported that the Census Bureau plans to change its preparation methods.
    """
    
    let testBoldText = """
    ### Test Bold Text
    
    This is a test of **bold text** formatting.
    
    • First bullet point with **bold emphasis** on key terms
    • Second bullet point with **multiple** **bold** **words** in **one** line
    • Third bullet point with no bold text
    
    Regular paragraph with **bold emphasis** and more **text** to demonstrate the formatting.
    """
    
    let testSimpleBold = """
    This is a simple test with **bold text** in the middle.
    """
    
    let testMinimalBold = "**bold text**"
    
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
                    
                    Divider()
                    
                    Text("Google AI Content Test:")
                        .font(.headline)
                    
                    Text(testGoogleAIContent)
                        .font(.caption)
                        .padding()
                        .background(Color.purple.opacity(0.1))
                        .cornerRadius(8)
                    
                    Text("Enhanced Google AI Rendering:")
                        .font(.headline)
                    
                    googleAIContentText(testGoogleAIContent)
                        .padding()
                        .background(Color.pink.opacity(0.1))
                        .cornerRadius(8)
                    
                    Divider()
                    
                    Text("Asterisk Formatting Test:")
                        .font(.headline)
                    
                    Text(testAsteriskFormatting)
                        .font(.caption)
                        .padding()
                        .background(Color.yellow.opacity(0.1))
                        .cornerRadius(8)
                    
                    Text("Enhanced Asterisk Rendering:")
                        .font(.headline)
                    
                    googleAIContentText(testAsteriskFormatting)
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                    
                    Divider()
                    
                    Text("Unstructured Content Test:")
                        .font(.headline)
                    
                    Text(testUnstructuredContent)
                        .font(.caption)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                    
                    Text("Enhanced Unstructured Content Rendering:")
                        .font(.headline)
                    
                    googleAIContentText(testUnstructuredContent)
                        .padding()
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(8)
                    
                    Divider()
                    
                    Text("Bold Text Test:")
                        .font(.headline)
                    
                    Text(testBoldText)
                        .font(.caption)
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                    
                    Text("Enhanced Bold Text Rendering:")
                        .font(.headline)
                    
                    googleAIContentText(testBoldText)
                        .padding()
                        .background(Color.purple.opacity(0.1))
                        .cornerRadius(8)
                    
                    Divider()
                    
                    Text("Simple Bold Text Test:")
                        .font(.headline)
                    
                    Text(testSimpleBold)
                        .font(.caption)
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                    
                    Text("Enhanced Simple Bold Rendering:")
                        .font(.headline)
                    
                    googleAIContentText(testSimpleBold)
                        .padding()
                        .background(Color.cyan.opacity(0.1))
                        .cornerRadius(8)
                    
                    Divider()
                    
                    Text("Minimal Bold Text Test:")
                        .font(.headline)
                    
                    Text(testMinimalBold)
                        .font(.caption)
                        .padding()
                        .background(Color.brown.opacity(0.1))
                        .cornerRadius(8)
                    
                    Text("Enhanced Minimal Bold Rendering:")
                        .font(.headline)
                    
                    googleAIContentText(testMinimalBold)
                        .padding()
                        .background(Color.mint.opacity(0.1))
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