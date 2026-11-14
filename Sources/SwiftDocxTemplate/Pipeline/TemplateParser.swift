import Foundation

/// Abstract syntax tree nodes for the template language.
indirect enum TemplateNode: Equatable {
    case literal(String)
    case variable(expression: String, filters: [FilterCall])
    case block(BlockNode)
}

struct BlockNode: Equatable {
    var open: OpenBlock
    var body: [TemplateNode]
    var elseBody: [TemplateNode]
}

/// Parses a flat token stream into a nested AST.
struct TemplateParser {
    private let tokens: [TemplateToken]
    private var index = 0

    init(tokens: [TemplateToken]) {
        self.tokens = tokens
    }

    init(source: String) throws {
        self.tokens = try TemplateLexer(source).tokenize()
    }

    mutating func parse() throws -> [TemplateNode] {
        try parseNodes(untilClose: false)
    }

    private mutating func parseNodes(untilClose: Bool) throws -> [TemplateNode] {
        var nodes: [TemplateNode] = []
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case .literal(let text):
                nodes.append(.literal(text))
                index += 1
            case .variable(let expression, let filters):
                nodes.append(.variable(expression: expression, filters: filters))
                index += 1
            case .openBlock(let open):
                index += 1
                let body = try parseNodes(untilClose: true)
                var elseBody: [TemplateNode] = []
                if index < tokens.count, case .elseBlock = tokens[index] {
                    index += 1
                    elseBody = try parseNodes(untilClose: true)
                }
                if index < tokens.count, case .closeBlock = tokens[index] {
                    index += 1
                } else {
                    throw DocxTemplateError.mismatchedBlock("Missing close for {\(open.raw)}")
                }
                nodes.append(.block(BlockNode(open: open, body: body, elseBody: elseBody)))
            case .elseBlock:
                if untilClose { return nodes }
                throw DocxTemplateError.mismatchedBlock("Unexpected else")
            case .closeBlock:
                if untilClose { return nodes }
                throw DocxTemplateError.mismatchedBlock("Unexpected close block")
            }
        }
        if untilClose {
            throw DocxTemplateError.mismatchedBlock("Unclosed block")
        }
        return nodes
    }
}

/// Collects variable expression names from an AST (undeclared-variable scanning).
enum TemplateAST {
    static func collectVariables(in nodes: [TemplateNode]) -> Set<String> {
        var result: Set<String> = []
        walk(nodes, into: &result)
        return result
    }

    private static func walk(_ nodes: [TemplateNode], into result: inout Set<String>) {
        for node in nodes {
            switch node {
            case .literal:
                continue
            case .variable(let expression, _):
                result.insert(primaryPath(expression))
            case .block(let block):
                switch block.open.kind {
                case .for(_, let collection):
                    result.insert(primaryPath(collection))
                case .if(let condition), .unless(let condition):
                    result.insert(primaryPath(condition))
                }
                walk(block.body, into: &result)
                walk(block.elseBody, into: &result)
            }
        }
    }

    /// Extracts the leading identifier / dotted path from an expression.
    static func primaryPath(_ expression: String) -> String {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        // Strip comparison operators for simple "name" / "user.name" forms.
        let stopChars = CharacterSet(charactersIn: " !<>=&|()[]")
        var path = ""
        for ch in trimmed {
            if let scalar = ch.unicodeScalars.first, stopChars.contains(scalar) {
                break
            }
            path.append(ch)
        }
        return path.isEmpty ? trimmed : path
    }
}
