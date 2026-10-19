import NoteKit
import SwiftUI

/// The Nomad's fixed vertical toolbar (left side, right-handed mode), top to bottom:
/// Files · Navigation · Needle-point · Ink pen · Marker · Eraser · Region eraser · Erase all ·
/// Lasso · Layers · Undo · Redo · Pages · Add page · Share · More · Full screen.
struct NomadToolbar: View {
    @Bindable var session: NoteSession
    @Binding var panel: EditorPanel?
    var onBack: () -> Void
    var onFullScreen: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                Group {
                    button("square.grid.2x2", "Back to Files", action: onBack)
                    sep
                    button("list.bullet.rectangle", "Navigation") { toggle(.navigation) }
                    sep
                    pen(.needlePoint, "pencil.tip", "Needle-point pen")
                    pen(.inkPen, "paintbrush.pointed", "Ink pen")
                    pen(.marker, "highlighter", "Marker")
                    sep
                }
                Group {
                    tool(.eraser, "eraser", "Eraser", options: .eraser)
                    tool(.regionEraser, "eraser.line.dashed", "Region eraser", options: nil)
                    button("trash", "Erase all") { session.eraseAll() }
                    sep
                    tool(.lasso, "lasso", "Lasso", options: nil)
                    button("square.3.layers.3d", "Layers") { toggle(.layers) }
                    sep
                }
                Group {
                    button("arrow.uturn.backward", "Undo", enabled: session.canUndo) { session.undo() }
                    button("arrow.uturn.forward", "Redo", enabled: session.canRedo) { session.redo() }
                    sep
                    button("doc.on.doc", "Pages") { toggle(.pages) }
                    button("doc.badge.plus", "Add page") { session.addPage() }
                    button("square.and.arrow.up", "Share") { toggle(.share) }
                    sep
                    button("ellipsis", "More") { toggle(.more) }
                    button("arrow.up.left.and.arrow.down.right", "Full screen", action: onFullScreen)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: EInk.toolbarWidth)
        .background(EInk.paper)
        .overlay(alignment: .trailing) { HairlineDivider(vertical: true) }
        .einkStatic()
    }

    private var sep: some View { HairlineDivider().padding(.horizontal, 10).padding(.vertical, 2) }

    private func toggle(_ p: EditorPanel) { panel = panel == p ? nil : p }

    private func pen(_ type: PenType, _ icon: String, _ label: String) -> some View {
        let s = session.pens[type]
        return tool(.pen(type), icon, label, options: .pen(type),
                    caption: s.map { String(format: "%.1f", $0.widthMM) })
    }

    /// Selectable tool: first tap selects, tapping the selected tool opens its options (like the device).
    private func tool(_ t: NoteSession.Tool, _ icon: String, _ label: String, options: EditorPanel?, caption: String? = nil) -> some View {
        let selected = session.tool == t
        return Button {
            if selected, let options { toggle(options) } else { session.tool = t; panel = nil }
        } label: {
            ToolIcon(systemName: icon, selected: selected, hasOptions: options != nil, caption: caption)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .disabled(session.readOnlyReason != nil)
    }

    private func button(_ icon: String, _ label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ToolIcon(systemName: icon, selected: false, hasOptions: false, caption: nil)
                .opacity(enabled ? 1 : 0.3)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

struct ToolIcon: View {
    let systemName: String
    let selected: Bool
    let hasOptions: Bool
    let caption: String?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                Image(systemName: systemName)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(EInk.ink)
                if let caption {
                    Text(caption).font(.system(size: 8)).foregroundStyle(EInk.ink)
                }
            }
            .frame(width: 38, height: 38)
            .overlay {
                if selected { RoundedRectangle(cornerRadius: 3).stroke(EInk.ink, lineWidth: 1.5) }
            }
            if hasOptions {
                // The little corner triangle the Nomad uses for "has options".
                Path { p in
                    p.move(to: CGPoint(x: 6, y: 0)); p.addLine(to: CGPoint(x: 6, y: 6)); p.addLine(to: CGPoint(x: 0, y: 6))
                    p.closeSubpath()
                }
                .fill(EInk.ink)
                .frame(width: 6, height: 6)
                .offset(x: -2, y: -2)
            }
        }
        .frame(width: EInk.toolbarWidth, height: 42)
        .contentShape(Rectangle())
    }
}

enum EditorPanel: Equatable {
    case pen(PenType)
    case eraser
    case navigation
    case layers
    case pages
    case share
    case more
}
