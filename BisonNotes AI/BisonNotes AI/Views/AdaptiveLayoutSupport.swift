//
//  AdaptiveLayoutSupport.swift
//  BisonNotes AI
//
//  Shared containers for layouts that adapt across iPhone, iPad and iPhone Duo.
//

import SwiftUI

#if os(iOS)
/// A list with its detail beside it at regular width, collapsing to a push at
/// compact width (the Mail pattern Apple asks for on iPhone Duo's inner display).
///
/// The caller owns the selection and passes its identity as `selectionID`.
/// **This container never clears it.** Going back to the list in a collapsed
/// split view — Back, the edge swipe, or the system choosing the list column on
/// its own — is recorded as "detail dismissed" in this container's own scene
/// storage (`dismissalStorageKey`). The selection, and the scene-stored copy the
/// caller keeps, survive it. Clearing the selection on that signal treated every
/// column change as the user's Back and wrote nil into scene storage, so a reset
/// could close the item the user had open. Only the detail's own Close or Cancel
/// ends a selection.
///
/// **Leaving a detail with unsaved work is refused.** `allowsLeavingDetail` is
/// asked whenever the collapsed split view moves to the list. If it says no, the
/// detail column is put back and `leaveRefused` runs, so the caller can show
/// its own Save/Discard prompt. An editor must also disable the edge swipe
/// (`InteractivePopDisabler`): a completed pop destroys the editor's state
/// before any refusal can bring it back.
///
/// **Every open must reveal the detail.** The column follows every change of
/// `selectionID`, and `revealToken` — bumped by the caller on every tap,
/// including a tap on the row that is already selected — brings the detail
/// forward even when the id did not change. Driving it only from "has a
/// selection" left a stale selection with the list on screen, and taps did
/// nothing.
///
/// **Never push a page inside the list column.** When the split view is
/// collapsed, a page pushed there sits under the detail, and switching to the
/// detail column shows nothing — every row on a "Show N more" page did nothing
/// when tapped on iPhone and iPhone Duo. Show such pages in place with state
/// (the lists' "Show N more" swaps the list content and adds a back button).
///
/// Do not cap the column widths: on a partly folded iPhone Duo the system
/// rebalances a split view's columns around the fold only when they are free
/// to resize.
struct ListDetailSplitView<ListContent: View, Detail: View>: View {
    let selectionID: String?
    let revealToken: Int
    let allowsLeavingDetail: () -> Bool
    let leaveRefused: () -> Void
    @ViewBuilder let list: ListContent
    @ViewBuilder let detail: Detail

    @State private var preferredCompactColumn: NavigationSplitViewColumn
    /// The user went back to the list with a selection still set. Scene-stored
    /// so a relaunch shows the list rather than reopening what they closed.
    @SceneStorage private var detailDismissed: Bool

    init(
        selectionID: String?,
        revealToken: Int,
        dismissalStorageKey: String,
        allowsLeavingDetail: @escaping () -> Bool = { true },
        leaveRefused: @escaping () -> Void = {},
        @ViewBuilder list: () -> ListContent,
        @ViewBuilder detail: () -> Detail
    ) {
        self.selectionID = selectionID
        self.revealToken = revealToken
        self.allowsLeavingDetail = allowsLeavingDetail
        self.leaveRefused = leaveRefused
        self.list = list()
        self.detail = detail()
        _detailDismissed = SceneStorage(wrappedValue: false, dismissalStorageKey)
        _preferredCompactColumn = State(initialValue: selectionID != nil ? .detail : .sidebar)
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            list
        } detail: {
            NavigationStack {
                detail
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            // Scene storage is restored after `init`, so the restored dismissal
            // is applied here.
            preferredCompactColumn = Self.initialColumn(selectionID: selectionID, detailDismissed: detailDismissed)
        }
        .onChange(of: selectionID) { _, newSelection in
            detailDismissed = false
            preferredCompactColumn = Self.initialColumn(selectionID: newSelection, detailDismissed: false)
        }
        .onChange(of: revealToken) { _, _ in
            detailDismissed = false
            preferredCompactColumn = Self.initialColumn(selectionID: selectionID, detailDismissed: false)
        }
        .onChange(of: preferredCompactColumn) { _, column in
            let resolved = Self.columnAfterChange(
                to: column,
                selectionID: selectionID,
                allowsLeavingDetail: column == .sidebar ? allowsLeavingDetail() : true
            )
            if resolved != column {
                preferredCompactColumn = resolved
                leaveRefused()
                return
            }
            detailDismissed = column == .sidebar && selectionID != nil
        }
    }

    /// Which column a collapsed split view should show for a selection.
    static func initialColumn(selectionID: String?, detailDismissed: Bool) -> NavigationSplitViewColumn {
        selectionID != nil && !detailDismissed ? .detail : .sidebar
    }

    /// The column to keep after the collapsed split view asked for `requested`.
    /// Moving to the list away from a detail that cannot be left keeps the
    /// detail; everything else is accepted.
    static func columnAfterChange(
        to requested: NavigationSplitViewColumn,
        selectionID: String?,
        allowsLeavingDetail: Bool
    ) -> NavigationSplitViewColumn {
        if requested == .sidebar, selectionID != nil, !allowsLeavingDetail {
            return .detail
        }
        return requested
    }
}

/// A primary and a secondary laid out by `ArrangementView` either side of
/// iPhone Duo's fold: side by side when the fold runs down the screen (book
/// pose, or no fold at all), top and bottom when it runs across it (laptop
/// pose — the primary on the top half, where you look, and the secondary on
/// the bottom half).
///
/// What the API does, learned on the simulators — keep these in mind before
/// changing it:
/// - `.split` with both axes divides a narrow phone top and bottom, leaving the
///   primary in a half-height scroll view. So the axis is chosen here, from the
///   fold (`ArrangementSplit.axes(forDivisions:)`), never left to the style.
/// - A split drops the secondary when there is no room for it (iPhone, iPad
///   portrait, the Duo closed). Anything only the secondary shows is then
///   unreachable, so `primary` is told the layout and must carry what matters
///   when it is `.single`.
/// - `splitArrangementAxis` follows the orientation whether or not the
///   secondary is shown (and is nil on the Duo's outer display), and the
///   secondary's `onAppear` fires even where it is then dropped. Size is the
///   reliable signal (`ArrangementSplit.layout`).
@available(iOS 27.1, *)
struct SideBySideArrangement<Primary: View, Secondary: View>: View {
    @ViewBuilder let primary: (_ layout: ArrangementLayout) -> Primary
    @ViewBuilder let secondary: () -> Secondary

    @State private var arrangementSize: CGSize = .zero
    @State private var primarySize: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let divisions = proxy.reservedRegions(kind: .division).filter(\.isActive).map(\.frame)
            let axes = ArrangementSplit.axes(forDivisions: divisions)
            ArrangementView {
                primary(ArrangementSplit.layout(primarySize: primarySize, arrangementSize: arrangementSize))
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { primarySize = $0 }
            } secondary: {
                secondary()
            }
            .arrangementViewStyle(.split.axes(axes))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { arrangementSize = $0 }
        }
    }
}

/// Turns off the navigation controller's edge swipe while `isDisabled`, for a
/// detail whose system Back is hidden because leaving must go through its own
/// prompt. Hiding the Back button does not reliably stop the swipe in a
/// collapsed split view, and a completed swipe destroys the view's state.
struct InteractivePopDisabler: UIViewControllerRepresentable {
    let isDisabled: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.isDisabled = isDisabled
    }

    final class Controller: UIViewController {
        var isDisabled = false {
            didSet { apply() }
        }
        private weak var managedNavigationController: UINavigationController?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            managedNavigationController = navigationController
            apply()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            managedNavigationController?.interactivePopGestureRecognizer?.isEnabled = true
        }

        private func apply() {
            guard viewIfLoaded?.window != nil else { return }
            (managedNavigationController ?? navigationController)?
                .interactivePopGestureRecognizer?.isEnabled = !isDisabled
        }
    }
}
#endif

/// How an arrangement's primary is placed.
enum ArrangementLayout: Equatable {
    /// The primary has the whole space; the secondary is not shown.
    case single
    /// The secondary is beside the primary (book pose, iPad landscape).
    case sideBySide
    /// The primary is on top and the secondary below (laptop pose).
    case topAndBottom
}

/// The arrangement decisions, pure so they can be tested.
enum ArrangementSplit {
    /// Side by side unless the fold runs across the screen — a division wider
    /// than it is tall is the laptop pose, which splits top and bottom.
    static func axes(forDivisions divisions: [CGRect]) -> Axis.Set {
        guard let fold = divisions.first else { return .horizontal }
        return fold.width > fold.height ? .vertical : .horizontal
    }

    /// A primary clearly smaller than the arrangement in one direction shares
    /// it. Until both are measured, assume one column, so nothing is out of
    /// reach.
    static func layout(primarySize: CGSize, arrangementSize: CGSize) -> ArrangementLayout {
        guard primarySize.width > 0, primarySize.height > 0,
              arrangementSize.width > 0, arrangementSize.height > 0 else { return .single }
        if primarySize.width < arrangementSize.width * 0.8 { return .sideBySide }
        if primarySize.height < arrangementSize.height * 0.8 { return .topAndBottom }
        return .single
    }
}

// MARK: - Open-row highlight

extension View {
    /// Outlines the list row whose item is open in the detail column, so the
    /// list beside it shows which one you are reading — and says so to
    /// VoiceOver.
    func openInDetailHighlight(_ isOpen: Bool, cornerRadius: CGFloat) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(isOpen ? 1 : 0)
        )
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}

// MARK: - Embedded detail presentation

/// How a detail view is hosted. A detail in a split-view column has no Done
/// button and must not wrap itself in another `NavigationStack`; closing it
/// clears the selection instead of dismissing a sheet.
struct EmbeddedDetailClose {
    let action: () -> Void
    func callAsFunction() { action() }
}

extension EnvironmentValues {
    /// Non-nil when the current detail view is embedded in a list/detail split.
    @Entry var embeddedDetailClose: EmbeddedDetailClose? = nil
}

// MARK: - Unsaved edits in an embedded editor

/// Lets a list ask the editor in its detail column whether it holds unsaved
/// work before replacing it. A sheet guards its editor by blocking dismissal;
/// a column has no dismissal to block, so selecting another row would
/// otherwise drop the edits silently.
///
/// The editor registers itself on appear and reports its dirty state; the
/// list checks `hasUnsavedChanges` before changing the selection and can ask
/// the editor to `save()` first. `owner` keeps an outgoing editor's late
/// `onDisappear` from clearing the incoming editor's registration.
@MainActor
final class UnsavedEditsGuard {
    private(set) var owner: UUID?
    private(set) var hasUnsavedChanges = false
    private var saveAction: (() -> Bool)?
    private var closeRequestAction: (() -> Void)?

    func register(owner: UUID, save: @escaping () -> Bool, requestClose: @escaping () -> Void = {}) {
        self.owner = owner
        saveAction = save
        closeRequestAction = requestClose
        hasUnsavedChanges = false
    }

    /// Asks the registered editor to show its own Save/Discard prompt — for a
    /// way out of the detail the editor did not start, such as the split view
    /// moving to the list.
    func requestClose() {
        closeRequestAction?()
    }

    func update(owner: UUID, hasUnsavedChanges: Bool) {
        guard self.owner == owner else { return }
        self.hasUnsavedChanges = hasUnsavedChanges
    }

    func unregister(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        saveAction = nil
        closeRequestAction = nil
        hasUnsavedChanges = false
    }

    /// Saves the registered editor. False when the save failed (the editor
    /// shows its own error) or no editor is registered.
    func save() -> Bool {
        saveAction?() ?? false
    }
}

extension EnvironmentValues {
    /// Set by a list that hosts an editor in its detail column.
    @Entry var unsavedEditsGuard: UnsavedEditsGuard? = nil
}
