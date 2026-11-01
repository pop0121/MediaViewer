import CoreGraphics
import Foundation

/// Bounded LRU of already-decoded `CGImage` bitmaps.
///
/// `NSCache` is intentionally not used for the grid: its cost accounting can
/// lag behind eviction and it stores NSImage wrappers. The grid needs a hard,
/// predictable byte budget because a full library should stay resident.
final class CGImageLRU: @unchecked Sendable {
    private final class Node {
        let key: String
        let image: CGImage
        let cost: Int
        var previous: Node?
        var next: Node?

        init(key: String, image: CGImage, cost: Int) {
            self.key = key
            self.image = image
            self.cost = cost
        }
    }

    let capacityBytes: Int
    private let lock = NSLock()
    private var nodes: [String: Node] = [:]
    private var head: Node?
    private var tail: Node?
    private(set) var totalBytes = 0
    private(set) var hits = 0
    private(set) var misses = 0

    init(capacityBytes: Int) {
        self.capacityBytes = max(capacityBytes, 1)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return nodes.count
    }

    func image(forKey key: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let node = nodes[key] else {
            misses += 1
            return nil
        }
        hits += 1
        moveToHead(node)
        return node.image
    }

    func insert(_ image: CGImage, forKey key: String, cost: Int? = nil) {
        let bytes = max(cost ?? (image.bytesPerRow * image.height), 1)
        lock.lock()
        defer { lock.unlock() }

        if let existing = nodes[key] {
            existing.previous?.next = existing.next
            existing.next?.previous = existing.previous
            if tail === existing { tail = existing.previous }
            if head === existing { head = existing.next }
            totalBytes -= existing.cost
            nodes.removeValue(forKey: key)
        }

        let node = Node(key: key, image: image, cost: bytes)
        nodes[key] = node
        totalBytes += bytes
        addToHead(node)

        while totalBytes > capacityBytes, let oldTail = tail {
            remove(oldTail)
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        nodes.removeAll(keepingCapacity: true)
        head = nil
        tail = nil
        totalBytes = 0
    }

    private func addToHead(_ node: Node) {
        node.previous = nil
        node.next = head
        head?.previous = node
        head = node
        if tail == nil { tail = node }
    }

    private func moveToHead(_ node: Node) {
        guard head !== node else { return }
        node.previous?.next = node.next
        node.next?.previous = node.previous
        if tail === node { tail = node.previous }
        node.previous = nil
        node.next = head
        head?.previous = node
        head = node
    }

    private func remove(_ node: Node) {
        node.previous?.next = node.next
        node.next?.previous = node.previous
        if head === node { head = node.next }
        if tail === node { tail = node.previous }
        totalBytes -= node.cost
        nodes.removeValue(forKey: node.key)
    }
}
