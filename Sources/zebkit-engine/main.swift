// zebkit-engine: gets the engine, and puts it where a program finds it.
//
// The engine is not part of a program that uses Zebkit: it is a directory
// with Chromium in a library, a helper program and data files, which the
// program opens when it runs. This downloads that directory, once, into a
// cache every program of this user finds it in, and copies it beside an
// executable that is to be shipped.

import CZebkit
import Foundation

let usage = """
    usage: zebkit-engine <command>

      install [--force]   Download zebkit \(String(cString: zk_release_version())) for this system into the cache
                          (about 45 MiB on macOS, 65 MiB on Linux; once), checked
                          against the SHA-256 it was released with
      path                Print the directory of the engine a program would open
      bundle <directory>  Copy that engine into <directory>/zebkit, for an
                          executable in <directory> to ship with

    environment:
      ZEBKIT_DIR           Use the engine in this directory and no other
      ZEBKIT_CACHE_DIR     Where downloads are kept, instead of ~/.cache/zebkit
      ZEBKIT_DOWNLOAD_URL  Where the archives are, for a mirror: the directory
                           that holds zebkit-<version>-<target>.tar.xz
    """

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Runs a program found on the PATH. Returns what it wrote to standard
/// output; throws `problem` when it cannot be run or fails.
@discardableResult
func run(_ program: String, _ arguments: [String], orFail problem: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [program] + arguments
    let output = Pipe()
    process.standardOutput = output
    do {
        try process.run()
    } catch {
        throw Failure("\(problem)\n(\(program) could not be run: \(error.localizedDescription))")
    }
    let written = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw Failure(problem) }
    return String(decoding: written, as: UTF8.self)
}

/// The directory of this system's engine in the cache, and what it is checked against.
func release() throws -> (name: String, directory: URL, checksum: String) {
    let version = String(cString: zk_release_version())
    guard let target = zk_release_target().map({ String(cString: $0) }),
        let checksum = zk_release_sha256(target).map({ String(cString: $0) })
    else {
        throw Failure(
            "there is no prebuilt zebkit \(version) for this system (there is one for Apple silicon Macs and "
                + "for x86-64 Linux).\nBuild the engine from https://github.com/ikey4u/zebkit and set ZEBKIT_DIR "
                + "to its package directory")
    }
    guard let cache = zk_engine_cache_directory() else {
        throw Failure("no place to keep the downloaded engine: set ZEBKIT_CACHE_DIR")
    }
    defer { free(cache) }
    let name = "zebkit-\(version)-\(target)"
    return (name, URL(fileURLWithPath: String(cString: cache), isDirectory: true).appendingPathComponent(name), checksum)
}

/// Downloads the engine into the cache unless it is there. Returns its directory.
func install(force: Bool) throws -> URL {
    let (name, directory, checksum) = try release()
    let files = FileManager.default
    // The marker is written last, so a directory that has it is complete.
    let marker = directory.appendingPathComponent(".zebkit-complete")
    if !force, (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == checksum {
        return directory
    }

    let cache = directory.deletingLastPathComponent()
    try files.createDirectory(at: cache, withIntermediateDirectories: true)
    let version = String(cString: zk_release_version())
    let base = ProcessInfo.processInfo.environment["ZEBKIT_DOWNLOAD_URL"]
        ?? "https://github.com/ikey4u/zebkit/releases/download/v\(version)"
    let url = "\(base.hasSuffix("/") ? String(base.dropLast()) : base)/\(name).tar.xz"
    // Another program may be doing the same at this moment: each works in a
    // place of its own and moves the result in at the end.
    let scratch = cache.appendingPathComponent(".\(name).\(ProcessInfo.processInfo.processIdentifier)")
    try? files.removeItem(at: scratch)
    try files.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: scratch) }
    let archive = scratch.appendingPathComponent("archive.tar.xz")

    FileHandle.standardError.write(Data("downloading \(url)\n".utf8))
    try run(
        "curl", ["--fail", "--location", "--silent", "--show-error", "--retry", "3", "--output", archive.path, url],
        orFail: "cannot download \(url).\nIf this machine has no access to it, download the file elsewhere, "
            + "unpack it and set ZEBKIT_DIR to the directory")
    // macOS has shasum where Linux has sha256sum; both print the sum first.
    #if os(macOS)
    let sum = try run("shasum", ["-a", "256", archive.path], orFail: "cannot compute the archive's SHA-256")
    #else
    let sum = try run("sha256sum", [archive.path], orFail: "cannot compute the archive's SHA-256")
    #endif
    let actual = sum.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    guard actual == checksum else {
        throw Failure("\(url) is not the file zebkit \(version) was released as:\n  expected sha256 \(checksum)\n  got             \(actual)")
    }
    try run("tar", ["-xJf", archive.path, "-C", scratch.path], orFail: "cannot unpack the engine; this needs tar and xz")
    let unpacked = scratch.appendingPathComponent(name)
    do {
        try checksum.write(to: unpacked.appendingPathComponent(".zebkit-complete"), atomically: true, encoding: .utf8)
    } catch {
        throw Failure("the archive has no \(name)/ directory")
    }
    try? files.removeItem(at: directory)
    do {
        try files.moveItem(at: unpacked, to: directory)
    } catch {
        // Losing this race to another program is fine: what is there is the same.
        guard files.fileExists(atPath: marker.path) else { throw Failure("cannot move the engine into \(directory.path)") }
    }
    return directory
}

/// The package directory a program would open the engine from.
func engineDirectory() throws -> URL {
    var message: UnsafeMutablePointer<CChar>?
    guard zk_engine_load(nil, &message) else {
        defer { free(message) }
        throw Failure(message.map { String(cString: $0) } ?? "the engine could not be opened")
    }
    return URL(fileURLWithPath: String(cString: zk_engine_directory()), isDirectory: true)
}

/// Makes `destination`/zebkit hold the engine: what a program needs to run,
/// without the headers and the release's own programs.
func bundle(into destination: URL) throws {
    let engine = try engineDirectory()
    let files = FileManager.default
    let target = destination.appendingPathComponent("zebkit", isDirectory: true)
    try files.createDirectory(at: target, withIntermediateDirectories: true)
    let tools: Set = ["zebkit-run", "zebkit-js", "zebkit-mcp"]
    for name in try files.contentsOfDirectory(atPath: engine.path).sorted() {
        // include/ is for compiling against the engine; a marker file of the
        // download is nobody's business; the release's own programs are not
        // the application's.
        if name == "include" || name.hasPrefix(".") || tools.contains(name) { continue }
        let copy = target.appendingPathComponent(name)
        try? files.removeItem(at: copy)
        // cp, for the symbolic links a framework is made of, which stay links;
        // and on macOS as a clone where the file system has those, which
        // takes no room until one side changes.
        #if os(macOS)
        let how = "-ac"
        #else
        let how = "-a"
        #endif
        try run("cp", [how, engine.appendingPathComponent(name).path, copy.path], orFail: "cannot copy \(name) to \(target.path)")
    }
    print(target.path)
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "install" where arguments.dropFirst().allSatisfy({ $0 == "--force" }):
        print(try install(force: arguments.contains("--force")).path)
    case "path" where arguments.count == 1:
        print(try engineDirectory().path)
    case "bundle" where arguments.count == 2:
        try bundle(into: URL(fileURLWithPath: arguments[1], isDirectory: true))
    case "help", "--help", "-h":
        print(usage)
    default:
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("zebkit-engine: \(error)\n".utf8))
    exit(1)
}
