#if os(macOS)
import AppKit
import Foundation
import MapKit

extension MacSummaryExportRenderer {
    struct MapImages {
        let close: NSImage
        let wide: NSImage
    }

    @MainActor
    static func buildMapImages(
        summaryId: UUID,
        locationData: LocationData?
    ) async -> MapImages? {
        guard let locationData else { return nil }
        let coordinate = CLLocationCoordinate2D(
            latitude: locationData.latitude,
            longitude: locationData.longitude
        )
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

        let size = CGSize(width: 680, height: 360)
        var closeImage = storedMapImage(
            summaryId: summaryId,
            locationData: locationData
        )
        if closeImage == nil {
            closeImage = await createMapImage(
                coordinate: coordinate,
                size: size,
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
            )
        }
        let fallbackImage = closeImage ?? fallbackMapImage(
            locationData: locationData,
            size: size
        )
        let wideImage = await createMapImage(
            coordinate: coordinate,
            size: size,
            span: MKCoordinateSpan(latitudeDelta: 18, longitudeDelta: 18)
        ) ?? fallbackImage

        return MapImages(close: fallbackImage, wide: wideImage)
    }

    @MainActor
    static func appendMapPageIfNeeded(
        _ images: MapImages?,
        locationData: LocationData?,
        locationAddress: String?,
        page: (generatedAt: Date, number: Int),
        context: CGContext
    ) {
        guard let images, let locationData else { return }

        context.beginPDFPage(nil)
        drawHeader(in: context, generatedAt: page.generatedAt)
        drawFooter(in: context, pageNumber: page.number)
        drawMapPage(
            images,
            locationData: locationData,
            locationAddress: locationAddress,
            in: context
        )
        context.endPDFPage()
    }
}

private extension MacSummaryExportRenderer {
    @MainActor
    static func storedMapImage(
        summaryId: UUID,
        locationData: LocationData
    ) -> NSImage? {
        let signature = String(
            format: "%.5f_%.5f",
            locationData.latitude,
            locationData.longitude
        )
        guard let data = MapSnapshotStorage.loadData(
            summaryId: summaryId,
            locationSignature: signature
        ) else {
            return nil
        }
        return NSImage(data: data)
    }

    @MainActor
    static func createMapImage(
        coordinate: CLLocationCoordinate2D,
        size: CGSize,
        span: MKCoordinateSpan
    ) async -> NSImage? {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: coordinate, span: span)
        options.size = size
        options.showsBuildings = false
        options.pointOfInterestFilter = .excludingAll

        let snapshotter = MKMapSnapshotter(options: options)
        do {
            let imageData: Data = try await withCheckedThrowingContinuation { continuation in
                snapshotter.start(with: .main) { snapshot, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let snapshot {
                        guard let imageData = snapshot.image.tiffRepresentation else {
                            continuation.resume(
                                throwing: NSError(
                                    domain: "MacSummaryExportRenderer",
                                    code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "Map snapshot image could not be encoded."]
                                )
                            )
                            return
                        }
                        continuation.resume(returning: imageData)
                    } else {
                        continuation.resume(
                            throwing: NSError(
                                domain: "MacSummaryExportRenderer",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Map snapshot returned no image."]
                            )
                        )
                    }
                }
            }
            return NSImage(data: imageData)
        } catch {
            AppLog.shared.fileManagement(
                "MacSummaryExportRenderer: Map generation failed: \(error.localizedDescription)",
                level: .error
            )
            return nil
        }
    }

    @MainActor
    static func fallbackMapImage(
        locationData: LocationData,
        size: CGSize
    ) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(
            roundedRect: CGRect(origin: .zero, size: size),
            xRadius: 18,
            yRadius: 18
        ).fill()

        let pin = NSImage(
            systemSymbolName: "mappin.circle.fill",
            accessibilityDescription: "Recording location"
        )
        pin?.draw(
            in: CGRect(
                x: (size.width - 54) / 2,
                y: (size.height - 54) / 2 + 20,
                width: 54,
                height: 54
            )
        )

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = String(
            format: "Recording Location\n%.4f, %.4f",
            locationData.latitude,
            locationData.longitude
        )
        text.draw(
            in: CGRect(x: 20, y: size.height / 2 - 55, width: size.width - 40, height: 55),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style
            ]
        )

        return image
    }

    @MainActor
    static func drawMapPage(
        _ images: MapImages,
        locationData: LocationData,
        locationAddress: String?,
        in context: CGContext
    ) {
        drawLine(
            "Location Maps",
            at: CGPoint(x: 50, y: 710),
            font: .boldSystemFont(ofSize: 22),
            color: .black,
            in: context
        )

        let address = locationAddress ?? locationData.address
        let locationDescription = [
            address?.trimmingCharacters(in: .whitespacesAndNewlines),
            String(format: "%.5f, %.5f", locationData.latitude, locationData.longitude)
        ]
        .compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        .joined(separator: " · ")

        drawLine(
            locationDescription,
            at: CGPoint(x: 50, y: 682),
            font: .systemFont(ofSize: 10),
            color: .darkGray,
            in: context
        )

        let closeRect = CGRect(x: 50, y: 410, width: 512, height: 240)
        let wideRect = CGRect(x: 50, y: 125, width: 512, height: 240)
        drawMapImage(images.close, in: closeRect, context: context)
        drawMapImage(images.wide, in: wideRect, context: context)

        drawLine(
            "Local View",
            at: CGPoint(x: closeRect.minX, y: closeRect.maxY + 10),
            font: .boldSystemFont(ofSize: 11),
            color: .darkGray,
            in: context
        )
        drawLine(
            "Regional View",
            at: CGPoint(x: wideRect.minX, y: wideRect.maxY + 10),
            font: .boldSystemFont(ofSize: 11),
            color: .darkGray,
            in: context
        )
    }

    @MainActor
    static func drawMapImage(
        _ image: NSImage,
        in rect: CGRect,
        context: CGContext
    ) {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            return
        }

        let sourceSize = CGSize(width: cgImage.width, height: cgImage.height)
        let scale = max(rect.width / sourceSize.width, rect.height / sourceSize.height)
        let drawSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let drawRect = CGRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        context.saveGState()
        context.clip(to: rect)
        context.draw(cgImage, in: drawRect)
        context.restoreGState()

        context.saveGState()
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(0.8)
        context.stroke(rect)
        context.restoreGState()
    }
}
#endif
