import Foundation

public struct BrowserNavigation: Equatable, Sendable {
    public private(set) var path: BrowsePath
    public private(set) var back: [BrowsePath] = []
    public private(set) var forward: [BrowsePath] = []

    public init(path: BrowsePath) {
        self.path = path
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    public mutating func selectRoot(_ root: DriveRoot) {
        let next = BrowsePath(root: root)
        guard next != path else { return }
        pushCurrent()
        path = next
    }

    public mutating func openFolder(id: String, name: String) {
        pushCurrent()
        path.folders.append(PathFolder(id: id, name: name))
    }

    public mutating func replace(path next: BrowsePath) {
        guard next != path else { return }
        pushCurrent()
        path = next
    }

    public mutating func jumpToCrumb(_ index: Int?) {
        var next = path
        if let index, index >= 0, index < path.folders.count {
            next.folders = Array(path.folders.prefix(index + 1))
        } else {
            next.folders = []
        }
        guard next != path else { return }
        pushCurrent()
        path = next
    }

    @discardableResult
    public mutating func goUp() -> Bool {
        guard !path.folders.isEmpty else { return false }
        pushCurrent()
        path.folders.removeLast()
        return true
    }

    public mutating func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(path)
        path = previous
    }

    public mutating func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(path)
        path = next
    }

    private mutating func pushCurrent() {
        back.append(path)
        forward.removeAll()
    }
}
