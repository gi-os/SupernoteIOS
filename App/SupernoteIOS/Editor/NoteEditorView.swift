import NoteKit
import SwiftUI

/// Full-screen note editor laid out like the Nomad: fixed toolbar on the left (right-handed),
/// the page, the page-number bar along the bottom, and the two physical "sidebars" as gesture
/// strips at the screen edges (slide up = undo, slide down = redo).
struct NoteEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: NoteSession
    @State private var panel: EditorPanel?
    @State private var toolbarHidden = false
    @State private var jumpText = ""
    @State private var showJump = false

    init(session: NoteSession) {
        _session = State(initialValue: session)
    }

    var body: some View {
        HStack(spacing: 0) {
            if model.leftHanded { sidebar(isUndoSide: false) } else { sidebar(isUndoSide: true) }
            if !toolbarHidden && !model.leftHanded { toolbar }
            VStack(spacing: 0) {
                pageArea
                pageBar
            }
            if !toolbarHidden && model.leftHanded { toolbar }
            if model.leftHanded { sidebar(isUndoSide: true) } else { sidebar(isUndoSide: false) }
        }
        .background(EInk.paper)
        .overlay(alignment: model.leftHanded ? .topTrailing : .topLeading) {
            if let panel, !toolbarHidden {
                EditorPanelView(session: session, panel: panel) { self.panel = nil }
                    .padding(.top, 8)
                    .padding(model.leftHanded ? .trailing : .leading, EInk.toolbarWidth + EInk.sidebarWidth + 6)
            }
        }
        .overlay(alignment: .bottom) {
            if let error = session.error {
                Text(error).font(.system(size: 13)).padding(10).einkPanel().padding(.bottom, 60)
                    .onTapGesture { session.error = nil }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .einkStatic()
        .task(id: session.revision) {
            // Autosave a few seconds after the last edit.
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { session.save() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.save() }
        }
        .alert("Go to page", isPresented: $showJump) {
            TextField("1–\(session.pageCount)", text: $jumpText).keyboardType(.numberPad)
            Button("Go") { if let n = Int(jumpText) { session.go(to: n - 1) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var toolbar: some View {
        NomadToolbar(session: session, panel: $panel, onBack: close, onFullScreen: { toolbarHidden = true; panel = nil })
    }

    private func close() {
        let changed = session.save()
        dismiss()
        if changed { Task { await model.sync() } }
    }

    // MARK: Page

    private var pageArea: some View {
        GeometryReader { geo in
            let size = session.pageSize
            let s = min(geo.size.width / size.width, geo.size.height / size.height)
            ZStack {
                PageCanvas(session: session, toolbarHidden: $toolbarHidden)
                    .frame(width: size.width * s, height: size.height * s)
                if let reason = session.readOnlyReason {
                    Text(reason).font(.system(size: 12)).padding(6).einkPanel()
                        .frame(maxHeight: .infinity, alignment: .top).padding(.top, 8)
                }
                if !session.selection.isEmpty {
                    lassoMenu.frame(maxHeight: .infinity, alignment: .top).padding(.top, 8)
                }
                if toolbarHidden {
                    Button { toolbarHidden = false } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 17))
                            .frame(width: 40, height: 40).einkPanel()
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.leftHanded ? .topTrailing : .topLeading)
                    .padding(8)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(EInk.paper)
    }

    private var lassoMenu: some View {
        HStack(spacing: 18) {
            Text("\(session.selection.count) selected").foregroundStyle(EInk.muted)
            Button { session.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
            Button { session.clearSelection() } label: { Label("Done", systemImage: "xmark") }
        }
        .font(.system(size: 14))
        .foregroundStyle(EInk.ink)
        .buttonStyle(.plain)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .einkPanel()
    }

    // MARK: Page number bar

    private var pageBar: some View {
        HStack(spacing: 22) {
            Button { session.previousPage() } label: { Image(systemName: "chevron.left") }
                .disabled(session.pageIndex == 0)
            Button { jumpText = ""; showJump = true } label: {
                Text("\(session.pageIndex + 1)").underline() + Text(" / \(session.pageCount)")
            }
            Button { session.nextPage() } label: { Image(systemName: "chevron.right") }
                .disabled(session.pageIndex >= session.pageCount - 1)
            Spacer()
            if session.hasUnsavedChanges { Circle().fill(EInk.ink).frame(width: 5, height: 5) }
            Text(session.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
        }
        .font(.system(size: 15))
        .foregroundStyle(EInk.ink)
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .frame(height: EInk.pageBarHeight)
        .background(EInk.paper)
        .overlay(alignment: .top) { HairlineDivider() }
    }

    // MARK: Sidebars

    /// Thin edge strip mimicking the Nomad's physical sidebar.
    /// Undo side: slide up = undo, slide down = redo. Other side: slide down = pages, slide up = refresh.
    private func sidebar(isUndoSide: Bool) -> some View {
        ZStack {
            EInk.paper
            Capsule().fill(EInk.ink.opacity(0.25)).frame(width: 2).padding(.vertical, 120)
        }
        .frame(width: EInk.sidebarWidth)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 30).onEnded { g in
            let up = g.translation.height < -30, down = g.translation.height > 30
            if isUndoSide {
                if up { session.undo() } else if down { session.redo() }
            } else {
                if down { panel = panel == .pages ? nil : .pages } else if up { session.go(to: session.pageIndex) }
            }
        })
        .accessibilityHidden(true)
    }
}
