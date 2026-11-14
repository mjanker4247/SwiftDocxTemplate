import Foundation

/// Bridges any `Encodable` model into a `[String: TemplateValue]` context dictionary.
public struct TemplateValueEncoder: Sendable {
    public init() {}

    /// Encodes a top-level object/struct into a context dictionary.
    public func encode<T: Encodable>(_ value: T) throws -> [String: TemplateValue] {
        let result = try encodeValue(value)
        guard case .object(let dict) = result else {
            throw DocxTemplateError.encodingFailed(
                "Top-level Encodable value must encode as an object/dictionary."
            )
        }
        return dict
    }

    /// Encodes any `Encodable` value into a single `TemplateValue`.
    public func encodeValue<T: Encodable>(_ value: T) throws -> TemplateValue {
        if let tv = value as? TemplateValue {
            return tv
        }
        if let image = value as? InlineImage {
            return .image(image)
        }
        if let runs = value as? [RichTextRun] {
            return .richText(runs)
        }
        if let date = value as? Date {
            return .date(date)
        }

        let box = ValueBox()
        let encoder = _Encoder(box: box, codingPath: [])
        try value.encode(to: encoder)
        guard let result = box.value else {
            throw DocxTemplateError.encodingFailed("Encodable value produced no TemplateValue.")
        }
        return result
    }
}

// MARK: - Box

private final class ValueBox {
    var value: TemplateValue?
}

// MARK: - Encoder

private struct _Encoder: Encoder {
    let box: ValueBox
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        if box.value == nil {
            box.value = .object([:])
        }
        return KeyedEncodingContainer(Keyed<Key>(box: box, codingPath: codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        if box.value == nil {
            box.value = .array([])
        }
        return Unkeyed(box: box, codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        SingleValue(box: box, codingPath: codingPath)
    }
}

// MARK: - Keyed

private struct Keyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let box: ValueBox
    var codingPath: [CodingKey]

    private var dict: [String: TemplateValue] {
        get {
            if case .object(let d)? = box.value { return d }
            return [:]
        }
        nonmutating set {
            box.value = .object(newValue)
        }
    }

    private func set(_ key: Key, _ value: TemplateValue) {
        var d = dict
        d[key.stringValue] = value
        dict = d
    }

    mutating func encodeNil(forKey key: Key) throws { set(key, .null) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { set(key, .bool(value)) }
    mutating func encode(_ value: String, forKey key: Key) throws { set(key, .string(value)) }
    mutating func encode(_ value: Double, forKey key: Key) throws { set(key, .double(value)) }
    mutating func encode(_ value: Float, forKey key: Key) throws { set(key, .double(Double(value))) }
    mutating func encode(_ value: Int, forKey key: Key) throws { set(key, .int(value)) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { set(key, .int(Int(value))) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        set(key, try encodeAny(value, codingPath: codingPath + [key]))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let child = ValueBox()
        child.value = .object([:])
        set(key, .object([:]))
        // Return a container that writes into `child`, then mirrors into parent on each write.
        return KeyedEncodingContainer(
            NestedKeyed<Key, NestedKey>(
                parentBox: box,
                parentKey: key.stringValue,
                childBox: child,
                codingPath: codingPath + [key]
            )
        )
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let child = ValueBox()
        child.value = .array([])
        set(key, .array([]))
        return NestedUnkeyed(
            parentBox: box,
            parentKey: key.stringValue,
            childBox: child,
            codingPath: codingPath + [key]
        )
    }

    mutating func superEncoder() -> Encoder {
        _Encoder(box: box, codingPath: codingPath)
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        let child = ValueBox()
        set(key, .null)
        return SuperEncoderProxy(parentBox: box, parentKey: key.stringValue, childBox: child, codingPath: codingPath + [key])
    }
}

// MARK: - Nested keyed bridge

private struct NestedKeyed<ParentKey: CodingKey, Key: CodingKey>: KeyedEncodingContainerProtocol {
    let parentBox: ValueBox
    let parentKey: String
    let childBox: ValueBox
    var codingPath: [CodingKey]

    private func mirror() {
        var parent: [String: TemplateValue] = [:]
        if case .object(let d)? = parentBox.value { parent = d }
        parent[parentKey] = childBox.value ?? .object([:])
        parentBox.value = .object(parent)
    }

    private func set(_ key: Key, _ value: TemplateValue) {
        var d: [String: TemplateValue] = [:]
        if case .object(let existing)? = childBox.value { d = existing }
        d[key.stringValue] = value
        childBox.value = .object(d)
        mirror()
    }

    mutating func encodeNil(forKey key: Key) throws { set(key, .null) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { set(key, .bool(value)) }
    mutating func encode(_ value: String, forKey key: Key) throws { set(key, .string(value)) }
    mutating func encode(_ value: Double, forKey key: Key) throws { set(key, .double(value)) }
    mutating func encode(_ value: Float, forKey key: Key) throws { set(key, .double(Double(value))) }
    mutating func encode(_ value: Int, forKey key: Key) throws { set(key, .int(value)) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { set(key, .int(Int(value))) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        set(key, try encodeAny(value, codingPath: codingPath + [key]))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let nested = ValueBox()
        nested.value = .object([:])
        set(key, .object([:]))
        return KeyedEncodingContainer(
            NestedKeyed<Key, NestedKey>(
                parentBox: childBox,
                parentKey: key.stringValue,
                childBox: nested,
                codingPath: codingPath + [key]
            )
        )
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let nested = ValueBox()
        nested.value = .array([])
        set(key, .array([]))
        return NestedUnkeyed(
            parentBox: childBox,
            parentKey: key.stringValue,
            childBox: nested,
            codingPath: codingPath + [key]
        )
    }

    mutating func superEncoder() -> Encoder {
        _Encoder(box: childBox, codingPath: codingPath)
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        let nested = ValueBox()
        set(key, .null)
        return SuperEncoderProxy(
            parentBox: childBox,
            parentKey: key.stringValue,
            childBox: nested,
            codingPath: codingPath + [key]
        )
    }
}

// MARK: - Unkeyed

private struct Unkeyed: UnkeyedEncodingContainer {
    let box: ValueBox
    var codingPath: [CodingKey]
    var count: Int {
        if case .array(let a)? = box.value { return a.count }
        return 0
    }

    private func append(_ value: TemplateValue) {
        var items: [TemplateValue] = []
        if case .array(let a)? = box.value { items = a }
        items.append(value)
        box.value = .array(items)
    }

    mutating func encodeNil() throws { append(.null) }
    mutating func encode(_ value: Bool) throws { append(.bool(value)) }
    mutating func encode(_ value: String) throws { append(.string(value)) }
    mutating func encode(_ value: Double) throws { append(.double(value)) }
    mutating func encode(_ value: Float) throws { append(.double(Double(value))) }
    mutating func encode(_ value: Int) throws { append(.int(value)) }
    mutating func encode(_ value: Int8) throws { append(.int(Int(value))) }
    mutating func encode(_ value: Int16) throws { append(.int(Int(value))) }
    mutating func encode(_ value: Int32) throws { append(.int(Int(value))) }
    mutating func encode(_ value: Int64) throws { append(.int(Int(value))) }
    mutating func encode(_ value: UInt) throws { append(.int(Int(value))) }
    mutating func encode(_ value: UInt8) throws { append(.int(Int(value))) }
    mutating func encode(_ value: UInt16) throws { append(.int(Int(value))) }
    mutating func encode(_ value: UInt32) throws { append(.int(Int(value))) }
    mutating func encode(_ value: UInt64) throws { append(.int(Int(value))) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        append(try encodeAny(value, codingPath: codingPath))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        let child = ValueBox()
        child.value = .object([:])
        append(.object([:]))
        let index = count - 1
        return KeyedEncodingContainer(
            ArrayNestedKeyed<NestedKey>(
                parentBox: box,
                index: index,
                childBox: child,
                codingPath: codingPath
            )
        )
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let child = ValueBox()
        child.value = .array([])
        append(.array([]))
        return Unkeyed(box: child, codingPath: codingPath)
    }

    mutating func superEncoder() -> Encoder {
        let child = ValueBox()
        append(.null)
        return _Encoder(box: child, codingPath: codingPath)
    }
}

private struct NestedUnkeyed: UnkeyedEncodingContainer {
    let parentBox: ValueBox
    let parentKey: String
    let childBox: ValueBox
    var codingPath: [CodingKey]
    var count: Int {
        if case .array(let a)? = childBox.value { return a.count }
        return 0
    }

    private func mirror() {
        var parent: [String: TemplateValue] = [:]
        if case .object(let d)? = parentBox.value { parent = d }
        parent[parentKey] = childBox.value ?? .array([])
        parentBox.value = .object(parent)
    }

    private func append(_ value: TemplateValue) {
        var items: [TemplateValue] = []
        if case .array(let a)? = childBox.value { items = a }
        items.append(value)
        childBox.value = .array(items)
        mirror()
    }

    mutating func encodeNil() throws { append(.null) }
    mutating func encode(_ value: Bool) throws { append(.bool(value)) }
    mutating func encode(_ value: String) throws { append(.string(value)) }
    mutating func encode(_ value: Double) throws { append(.double(value)) }
    mutating func encode(_ value: Float) throws { append(.double(Double(value))) }
    mutating func encode(_ value: Int) throws { append(.int(value)) }
    mutating func encode(_ value: Int8) throws { append(.int(Int(value))) }
    mutating func encode(_ value: Int16) throws { append(.int(Int(value))) }
    mutating func encode(_ value: Int32) throws { append(.int(Int(value))) }
    mutating func encode(_ value: Int64) throws { append(.int(Int(value))) }
    mutating func encode(_ value: UInt) throws { append(.int(Int(value))) }
    mutating func encode(_ value: UInt8) throws { append(.int(Int(value))) }
    mutating func encode(_ value: UInt16) throws { append(.int(Int(value))) }
    mutating func encode(_ value: UInt32) throws { append(.int(Int(value))) }
    mutating func encode(_ value: UInt64) throws { append(.int(Int(value))) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        append(try encodeAny(value, codingPath: codingPath))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        let nested = ValueBox()
        nested.value = .object([:])
        append(.object([:]))
        return KeyedEncodingContainer(
            Keyed<NestedKey>(box: nested, codingPath: codingPath)
        )
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let nested = ValueBox()
        nested.value = .array([])
        append(.array([]))
        return Unkeyed(box: nested, codingPath: codingPath)
    }

    mutating func superEncoder() -> Encoder {
        _Encoder(box: childBox, codingPath: codingPath)
    }
}

private struct ArrayNestedKeyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let parentBox: ValueBox
    let index: Int
    let childBox: ValueBox
    var codingPath: [CodingKey]

    private func mirror() {
        var items: [TemplateValue] = []
        if case .array(let a)? = parentBox.value { items = a }
        guard items.indices.contains(index) else { return }
        items[index] = childBox.value ?? .object([:])
        parentBox.value = .array(items)
    }

    private func set(_ key: Key, _ value: TemplateValue) {
        var d: [String: TemplateValue] = [:]
        if case .object(let existing)? = childBox.value { d = existing }
        d[key.stringValue] = value
        childBox.value = .object(d)
        mirror()
    }

    mutating func encodeNil(forKey key: Key) throws { set(key, .null) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { set(key, .bool(value)) }
    mutating func encode(_ value: String, forKey key: Key) throws { set(key, .string(value)) }
    mutating func encode(_ value: Double, forKey key: Key) throws { set(key, .double(value)) }
    mutating func encode(_ value: Float, forKey key: Key) throws { set(key, .double(Double(value))) }
    mutating func encode(_ value: Int, forKey key: Key) throws { set(key, .int(value)) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { set(key, .int(Int(value))) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { set(key, .int(Int(value))) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        set(key, try encodeAny(value, codingPath: codingPath + [key]))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let nested = ValueBox()
        nested.value = .object([:])
        set(key, .object([:]))
        return KeyedEncodingContainer(
            NestedKeyed<Key, NestedKey>(
                parentBox: childBox,
                parentKey: key.stringValue,
                childBox: nested,
                codingPath: codingPath + [key]
            )
        )
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let nested = ValueBox()
        nested.value = .array([])
        set(key, .array([]))
        return NestedUnkeyed(
            parentBox: childBox,
            parentKey: key.stringValue,
            childBox: nested,
            codingPath: codingPath + [key]
        )
    }

    mutating func superEncoder() -> Encoder {
        _Encoder(box: childBox, codingPath: codingPath)
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        let nested = ValueBox()
        set(key, .null)
        return SuperEncoderProxy(
            parentBox: childBox,
            parentKey: key.stringValue,
            childBox: nested,
            codingPath: codingPath + [key]
        )
    }
}

// MARK: - Single value

private struct SingleValue: SingleValueEncodingContainer {
    let box: ValueBox
    var codingPath: [CodingKey]

    mutating func encodeNil() throws { box.value = .null }
    mutating func encode(_ value: Bool) throws { box.value = .bool(value) }
    mutating func encode(_ value: String) throws { box.value = .string(value) }
    mutating func encode(_ value: Double) throws { box.value = .double(value) }
    mutating func encode(_ value: Float) throws { box.value = .double(Double(value)) }
    mutating func encode(_ value: Int) throws { box.value = .int(value) }
    mutating func encode(_ value: Int8) throws { box.value = .int(Int(value)) }
    mutating func encode(_ value: Int16) throws { box.value = .int(Int(value)) }
    mutating func encode(_ value: Int32) throws { box.value = .int(Int(value)) }
    mutating func encode(_ value: Int64) throws { box.value = .int(Int(value)) }
    mutating func encode(_ value: UInt) throws { box.value = .int(Int(value)) }
    mutating func encode(_ value: UInt8) throws { box.value = .int(Int(value)) }
    mutating func encode(_ value: UInt16) throws { box.value = .int(Int(value)) }
    mutating func encode(_ value: UInt32) throws { box.value = .int(Int(value)) }
    mutating func encode(_ value: UInt64) throws { box.value = .int(Int(value)) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        box.value = try encodeAny(value, codingPath: codingPath)
    }
}

// MARK: - Super encoder proxy

private struct SuperEncoderProxy: Encoder {
    let parentBox: ValueBox
    let parentKey: String
    let childBox: ValueBox
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    private func mirror() {
        var parent: [String: TemplateValue] = [:]
        if case .object(let d)? = parentBox.value { parent = d }
        parent[parentKey] = childBox.value ?? .null
        parentBox.value = .object(parent)
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        childBox.value = .object([:])
        mirror()
        return KeyedEncodingContainer(
            NestedKeyed<_StringKey, Key>(
                parentBox: parentBox,
                parentKey: parentKey,
                childBox: childBox,
                codingPath: codingPath
            )
        )
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        childBox.value = .array([])
        mirror()
        return NestedUnkeyed(
            parentBox: parentBox,
            parentKey: parentKey,
            childBox: childBox,
            codingPath: codingPath
        )
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        SingleValueMirror(parentBox: parentBox, parentKey: parentKey, childBox: childBox, codingPath: codingPath)
    }
}

private struct SingleValueMirror: SingleValueEncodingContainer {
    let parentBox: ValueBox
    let parentKey: String
    let childBox: ValueBox
    var codingPath: [CodingKey]

    private func mirror() {
        var parent: [String: TemplateValue] = [:]
        if case .object(let d)? = parentBox.value { parent = d }
        parent[parentKey] = childBox.value ?? .null
        parentBox.value = .object(parent)
    }

    private func set(_ value: TemplateValue) {
        childBox.value = value
        mirror()
    }

    mutating func encodeNil() throws { set(.null) }
    mutating func encode(_ value: Bool) throws { set(.bool(value)) }
    mutating func encode(_ value: String) throws { set(.string(value)) }
    mutating func encode(_ value: Double) throws { set(.double(value)) }
    mutating func encode(_ value: Float) throws { set(.double(Double(value))) }
    mutating func encode(_ value: Int) throws { set(.int(value)) }
    mutating func encode(_ value: Int8) throws { set(.int(Int(value))) }
    mutating func encode(_ value: Int16) throws { set(.int(Int(value))) }
    mutating func encode(_ value: Int32) throws { set(.int(Int(value))) }
    mutating func encode(_ value: Int64) throws { set(.int(Int(value))) }
    mutating func encode(_ value: UInt) throws { set(.int(Int(value))) }
    mutating func encode(_ value: UInt8) throws { set(.int(Int(value))) }
    mutating func encode(_ value: UInt16) throws { set(.int(Int(value))) }
    mutating func encode(_ value: UInt32) throws { set(.int(Int(value))) }
    mutating func encode(_ value: UInt64) throws { set(.int(Int(value))) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        set(try encodeAny(value, codingPath: codingPath))
    }
}

private struct _StringKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

// MARK: - Shared encode helper

private func encodeAny<T: Encodable>(_ value: T, codingPath: [CodingKey]) throws -> TemplateValue {
    if let tv = value as? TemplateValue { return tv }
    if let image = value as? InlineImage { return .image(image) }
    if let runs = value as? [RichTextRun] { return .richText(runs) }
    if let date = value as? Date { return .date(date) }
    if let url = value as? URL { return .string(url.absoluteString) }

    let box = ValueBox()
    let encoder = _Encoder(box: box, codingPath: codingPath)
    try value.encode(to: encoder)
    return box.value ?? .null
}
