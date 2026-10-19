import NoteKit
import SwiftUI

/// Visual language of the Nomad's e-ink UI: paper white, pure black hairlines, no shadows,
/// no color, no animation.
enum EInk {
    static let paper = Color.white
    static let ink = Color.black
    static let muted = Color(white: 0.6)
    static let hairline: CGFloat = 1
    static let toolbarWidth: CGFloat = 46
    static let pageBarHeight: CGFloat = 40
    static let sidebarWidth: CGFloat = 14

    static func gray(_ c: InkColor) -> Color {
        switch c {
        case .black: Color(white: 0)
        case .darkGray: Color(white: 157.0 / 255)
        case .lightGray: Color(white: 201.0 / 255)
        case .white: Color(white: 254.0 / 255)
        }
    }
}

/// An e-ink panel: white fill, 1pt black border, small corner radius.
struct EInkPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(EInk.paper)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(EInk.ink, lineWidth: 1.5))
    }
}

extension View {
    func einkPanel() -> some View { modifier(EInkPanel()) }

    /// Kill implicit SwiftUI animations — e-ink doesn't animate.
    func einkStatic() -> some View { transaction { $0.animation = nil } }
}

struct HairlineDivider: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(EInk.ink.opacity(0.35))
            .frame(width: vertical ? EInk.hairline : nil, height: vertical ? nil : EInk.hairline)
    }
}
