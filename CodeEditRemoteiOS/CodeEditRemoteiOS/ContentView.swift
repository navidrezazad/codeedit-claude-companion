//
//  ContentView.swift
//  CodeEditRemoteiOS
//
//  Created by Claude on 6/12/26.
//

import SwiftUI
import WebKit
import UIKit
import AVFoundation

// swiftlint:disable file_length

private enum TerminalDisplayMode: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case markdownStream = "MD"

    var id: Self {
        self
    }

    var showsInputBar: Bool {
        self != .markdownStream
    }
}

// swiftlint:disable:next type_body_length
struct ContentView: View {
    private enum AppTab: Hashable {
        case terminals
        case files
        case markdown
    }

    @StateObject private var client = RemoteTerminalClient()
    @State private var selectedTab = AppTab.terminals
    @State private var terminalDisplayMode = TerminalDisplayMode.terminal
    @State private var isShowingScanner = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if client.isAuthenticated {
                authenticatedTabs
            } else {
                NavigationStack {
                    connectionView
                        .navigationTitle("CodeEdit Remote")
                }
            }
        }
        .onAppear {
            client.startBrowsing()
            client.attemptAutoReconnect()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                client.endBackgroundKeepAlive()
                client.attemptAutoReconnect()
            case .background:
                client.beginBackgroundKeepAlive()
            default:
                break
            }
        }
        .onChange(of: client.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated {
                Haptics.success()
            }
        }
        .onOpenURL { url in
            client.handlePairingURL(url)
        }
    }

    private var authenticatedTabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                terminalView
                    .navigationTitle("Terminals")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                client.refreshSessions()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    }
            }
            .tabItem {
                Label("Terminals", systemImage: "terminal")
            }
            .tag(AppTab.terminals)

            NavigationStack {
                filesView
                    .navigationTitle(directoryTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button {
                                client.browseFiles()
                            } label: {
                                Image(systemName: "icloud")
                            }

                            Button {
                                client.browseFiles(path: client.currentDirectoryPath)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    }
            }
            .tabItem {
                Label("Files", systemImage: "folder")
            }
            .tag(AppTab.files)

            NavigationStack {
                markdownView
                    .navigationTitle(client.markdownDocument?.name ?? "Markdown")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem {
                Label("Markdown", systemImage: "doc.richtext")
            }
            .tag(AppTab.markdown)
        }
        .background(markdownRendererPrewarmView)
    }

    private var markdownRendererPrewarmView: some View {
        MarkdownWebView(markdown: "$$x$$")
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var connectionView: some View {
        List {
            Section {
                Button {
                    isShowingScanner = true
                } label: {
                    Label("Scan Pairing QR", systemImage: "qrcode.viewfinder")
                }
            } footer: {
                Text("Open CodeEditV2 ▸ Settings ▸ General on your Mac and scan the pairing QR to fill in the address and passcode automatically.")
            }

            Section("Local Network") {
                if client.hosts.isEmpty {
                    Label(client.statusMessage, systemImage: "network")
                        .foregroundStyle(.secondary)
                }

                ForEach(client.hosts) { host in
                    Button {
                        client.connect(to: host)
                    } label: {
                        Label(host.name, systemImage: "desktopcomputer")
                    }
                }

                TextField("Local IP or hostname", text: $client.localHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)

                TextField("Local port", text: $client.localPort)
                    .keyboardType(.numberPad)

                Button {
                    client.connectLocalDirect()
                } label: {
                    Label("Connect Local", systemImage: "wifi")
                }
                .disabled(client.localHost.isEmpty || client.localPort.isEmpty)
            }

            Section("Global IP") {
                TextField("Public IP or hostname", text: $client.globalHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)

                TextField("Public port", text: $client.globalPort)
                    .keyboardType(.numberPad)

                Button {
                    client.connectGlobalDirect()
                } label: {
                    Label("Connect Global", systemImage: "globe")
                }
                .disabled(client.globalHost.isEmpty || client.globalPort.isEmpty)
            }

            Section("Passcode") {
                SecureField("Mac passcode", text: $client.passcode)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    client.authenticate()
                } label: {
                    Label("Unlock", systemImage: "lock.open")
                }
                .disabled(!client.isConnected || client.passcode.isEmpty)
            }

            Section("Status") {
                Text(client.statusMessage)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $isShowingScanner) {
            pairingScannerSheet
        }
    }

    private var pairingScannerSheet: some View {
        NavigationStack {
            QRScannerView { code in
                isShowingScanner = false
                if let url = URL(string: code) {
                    Haptics.success()
                    client.handlePairingURL(url)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) {
                Text("Point the camera at the pairing QR on your Mac")
                    .font(.callout)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 24)
            }
            .navigationTitle("Scan Pairing QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        isShowingScanner = false
                    }
                }
            }
        }
    }

    private var terminalView: some View {
        VStack(spacing: 0) {
            terminalSessionStrip

            Divider()

            terminalModePicker

            Divider()

            terminalOutputPane
        }
        .safeAreaInset(edge: .bottom) {
            if terminalDisplayMode.showsInputBar {
                VStack(spacing: 0) {
                    Divider()
                    terminalKeyBar
                    Divider()
                    terminalInputBar
                }
                .background(Color(uiColor: .systemBackground))
            }
        }
    }

    private var terminalKeyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(TerminalControlKey.all) { key in
                    Button {
                        Haptics.tap()
                        client.sendInput(Data(key.bytes))
                    } label: {
                        Text(key.label)
                            .font(.caption.weight(.medium))
                            .frame(minWidth: 26)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(client.selectedSessionID == nil)
                    .accessibilityLabel(key.accessibilityLabel)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
    }

    private var terminalSessionStrip: some View {
        HStack(spacing: 8) {
            if client.sessions.isEmpty {
                Label("No Terminals", systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(client.sessions) { session in
                            terminalSessionButton(session)
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }

            Button {
                client.refreshSessions()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Refresh terminals")

            Button {
                client.disconnect()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Disconnect")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(uiColor: .systemBackground))
    }

    private var terminalModePicker: some View {
        Picker("Terminal mode", selection: $terminalDisplayMode) {
            ForEach(TerminalDisplayMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(uiColor: .systemBackground))
    }

    private var terminalOutputPane: some View {
        Group {
            switch terminalDisplayMode {
            case .terminal:
                TerminalMirrorView(
                    snapshot: client.terminalMirrorSnapshot,
                    session: client.selectedSession
                )
            case .markdownStream:
                MarkdownStreamAgentView(
                    document: client.markdownStreamDocument,
                    status: client.markdownStreamStatus,
                    statusDetail: client.markdownStreamStatusDetail,
                    isTruncated: client.markdownStreamIsTruncated,
                    session: client.selectedSession,
                    isActive: client.markdownStreamIsActive,
                    onTrigger: client.triggerMarkdownStreamUpdate,
                    onRewrite: client.rewriteMarkdownStream,
                    onStop: client.stopMarkdownStream
                )
                .onAppear {
                    client.ensureAutomaticMarkdownStream()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(Rectangle())
    }

    private func terminalSessionButton(_ session: TerminalRemoteProtocol.Session) -> some View {
        let isSelected = client.selectedSessionID == session.id

        return Button {
            client.attach(to: session)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(session.isRunning ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)

                    Text(session.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }

                Text(terminalSubtitle(for: session))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 136, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color(uiColor: .secondarySystemBackground))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var filesView: some View {
        List {
            Section {
                if client.currentDirectoryPath != nil {
                    Button {
                        client.browseParentDirectory()
                    } label: {
                        Label("..", systemImage: "arrow.up")
                    }
                }

                if client.files.isEmpty {
                    Label("No Files", systemImage: "folder")
                        .foregroundStyle(.secondary)
                }

                ForEach(client.files) { file in
                    Button {
                        client.open(file)
                        if file.isMarkdown {
                            selectedTab = .markdown
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Label(file.name, systemImage: iconName(for: file))
                                .lineLimit(1)

                            Spacer()

                            if file.isDirectory {
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var markdownView: some View {
        Group {
            if let document = client.markdownDocument {
                MarkdownWebView(markdown: document.markdown)
            } else {
                ContentUnavailableView("No Markdown File", systemImage: "doc.richtext")
                    .frame(maxWidth: .infinity, minHeight: 320)
            }
        }
    }

    private var directoryTitle: String {
        guard let path = client.currentDirectoryPath else {
            return "Files"
        }

        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func iconName(for file: TerminalRemoteProtocol.FileItem) -> String {
        if file.isDirectory {
            return "folder"
        }

        return file.isMarkdown ? "doc.richtext" : "doc"
    }

    private func terminalSubtitle(for session: TerminalRemoteProtocol.Session) -> String {
        let state = session.isRunning ? "Running" : "Ready"
        guard let currentDirectory = session.currentDirectory, !currentDirectory.isEmpty else {
            return state
        }

        let name = URL(fileURLWithPath: currentDirectory).lastPathComponent
        return name.isEmpty ? state : "\(state) - \(name)"
    }
}

private extension ContentView {
    var terminalInputBar: some View {
        HStack(spacing: 8) {
            TextField("Command", text: $client.pendingInput)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.return)
                .onSubmit {
                    submitTerminalInput()
                }

            Button {
                submitTerminalInput()
            } label: {
                Image(systemName: "return")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(client.pendingInput.isEmpty || client.selectedSessionID == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func submitTerminalInput() {
        client.sendPendingInput()
    }
}

// swiftlint:disable:next type_body_length
struct MarkdownWebView: UIViewRepresentable {
    let markdown: String
    var scrollsToBottom = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.scrollsToBottom = scrollsToBottom
        // Always load KaTeX. Detecting "does this contain math?" separately from the tokenizer that
        // actually extracts it meant the two could disagree for some delimiters (e.g. inline `$ x$`),
        // leaving KaTeX unloaded so equations silently fell back to raw text. Loading it unconditionally
        // keeps math rendering reliable; the assets are already bundled and prewarmed.
        let needsMath = true

        guard context.coordinator.renderedMarkdown != markdown
            || context.coordinator.loadedMathSupport != needsMath
        else {
            if scrollsToBottom {
                context.coordinator.scrollToBottomIfFollowing(in: webView)
            }
            return
        }

        let source = Self.javascriptStringLiteral(markdown)
        let renderID = context.coordinator.nextRenderID()
        context.coordinator.renderedMarkdown = markdown

        guard context.coordinator.hasLoadedInitialDocument,
              context.coordinator.loadedMathSupport == needsMath
        else {
            context.coordinator.hasLoadedInitialDocument = true
            context.coordinator.loadedMathSupport = needsMath
            webView.loadHTMLString(
                Self.htmlDocument(
                    for: markdown,
                    scrollsToBottom: scrollsToBottom,
                    loadsMath: needsMath,
                    renderID: renderID
                ),
                baseURL: nil
            )
            return
        }

        let script = """
        if (!window.latestMarkdownRenderID || \(renderID) >= window.latestMarkdownRenderID) {
          window.latestMarkdownRenderID = \(renderID);
          window.currentMarkdown = \(source);
          if (window.renderMarkdown) {
            window.renderMarkdown(window.currentMarkdown, \(scrollsToBottom ? "true" : "false"), \(renderID));
          }
        }
        """
        webView.evaluateJavaScript(script) { _, error in
            if error != nil {
                webView.loadHTMLString(
                    Self.htmlDocument(
                        for: markdown,
                        scrollsToBottom: scrollsToBottom,
                        loadsMath: needsMath,
                        renderID: renderID
                    ),
                    baseURL: nil
                )
                context.coordinator.loadedMathSupport = needsMath
            }
        }
    }

    private static func htmlDocument(
        for markdown: String,
        scrollsToBottom: Bool,
        loadsMath: Bool,
        renderID: Int = 0
    ) -> String {
        let source = javascriptStringLiteral(markdown)
        let shouldScrollToBottom = scrollsToBottom ? "true" : "false"

        return """
        <!doctype html>
        <html>
        \(markdownDocumentHead(loadsMath: loadsMath))
        <body>
          <article id="content"></article>
          \(markdownRuntimeScript(source: source, shouldScrollToBottom: shouldScrollToBottom, renderID: renderID))
        </body>
        </html>
        """
    }

    private static func markdownDocumentHead(loadsMath: Bool) -> String {
        let mathAssets = loadsMath ? """
          <style>
          \(MarkdownRendererAssets.katexCSS)
          </style>
          <script>
          \(MarkdownRendererAssets.katexJS)
          </script>
        """ : ""

        return """
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
      <script>
      \(MarkdownRendererAssets.markedJS)
      </script>
      <script>
      \(MarkdownRendererAssets.domPurifyJS)
      </script>
      \(mathAssets)
      <style>
        :root {
          color-scheme: light dark;
          font: -apple-system-body;
        }
        body {
          margin: 0;
          padding: 12px;
          color: CanvasText;
          background: Canvas;
          word-wrap: break-word;
        }
        article {
          max-width: 100%;
        }
        img, video {
          max-width: 100%;
          height: auto;
        }
        table {
          border-collapse: collapse;
          display: block;
          max-width: 100%;
          overflow-x: auto;
        }
        th, td {
          border: 1px solid color-mix(in srgb, CanvasText 22%, transparent);
          padding: 4px 6px;
        }
        pre {
          overflow-x: auto;
          padding: 10px;
          border-radius: 8px;
          background: color-mix(in srgb, CanvasText 8%, transparent);
        }
        code {
          font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: 0.92em;
        }
        blockquote {
          margin-left: 0;
          padding-left: 14px;
          border-left: 3px solid color-mix(in srgb, CanvasText 24%, transparent);
          color: color-mix(in srgb, CanvasText 72%, transparent);
        }
        .math-display {
          margin: 0.9em 0;
          max-width: 100%;
          overflow-x: auto;
          overflow-y: hidden;
        }
        .math-inline {
          display: inline-block;
          max-width: 100%;
          overflow-x: auto;
          vertical-align: middle;
        }
      </style>
    </head>
    """
    }

    // swiftlint:disable:next function_body_length
    private static func markdownRuntimeScript(
        source: String,
        shouldScrollToBottom: String,
        renderID: Int
    ) -> String {
        """
        <script>
        window.latestMarkdownRenderID = \(renderID);
        window.currentMarkdown = \(source);
        window.shouldScrollMarkdownToBottom = \(shouldScrollToBottom);
        window.markdownAutoFollow = true;
        const content = document.getElementById('content');

        function escapeHTML(value) {
          return value
            .replaceAll('&', '&amp;')
            .replaceAll('<', '&lt;')
            .replaceAll('>', '&gt;');
        }

        function isEscaped(value, index) {
          const slash = String.fromCharCode(92);
          let count = 0;
          for (let cursor = index - 1; cursor >= 0 && value[cursor] === slash; cursor -= 1) {
            count += 1;
          }
          return count % 2 === 1;
        }

        function findUnescaped(value, delimiter, startIndex) {
          let index = startIndex;
          while (index < value.length) {
            const matchIndex = value.indexOf(delimiter, index);
            if (matchIndex === -1) {
              return -1;
            }
            if (!isEscaped(value, matchIndex)) {
              return matchIndex;
            }
            index = matchIndex + delimiter.length;
          }
          return -1;
        }

        function findInlineDollar(value, startIndex) {
          let index = startIndex;
          while (index < value.length) {
            const lineBreak = value.indexOf('\\n', index);
            const matchIndex = value.indexOf('$', index);
            if (matchIndex === -1 || (lineBreak !== -1 && lineBreak < matchIndex)) {
              return -1;
            }
            if (!isEscaped(value, matchIndex)) {
              return matchIndex;
            }
            index = matchIndex + 1;
          }
          return -1;
        }

        function looksLikeInlineMath(value) {
          const source = value.trim();
          if (!source || source.includes('\\n')) {
            return false;
          }
          const signals = ['\\\\', '_', '^', '=', '+', '-', '*', '/', '<', '>', '|', '{', '}'];
          return /^[A-Za-z][A-Za-z0-9]*$/.test(source)
            || /^[-+]?\\d+(\\.\\d+)?$/.test(source)
            || signals.some((signal) => source.includes(signal));
        }

        function closingFenceEndIndex(value, startIndex, fenceChar, minLength) {
          let lineStart = value.indexOf('\\n', startIndex);
          if (lineStart === -1) {
            return -1;
          }
          lineStart += 1;

          while (lineStart < value.length) {
            const lineEnd = value.indexOf('\\n', lineStart);
            const end = lineEnd === -1 ? value.length : lineEnd;
            const line = value.slice(lineStart, end);
            let cursor = 0;
            while (cursor < line.length && line[cursor] === ' ') {
              cursor += 1;
            }
            if (cursor <= 3) {
              let count = 0;
              while (cursor + count < line.length && line[cursor + count] === fenceChar) {
                count += 1;
              }
              if (count >= minLength && line.slice(cursor + count).trim() === '') {
                return lineEnd === -1 ? value.length : lineEnd + 1;
              }
            }
            if (lineEnd === -1) {
              return -1;
            }
            lineStart = lineEnd + 1;
          }

          return -1;
        }

        function protectMath(source) {
          const slash = String.fromCharCode(92);
          const math = [];
          let output = '';
          let index = 0;

          function addMath(kind, value) {
            const token = '@@CODEEDITV2MATH' + math.length + '@@';
            math.push({ token: token, kind: kind, value: value.trim() });
            return token;
          }

          while (index < source.length) {
            const atLineStart = index === 0 || source[index - 1] === '\\n';
            if (atLineStart) {
              const lineEnd = source.indexOf('\\n', index);
              const end = lineEnd === -1 ? source.length : lineEnd;
              const line = source.slice(index, end);
              const trimmedLeft = line.replace(/^ {0,3}/, '');
              if (trimmedLeft.startsWith('```') || trimmedLeft.startsWith('~~~')) {
                const fenceChar = trimmedLeft[0];
                let fenceLength = 0;
                while (fenceLength < trimmedLeft.length && trimmedLeft[fenceLength] === fenceChar) {
                  fenceLength += 1;
                }
                const fenceEnd = closingFenceEndIndex(source, end, fenceChar, fenceLength);
                const copyEnd = fenceEnd === -1 ? source.length : fenceEnd;
                output += source.slice(index, copyEnd);
                index = copyEnd;
                continue;
              }
            }

            if (source[index] === '`') {
              let tickCount = 0;
              while (index + tickCount < source.length && source[index + tickCount] === '`') {
                tickCount += 1;
              }
              const delimiter = '`'.repeat(tickCount);
              const end = source.indexOf(delimiter, index + tickCount);
              if (end !== -1) {
                output += source.slice(index, end + tickCount);
                index = end + tickCount;
                continue;
              }
            }

            if (source.startsWith('$$', index) && !isEscaped(source, index)) {
              const end = findUnescaped(source, '$$', index + 2);
              if (end !== -1) {
                const token = addMath('display', source.slice(index + 2, end));
                if (output.length > 0 && !output.endsWith('\\n\\n')) {
                  output += '\\n\\n';
                }
                output += token + '\\n\\n';
                index = end + 2;
                continue;
              }
            }

            if (source.startsWith(slash + '[', index) && !isEscaped(source, index)) {
              const end = findUnescaped(source, slash + ']', index + 2);
              if (end !== -1) {
                const token = addMath('display', source.slice(index + 2, end));
                if (output.length > 0 && !output.endsWith('\\n\\n')) {
                  output += '\\n\\n';
                }
                output += token + '\\n\\n';
                index = end + 2;
                continue;
              }
            }

            if (source.startsWith(slash + '(', index) && !isEscaped(source, index)) {
              const end = findUnescaped(source, slash + ')', index + 2);
              if (end !== -1) {
                output += addMath('inline', source.slice(index + 2, end));
                index = end + 2;
                continue;
              }
            }

            if (
              source[index] === '$' &&
              source[index + 1] !== '$' &&
              source[index + 1] !== '\\n' &&
              !isEscaped(source, index)
            ) {
              const end = findInlineDollar(source, index + 1);
              const mathSource = end === -1 ? '' : source.slice(index + 1, end);
              if (end !== -1 && looksLikeInlineMath(mathSource)) {
                output += addMath('inline', mathSource);
                index = end + 1;
                continue;
              }
            }

            output += source[index];
            index += 1;
          }

          return { markdown: output, math: math };
        }

        function renderedMath(entry) {
          const slash = String.fromCharCode(92);
          const escaped = escapeHTML(entry.value);
          if (window.katex) {
            return katex.renderToString(entry.value, {
              displayMode: entry.kind === 'display',
              throwOnError: false,
              strict: 'ignore',
              trust: false
            });
          }

          if (entry.kind === 'display') {
            return '<div class="math-display">' + slash + '[' + escaped + slash + ']' + '</div>';
          }
          return '<span class="math-inline">' + slash + '(' + escaped + slash + ')' + '</span>';
        }

        function restoreMath(html, math) {
          let restored = html;
          for (const entry of math) {
            const rendered = renderedMath(entry);
            restored = restored.split('<p>' + entry.token + '</p>').join(rendered);
            restored = restored.split(entry.token).join(rendered);
          }
          return restored;
        }

        function isNearMarkdownBottom() {
          const height = Math.max(document.body.scrollHeight, document.documentElement.scrollHeight);
          const viewportBottom = window.scrollY + window.innerHeight;
          return height - viewportBottom < 96;
        }

        window.addEventListener('scroll', () => {
          window.markdownAutoFollow = isNearMarkdownBottom();
        }, { passive: true });

        window.scrollMarkdownToBottom = function() {
          window.markdownAutoFollow = true;
          requestAnimationFrame(() => {
            requestAnimationFrame(() => {
              const height = Math.max(document.body.scrollHeight, document.documentElement.scrollHeight);
              window.scrollTo(0, height);
            });
          });
        }

        window.scrollMarkdownToBottomIfFollowing = function() {
          if (window.markdownAutoFollow !== false) {
            window.scrollMarkdownToBottom();
          }
        }

        window.renderMarkdown = function(source, scrollToBottom = false, renderID = 0) {
          if (renderID < window.latestMarkdownRenderID) {
            return;
          }
          window.latestMarkdownRenderID = renderID;
          const shouldFollowBottom = scrollToBottom && window.markdownAutoFollow !== false;
          const protectedSource = protectMath(source);
          let html = '';

          if (window.marked) {
            marked.setOptions({ gfm: true, breaks: false });
            html = marked.parse(protectedSource.markdown);
          } else {
            html = '<pre>' + escapeHTML(protectedSource.markdown) + '</pre>';
          }

          const sanitizeOptions = {
            ADD_ATTR: ['target', 'rel'],
            ALLOW_DATA_ATTR: false
          };
          const sanitized = window.DOMPurify
            ? DOMPurify.sanitize(html, sanitizeOptions)
            : '<pre>' + escapeHTML(protectedSource.markdown) + '</pre>';
          const restored = restoreMath(sanitized, protectedSource.math);
          content.innerHTML = window.DOMPurify
            ? DOMPurify.sanitize(restored, sanitizeOptions)
            : sanitized;
          content.querySelectorAll('a[href]').forEach((anchor) => {
            anchor.target = '_blank';
            anchor.rel = 'noopener noreferrer';
          });

          const finish = () => {
            if (shouldFollowBottom) {
              window.scrollMarkdownToBottom();
            }
          };

          requestAnimationFrame(finish);
        }

        window.renderMarkdown(window.currentMarkdown, window.shouldScrollMarkdownToBottom, window.latestMarkdownRenderID);
        </script>
        """
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "\"\""
        }

        return string
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var renderedMarkdown: String?
        var hasLoadedInitialDocument = false
        var loadedMathSupport = false
        var scrollsToBottom = false
        private var renderID = 0

        func nextRenderID() -> Int {
            renderID += 1
            return renderID
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if scrollsToBottom {
                scrollToBottomIfFollowing(in: webView)
            }
        }

        /// WebKit jettisons the web content process while the Markdown tab is offscreen (e.g. after
        /// switching to the Files or Terminal tab), which leaves the web view blank. The early-return
        /// in `updateUIView` would otherwise keep it blank because the coordinator still believes it
        /// rendered this Markdown. Reload the last rendered document so the tab restores its content.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard let markdown = renderedMarkdown else {
                return
            }

            let nextID = nextRenderID()
            hasLoadedInitialDocument = true
            webView.loadHTMLString(
                MarkdownWebView.htmlDocument(
                    for: markdown,
                    scrollsToBottom: scrollsToBottom,
                    loadsMath: loadedMathSupport,
                    renderID: nextID
                ),
                baseURL: nil
            )
        }

        func scrollToBottomIfFollowing(in webView: WKWebView) {
            let script = """
            if (window.scrollMarkdownToBottomIfFollowing) {
              window.scrollMarkdownToBottomIfFollowing();
            } else if (window.markdownAutoFollow !== false) {
              window.scrollTo(0, Math.max(document.body.scrollHeight, document.documentElement.scrollHeight));
            }
            """
            webView.evaluateJavaScript(script)
        }

        func scrollToBottom(in webView: WKWebView) {
            let script = """
            if (window.scrollMarkdownToBottom) {
                window.scrollMarkdownToBottom();
            } else {
                window.scrollTo(0, Math.max(document.body.scrollHeight, document.documentElement.scrollHeight));
            }
            """
            webView.evaluateJavaScript(script)
        }
    }
}

#Preview {
    ContentView()
}

/// A control/special key sent to the terminal as raw bytes through the normal input path.
private struct TerminalControlKey: Identifiable {
    let label: String
    let bytes: [UInt8]
    let accessibilityLabel: String

    var id: String { label }

    static let all: [TerminalControlKey] = [
        .init(label: "esc", bytes: [0x1B], accessibilityLabel: "Escape"),
        .init(label: "tab", bytes: [0x09], accessibilityLabel: "Tab"),
        .init(label: "⌃C", bytes: [0x03], accessibilityLabel: "Control C"),
        .init(label: "⌃D", bytes: [0x04], accessibilityLabel: "Control D"),
        .init(label: "⌃Z", bytes: [0x1A], accessibilityLabel: "Control Z"),
        .init(label: "⌃L", bytes: [0x0C], accessibilityLabel: "Clear screen"),
        .init(label: "↑", bytes: [0x1B, 0x5B, 0x41], accessibilityLabel: "Up arrow"),
        .init(label: "↓", bytes: [0x1B, 0x5B, 0x42], accessibilityLabel: "Down arrow"),
        .init(label: "←", bytes: [0x1B, 0x5B, 0x44], accessibilityLabel: "Left arrow"),
        .init(label: "→", bytes: [0x1B, 0x5B, 0x43], accessibilityLabel: "Right arrow")
    ]
}

/// Lightweight haptic feedback helpers for connection and key events.
enum Haptics {
    static func tap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }
}

/// A minimal AVFoundation-backed QR scanner that reports the first decoded string value.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onCode: (String) -> Void
        private var didEmit = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !didEmit,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  object.type == .qr,
                  let value = object.stringValue else {
                return
            }

            didEmit = true
            DispatchQueue.main.async { [onCode] in
                onCode(value)
            }
        }
    }

    final class ScannerViewController: UIViewController {
        weak var coordinator: Coordinator?

        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            requestAccessAndConfigure()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            stopSession()
        }

        private func requestAccessAndConfigure() {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configureSession()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    guard granted else {
                        return
                    }
                    DispatchQueue.main.async {
                        self?.configureSession()
                    }
                }
            default:
                break
            }
        }

        private func configureSession() {
            guard previewLayer == nil,
                  let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                return
            }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(coordinator, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            previewLayer = layer

            startSession()
        }

        private func startSession() {
            guard !session.isRunning else {
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }

        private func stopSession() {
            guard session.isRunning else {
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.stopRunning()
            }
        }
    }
}
