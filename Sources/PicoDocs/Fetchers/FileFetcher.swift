//
//  File.swift
//  PicoDocs
//
//  Created by Ronald Mannak on 1/12/25.
//

import Foundation
import UniformTypeIdentifiers
import CoreXLSX

#if os(macOS)
import Foundation
#else
import Foundation
import XMLCoder
#endif

open class FileFetcher: FetcherProtocol {
    
    public let url: URL
    
    public required init(url: URL) {
        self.url = url
    }
    
    public func fetch(progressHandler: ((Progress) -> Void)? = nil) async throws -> (Data?, UTType?, [URL]?) {
        
        let fileManager = FileManager.default
        
        // Check if file needs to be downloaded from the cloud first
        if try await self.url.isStoredOniCloud {
            try await downloadFromCloud(progressHandler: progressHandler)
        }
        
        if self.url.isDirectory {
            
            // url is a directory
            
            let files = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [
                    .isUbiquitousItemKey,
                    .nameKey,
                    .fileSizeKey
                ],
                options: [
                    .skipsHiddenFiles,
                ]
            )
            
            return (nil, nil, files)

        } else {
            
            // url is a file
            
            let data = try Data(contentsOf: self.url)
            // Resolve the type from the file system's resource values first; this
            // handles extensionless files and custom system-registered types more
            // robustly. Fall back to the path extension. (The previous code passed
            // `path()` — the full path — to `UTType(filenameExtension:)`, which
            // expects a bare extension like "docx", so it almost always returned nil.)
            let utType = (try? self.url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: self.url.pathExtension)
            return (data, utType, nil)
        }
    }
    
    private func downloadFromCloud(progressHandler: ((Progress) -> Void)?) async throws {
        let fileManager = FileManager.default
        try fileManager.startDownloadingUbiquitousItem(at: self.url)
        
        await withCheckedContinuation { continuation in
            let query = NSMetadataQuery()
            query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemURLKey, url as NSURL)
            query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
            
            NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { _ in
                query.disableUpdates()
                //                defer { query.enableUpdates() }
                
                guard let item = query.results.first as? NSMetadataItem else { return }
                
                // Report progress
                if let percentDownloaded = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double {
                    let progress = Progress(totalUnitCount: 100)
                    progress.completedUnitCount = Int64(percentDownloaded)
                    progressHandler?(progress)
                    query.enableUpdates()
                }
                
                // Check if download is complete
                if item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String == NSMetadataUbiquitousItemDownloadingStatusCurrent {
                    query.stop()
                    continuation.resume()
                } else {
                    query.enableUpdates()
                }
            }
            
            query.start()
        }
    }
}
