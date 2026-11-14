import Foundation
import AEXML

/// Resolves which WordprocessingML element a block tag should clone/remove
/// (`tr`, `tc`, `p`, `r`, or auto-inferred from the DOM).
enum DOMScopeResolver {
    /// Finds the ancestor element matching `scope` starting from a run that contains the tag.
    static func resolveHost(
        for scope: BlockScope,
        from run: AEXMLElement,
        preferredTag: String? = nil
    ) -> AEXMLElement {
        switch scope {
        case .tr:
            return ancestor(named: "tr", from: run) ?? run
        case .tc:
            return ancestor(named: "tc", from: run) ?? run
        case .p:
            return ancestor(named: "p", from: run) ?? run
        case .r:
            return run
        case .auto:
            return inferScope(from: run, preferredTag: preferredTag)
        }
    }

    /// Auto-inference mirrors docxtpl: prefer row if inside a table row, else paragraph, else run.
    static func inferScope(from run: AEXMLElement, preferredTag: String?) -> AEXMLElement {
        if let tr = ancestor(named: "tr", from: run) {
            return tr
        }
        if let p = ancestor(named: "p", from: run) {
            return p
        }
        return run
    }

    static func ancestor(named localName: String, from element: AEXMLElement) -> AEXMLElement? {
        var current: AEXMLElement? = element.parent
        while let node = current {
            if isWord(node, localName) {
                return node
            }
            current = node.parent
        }
        return nil
    }

    static func isWord(_ element: AEXMLElement, _ localName: String) -> Bool {
        let name = element.name
        return name == localName
            || name == "w:\(localName)"
            || name.hasSuffix(":\(localName)")
    }

    /// Returns the local WordprocessingML name without prefix.
    static func localName(_ element: AEXMLElement) -> String {
        if let idx = element.name.lastIndex(of: ":") {
            return String(element.name[element.name.index(after: idx)...])
        }
        return element.name
    }
}
