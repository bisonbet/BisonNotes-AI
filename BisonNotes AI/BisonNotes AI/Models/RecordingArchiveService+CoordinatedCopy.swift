import Foundation

extension RecordingArchiveService {
    func copyArchiveSource(_ sourceURL: URL, to destinationURL: URL) throws {
            var coordinatorError: NSError?
            var operationError: Error?
            var didCopy = false
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordinatorError) { coordinatedURL in
                do {
                    try FileManager.default.copyItem(at: coordinatedURL, to: destinationURL)
                    AppFileProtection.apply(to: destinationURL)
                    didCopy = true
                } catch {
                    operationError = error
                }
            }

            if let operationError {
                throw RecordingArchiveError.copyFailed(operationError.localizedDescription)
            }
            if let coordinatorError {
                throw RecordingArchiveError.copyFailed(coordinatorError.localizedDescription)
            }
            guard didCopy else {
                throw RecordingArchiveError.copyFailed("The file provider did not return a readable file.")
            }

    }
    static func resolveLocalURL(from urlString: String) -> URL? {
        if urlString.hasPrefix("/") {
            return URL(fileURLWithPath: urlString)
        }
        if let parsed = URL(string: urlString), parsed.scheme != nil {
            return parsed.isFileURL ? parsed : nil
        }
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let decoded = urlString.removingPercentEncoding ?? urlString
        return docs.appendingPathComponent(decoded)
    }
    func totalFileSize(for recordings: [RecordingEntry]) -> Int64 {
        let urls = audioURLs(for: recordings)
        return urls.reduce(Int64(0)) { total, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
            return total + size
        }
    }
}
