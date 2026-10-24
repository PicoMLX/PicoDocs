//
//  Node+ReleaseIteratively.swift
//  PicoDocs
//
//  A SwiftSoup node frees its children from its own deinit, so dropping a tree
//  nested a few thousand levels deep recurses that many times and overflows a
//  secondary thread's stack (512 KB on Apple platforms, where conversions run).
//

import SwiftSoup

extension Node {
    /// Empties every element under this node, so the tree's nodes are freed one
    /// at a time instead of recursively. Call it once the tree is no longer used.
    func releaseIteratively() {
        var nodes: [Node] = []
        var pending: [Node] = [self]
        while let node = pending.popLast() {
            nodes.append(node)
            pending.append(contentsOf: node.getChildNodes())
        }
        for case let element as Element in nodes {
            element.empty()
        }
    }
}
