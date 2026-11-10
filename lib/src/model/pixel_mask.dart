import 'dart:typed_data';

import 'package:equatable/equatable.dart';

import 'output_spec.dart';

/// A bit set over the pixels of a target layout: the icicle pixels
/// (`xCount × yCount`, column-major `x · yCount + y`) followed by the radio
/// panel pixels (`radioPanelsCount × radioPanelPixelCount`, panel-major).
///
/// A set bit means the pixel is drawn (included). The mask remembers the
/// dimensions it was made for; [fitTo] re-dimensions it to another target.
///
/// Bits are packed little-endian: pixel `i` is bit `i & 7` of byte `i >> 3`.
class PixelMask extends Equatable {
  final int xCount;
  final int yCount;
  final int radioPanelsCount;
  final int radioPanelPixelCount;

  /// The packed bits, `ceil(length / 8)` bytes; unmodifiable.
  final Uint8List bits;

  PixelMask._(this.xCount, this.yCount, this.radioPanelsCount, this.radioPanelPixelCount, Uint8List bits)
      : bits = bits.asUnmodifiableView();

  /// A mask over [bits] packed for the given dimensions. Throws an
  /// [ArgumentError] for negative dimensions or a byte array of another
  /// length than `ceil(length / 8)`; padding bits past the length are
  /// cleared.
  factory PixelMask({
    required int xCount,
    required int yCount,
    int radioPanelsCount = 0,
    int radioPanelPixelCount = 1,
    required Uint8List bits,
  }) {
    for (final (name, value) in [
      ('xCount', xCount),
      ('yCount', yCount),
      ('radioPanelsCount', radioPanelsCount),
      ('radioPanelPixelCount', radioPanelPixelCount),
    ]) {
      if (value < 0) throw ArgumentError.value(value, name, 'Must not be negative.');
    }
    final length = xCount * yCount + radioPanelsCount * radioPanelPixelCount;
    final byteCount = _byteCountFor(length);
    if (bits.length != byteCount) {
      throw ArgumentError.value(bits.length, 'bits', 'Must hold $byteCount bytes for $length pixels.');
    }
    return PixelMask._(
        xCount, yCount, radioPanelsCount, radioPanelPixelCount, _trimmed(Uint8List.fromList(bits), length));
  }

  /// A mask of [target]'s dimensions with every bit set.
  factory PixelMask.full(OutputSpec target) => _filled(target, 0xFF);

  /// A mask of [target]'s dimensions with no bit set.
  factory PixelMask.empty(OutputSpec target) => _filled(target, 0);

  static PixelMask _filled(OutputSpec target, int byte) {
    final length = target.pixelsCount + target.radioPanelsCount * target.radioPanelPixelCount;
    return PixelMask._(
      target.xCount,
      target.yCount,
      target.radioPanelsCount,
      target.radioPanelPixelCount,
      _trimmed(Uint8List(_byteCountFor(length))..fillRange(0, _byteCountFor(length), byte), length),
    );
  }

  static int _byteCountFor(int length) => (length + 7) >> 3;

  /// Clears the padding bits past [length].
  static Uint8List _trimmed(Uint8List bytes, int length) {
    final spare = length & 7;
    if (spare != 0 && bytes.isNotEmpty) bytes[bytes.length - 1] &= (1 << spare) - 1;
    return bytes;
  }

  /// Number of icicle pixels.
  int get iciclePixelCount => xCount * yCount;

  /// Number of radio panel pixels.
  int get panelPixelCount => radioPanelsCount * radioPanelPixelCount;

  /// Total number of pixels (bits).
  int get length => iciclePixelCount + panelPixelCount;

  /// Whether the mask was made for [target]'s dimensions.
  bool fits(OutputSpec target) =>
      xCount == target.xCount &&
      yCount == target.yCount &&
      radioPanelsCount == target.radioPanelsCount &&
      radioPanelPixelCount == target.radioPanelPixelCount;

  bool _bit(int index) => (bits[index >> 3] >> (index & 7)) & 1 == 1;

  /// Whether the icicle pixel [pixel] (column-major index) is included;
  /// `false` outside the grid.
  bool contains(int pixel) => pixel >= 0 && pixel < iciclePixelCount && _bit(pixel);

  /// Index of the LED [led] of the 1-based [panel] in the bit set, or
  /// `null` when outside the panels.
  int? panelPixelIndex(int panel, int led) {
    if (panel < 1 || panel > radioPanelsCount || led < 0 || led >= radioPanelPixelCount) return null;
    return iciclePixelCount + (panel - 1) * radioPanelPixelCount + led;
  }

  /// Whether the LED [led] (0-based) of the 1-based radio [panel] is
  /// included; `false` outside the panels.
  bool containsPanelPixel(int panel, int led) {
    final index = panelPixelIndex(panel, led);
    return index != null && _bit(index);
  }

  /// Whether the bit at [index] of the whole set is set; `false` outside.
  bool containsIndex(int index) => index >= 0 && index < length && _bit(index);

  /// Number of included pixels.
  int get coveredCount {
    var count = 0;
    for (final byte in bits) {
      var value = byte;
      while (value != 0) {
        value &= value - 1;
        count++;
      }
    }
    return count;
  }

  /// Whether every pixel is included.
  bool get isFull => coveredCount == length;

  /// Whether no pixel is included.
  bool get isEmpty => bits.every((byte) => byte == 0);

  /// A copy with the icicle pixel [pixel] included ([value] `true`) or
  /// excluded; unchanged outside the grid.
  PixelMask withPixel(int pixel, bool value) => pixel < 0 || pixel >= iciclePixelCount ? this : withIndex(pixel, value);

  /// A copy with the LED [led] of the 1-based [panel] included or
  /// excluded; unchanged outside the panels.
  PixelMask withPanelPixel(int panel, int led, bool value) {
    final index = panelPixelIndex(panel, led);
    return index == null ? this : withIndex(index, value);
  }

  /// A copy with the bit at [index] of the whole set changed; unchanged
  /// outside the set.
  PixelMask withIndex(int index, bool value) {
    if (index < 0 || index >= length || _bit(index) == value) return this;
    final copy = Uint8List.fromList(bits);
    if (value) {
      copy[index >> 3] |= 1 << (index & 7);
    } else {
      copy[index >> 3] &= ~(1 << (index & 7));
    }
    return PixelMask._(xCount, yCount, radioPanelsCount, radioPanelPixelCount, copy);
  }

  /// A copy with several bits changed at once: [icicles] are icicle pixel
  /// indices, [panelPixels] `(panel, led)` pairs; indices outside the set
  /// are ignored.
  PixelMask withPixels(
      {Iterable<int> icicles = const [], Iterable<(int, int)> panelPixels = const [], required bool value}) {
    final copy = Uint8List.fromList(bits);
    void set(int index) {
      if (value) {
        copy[index >> 3] |= 1 << (index & 7);
      } else {
        copy[index >> 3] &= ~(1 << (index & 7));
      }
    }

    for (final pixel in icicles) {
      if (pixel >= 0 && pixel < iciclePixelCount) set(pixel);
    }
    for (final (panel, led) in panelPixels) {
      final index = panelPixelIndex(panel, led);
      if (index != null) set(index);
    }
    return PixelMask._(xCount, yCount, radioPanelsCount, radioPanelPixelCount, copy);
  }

  /// A copy with every bit flipped.
  PixelMask inverted() {
    final copy = Uint8List.fromList(bits);
    for (var i = 0; i < copy.length; i++) {
      copy[i] = ~copy[i] & 0xFF;
    }
    return PixelMask._(xCount, yCount, radioPanelsCount, radioPanelPixelCount, _trimmed(copy, length));
  }

  /// This mask re-dimensioned to [target]: pixels at the same grid position
  /// (`x`, `y`) and the same panel LED keep their bit, pixels the old
  /// layout did not have are included (`true`). Returns `this` when the
  /// mask already [fits].
  PixelMask fitTo(OutputSpec target) {
    if (fits(target)) return this;
    var fitted = PixelMask.full(target);
    final copy = Uint8List.fromList(fitted.bits);
    void clear(int index) => copy[index >> 3] &= ~(1 << (index & 7));
    for (var x = 0; x < xCount && x < target.xCount; x++) {
      for (var y = 0; y < yCount && y < target.yCount; y++) {
        if (!_bit(x * yCount + y)) clear(x * target.yCount + y);
      }
    }
    for (var panel = 1; panel <= radioPanelsCount && panel <= target.radioPanelsCount; panel++) {
      for (var led = 0; led < radioPanelPixelCount && led < target.radioPanelPixelCount; led++) {
        if (!_bit(panelPixelIndex(panel, led)!)) clear(fitted.panelPixelIndex(panel, led)!);
      }
    }
    fitted = PixelMask._(target.xCount, target.yCount, target.radioPanelsCount, target.radioPanelPixelCount, copy);
    return fitted;
  }

  @override
  List<Object?> get props => [xCount, yCount, radioPanelsCount, radioPanelPixelCount, bits];

  @override
  String toString() => 'PixelMask(${xCount}x$yCount + $radioPanelsCount×$radioPanelPixelCount, $coveredCount/$length)';
}
