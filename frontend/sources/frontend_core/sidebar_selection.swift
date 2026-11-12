import Foundation

public enum Page: Hashable { case overview, sandbox(String), activity, settings }

/// Native List owns Cmd/Shift gestures; this only keeps navigation and the
/// visible sandbox selection consistent, excluding utility rows from batches.
public struct SidebarSelection {
    public private(set) var items: Set<Page> = [.overview]
    public private(set) var page: Page? = .overview
    public init() {}

    public mutating func select(_ proposed: Set<Page>, visibleIDs: [String], extendingSelection: Bool = false) {
        let tools: [Page] = [.overview, .activity, .settings]
        let sandboxes = Set(visibleIDs.map(Page.sandbox))
        // Native List's Select All includes navigation rows. Keep only visible
        // sandboxes; leave keyboard/text focus routing to the system.
        if proposed == sandboxes.union(tools) {
            guard !sandboxes.isEmpty else { return }
            items = sandboxes
            updatePage(visibleIDs: visibleIDs)
            return
        }
        let added = proposed.subtracting(items)
        if let tool = tools.first(where: { proposed.contains($0) }) {
            if proposed.count == 1 && !extendingSelection {
                items = [tool]; page = tool
                return
            }
            if proposed.isDisjoint(with: sandboxes) { return }
            if proposed.intersection(sandboxes) == items { return }
        }
        if !proposed.isDisjoint(with: sandboxes) { items = proposed.intersection(sandboxes) }
        else { items = proposed.intersection(Set(tools)) }
        // Filtering/deselecting rows is not a request to navigate away.
        guard !items.isEmpty else { return }
        if added.isEmpty, let page, !items.contains(page), !sandboxes.contains(page) { return }
        updatePage(visibleIDs: visibleIDs)
    }

    public mutating func navigate(to target: Page?) {
        guard target != page else { return }
        page = target
        items = target.map { [$0] } ?? []
    }

    public mutating func prune(visibleIDs: [String], existingIDs: [String]) {
        let valid = Set(visibleIDs.map(Page.sandbox) + [.overview, .activity, .settings])
        items.formIntersection(valid)
        if case .sandbox(let id) = page {
            if existingIDs.contains(id) {
                if items.isEmpty && visibleIDs.contains(id) { items = [.sandbox(id)] }
                return
            }
            page = nil
        } else if page != nil { return }
        updatePage(visibleIDs: visibleIDs)
    }

    private mutating func updatePage(visibleIDs: [String]) {
        if items.count > 1, page != nil {
            // Multi-selection is for contextual actions, not navigation.
            return
        }
        if let page, items.contains(page) { return }
        page = visibleIDs.map(Page.sandbox).first { items.contains($0) }
            ?? [.overview, .activity, .settings].first { items.contains($0) }
            ?? .overview
    }
}
