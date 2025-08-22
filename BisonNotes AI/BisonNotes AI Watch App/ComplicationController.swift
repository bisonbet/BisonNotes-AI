import ClockKit
import SwiftUI

class ComplicationController: NSObject, CLKComplicationDataSource {
    
    // Helper to get complication images from individual imagesets
    private func getComplicationImage(for family: CLKComplicationFamily) -> UIImage? {
        let imageName: String
        switch family {
        case .circularSmall:
            imageName = "ComplicationCircular"
        case .modularSmall:
            imageName = "ComplicationModular"
        case .graphicCircular:
            imageName = "ComplicationGraphicCircular"
        case .graphicCorner:
            imageName = "ComplicationGraphicCorner"
        case .graphicExtraLarge:
            imageName = "ComplicationExtraLarge"
        default:
            return nil
        }
        
        if let image = UIImage(named: imageName) {
            return image
        }
        // Fallback to app icon
        if let appIconImage = UIImage(named: "BisonNotes AI-1") {
            return appIconImage
        }
        // Last resort - create a simple placeholder
        return createPlaceholderImage()
    }
    
    private func createPlaceholderImage() -> UIImage {
        let size = CGSize(width: 40, height: 40)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        UIColor.white.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image
    }
    
    func getComplicationDescriptors(handler: @escaping ([CLKComplicationDescriptor]) -> Void) {
        let descriptors = [
            CLKComplicationDescriptor(
                identifier: "BisonNotesAI",
                displayName: "BisonNotes AI",
                supportedFamilies: [
                    .circularSmall,
                    .modularSmall,
                    .graphicCircular,
                    .graphicCorner,
                    .graphicExtraLarge
                ]
            )
        ]
        
        handler(descriptors)
    }
    
    func handleSharedComplicationDescriptors(_ complicationDescriptors: [CLKComplicationDescriptor]) {
        
    }
    
    func getTimelineStartDate(for complication: CLKComplication, withHandler handler: @escaping (Date?) -> Void) {
        handler(nil)
    }
    
    func getTimelineEndDate(for complication: CLKComplication, withHandler handler: @escaping (Date?) -> Void) {
        handler(nil)
    }
    
    func getPrivacyBehavior(for complication: CLKComplication, withHandler handler: @escaping (CLKComplicationPrivacyBehavior) -> Void) {
        handler(.showOnLockScreen)
    }
    
    func getCurrentTimelineEntry(for complication: CLKComplication, withHandler handler: @escaping (CLKComplicationTimelineEntry?) -> Void) {
        guard let image = getComplicationImage(for: complication.family) else {
            handler(nil)
            return
        }
        
        switch complication.family {
        case .circularSmall:
            let imageProvider = CLKImageProvider(onePieceImage: image)
            let template = CLKComplicationTemplateCircularSmallSimpleImage(imageProvider: imageProvider)
            let timelineEntry = CLKComplicationTimelineEntry(date: Date(), complicationTemplate: template)
            handler(timelineEntry)
            
        case .modularSmall:
            let imageProvider = CLKImageProvider(onePieceImage: image)
            let template = CLKComplicationTemplateModularSmallSimpleImage(imageProvider: imageProvider)
            let timelineEntry = CLKComplicationTimelineEntry(date: Date(), complicationTemplate: template)
            handler(timelineEntry)
            
        case .graphicCircular:
            let imageProvider = CLKFullColorImageProvider(fullColorImage: image)
            let template = CLKComplicationTemplateGraphicCircularImage(imageProvider: imageProvider)
            let timelineEntry = CLKComplicationTimelineEntry(date: Date(), complicationTemplate: template)
            handler(timelineEntry)
            
        case .graphicCorner:
            let imageProvider = CLKFullColorImageProvider(fullColorImage: image)
            let template = CLKComplicationTemplateGraphicCornerCircularImage(imageProvider: imageProvider)
            let timelineEntry = CLKComplicationTimelineEntry(date: Date(), complicationTemplate: template)
            handler(timelineEntry)
            
        case .graphicExtraLarge:
            let imageProvider = CLKFullColorImageProvider(fullColorImage: image)
            let template = CLKComplicationTemplateGraphicExtraLargeCircularImage(imageProvider: imageProvider)
            let timelineEntry = CLKComplicationTimelineEntry(date: Date(), complicationTemplate: template)
            handler(timelineEntry)
            
        default:
            handler(nil)
        }
    }
    
    func getTimelineEntries(for complication: CLKComplication, after date: Date, limit: Int, withHandler handler: @escaping ([CLKComplicationTimelineEntry]?) -> Void) {
        handler(nil)
    }
    
    func getLocalizableSampleTemplate(for complication: CLKComplication, withHandler handler: @escaping (CLKComplicationTemplate?) -> Void) {
        getCurrentTimelineEntry(for: complication) { timelineEntry in
            handler(timelineEntry?.complicationTemplate)
        }
    }
}