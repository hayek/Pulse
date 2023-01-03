// The MIT License (MIT)
//
// Copyright (c) 2020–2022 Alexander Grebenyuk (github.com/kean).

#if !os(watchOS)

import Foundation
import Pulse
import CoreData
import SwiftUI
import Pulse

/// Renders console messages as attributed strings.
@available(iOS 14.0, tvOS 14.0, *)
final class ConsoleTextRenderer {
    struct Options {
        var networkContent: NetworkContent = [.errorDetails, .requestBody, .responseBody]
        var isMonocrhome = true
        var isBodySyntaxHighlightingEnabled = true
        var isBodyExpanded = false
        var bodyCollapseLimit = 20
        var fontSize: CGFloat = 15
    }

    struct NetworkContent: OptionSet {
        let rawValue: Int16

        init(rawValue: Int16) {
            self.rawValue = rawValue
        }

        static let errorDetails = NetworkContent(rawValue: 1 << 0)
        static let originalRequestHeaders = NetworkContent(rawValue: 1 << 2)
        static let currentRequestHeaders = NetworkContent(rawValue: 1 << 3)
        static let requestOptions = NetworkContent(rawValue: 1 << 4)
        static let requestBody = NetworkContent(rawValue: 1 << 5)
        static let responseHeaders = NetworkContent(rawValue: 1 << 6)
        static let responseBody = NetworkContent(rawValue: 1 << 7)

        static let all: NetworkContent = [
            errorDetails, originalRequestHeaders, currentRequestHeaders, requestOptions, requestBody, responseHeaders, responseBody
        ]
    }

    private var options: Options = .init()
    private var helpers = TextRenderingHelpers(options: .init())
    private var index = 0
    var expanded: Set<Int> = []

    func render(_ entities: [NSManagedObject], options: Options = .init()) -> NSAttributedString {
        if let entities = entities as? [LoggerMessageEntity] {
            return render(entities, options: options)
        } else if let entities = entities as? [NetworkTaskEntity] {
            return render(entities, options: options)
        } else {
            return NSAttributedString(string: "Unsupported entities")
        }
    }

    func render(_ entities: [NetworkTaskEntity], options: Options = .init()) -> NSAttributedString {
        prepare(options: options)
        return joined(entities.map(render))
    }

    func render(_ entities: [LoggerMessageEntity], options: Options = .init()) -> NSAttributedString {
        prepare(options: options)
        return joined(entities.map(render))
    }

    private func prepare(options: Options) {
        self.options = options
        self.helpers = TextRenderingHelpers(options: options)
        self.index = 0
    }

    private func joined(_ strings: [NSAttributedString]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for string in strings {
            output.append(string)
            output.append("\n", helpers.newlineAttributes)
        }
        return output
    }

    func render(_ message: LoggerMessageEntity) -> NSAttributedString {
        defer { index += 1 }

        if let task = message.task {
            return render(task)
        }

        let text = NSMutableAttributedString()

        // Title
        let viewModel = ConsoleMessageViewModel(message: message)
        let level = LoggerStore.Level(rawValue: message.level) ?? .debug
        text.append(viewModel.titleForTextRepresentation + "\n", helpers.titleAttributes)

        // Text
        let textAttributes = helpers.textAttributes[level]!
        text.append(message.text + "\n", textAttributes)

        return text
    }

    func render(_ task: NetworkTaskEntity) -> NSAttributedString {
        defer { index += 1 }

        let text = NSMutableAttributedString()

        let state = task.state

        let tintColor: UXColor = {
            switch state {
            case .pending: return .systemYellow
            case .success: return .systemGreen
            case .failure: return Palette.red
            }
        }()

        let topViewModel = ConsoleNetworkRequestViewModel(task: task)
        let title = topViewModel.titleForTextRepresentation

        text.append(title + "\n", {
            var attributes = helpers.titleAttributes
            if !options.isMonocrhome {
                attributes[.foregroundColor] = tintColor
            }
            return attributes
        }())

        func append(section: KeyValueSectionViewModel?) {
            guard let section = section else { return }
            text.append("\n", helpers.newlineAttributes)

            let fontSize = options.fontSize - 1
            text.append(section.title + "\n", helpers.titleAttributes)
            var keyAttributes = helpers.detailsAttributes
            keyAttributes[.font] = UXFont.systemFont(ofSize: fontSize, weight: .medium)
            if !options.isMonocrhome {
                keyAttributes[.foregroundColor] = UXColor(section.color)
            }
            var valueAttributes = helpers.detailsAttributes
            valueAttributes[.font] = UXFont.systemFont(ofSize: fontSize, weight: .regular)
            if section.items.isEmpty {
                text.append("–\n", helpers.detailsAttributes)
            } else {
                for (key, value) in section.items {
                    text.append(key, keyAttributes)
                    text.append(": \(value ?? "–")\n", valueAttributes)
                }
            }
        }

        if let url = task.url {
            var attributes = helpers.textAttributes[.debug]!
            attributes[.font] = UXFont.systemFont(ofSize: options.fontSize, weight: .medium)
            if !options.isMonocrhome {
                attributes[.foregroundColor] = tintColor
            }
            text.append(url + "\n", attributes)
        }

        let viewModel = NetworkInspectorSummaryViewModel(task: task)
        let content = options.networkContent

        if content.contains(.errorDetails) {
            append(section: viewModel.errorModel)
        }

        if task.originalRequest != nil {
            let originalHeaders = viewModel.originalRequestHeaders
            var currentHeaders = viewModel.currentRequestHeaders
            if content.contains(.originalRequestHeaders) {
                append(section:originalHeaders .title("Original Request Headers"))
            }
            if content.contains(.currentRequestHeaders), task.currentRequest != nil {
                if task.originalRequest?.headers == task.currentRequest?.headers {
                    currentHeaders.items = [("Headers", "<original>")]
                }
                append(section: currentHeaders.title("Current Request Headers"))
            }
            if content.contains(.requestOptions) {
                append(section: viewModel.originalRequestParameters?.title("Request Options"))
            }
            if content.contains(.requestBody), let data = task.requestBody?.data, !data.isEmpty {
                text.append("\n", helpers.newlineAttributes)
                text.append("Request Body\n", helpers.titleAttributes)
                text.append(renderNetworkTaskBody(data, contentType: task.responseContentType.map(NetworkLogger.ContentType.init), error: task.decodingError))
                text.append("\n", helpers.detailsAttributes)
            }
        }
        if content.contains(.responseHeaders), task.response != nil {
            append(section: viewModel.responseHeaders.title("Response Headers"))
        }
        if content.contains(.responseBody), let data = task.responseBody?.data, !data.isEmpty {
            text.append("\n", helpers.newlineAttributes)
            text.append("Response Body\n", helpers.titleAttributes)
            text.append(renderNetworkTaskBody(data, contentType: task.responseContentType.map(NetworkLogger.ContentType.init), error: task.decodingError))
            text.append("\n", helpers.detailsAttributes)
        }
        return text
    }

    private func renderNetworkTaskBody(_ data: Data, contentType: NetworkLogger.ContentType?, error: NetworkLogger.DecodingError?) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: _renderNetworkTaskBody(data, contentType: contentType, error: error))
        if !options.isBodySyntaxHighlightingEnabled {
            text.addAttributes([
                .foregroundColor: UXColor.label
            ])
        }
        if !options.isBodyExpanded && !expanded.contains(index) {
            let string = text.string as NSString
            var counter = 0
            var index = 0
            while index < string.length, counter < options.bodyCollapseLimit {
                if string.character(at: index) == 0x0a {
                    counter += 1
                }
                index += 1
            }
            if index != string.length {
                do { // trim newlines
                    while index > 1, string.character(at: index - 1) == 0x0a {
                        index -= 1
                    }
                }
                let text = NSMutableAttributedString(attributedString: text.attributedSubstring(from: NSRange(location: 0, length: index)))
                var attributes = helpers.detailsAttributes
                attributes[.foregroundColor] = UXColor.systemBlue
                attributes[.link] = URL(string: "pulse://expand/\(self.index)")
                attributes[.underlineColor] = UXColor.clear
                text.append("\n", helpers.newlineAttributes)
                text.append("\nExpand ▷", attributes)
                return text
            }
        }
        return text
    }

    private func _renderNetworkTaskBody(_ data: Data, contentType: NetworkLogger.ContentType?, error: NetworkLogger.DecodingError?) -> NSAttributedString {
        let fontSize = options.fontSize - 3
        if let json = try? JSONSerialization.jsonObject(with: data, options: []) {
            let renderer = AttributedStringJSONRenderer(fontSize: fontSize, lineHeight: geLineHeight(for: Int(fontSize)))
            let printer = JSONPrinter(renderer: renderer)
            printer.render(json: json, error: error)
            return renderer.make()
        } else if let string = String(data: data, encoding: .utf8) {
            if contentType?.isEncodedForm ?? false, let components = decodeQueryParameters(form: string) {
                return components.asAttributedString()
            } else if contentType?.isHTML ?? false {
                return HTMLPrettyPrint(string: string, fontSize: Int(fontSize)).render()
            }
            return NSAttributedString(string: string, attributes: helpers.textAttributes[.debug]!)
        } else {
            let message = "Data \(ByteCountFormatter.string(fromByteCount: Int64(data.count)))"
            return NSAttributedString(string: message, attributes: helpers.textAttributes[.debug]!)
        }
    }

    private func decodeQueryParameters(form string: String) -> KeyValueSectionViewModel? {
        let string = "https://placeholder.com/path?" + string
        guard let components = URLComponents(string: string),
              let queryItems = components.queryItems,
              !queryItems.isEmpty else {
            return nil
        }
        return KeyValueSectionViewModel.makeQueryItems(for: queryItems, action: {})
    }
}

@available(iOS 14.0, tvOS 14.0, *)
final class TextRenderingHelpers {
    let paragraphStyle: NSParagraphStyle
    let titleAttributes: [NSAttributedString.Key: Any]
    let newlineAttributes: [NSAttributedString.Key: Any]
    private(set) var textAttributes: [LoggerStore.Level: [NSAttributedString.Key: Any]] = [:]

    var detailsAttributes: [NSAttributedString.Key: Any] { textAttributes[.debug]! }

    init(options: ConsoleTextRenderer.Options) {
        let lineHeight = geLineHeight(for: Int(options.fontSize))
        self.paragraphStyle = NSParagraphStyle.make(lineHeight: lineHeight)

        self.titleAttributes = [
            .font: UXFont.preferredFont(forTextStyle: .caption1),
            .foregroundColor: UXColor.secondaryLabel,
            .paragraphStyle: paragraphStyle
        ]

        self.newlineAttributes = [
            .font: UXFont.preferredFont(forTextStyle: .caption1),
            .paragraphStyle: {
                let style = NSMutableParagraphStyle()
                style.maximumLineHeight = 10
                style.minimumLineHeight = 10
                return style
            }()
        ]

        func makeLabelAttributes(level: LoggerStore.Level) -> [NSAttributedString.Key: Any] {
            let textColor: UXColor
            if !options.isMonocrhome {
                textColor = level == .trace ? .secondaryLabel : UXColor(ConsoleMessageStyle.textColor(level: level))
            } else {
                textColor = .label
            }
            return [
                .font: UXFont.systemFont(ofSize: options.fontSize),
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle
            ]
        }

        for level in LoggerStore.Level.allCases {
            textAttributes[level] = makeLabelAttributes(level: level)
        }
    }
}

private func geLineHeight(for fontSize: Int) -> CGFloat {
    CGFloat(fontSize + 6)
}

#endif