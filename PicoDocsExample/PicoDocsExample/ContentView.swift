//
//  ContentView.swift
//  PicoDocsExample//
//  Created by Ronald Mannak on 1/11/25.//

import SwiftUI
import PicoDocs
import UniformTypeIdentifiers

struct ContentView: View {
    
    @State var text = ""
    @State var isShowingFileImporter = false
    @State var isShowingURLDialog = false
    @State var webURLString = ""
    @State var outputFormat: ExportFileType? = .markdown
    @State var document: PicoDocument?
    @State private var isTargeted = false
    
    @State var selectedChapter: Int = 0
    @State var numberOfChapters = 1
    
    var body: some View {
        VStack {
            
            if let children = document?.children {
                TabView {
                    ForEach(children, id: \.self) { child in
                        Tab("\(child.title ?? child.filename)", systemImage: "document") {
                            ScrollView {
                                if outputFormat == nil, let data = child.originalContent, let original = String(data: data, encoding: .utf8) {
                                    Text(original)
                                } else {
                                    Text(child.exportedContent?.joined(separator: "\n\n------\n\n") ?? "")
                                }
                            }
                            MetadataView(document: child)
                        }
                    }
                }
                .id(children.count)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .textSelection(.enabled)

            } else if outputFormat == nil, let data = document?.originalContent, let original = String(data: data, encoding: .utf8) {
                ScrollView {
                    Text(original)
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                if let document {
                    MetadataView(document: document)
                }
                
            } else if let chapters = document?.exportedContent {
                
                Picker(selection: $selectedChapter) {
                    ForEach(0 ..< chapters.count, id: \.self) { index in
                        Text("Chapter \(index + 1)")
                            .tag(index)
                    }
                } label: {
                    Text("Show Chapter")
                }
                .padding()
                ScrollView {
                    if selectedChapter < chapters.count {
                        Text(chapters[selectedChapter])
                    } else {
                        Text("Drop a file here")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)                
                if let document {
                    MetadataView(document: document)
                }
            } else {
                Text("")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            Divider()
            HStack {
                
                Picker("Output format", selection: $outputFormat) {
                    Text("Original Content")
                        .tag(nil as ExportFileType?)
                    ForEach(ExportFileType.allCases, id: \.self) { item in
                        Text(item.rawValue)
                            .tag(item as ExportFileType?)
                    }
                }
            
                Spacer()
                Menu("Open File...") {
                    Button("Select File From Disk...") {
                        isShowingFileImporter = true
                    }
                    Button("Enter Web URL...") {
                        isShowingURLDialog = true
                    }
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .frame(width: 200)
                .fileImporter(
                    isPresented: $isShowingFileImporter,
                    allowedContentTypes: UTType.supportedDocumentTypes,
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        guard let url = urls.first else { return }
                        Task {
                            do {
                                try await loadFileFromDisk(url: url)
                            } catch {
                                text = "Error: \(error.localizedDescription)"
                            }
                        }
                    case .failure(let error):
                        text = "Error: \(error.localizedDescription)"
                    }
                }
                .alert("Download a file from the web", isPresented: $isShowingURLDialog) {
                    TextField("", text: $webURLString)
                    Button("OK", action: downloadFileFromWeb)
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Enter URL of any HTML, PDF, Word, Excel, or ePub file on the web")
                }
            }
        }
        .padding()
        .dropDestination(for: URL.self) { urls, _ in
            
            // Note: this supports files and directories from disk, and URLs dragged from Chrome's address bar. URL's dragged from
            // Safari's address bar are *NOT* supported.
            // However, if you drag a URL from Safari in Finder and then drag the webloc file onto this app, it does work.
            
            guard !urls.isEmpty else {
                print("No URLs received")
                return false
            }
            
            for url in urls {
                Task {
                    do {
                        if url.isFileURL {
                            try await self.loadFileFromDisk(url: url)
                        } else {
                            // Webloc file was dropped
                            try await self.parse(url: url)
                        }
                    } catch {
                        print("Error importing file \(url): \(error.localizedDescription)")
                    }
                }
            }
            return true
        } isTargeted: { targeted in
            withAnimation {
                isTargeted = targeted
            }
        }
        .overlay {
            if isTargeted {
                ContentUnavailableView {
                    Label("Drop documents or directories here", systemImage: "arrow.down.doc")
                } description: {
                    EmptyView()
                }
            }
        }
        .onChange(of: outputFormat) { _, newValue in
            Task {
                guard let document else { return }
                try? await document.parse(to: newValue)
            }
        }
    }
    
    private func loadFileFromDisk(url: URL) async throws {
        
        // Create bookmark with read-only access to access file or directory outside of sandbox
        // See: https://www.avanderlee.com/swift/security-scoped-bookmarks-for-url-access/
        // Note that this isn't necessary for files added using .dropDestination. startAccessingSecurityScopedResource
        // will return false, so we simply ignore the result
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        
        // Tip: Save bookmark to access file later
        
        let bookmark = try url.bookmarkData(
            options: [
                .withSecurityScope,
                .securityScopeAllowOnlyReadAccess,
            ],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard isStale == false else {
            // Bookmark should be updated
            throw PicoDocsError.stale
        }
        
        try await parse(url: url)
    }
    
    private func downloadFileFromWeb() {
        guard let url = URL(string: webURLString) else {
            text = "Error: not a valid URL"
            return
        }
        Task {
            do {
                try await parse(url: url)
            } catch {
                print("Error: \(error)")
            }
        }
    }
    
    private func parse(url: URL) async throws {
        
        // Create empty PicoDocument
        let doc = PicoDocument(url: url)
        self.document = doc
        
        // Fetch file's content
        try await doc.fetch()

        // Convert
        try await doc.parse(to: self.outputFormat)
    }
}


struct MetadataView: View {
    
    @Environment(\.openURL) var openURL
    let document: PicoDocument
    
    var body: some View {
        
        GroupBox("File metadata") {
            Grid {
                GridRow {
                    Text("Filename:")
                    Text(document.filename)
                        .frame(maxWidth: .infinity)
                }
                .gridColumnAlignment(.leading)
                GridRow {
                    Text("Kind:")
                    Text(document.utType.localizedDescription ?? "")
                }
                GridRow {
                    Text("Size:")
                    Text(formatFileSize(document.fileSize))
                }
                GridRow {
                    Text("Original location")
                    HStack {
                        Text(document.originURL.path)
                        Button {
                            openURL(document.originURL)
                        } label: {
                            Image(systemName: "link")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                    }
                }
                GridRow {
                    Text("Status:")
                    
                    switch document.status {
                    case .parsed:
                        Text("Parsed")
                    case .downloaded:
                        Text("Downloaded")
                    case .inProgress(let fraction):
                        Text("Downloading in progress (\(fraction.formatted(.percent)))")
                    case .failed(let error):
                        Text("Download failed: \(error.localizedDescription)")
                            .foregroundStyle(.red)
                    case .awaitingFetch:
                        Text("Not started")
                    }
                }
                GridRow {
                    Text("Date created:")
                    if let dateCreated = document.dateCreated {
                        Text(dateCreated, style: .date)
                    }
                }
                GridRow {
                    Text("Date last modified:")
                    if let dateLastModified = document.dateModified {
                        Text(dateLastModified, style: .date)
                    }
                }
                GridRow {
                    Text("Children:")
                    if let children = document.children {
                        Text("\(children.count)")
                    }
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
    
    /// Formats file sizes in human readable form
    private func formatFileSize(_ bytes: Int64, countStyle: ByteCountFormatter.CountStyle = .file) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = .useAll // Automatically choose the best unit
        formatter.countStyle = countStyle
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    ContentView()
}
