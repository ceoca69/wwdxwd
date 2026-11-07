//
// Safe dual-scanner implementation for iOS 15+
// Uses only user-granted, security-scoped folder access and public Foundation APIs.
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum ScanMode {
    case foldersV6
    case filesV7

    var title: String {
        switch self {
        case .foldersV6: return "Folders (v6)"
        case .filesV7: return "Files (v7)"
        }
    }

    var zipSuffix: String {
        switch self {
        case .foldersV6: return "_v6_folders"
        case .filesV7: return "_v7_files"
        }
    }
}

private struct ScanOutput {
    let lines: [String]
    let zipURL: URL?
    let fileCount: Int
    let totalBytes: Int64
    let failedCount: Int
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ContentView: View {
    @State private var status = "Choose a folder to scan"
    @State private var selectedFolder: URL?
    @State private var isRunning = false
    @State private var logs: [String] = []
    @State private var resultURL: URL?
    @State private var showFolderPicker = false
    @State private var showExport = false

    private let panelColor = Color(uiColor: .secondarySystemBackground)
    private let panelShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("CoreMedia PoC — Safe Scanner")
                    .font(.headline)
                Text(status)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Selected folder")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(selectedFolder?.path ?? "No folder selected")
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                    .padding(12)
                    .background(panelColor, in: panelShape)
                Button {
                    showFolderPicker = true
                } label: {
                    Label("Choose folder in Files", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.bordered)
                .disabled(isRunning)
            }

            HStack(spacing: 10) {
                Button {
                    startScan(mode: .foldersV6)
                } label: {
                    VStack(spacing: 5) {
                        Label("Folders", systemImage: "folder")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Recursive · v6")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 66)
                    .background(Color(uiColor: .systemIndigo), in: panelShape)
                }
                .buttonStyle(.plain)
                .disabled(isRunning || selectedFolder == nil)

                Button {
                    startScan(mode: .filesV7)
                } label: {
                    VStack(spacing: 5) {
                        Label("Files", systemImage: "doc.text")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Direct only · v7")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 66)
                    .background(Color(uiColor: .systemBlue), in: panelShape)
                }
                .buttonStyle(.plain)
                .disabled(isRunning || selectedFolder == nil)
            }

            HStack {
                Text("Run Log")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear", role: .destructive) {
                    logs.removeAll()
                }
                .disabled(isRunning)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(logs.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .onChange(of: logs.count) { _ in
                    if let lastIndex = logs.indices.last {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(panelColor, in: panelShape)

            Button {
                guard resultURL != nil else { return }
                showExport = true
            } label: {
                Label("Export result", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
            }
            .buttonStyle(.bordered)
            .disabled(resultURL == nil || isRunning)
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let folder = urls.first else { return }
                selectedFolder = folder
                status = "Folder selected — ready"
                logs.append("Selected folder: \(folder.lastPathComponent)")
            case .failure(let error):
                status = "Folder selection failed"
                logs.append("Picker error: \(error.localizedDescription)")
            }
        }
        .sheet(isPresented: $showExport) {
            if let resultURL = resultURL {
                ActivityView(activityItems: [resultURL])
            }
        }
    }

    private func startScan(mode: ScanMode) {
        guard !isRunning, let folder = selectedFolder else { return }

        isRunning = true
        resultURL = nil
        status = "Running \(mode.title)…"
        logs.append("──────── New run: \(mode.title) ────────")

        DispatchQueue.global(qos: .userInitiated).async {
            let output = performScan(folder: folder, mode: mode)
            DispatchQueue.main.async {
                logs.append(contentsOf: output.lines)
                resultURL = output.zipURL
                status = output.zipURL == nil
                    ? "Finished with errors — \(mode.title)"
                    : "Finished \(mode.title) — \(output.fileCount) files"
                isRunning = false
            }
        }
    }
}

// MARK: - Public-API scanning

private func performScan(folder: URL, mode: ScanMode) -> ScanOutput {
    var lines: [String] = []
    var fileCount = 0
    var totalBytes: Int64 = 0
    var failedCount = 0
    let fileManager = FileManager.default

    func log(_ message: String) {
        lines.append(message)
    }

    let didStartAccess = folder.startAccessingSecurityScopedResource()
    defer {
        if didStartAccess {
            folder.stopAccessingSecurityScopedResource()
        }
    }

    log("Run started: \(mode.title)")
    log("Folder: \(folder.path)")
    log("Security-scoped access: \(didStartAccess ? "started" : "not required / unavailable")")

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        log("Selected URL is not an accessible directory.")
        return ScanOutput(lines: lines, zipURL: nil, fileCount: 0, totalBytes: 0, failedCount: 1)
    }

    let folderName = folder.lastPathComponent.isEmpty ? "SelectedFolder" : folder.lastPathComponent
    let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent("SafeScan-\(UUID().uuidString)", isDirectory: true)
    let outputRoot = temporaryRoot.appendingPathComponent(folderName, isDirectory: true)

    do {
        try fileManager.createDirectory(at: outputRoot, withIntermediateDirectories: true)
    } catch {
        log("Could not create temporary output folder: \(error.localizedDescription)")
        return ScanOutput(lines: lines, zipURL: nil, fileCount: 0, totalBytes: 0, failedCount: 1)
    }
    defer { try? fileManager.removeItem(at: temporaryRoot) }

    func copyRegularFile(_ sourceURL: URL, relativePath: String) {
        do {
            let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { return }

            let destinationURL = outputRoot.appendingPathComponent(relativePath)
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            fileCount += 1
            totalBytes += Int64(values.fileSize ?? 0)
        } catch {
            failedCount += 1
            log("Could not copy \(relativePath): \(error.localizedDescription)")
        }
    }

    switch mode {
    case .filesV7:
        log("v7: scanning regular files directly inside the selected folder.")
        do {
            let children = try fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                options: []
            ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            for child in children {
                do {
                    let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if values.isRegularFile == true && values.isSymbolicLink != true {
                        copyRegularFile(child, relativePath: child.lastPathComponent)
                    }
                } catch {
                    failedCount += 1
                    log("Could not inspect \(child.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch {
            failedCount += 1
            log("Could not list selected folder: \(error.localizedDescription)")
        }

    case .foldersV6:
        log("v6: recursively scanning folders and files, preserving directory structure.")
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        if let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { failedURL, error in
                failedCount += 1
                log("Could not enumerate \(failedURL.lastPathComponent): \(error.localizedDescription)")
                return true
            }
        ) {
            for case let child as URL in enumerator {
                let standardizedRoot = folder.standardizedFileURL.path
                let standardizedChild = child.standardizedFileURL.path
                let prefix = standardizedRoot.hasSuffix("/") ? standardizedRoot : standardizedRoot + "/"
                guard standardizedChild.hasPrefix(prefix) else {
                    failedCount += 1
                    log("Skipped path outside selected folder: \(child.path)")
                    continue
                }
                let relativePath = String(standardizedChild.dropFirst(prefix.count))
                guard !relativePath.isEmpty else { continue }

                do {
                    let values = try child.resourceValues(forKeys: keys)
                    if values.isSymbolicLink == true { continue }
                    if values.isDirectory == true {
                        try fileManager.createDirectory(
                            at: outputRoot.appendingPathComponent(relativePath, isDirectory: true),
                            withIntermediateDirectories: true
                        )
                    } else if values.isRegularFile == true {
                        copyRegularFile(child, relativePath: relativePath)
                    }
                } catch {
                    failedCount += 1
                    log("Could not process \(relativePath): \(error.localizedDescription)")
                }
            }
        } else {
            failedCount += 1
            log("Could not create recursive directory enumerator.")
        }
    }

    log("Scan complete: \(fileCount) files, \(totalBytes) bytes, \(failedCount) failures.")

    let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let zipURL = documents.appendingPathComponent(folderName + mode.zipSuffix + ".zip")
    try? fileManager.removeItem(at: zipURL)

    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var archiveError: String?
    var archiveCreated = false

    coordinator.coordinate(readingItemAt: outputRoot, options: [.forUploading], error: &coordinationError) { temporaryZipURL in
        do {
            try fileManager.copyItem(at: temporaryZipURL, to: zipURL)
            archiveCreated = true
        } catch {
            archiveError = error.localizedDescription
        }
    }

    if let coordinationError = coordinationError {
        failedCount += 1
        log("ZIP coordination failed: \(coordinationError.localizedDescription)")
    }
    if let archiveError = archiveError {
        failedCount += 1
        log("ZIP save failed: \(archiveError)")
    }

    if archiveCreated {
        log("Saved archive: \(zipURL.lastPathComponent)")
    } else {
        log("Archive was not created.")
    }

    // Save a separate log for this run: no shared global file descriptor.
    let logName = "run-\(mode.zipSuffix.dropFirst())-\(UUID().uuidString.prefix(8)).log"
    let logURL = documents.appendingPathComponent(logName)
    try? (lines.joined(separator: "\n") + "\n").write(to: logURL, atomically: true, encoding: .utf8)

    return ScanOutput(
        lines: lines,
        zipURL: archiveCreated ? zipURL : nil,
        fileCount: fileCount,
        totalBytes: totalBytes,
        failedCount: failedCount
    )
}
