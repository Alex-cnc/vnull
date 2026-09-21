import AppKit
import SwiftUI

/// 只接受 Roman/ASCII 输入的密码框。
///
/// 背景：macOS 上如果当前输入法是中文输入法（尤其是搜狗/QQ 等），
/// `u` 可能被输入法当作特殊模式前缀拦截，导致密码框里打不出 `u`。
/// 这里用 `NSSecureTextField` + `allowedInputSourceLocales`
/// 把密码输入限制为 Roman 输入源。
struct SecureASCIIField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        return field
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else {
                return
            }
            editor.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }
            text.wrappedValue = field.stringValue
        }
    }
}
