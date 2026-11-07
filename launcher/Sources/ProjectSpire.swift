// Project Spire: builds and starts the native Mac version of Fable II from the user's own disc.
//
// The app ships no game data and no game code. On first run the user picks their disc image;
// toolkit/spire_setup.sh (inside this bundle) checks it is a supported release, copies the game
// files, translates the game code and compiles it on this Mac. After that, Play starts the
// installed game, and the disc image is no longer needed.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Install location and state

enum Paths {
  static let defaultInstall = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Project Spire", isDirectory: true)

  static var install: URL {
    get {
      if let path = UserDefaults.standard.string(forKey: "InstallPath") {
        return URL(fileURLWithPath: path, isDirectory: true)
      }
      return defaultInstall
    }
    set { UserDefaults.standard.set(newValue.path, forKey: "InstallPath") }
  }

  static var toolkit: URL { Bundle.main.resourceURL!.appendingPathComponent("toolkit", isDirectory: true) }
  static var gameBundle: URL { install.appendingPathComponent("Project Spire Game.app", isDirectory: true) }
  static var gameExecutable: URL { gameBundle.appendingPathComponent("Contents/MacOS/fable_2") }
  static var manifest: URL { install.appendingPathComponent("spire.json") }
  static var logFile: URL { install.appendingPathComponent("setup.log") }
}

struct InstallInfo: Decodable {
  var version: String
  var game: String
  var built: String
}

func readInstall() -> InstallInfo? {
  guard FileManager.default.isExecutableFile(atPath: Paths.gameExecutable.path),
        let data = try? Data(contentsOf: Paths.manifest) else { return nil }
  return try? JSONDecoder().decode(InstallInfo.self, from: data)
}

func commandLineToolsInstalled() -> Bool {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
  process.arguments = ["-p"]
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  do {
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
  } catch {
    return false
  }
}

// MARK: - Setup runner

@MainActor
final class Setup: ObservableObject {
  enum Phase: Equatable {
    case idle, running, failed(String), finished
  }

  @Published var phase: Phase = .idle
  @Published var stepTitle = ""
  @Published var stepNumber = 0
  @Published var stepCount = 6
  @Published var stepProgress: Double?
  @Published var log = ""
  @Published var started: Date?

  private var process: Process?
  private var cancelled = false
  private var logHandle: FileHandle?

  var overallProgress: Double {
    guard stepNumber > 0 else { return 0 }
    // The build is most of the time; weight the steps roughly by how long they take.
    let weights: [Double] = [0.01, 0.01, 0.12, 0.06, 0.78, 0.02]
    let index = min(stepNumber, weights.count) - 1
    let before = weights[..<index].reduce(0, +)
    return before + weights[index] * (stepProgress ?? 0)
  }

  func start(iso: URL, install: URL) {
    guard phase != .running else { return }
    phase = .running
    cancelled = false
    log = ""
    stepNumber = 0
    stepTitle = "Starting"
    stepProgress = nil
    started = Date()

    try? FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: Paths.logFile.path, contents: nil)
    logHandle = try? FileHandle(forWritingTo: Paths.logFile)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [Paths.toolkit.appendingPathComponent("spire_setup.sh").path, iso.path, install.path]
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    var pending = Data()
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      pending.append(chunk)
      var lines: [String] = []
      while let newline = pending.firstIndex(of: 0x0A) {
        lines.append(String(decoding: pending[..<newline], as: UTF8.self))
        pending.removeSubrange(...newline)
      }
      guard !lines.isEmpty else { return }
      Task { @MainActor in self?.handle(lines) }
    }
    process.terminationHandler = { [weak self] finished in
      pipe.fileHandleForReading.readabilityHandler = nil
      let status = finished.terminationStatus
      Task { @MainActor in self?.finish(status: status) }
    }
    do {
      try process.run()
      self.process = process
    } catch {
      phase = .failed("Setup could not start: \(error.localizedDescription)")
    }
  }

  func cancel() {
    cancelled = true
    if let process, process.isRunning {
      // Stop the whole build (compilers, ninja, cmake), not just the script.
      killTree(process.processIdentifier)
    }
  }

  private func killTree(_ pid: Int32) {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-P", String(pid)]
    let pipe = Pipe()
    pgrep.standardOutput = pipe
    try? pgrep.run()
    pgrep.waitUntilExit()
    let children = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .split(separator: "\n").compactMap { Int32($0) }
    kill(pid, SIGSTOP)
    children.forEach(killTree)
    kill(pid, SIGTERM)
    kill(pid, SIGCONT)
  }

  private func handle(_ lines: [String]) {
    for line in lines {
      logHandle?.write(Data((line + "\n").utf8))
      if line.hasPrefix("STEP ") {
        let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
        if parts.count == 4 {
          stepNumber = Int(parts[1]) ?? stepNumber
          stepCount = Int(parts[2]) ?? stepCount
          stepTitle = parts[3]
          stepProgress = nil
        }
      } else if line.hasPrefix("PROGRESS ") {
        stepProgress = Double(line.dropFirst(9))
      } else if line.hasPrefix("ERROR ") {
        phase = .failed(String(line.dropFirst(6)))
      } else if line == "DONE" {
        phase = .finished
      } else {
        log += line + "\n"
        if log.count > 200_000 { log = String(log.suffix(100_000)) }
      }
    }
  }

  private func finish(status: Int32) {
    try? logHandle?.close()
    logHandle = nil
    process = nil
    if cancelled {
      phase = .failed("Setup was cancelled.")
    } else if status == 0, phase == .running || phase == .finished {
      phase = .finished
    } else if case .failed = phase {
      // Keep the script's own message.
    } else {
      phase = .failed("Setup stopped unexpectedly (exit \(status)). The log has the details.")
    }
  }
}

// MARK: - Game process

@MainActor
final class Game: ObservableObject {
  @Published var running = false
  @Published var error: String?
  private var app: NSRunningApplication?
  private var observer: NSObjectProtocol?

  func play() {
    error = nil
    let configuration = NSWorkspace.OpenConfiguration()
    // The game finds game/ and user/ next to its bundle by itself.
    configuration.arguments = ["--gpu_backend=metal"]
    configuration.createsNewApplicationInstance = false
    configuration.activates = true
    running = true
    NSWorkspace.shared.openApplication(at: Paths.gameBundle, configuration: configuration) { app, error in
      Task { @MainActor in
        if let error {
          self.running = false
          self.error = "The game could not start: \(error.localizedDescription)"
          return
        }
        self.app = app
        self.watch()
        NSApp.hide(nil)
      }
    }
  }

  private func watch() {
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      let ended = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      Task { @MainActor in
        guard let self, let ended, ended == self.app else { return }
        self.running = false
        self.app = nil
        if let observer = self.observer {
          NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        NSApp.unhide(nil)
        NSApp.activate()
      }
    }
  }
}

// MARK: - Views

struct ContentView: View {
  @StateObject private var setup = Setup()
  @StateObject private var game = Game()
  @State private var install = readInstall()
  @State private var showSetup = readInstall() == nil
  @State private var iso: URL?
  @State private var location = Paths.install
  @State private var toolsInstalled = commandLineToolsInstalled()
  @State private var showLog = false

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      Group {
        if showSetup || setup.phase != .idle && setup.phase != .finished {
          setupView
        } else {
          readyView
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .frame(width: 560)
    .frame(minHeight: 420)
    .onChange(of: setup.phase) { _, phase in
      if phase == .finished {
        install = readInstall()
        showSetup = install == nil
      }
    }
  }

  private var header: some View {
    HStack(spacing: 16) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 72, height: 72)
      VStack(alignment: .leading, spacing: 4) {
        Text("Project Spire").font(.largeTitle.weight(.semibold))
        Text("Fable II, rebuilt natively for this Mac").foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(20)
  }

  // Ready: the game is installed.
  private var readyView: some View {
    VStack(alignment: .leading, spacing: 18) {
      if let install {
        Text("\(install.game) is installed.").font(.title3)
      }
      Button {
        game.play()
      } label: {
        Text(game.running ? "Playing…" : "Play")
          .font(.title2.weight(.semibold))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(game.running)
      .keyboardShortcut(.defaultAction)
      if let error = game.error {
        Text(error).foregroundStyle(.red)
      }
      Spacer()
      HStack {
        Button("Show Game Folder") {
          NSWorkspace.shared.activateFileViewerSelecting([Paths.install])
        }
        Button("Show Saves and Settings") {
          NSWorkspace.shared.open(Paths.install.appendingPathComponent("user", isDirectory: true))
        }
        Spacer()
        Button("Rebuild from Disc…") {
          showSetup = true
          setup.phase = .idle
        }
        .disabled(game.running)
      }
      .controlSize(.small)
    }
  }

  private var setupView: some View {
    VStack(alignment: .leading, spacing: 14) {
      switch setup.phase {
      case .idle:
        chooseView
      case .running:
        progressView
      case .failed(let message):
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .textSelection(.enabled)
        HStack {
          Button("Try Again") { setup.phase = .idle }
          Button("Show Log") { NSWorkspace.shared.open(Paths.logFile) }
          if install != nil {
            Spacer()
            Button("Back") {
              setup.phase = .idle
              showSetup = false
            }
          }
        }
      case .finished:
        EmptyView()
      }
    }
  }

  private var chooseView: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Project Spire turns your own Fable II disc into a native Mac game. Choose a disc image (.iso) of the Game of the Year edition. The game is built on this Mac, which takes a while; after that the disc image is no longer needed.")
        .fixedSize(horizontal: false, vertical: true)
      if !toolsInstalled {
        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            Text("Building needs Apple's free Command Line Tools.")
            HStack {
              Button("Install Command Line Tools") {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
                process.arguments = ["--install"]
                try? process.run()
              }
              Button("Check Again") { toolsInstalled = commandLineToolsInstalled() }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      LabeledContent("Disc image") {
        HStack {
          Text(iso?.lastPathComponent ?? "None chosen")
            .foregroundStyle(iso == nil ? .secondary : .primary)
            .lineLimit(1).truncationMode(.middle)
          Button("Choose…") { chooseISO() }
        }
      }
      LabeledContent("Install to") {
        HStack {
          Text(location.path(percentEncoded: false))
            .lineLimit(1).truncationMode(.head)
            .help(location.path(percentEncoded: false))
          Button("Change…") { chooseLocation() }
        }
      }
      Text("Needs about 15 GB of free space while building, and about 7 GB after.")
        .font(.callout).foregroundStyle(.secondary)
      HStack {
        if install != nil {
          Button("Cancel") { showSetup = false }
        }
        Spacer()
        Button("Build Game") {
          guard let iso else { return }
          Paths.install = location
          setup.start(iso: iso, install: location)
        }
        .buttonStyle(.borderedProminent)
        .disabled(iso == nil || !toolsInstalled)
        .keyboardShortcut(.defaultAction)
      }
      .padding(.top, 6)
    }
  }

  private var progressView: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Step \(max(setup.stepNumber, 1)) of \(setup.stepCount): \(setup.stepTitle)")
        .font(.headline)
      ProgressView(value: setup.overallProgress)
      if let started = setup.started {
        TimelineView(.periodic(from: started, by: 1)) { context in
          Text("Elapsed: " + elapsed(context.date.timeIntervalSince(started)))
            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
      }
      Text("You can keep using your Mac. It may run warm and slow while the game builds.")
        .font(.callout).foregroundStyle(.secondary)
      DisclosureGroup("Details", isExpanded: $showLog) {
        ScrollView {
          Text(setup.log.suffix(20_000))
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(height: 140)
        .defaultScrollAnchor(.bottom)
      }
      HStack {
        Spacer()
        Button("Cancel") { setup.cancel() }
      }
    }
  }

  private func elapsed(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    return String(format: "%d:%02d", s / 60, s % 60)
  }

  private func chooseISO() {
    let panel = NSOpenPanel()
    panel.title = "Choose your Fable II disc image"
    panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data]
    panel.allowsOtherFileTypes = true
    if panel.runModal() == .OK { iso = panel.url }
  }

  private func chooseLocation() {
    let panel = NSOpenPanel()
    panel.title = "Choose where to install the game"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Install Here"
    if panel.runModal() == .OK, let url = panel.url {
      location = url.lastPathComponent == "Project Spire" ? url : url.appendingPathComponent("Project Spire")
    }
  }
}

@main
struct ProjectSpireApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate

  var body: some Scene {
    Window("Project Spire", id: "main") {
      ContentView()
    }
    .windowResizability(.contentSize)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
