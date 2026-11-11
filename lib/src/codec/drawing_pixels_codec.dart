import 'dart:convert';
import 'dart:typed_data';

/// The `.icproj` encoding of a drawing frame's RGB pixels: run-length
/// encoded (`count r g b` per run, `count` 1–255) and Base64-encoded. Hand
/// drawn frames are mostly black with a few strokes, so a 2400-byte frame
/// usually encodes in a few dozen characters.
abstract final class DrawingPixelsCodec {
  static String encode(Uint8List rgb) {
    if (rgb.length % 3 != 0) throw ArgumentError.value(rgb.length, 'rgb', 'Must hold whole RGB triples.');
    final runs = BytesBuilder(copy: false);
    var i = 0;
    while (i < rgb.length) {
      final r = rgb[i], g = rgb[i + 1], b = rgb[i + 2];
      var count = 1;
      var j = i + 3;
      while (count < 255 && j < rgb.length && rgb[j] == r && rgb[j + 1] == g && rgb[j + 2] == b) {
        count++;
        j += 3;
      }
      runs.add([count, r, g, b]);
      i = j;
    }
    return base64Encode(runs.takeBytes());
  }

  /// The pixels of [text] made by [encode], which must decode to exactly
  /// [pixelCount] pixels. Throws a [FormatException] otherwise.
  static Uint8List decode(String text, {required int pixelCount}) {
    final Uint8List runs;
    try {
      runs = base64Decode(text);
    } on FormatException catch (error) {
      throw FormatException('Not Base64: ${error.message}');
    }
    if (runs.length % 4 != 0) throw const FormatException('Runs must be 4 bytes each.');
    final rgb = Uint8List(pixelCount * 3);
    var o = 0;
    for (var i = 0; i < runs.length; i += 4) {
      final count = runs[i];
      if (count == 0) throw const FormatException('A run of 0 pixels.');
      if (o + count * 3 > rgb.length) throw FormatException('More than $pixelCount pixels.');
      for (var n = 0; n < count; n++) {
        rgb[o++] = runs[i + 1];
        rgb[o++] = runs[i + 2];
        rgb[o++] = runs[i + 3];
      }
    }
    if (o != rgb.length) throw FormatException('${o ~/ 3} pixels instead of $pixelCount.');
    return rgb;
  }
}
