//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2015 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

internal struct _SmallUTF8Sink : SinkType {
  var asInt: UInt64 = 0
  var shift: UInt64 = 0
  mutating func put(x: UTF8.CodeUnit) {
    asInt |= UInt64(x) << shift
    shift += 8
  }
}

/// `Character` represents some Unicode grapheme cluster as
/// defined by a canonical, localized, or otherwise tailored
/// segmentation algorithm.
public enum Character :
  _BuiltinExtendedGraphemeClusterLiteralConvertible,
  ExtendedGraphemeClusterLiteralConvertible, Equatable, Hashable, Comparable {

  // Fundamentally, it is just a String, but it is optimized for the
  // common case where the UTF-8 representation fits in 63 bits.  The
  // remaining bit is used to discriminate between small and large
  // representations.  In the small representation, the unused bytes
  // are filled with 0xFF.
  //
  // If the grapheme cluster can be represented in SmallRepresentation, it
  // should be represented as such.
  case LargeRepresentation(OnHeap<String>)
  case SmallRepresentation(Builtin.Int63)

  /// Construct a `Character` containing just the given `scalar`.
  public init(_ scalar: UnicodeScalar) {
    var output = _SmallUTF8Sink()
    UTF8.encode(scalar, output: &output)
    output.asInt |= (~0) << output.shift
    self = SmallRepresentation(Builtin.trunc_Int64_Int63(output.asInt.value))
  }

  @effects(readonly)
  public init(_builtinUnicodeScalarLiteral value: Builtin.Int32) {
    self = Character(
      String._fromWellFormedCodeUnitSequence(
        UTF32.self, input: CollectionOfOne(UInt32(value))))
  }

  /// Create an instance initialized to `value`.
  public init(unicodeScalarLiteral value: Character) {
    self = value
  }

  @effects(readonly)
  public init(
    _builtinExtendedGraphemeClusterLiteral start: Builtin.RawPointer,
    byteSize: Builtin.Word,
    isASCII: Builtin.Int1) {
    self = Character(
      String(
        _builtinExtendedGraphemeClusterLiteral: start, 
        byteSize: byteSize, 
        isASCII: isASCII))
  }

  /// Create an instance initialized to `value`.
  public init(extendedGraphemeClusterLiteral value: Character) {
    self = value
  }

  /// Create an instance from a single-character `String`.
  ///
  /// Requires: `s` contains exactly one extended grapheme cluster.
  public init(_ s: String) {
    // The small representation can accept up to 8 code units as long
    // as the last one is a continuation.  Since the high bit of the
    // last byte is used for the enum's discriminator, we have to
    // reconstruct it.  As a result, we can't store 0x7f in the final
    // byte, because we wouldn't be able to distinguish it from an
    // unused 0xFF byte.  Rather than trying to squeeze in other
    // one-byte code points there, we simplify decoding by banning
    // starting a code point in the last byte, and assuming that its
    // high bit is 1.
    _precondition(
      s._core.count != 0, "Can't form a Character from an empty String")
    _precondition(
      s.startIndex.successor() == s.endIndex,
      "Can't form a Character from a String containing more than one extended grapheme cluster")

    var (count, initialUTF8) = s._core._encodeSomeUTF8(0)
    // Notice that the result of sizeof() is a small non-zero number and can't
    // overflow when multiplied by 8.
    let bits = sizeofValue(initialUTF8) &* 8 &- 1
    if _fastPath(
      count == s._core.count && (initialUTF8 & (1 << numericCast(bits))) != 0) {
      self = SmallRepresentation(Builtin.trunc_Int64_Int63(initialUTF8.value))
    }
    else {
      self = LargeRepresentation(OnHeap(s))
    }
  }

  /// Return the index of the lowest byte that is 0xFF, or 8 if
  /// there is none
  static func _smallSize(value: UInt64) -> Int {
    var mask: UInt64 = 0xFF
    for var i = 0; i < 8; ++i {
      if (value & mask) == mask {
        return i
      }
      mask <<= 8
    }
    return 8
  }

  static func _smallValue(value: Builtin.Int63) -> UInt64 {
    return UInt64(Builtin.zext_Int63_Int64(value)) | (1<<63)
  }

  internal static func _makeSmallUTF8Generator(var u8: UInt64)
    -> GeneratorOf<UTF8.CodeUnit> {
    return GeneratorOf<UTF8.CodeUnit> {
      let result = UInt8(truncatingBitPattern: u8)
      if result == 0xFF {
        return nil
      }
      u8 = u8 >> 8
      return result
    }
  }

  internal struct _SmallUTF16Sink : SinkType {
    mutating func put(x: UTF16.CodeUnit) {
      u16 = u16 << 16
      u16 = u16 | UInt64(x)
    }
    var u16: UInt64 = 0
  }

  struct _SmallUTF16 : CollectionType {
    init(var _ u8: UInt64) {
      let count = UTF16.measure(
        UTF8.self, input: Character._makeSmallUTF8Generator(u8),
        repairIllFormedSequences: true)!.0
      _sanityCheck(count <= 4, "Character with more than 4 UTF16 code units")
      self.count = UInt16(count)
      var output = _SmallUTF16Sink()
      transcode(
        UTF8.self, UTF16.self, Character._makeSmallUTF8Generator(u8), &output,
        stopOnError: false)
      self.data = output.u16
    }

    /// The position of the first element in a non-empty collection.
    ///
    /// Identical to `endIndex` in an empty collection.
    var startIndex : Int {
      return 0
    }
    
    /// The collection's "past the end" position.
    ///
    /// `endIndex` is not a valid argument to `subscript`, and is always
    /// reachable from `startIndex` by zero or more applications of
    /// `successor()`.
    var endIndex : Int {
      return Int(count)
    }
    
    /// Access the code unit at `position`.
    ///
    /// Requires: `position` is a valid position in `self` and
    /// `position != endIndex`.
    subscript(position: Int) -> UTF16.CodeUnit {
      _sanityCheck(position >= 0)
      _sanityCheck(position < Int(count))
      // Note: using unchecked arthmetic because overflow can not happen if the
      // above sanity checks hold.
      return UTF16.CodeUnit(
        truncatingBitPattern: data >> (UInt64(position) &* 16))
    }

    /// Return a *generator* over the elements of this *sequence*.
    ///
    /// Complexity: O(1)
    func generate() -> IndexingGenerator<_SmallUTF16> {
      return IndexingGenerator(self)
    }
    
    var count: UInt16
    var data: UInt64
  }
  
  /// The hash value.
  ///
  /// **Axiom:** `x == y` implies `x.hashValue == y.hashValue`
  ///
  /// **Note:** the hash value is not guaranteed to be stable across
  /// different invocations of the same program.  Do not persist the
  /// hash value across program runs.
  public var hashValue: Int {
    // FIXME(performance): constructing a temporary string is extremely
    // wasteful and inefficient.
    return String(self).hashValue
  }

  typealias UTF16View = String.UTF16View
  var utf16: UTF16View {
    return String(self).utf16
  }
}

extension String {
  /// Construct an instance containing just the given `Character`.
  public init(_ c: Character) {
    switch c {
    case .SmallRepresentation(var _63bits):
      var value = Character._smallValue(_63bits)
      var size = Character._smallSize(value)
      self = String._fromWellFormedCodeUnitSequence(
        UTF8.self,
        input: UnsafeBufferPointer(
          start: UnsafeMutablePointer<UTF8.CodeUnit>(
            Builtin.addressof(&value)), 
          count: size))
    case .LargeRepresentation(var value):
      self = value._value
    }
  }
}

public func ==(lhs: Character, rhs: Character) -> Bool {
  // FIXME(performance): constructing two temporary strings is extremely
  // wasteful and inefficient.
  return String(lhs) == String(rhs)
}

public func <(lhs: Character, rhs: Character) -> Bool {
  // FIXME(performance): constructing two temporary strings is extremely
  // wasteful and inefficient.
  return String(lhs) < String(rhs)
}
