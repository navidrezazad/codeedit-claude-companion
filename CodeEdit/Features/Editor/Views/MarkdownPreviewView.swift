//
//  MarkdownPreviewView.swift
//  CodeEdit
//
//  Created by Claude on 01/05/2026.
//

// swiftlint:disable file_length

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

private let markdownPreviewTextDebounce: DispatchTimeInterval = .milliseconds(120)
private let markdownPreviewLargeDocumentDebounce: DispatchTimeInterval = .milliseconds(700)
private let markdownPreviewHugeDocumentDebounce: DispatchTimeInterval = .milliseconds(1_800)
private let markdownPreviewRenderDebounce: DispatchTimeInterval = .milliseconds(80)
private let markdownPreviewLargeDocumentLength = 1_000_000
private let markdownPreviewHugeDocumentLength = 5_000_000
private let markdownResourceScheme = "codeedit-md-resource"

struct MarkdownPreviewView: View {
    @ObservedObject private var codeFile: CodeFileDocument
    @Environment(\.colorScheme)
    private var colorScheme
    @State private var markdownText: String
    @State private var needsRender = false
    @State private var refreshWorkItem: DispatchWorkItem?
    private let isActive: Bool

    init(codeFile: CodeFileDocument, isActive: Bool = true) {
        self.codeFile = codeFile
        self.isActive = isActive
        self._markdownText = State(initialValue: codeFile.content?.string ?? "")
    }

    private var baseURL: URL? {
        codeFile.fileURL?.deletingLastPathComponent()
    }

    var body: some View {
        MarkdownWebView(
            markdown: markdownText,
            baseURL: baseURL,
            colorScheme: colorScheme,
            isRenderingEnabled: isActive
        )
        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(codeFile.contentCoordinator.textUpdatePublisher) { _ in
            refreshMarkdownIfActive()
        }
        .onChange(of: codeFile.fileURL) { _, _ in
            refreshMarkdownIfActive(immediate: true)
        }
        .onChange(of: isActive) { _, active in
            guard active else {
                cancelScheduledRefresh()
                return
            }

            if needsRender {
                refreshMarkdown()
            }
        }
        .onDisappear {
            cancelScheduledRefresh()
        }
    }

    private var markdownRefreshDebounce: DispatchTimeInterval {
        let documentLength = codeFile.content?.length ?? markdownText.utf16.count

        if documentLength >= markdownPreviewHugeDocumentLength {
            return markdownPreviewHugeDocumentDebounce
        }

        if documentLength >= markdownPreviewLargeDocumentLength {
            return markdownPreviewLargeDocumentDebounce
        }

        return markdownPreviewTextDebounce
    }

    private func refreshMarkdownIfActive(immediate: Bool = false) {
        guard isActive else {
            needsRender = true
            cancelScheduledRefresh()
            return
        }

        if immediate {
            refreshMarkdown()
        } else {
            scheduleMarkdownRefresh()
        }
    }

    private func scheduleMarkdownRefresh() {
        cancelScheduledRefresh()

        let workItem = DispatchWorkItem {
            refreshMarkdown()
        }

        refreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + markdownRefreshDebounce,
            execute: workItem
        )
    }

    private func cancelScheduledRefresh() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
    }

    private func refreshMarkdown() {
        cancelScheduledRefresh()

        let latestMarkdown = codeFile.content?.string ?? ""
        if markdownText != latestMarkdown {
            markdownText = latestMarkdown
        }
        needsRender = false
    }
}

struct MarkdownRenderPayload: Codable, Equatable {
    let markdown: String
    let baseURL: String?
    let colorScheme: String
    let useResourceScheme: Bool
}

private struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    let baseURL: URL?
    let colorScheme: ColorScheme
    let isRenderingEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(
            MarkdownResourceSchemeHandler(),
            forURLScheme: markdownResourceScheme
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        webView.loadHTMLString(markdownPreviewHTML(), baseURL: baseURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let payload = MarkdownRenderPayload(
            markdown: markdown,
            baseURL: baseURL?.absoluteString,
            colorScheme: colorScheme == .dark ? "dark" : "light",
            useResourceScheme: true
        )

        guard isRenderingEnabled else {
            context.coordinator.deferRender(payload)
            return
        }

        context.coordinator.render(
            payload,
            in: webView
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var didLoadPage = false
        private var pendingPayload: MarkdownRenderPayload?
        private var renderedPayload: MarkdownRenderPayload?
        private var renderWorkItem: DispatchWorkItem?
        private var renderGeneration = 0
        private var renderingEnabled = true

        func render(_ payload: MarkdownRenderPayload, in webView: WKWebView) {
            renderingEnabled = true
            pendingPayload = payload

            guard didLoadPage else {
                return
            }

            guard payload != renderedPayload else {
                renderWorkItem?.cancel()
                renderWorkItem = nil
                return
            }

            scheduleRender(in: webView)
        }

        private func scheduleRender(in webView: WKWebView) {
            renderWorkItem?.cancel()
            renderGeneration += 1
            let generation = renderGeneration

            let workItem = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView, self.renderGeneration == generation else {
                    return
                }

                self.renderPendingPayload(in: webView)
            }

            renderWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + markdownPreviewRenderDebounce,
                execute: workItem
            )
        }

        private func renderPendingPayload(in webView: WKWebView) {
            renderWorkItem?.cancel()
            renderWorkItem = nil

            guard let payload = pendingPayload, payload != renderedPayload else {
                return
            }

            guard
                let data = try? JSONEncoder().encode(payload),
                let json = String(data: data, encoding: .utf8)
            else {
                return
            }

            renderedPayload = payload
            webView.evaluateJavaScript("window.renderMarkdown(\(json));")
        }

        func deferRender(_ payload: MarkdownRenderPayload) {
            renderingEnabled = false
            pendingPayload = payload
            renderWorkItem?.cancel()
            renderWorkItem = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didLoadPage = true
            guard renderingEnabled else {
                return
            }
            renderPendingPayload(in: webView)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                if let scheme = url.scheme?.lowercased(),
                   ["file", "http", "https", "mailto"].contains(scheme) {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }
}

private final class MarkdownResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    private let fileQueue = DispatchQueue(
        label: "app.codeedit.markdown-preview.resource-handler",
        qos: .userInitiated
    )
    private var activeTasks = Set<ObjectIdentifier>()
    private let lock = NSLock()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        lock.lock()
        activeTasks.insert(taskID)
        lock.unlock()

        guard let requestURL = urlSchemeTask.request.url,
              let fileURL = Self.resolveFileURL(from: requestURL) else {
            fail(taskID: taskID, task: urlSchemeTask, with: URLError(.badURL))
            return
        }

        fileQueue.async { [weak self] in
            guard let self else { return }
            do {
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                let response = URLResponse(
                    url: requestURL,
                    mimeType: Self.mimeType(for: fileURL),
                    expectedContentLength: data.count,
                    textEncodingName: nil
                )
                DispatchQueue.main.async {
                    self.complete(taskID: taskID, task: urlSchemeTask, response: response, data: data)
                }
            } catch {
                DispatchQueue.main.async {
                    self.fail(taskID: taskID, task: urlSchemeTask, with: error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.lock()
        activeTasks.remove(ObjectIdentifier(urlSchemeTask))
        lock.unlock()
    }

    private func complete(
        taskID: ObjectIdentifier,
        task: WKURLSchemeTask,
        response: URLResponse,
        data: Data
    ) {
        lock.lock()
        let wasActive = activeTasks.remove(taskID) != nil
        lock.unlock()
        guard wasActive else { return }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(taskID: ObjectIdentifier, task: WKURLSchemeTask, with error: Error) {
        lock.lock()
        let wasActive = activeTasks.remove(taskID) != nil
        lock.unlock()
        guard wasActive else { return }
        task.didFailWithError(error)
    }

    private static func resolveFileURL(from url: URL) -> URL? {
        let path = url.path
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}

enum MarkdownPreviewExporter {
    static func exportHTML(markdown: String, sourceURL: URL?) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.html]
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = defaultExportName(for: sourceURL)

        guard savePanel.runModal() == .OK, let destinationURL = savePanel.url else {
            return
        }

        do {
            try standaloneHTML(markdown: markdown, sourceURL: sourceURL)
                .write(to: destinationURL, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private static func standaloneHTML(markdown: String, sourceURL: URL?) -> String {
        markdownPreviewHTML(
            autorenderPayload: MarkdownRenderPayload(
                markdown: markdown,
                baseURL: sourceURL?.deletingLastPathComponent().absoluteString,
                colorScheme: "light",
                useResourceScheme: false
            )
        )
    }

    private static func defaultExportName(for sourceURL: URL?) -> String {
        guard let sourceURL else {
            return "Markdown Preview.html"
        }

        return sourceURL.deletingPathExtension().lastPathComponent + ".html"
    }
}

private let markdownPreviewContentSecurityPolicy = [
    "default-src 'none'",
    "img-src 'self' file: data: \(markdownResourceScheme):",
    "media-src 'self' file: data: \(markdownResourceScheme):",
    "style-src 'unsafe-inline'",
    "script-src 'unsafe-inline'",
    "font-src data:",
    "connect-src 'none'",
    "frame-src 'none'",
    "object-src 'none'",
    "base-uri 'none'",
    "form-action 'none'"
].joined(separator: "; ")

// swiftlint:disable:next function_body_length
private func markdownPreviewHTML(autorenderPayload: MarkdownRenderPayload? = nil) -> String {
    """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="\(markdownPreviewContentSecurityPolicy)">
      <style>
        \(MarkdownRendererAssets.katexCSS)

        :root {
          color-scheme: light dark;
          --background: #ffffff;
          --foreground: #1f2328;
          --muted: #6e7781;
          --border: #d0d7de;
          --code-background: #f6f8fa;
          --blockquote-border: #d0d7de;
          --link: #0969da;
        }

        :root[data-color-scheme="dark"] {
          --background: #1e1e1e;
          --foreground: #d4d4d4;
          --muted: #8b949e;
          --border: #30363d;
          --code-background: #2d2d2d;
          --blockquote-border: #3d444d;
          --link: #58a6ff;
        }

        html, body {
          min-height: 100%;
          margin: 0;
          background: var(--background);
          color: var(--foreground);
          font: -apple-system-body;
        }

        body {
          overflow-wrap: break-word;
        }

        .markdown-body {
          box-sizing: border-box;
          max-width: 960px;
          min-width: 200px;
          margin: 0 auto;
          padding: 24px;
          line-height: 1.55;
        }

        h1, h2, h3, h4, h5, h6 {
          margin: 24px 0 16px;
          line-height: 1.25;
        }

        h1, h2 {
          padding-bottom: 0.3em;
          border-bottom: 1px solid var(--border);
        }

        p, blockquote, ul, ol, dl, table, pre, details {
          margin-top: 0;
          margin-bottom: 16px;
        }

        a {
          color: var(--link);
          text-decoration: none;
        }

        a:hover {
          text-decoration: underline;
        }

        blockquote {
          padding: 0 1em;
          color: var(--muted);
          border-left: 0.25em solid var(--blockquote-border);
        }

        code {
          padding: 0.2em 0.4em;
          border-radius: 4px;
          background: var(--code-background);
          font: 85% ui-monospace, SFMono-Regular, SF Mono, Menlo, Consolas, monospace;
        }

        pre {
          overflow: auto;
          padding: 16px;
          border-radius: 6px;
          background: var(--code-background);
        }

        pre code {
          padding: 0;
          background: transparent;
          font-size: 100%;
        }

        table {
          border-spacing: 0;
          border-collapse: collapse;
          display: block;
          width: max-content;
          max-width: 100%;
          overflow: auto;
        }

        th, td {
          padding: 6px 13px;
          border: 1px solid var(--border);
        }

        tr:nth-child(2n) {
          background: color-mix(in srgb, var(--code-background) 70%, transparent);
        }

        img {
          max-width: 100%;
          height: auto;
        }

        .blocked-remote-resource {
          display: block;
          margin: 0 0 16px;
          padding: 10px 12px;
          border: 1px dashed var(--border);
          border-radius: 6px;
          color: var(--muted);
          background: var(--code-background);
          font: 12px ui-monospace, SFMono-Regular, SF Mono, Menlo, Consolas, monospace;
        }

        .katex-display {
          overflow-x: auto;
          overflow-y: hidden;
          padding: 4px 0;
        }

        .renderer-status {
          box-sizing: border-box;
          margin: 16px 24px 0;
          padding: 10px 12px;
          border: 1px solid var(--border);
          border-radius: 6px;
          color: var(--muted);
          background: var(--code-background);
          font: 12px ui-monospace, SFMono-Regular, SF Mono, Menlo, Consolas, monospace;
        }
      </style>
    </head>
    <body>
      <div id="renderer-status" class="renderer-status" hidden></div>
      <article id="content" class="markdown-body"></article>
      <script>
        \(MarkdownRendererAssets.markedJS)
      </script>
      <script>
        \(MarkdownRendererAssets.domPurifyJS)
      </script>
      <script>
        \(MarkdownRendererAssets.katexJS)
      </script>
      <script>
        const content = document.getElementById("content");
        const rendererStatus = document.getElementById("renderer-status");
        let latestPayload = null;
        let pendingRender = null;
        let dependencyRetryCount = 0;
        const maxDependencyRetries = 100;

        if (window.marked) {
          marked.use({
            gfm: true,
            breaks: false
          });
        }

        const MARKDOWN_RESOURCE_SCHEME = "\(markdownResourceScheme)";

        function isAbsoluteURL(value) {
          return /^[a-z][a-z0-9+.-]*:/i.test(value);
        }

        function isRemoteURL(value) {
          return /^https?:\\/\\//i.test(value);
        }

        function toResourceURL(fileURLString) {
          return MARKDOWN_RESOURCE_SCHEME + ":" + fileURLString.substring("file:".length);
        }

        function blockRemoteImages() {
          content.querySelectorAll("img[src]").forEach((image) => {
            const source = image.getAttribute("src");
            if (!source || !isRemoteURL(source)) {
              return;
            }

            const placeholder = document.createElement("span");
            placeholder.className = "blocked-remote-resource";
            placeholder.textContent = "Remote image blocked: " + source;
            image.replaceWith(placeholder);
          });
        }

        function rewriteRelativeURLs(baseURL, useResourceScheme) {
          if (!baseURL) {
            return;
          }

          content.querySelectorAll("img[src]").forEach((image) => {
            const source = image.getAttribute("src");
            if (!source) {
              return;
            }

            let resolved;
            if (isAbsoluteURL(source)) {
              if (/^file:/i.test(source)) {
                resolved = source;
              } else {
                return;
              }
            } else {
              resolved = new URL(source, baseURL).href;
            }

            if (useResourceScheme && /^file:/i.test(resolved)) {
              image.src = toResourceURL(resolved);
            } else {
              image.src = resolved;
            }
          });

          content.querySelectorAll("a[href]").forEach((anchor) => {
            const href = anchor.getAttribute("href");
            if (href && !href.startsWith("#") && !isAbsoluteURL(href)) {
              anchor.href = new URL(href, baseURL).href;
            }
          });
        }

        function isEscaped(source, index) {
          let slashCount = 0;
          let position = index - 1;

          while (position >= 0 && source[position] === "\\\\") {
            slashCount += 1;
            position -= 1;
          }

          return slashCount % 2 === 1;
        }

        function isLineStart(source, index) {
          return index === 0 || source[index - 1] === "\\n";
        }

        function readFence(source, index) {
          if (!isLineStart(source, index)) {
            return null;
          }

          const match = source.slice(index).match(/^( {0,3})(`{3,}|~{3,})/);
          if (!match) {
            return null;
          }

          return match[2];
        }

        function findClosing(source, start, delimiter) {
          let index = start;

          while (index < source.length) {
            const match = source.indexOf(delimiter, index);
            if (match === -1) {
              return -1;
            }

            if (!isEscaped(source, match)) {
              return match;
            }

            index = match + delimiter.length;
          }

          return -1;
        }

        function findClosingDollar(source, start) {
          let index = start;

          while (index < source.length) {
            const lineBreak = source.indexOf("\\n", index);
            const match = source.indexOf("$", index);
            if (match === -1 || (lineBreak !== -1 && lineBreak < match)) {
              return -1;
            }

            if (!isEscaped(source, match)) {
              return match;
            }

            index = match + 1;
          }

          return -1;
        }

        function readMathEnvironment(source, index) {
          const match = source.slice(index).match(/^\\\\begin\\{([A-Za-z]+\\*?)\\}/);
          if (!match) {
            return null;
          }

          const environment = match[1];
          const closingDelimiter = "\\\\end{" + environment + "}";
          const end = findClosing(source, index + match[0].length, closingDelimiter);
          if (end === -1) {
            return null;
          }

          return {
            source: source.slice(index, end + closingDelimiter.length).trim(),
            endIndex: end + closingDelimiter.length
          };
        }

        function looksLikeInlineMath(source) {
          const value = source.trim();
          if (!value || value.includes("\\n")) {
            return false;
          }

          const mathSignals = ["\\\\", "_", "^", "=", "+", "-", "*", "/", "<", ">", "|", "{", "}"];
          return /^[A-Za-z][A-Za-z0-9]*$/.test(value)
            || /^[-+]?\\d+(\\.\\d+)?$/.test(value)
            || mathSignals.some((signal) => value.includes(signal));
        }

        function pushMathToken(mathItems, source, displayMode) {
          const token = "%%CODEEDIT_MATH_" + mathItems.length + "%%";
          mathItems.push({ source, displayMode });
          return token;
        }

        function protectMath(markdown) {
          const mathItems = [];
          let protectedMarkdown = "";
          let index = 0;
          let codeFence = null;

          while (index < markdown.length) {
            const fence = readFence(markdown, index);
            if (fence) {
              if (codeFence && fence[0] === codeFence[0] && fence.length >= codeFence.length) {
                codeFence = null;
              } else if (!codeFence) {
                codeFence = fence;
              }

              protectedMarkdown += fence;
              index += fence.length;
              continue;
            }

            if (codeFence) {
              protectedMarkdown += markdown[index];
              index += 1;
              continue;
            }

            if (markdown[index] === "`") {
              const match = markdown.slice(index).match(/^`+/);
              const marker = match[0];
              const end = markdown.indexOf(marker, index + marker.length);

              if (end !== -1) {
                protectedMarkdown += markdown.slice(index, end + marker.length);
                index = end + marker.length;
                continue;
              }
            }

            if (markdown.startsWith("$$", index)) {
              const end = findClosing(markdown, index + 2, "$$");
              if (end !== -1) {
                protectedMarkdown += pushMathToken(mathItems, markdown.slice(index + 2, end).trim(), true);
                index = end + 2;
                continue;
              }
            }

            if (markdown.startsWith("\\\\[", index)) {
              const end = findClosing(markdown, index + 2, "\\\\]");
              if (end !== -1) {
                protectedMarkdown += pushMathToken(mathItems, markdown.slice(index + 2, end).trim(), true);
                index = end + 2;
                continue;
              }
            }

            if (markdown.startsWith("\\\\(", index)) {
              const end = findClosing(markdown, index + 2, "\\\\)");
              if (end !== -1) {
                protectedMarkdown += pushMathToken(mathItems, markdown.slice(index + 2, end).trim(), false);
                index = end + 2;
                continue;
              }
            }

            const mathEnvironment = readMathEnvironment(markdown, index);
            if (mathEnvironment) {
              protectedMarkdown += pushMathToken(mathItems, mathEnvironment.source, true);
              index = mathEnvironment.endIndex;
              continue;
            }

            if (
              markdown[index] === "$" &&
              markdown[index + 1] !== "$" &&
              markdown[index + 1] !== "\\n"
            ) {
              const end = findClosingDollar(markdown, index + 1);
              const mathSource = end === -1 ? "" : markdown.slice(index + 1, end).trim();
              if (end !== -1 && looksLikeInlineMath(mathSource)) {
                protectedMarkdown += pushMathToken(mathItems, mathSource, false);
                index = end + 1;
                continue;
              }
            }

            protectedMarkdown += markdown[index];
            index += 1;
          }

          return { protectedMarkdown, mathItems };
        }

        function replaceMathPlaceholders(mathItems) {
          const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
          const replacements = [];
          const pattern = /%%CODEEDIT_MATH_(\\d+)%%/g;

          while (walker.nextNode()) {
            const node = walker.currentNode;
            if (pattern.test(node.nodeValue)) {
              replacements.push(node);
            }
            pattern.lastIndex = 0;
          }

          replacements.forEach((node) => {
            const fragment = document.createDocumentFragment();
            let lastIndex = 0;

            node.nodeValue.replace(pattern, (match, indexText, offset) => {
              if (offset > lastIndex) {
                fragment.appendChild(document.createTextNode(node.nodeValue.slice(lastIndex, offset)));
              }

              const item = mathItems[Number(indexText)];
              const span = document.createElement(item.displayMode ? "div" : "span");
              span.className = item.displayMode ? "math-block" : "math-inline";

              if (window.katex) {
                span.innerHTML = katex.renderToString(item.source, {
                  displayMode: item.displayMode,
                  throwOnError: false,
                  strict: "ignore"
                });
              } else {
                span.textContent = item.source;
              }

              fragment.appendChild(span);
              lastIndex = offset + match.length;
            });

            if (lastIndex < node.nodeValue.length) {
              fragment.appendChild(document.createTextNode(node.nodeValue.slice(lastIndex)));
            }

            node.parentNode.replaceChild(fragment, node);
          });
        }

        function setRendererStatus(message) {
          if (!message) {
            rendererStatus.hidden = true;
            rendererStatus.textContent = "";
            return;
          }

          rendererStatus.hidden = false;
          rendererStatus.textContent = message;
        }

        function missingDependencies() {
          const missing = [];
          if (!window.marked) {
            missing.push("marked");
          }

          if (!window.DOMPurify) {
            missing.push("DOMPurify");
          }

          if (!window.katex) {
            missing.push("KaTeX");
          }

          return missing;
        }

        function dependenciesReady() {
          return window.marked && window.DOMPurify && window.katex;
        }

        function currentScrollProgress() {
          const scrollableHeight = document.documentElement.scrollHeight - window.innerHeight;
          if (scrollableHeight <= 0) {
            return 0;
          }

          return window.scrollY / scrollableHeight;
        }

        function restoreScrollProgress(progress) {
          const scrollableHeight = document.documentElement.scrollHeight - window.innerHeight;
          if (scrollableHeight <= 0) {
            return;
          }

          const nextScrollY = Math.max(0, Math.min(scrollableHeight, scrollableHeight * progress));
          window.scrollTo(0, nextScrollY);
        }

        function renderLatestPayload() {
          if (!latestPayload) {
            return;
          }

          if (!dependenciesReady()) {
            dependencyRetryCount += 1;

            if (dependencyRetryCount >= maxDependencyRetries) {
              setRendererStatus(
                "Markdown preview could not load renderer assets: " + missingDependencies().join(", ")
              );
              content.textContent = latestPayload.markdown || "";
              return;
            }

            setRendererStatus("Loading Markdown preview...");

            if (!pendingRender) {
              pendingRender = window.setTimeout(() => {
                pendingRender = null;
                renderLatestPayload();
              }, 100);
            }

            return;
          }

          dependencyRetryCount = 0;
          setRendererStatus(null);
          document.documentElement.dataset.colorScheme = latestPayload.colorScheme;

          const previousScrollProgress = currentScrollProgress();
          const { protectedMarkdown, mathItems } = protectMath(latestPayload.markdown || "");
          const html = marked.parse(protectedMarkdown);
          content.innerHTML = DOMPurify.sanitize(html, {
            ADD_ATTR: ["target", "rel"],
            ALLOW_DATA_ATTR: false
          });

          content.querySelectorAll("a[href]").forEach((anchor) => {
            anchor.target = "_blank";
            anchor.rel = "noopener noreferrer";
          });

          rewriteRelativeURLs(latestPayload.baseURL, Boolean(latestPayload.useResourceScheme));
          blockRemoteImages();
          replaceMathPlaceholders(mathItems);
          restoreScrollProgress(previousScrollProgress);
        }

        window.renderMarkdown = function(payload) {
          latestPayload = payload;
          renderLatestPayload();
        };

        window.addEventListener("load", renderLatestPayload);
      </script>
      \(markdownPreviewAutorenderScript(for: autorenderPayload))
    </body>
    </html>
    """
}

private func markdownPreviewAutorenderScript(for payload: MarkdownRenderPayload?) -> String {
    guard
        let payload,
        let data = try? JSONEncoder().encode(payload),
        let json = String(data: data, encoding: .utf8)
    else {
        return ""
    }

    return """
      <script>
        window.addEventListener("load", function() {
          window.renderMarkdown(\(json));
        });
      </script>
    """
}
