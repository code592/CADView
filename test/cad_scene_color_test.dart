import 'package:cad_view/features/viewer/cad_scene_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('near-black neutral ink is readable without changing opacity', () {
    expect(cadCanvasColor(0xff000000), const Color(0xffebebeb));
    expect(cadCanvasColor(0x80202020), const Color(0x80cbcbcb));
    expect(cadCanvasColor(0x00000000), const Color(0x00ebebeb));
  });

  test(
    'source chromatic, light and non-dark neutral colors stay unchanged',
    () {
      for (final argb in [
        0xff0000ff,
        0xffff0000,
        0xff00ff00,
        0xff000020,
        0xff505050,
        0xffffffff,
        0xff071017,
        0x804d67ab,
      ]) {
        expect(cadCanvasColor(argb), Color(argb));
      }
    },
  );
}
