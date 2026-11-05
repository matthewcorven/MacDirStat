import SwiftUI

struct TreemapRect: Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var area: Double { width * height }

    /// Grows the rect about its center so both sides are at least `minSide`,
    /// clamped to stay inside `container`.
    func atLeastVisible(minSide: Double, inside container: TreemapRect) -> TreemapRect {
        guard width < minSide || height < minSide else { return self }
        var result = self
        let newWidth = max(width, minSide)
        let newHeight = max(height, minSide)
        result.x = centerX - newWidth / 2
        result.y = centerY - newHeight / 2
        result.width = newWidth
        result.height = newHeight
        // Keep it inside the parent so it never paints over a sibling.
        result.x = min(max(result.x, container.x), container.maxX - newWidth)
        result.y = min(max(result.y, container.y), container.maxY - newHeight)
        return result
    }

    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var minSide: Double { min(width, height) }

    func contains(point: CGPoint) -> Bool {
        point.x >= x && point.x <= x + width &&
        point.y >= y && point.y <= y + height
    }
}

struct TreemapItem: Identifiable, Sendable {
    let id: Int
    let node: FileNode
    let rect: TreemapRect
    let depth: Int
    let color: CGColor
}

struct TreemapLayoutEngine: Sendable {
    let maxDepth: Int
    let minPixelArea: Double

    /// Smallest edge, in points, a worktree block keeps so it stays visible.
    static let minimumWorktreeSide: Double = 4

    init(maxDepth: Int = 12, minPixelArea: Double = 4) {
        self.maxDepth = maxDepth
        self.minPixelArea = minPixelArea
    }

    func layout(root: FileNode, in bounds: TreemapRect, sizeMetric: SizeMetric = .allocatedSize,
                highlightWorktrees: Bool = true) -> [TreemapItem] {
        var items: [TreemapItem] = []
        items.reserveCapacity(8192)
        var nextID = 0
        layoutNode(root, in: bounds, depth: 0, sizeMetric: sizeMetric,
                   highlightWorktrees: highlightWorktrees, insideWorktree: false,
                   items: &items, nextID: &nextID)
        return items
    }

    /// `insideWorktree` is true for everything below a worktree root, so the
    /// whole worktree is one solid block instead of a few-pixel root cell with
    /// its contents in ordinary file-type colors.
    private func colorForNode(_ node: FileNode, depth: Int, highlightWorktrees: Bool,
                              insideWorktree: Bool) -> CGColor {
        let darkenFactor = max(0.5, 1.0 - Double(depth) * 0.08)
        let isWorktree = node.isGitWorktree || insideWorktree
        let baseColor = (highlightWorktrees && isWorktree
                         ? GitWorktreeStyle.color
                         : node.category.color).resolve(in: .init())
        return CGColor(
            red: Double(baseColor.red) * darkenFactor,
            green: Double(baseColor.green) * darkenFactor,
            blue: Double(baseColor.blue) * darkenFactor,
            alpha: 1.0
        )
    }

    private func layoutNode(
        _ node: FileNode,
        in bounds: TreemapRect,
        depth: Int,
        sizeMetric: SizeMetric,
        highlightWorktrees: Bool,
        insideWorktree: Bool,
        items: inout [TreemapItem],
        nextID: inout Int
    ) {
        // Cull sub-pixel rectangles to keep item counts sane, but never drop a
        // worktree root: at full-disk scale a 5 MB worktree is under 4 px2, so
        // ordinary culling made real worktrees disappear from the treemap while
        // the legend still counted them.
        guard bounds.area >= minPixelArea || (highlightWorktrees && node.isGitWorktree) else { return }
        // Worktrees are shaded as a unit, so descendants inherit the tint.
        let inWorktree = insideWorktree || node.isGitWorktree

        // Leaf node (file or empty/childless directory)
        if !node.isDirectory || node.children.isEmpty || depth >= maxDepth {
            let itemID = nextID; nextID += 1
            items.append(TreemapItem(
                id: itemID,
                node: node,
                rect: bounds,
                depth: depth,
                color: colorForNode(node, depth: depth, highlightWorktrees: highlightWorktrees,
                                    insideWorktree: insideWorktree)
            ))
            return
        }

        // Filter children with positive size
        let children = node.children.filter { $0.size(for: sizeMetric) > 0 }
            .sorted { $0.size(for: sizeMetric) > $1.size(for: sizeMetric) }
        guard !children.isEmpty else {
            let itemID = nextID; nextID += 1
            items.append(TreemapItem(
                id: itemID,
                node: node,
                rect: bounds,
                depth: depth,
                color: colorForNode(node, depth: depth, highlightWorktrees: highlightWorktrees,
                                    insideWorktree: insideWorktree)
            ))
            return
        }

        // Render directory as background so gaps show its color, not black
        let itemID = nextID; nextID += 1
        items.append(TreemapItem(
            id: itemID,
            node: node,
            rect: bounds,
            depth: depth,
            color: colorForNode(node, depth: depth, highlightWorktrees: highlightWorktrees,
                                insideWorktree: insideWorktree)
        ))

        let totalSize = Double(children.reduce(0) { $0 + $1.size(for: sizeMetric) })
        guard totalSize > 0 else { return }

        // Compute normalized sizes proportional to area
        let sizes = children.map { Double($0.size(for: sizeMetric)) / totalSize * bounds.area }

        let rects = squarify(sizes: sizes, in: bounds)

        for (i, child) in children.enumerated() where i < rects.count {
            var rect = rects[i]
            if highlightWorktrees, child.isGitWorktree {
                // Sizing by bytes alone can leave a worktree a fraction of a
                // pixel wide, which is indistinguishable from no worktree at
                // all. Give it a small visible footprint inside its own slot.
                // Clamp to the parent so an enlarged block can't paint over an
                // unrelated sibling's area.
                rect = rect.atLeastVisible(minSide: Self.minimumWorktreeSide, inside: bounds)
            }
            layoutNode(child, in: rect, depth: depth + 1, sizeMetric: sizeMetric,
                       highlightWorktrees: highlightWorktrees, insideWorktree: inWorktree,
                       items: &items, nextID: &nextID)
        }
    }

    private func squarify(sizes: [Double], in bounds: TreemapRect) -> [TreemapRect] {
        guard !sizes.isEmpty else { return [] }

        var rects = [TreemapRect](repeating: TreemapRect(x: 0, y: 0, width: 0, height: 0), count: sizes.count)
        var remaining = bounds
        var index = 0

        while index < sizes.count {
            let shortSide = remaining.minSide

            // Find the optimal row
            var row: [Int] = [index]
            var rowSum = sizes[index]
            var bestWorst = worstAspectRatio(row: [sizes[index]], totalArea: rowSum, shortSide: shortSide)

            var next = index + 1
            while next < sizes.count {
                let newSum = rowSum + sizes[next]
                var rowSizes = row.map { sizes[$0] }
                rowSizes.append(sizes[next])
                let newWorst = worstAspectRatio(row: rowSizes, totalArea: newSum, shortSide: shortSide)
                if newWorst > bestWorst {
                    break
                }
                bestWorst = newWorst
                row.append(next)
                rowSum = newSum
                next += 1
            }

            // Lay out the row
            let rowFraction = rowSum / (remaining.width * remaining.height)
            let isHorizontal = remaining.width >= remaining.height

            if isHorizontal {
                let rowWidth = remaining.width * rowFraction
                var yOffset = remaining.y
                for idx in row {
                    let itemHeight = (sizes[idx] / rowSum) * remaining.height
                    rects[idx] = TreemapRect(
                        x: remaining.x,
                        y: yOffset,
                        width: rowWidth,
                        height: itemHeight
                    )
                    yOffset += itemHeight
                }
                remaining = TreemapRect(
                    x: remaining.x + rowWidth,
                    y: remaining.y,
                    width: remaining.width - rowWidth,
                    height: remaining.height
                )
            } else {
                let rowHeight = remaining.height * rowFraction
                var xOffset = remaining.x
                for idx in row {
                    let itemWidth = (sizes[idx] / rowSum) * remaining.width
                    rects[idx] = TreemapRect(
                        x: xOffset,
                        y: remaining.y,
                        width: itemWidth,
                        height: rowHeight
                    )
                    xOffset += itemWidth
                }
                remaining = TreemapRect(
                    x: remaining.x,
                    y: remaining.y + rowHeight,
                    width: remaining.width,
                    height: remaining.height - rowHeight
                )
            }

            index = next
        }

        return rects
    }

    private func worstAspectRatio(row: [Double], totalArea: Double, shortSide: Double) -> Double {
        guard shortSide > 0 && totalArea > 0 else { return Double.infinity }
        let s2 = shortSide * shortSide
        var worst: Double = 0
        for size in row {
            guard size > 0 else { continue }
            let ratio = max(
                (s2 * size) / (totalArea * totalArea),
                (totalArea * totalArea) / (s2 * size)
            )
            worst = max(worst, ratio)
        }
        return worst
    }
}
