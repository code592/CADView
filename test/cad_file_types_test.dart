import 'package:cad_view/core/cad_engine.dart';
import 'package:cad_view/core/cad_file_types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('file picker exposes only extensions with an available backend', () {
    const formats = [
      CadFormatDescriptor(
        id: 'dwg',
        displayName: 'DWG',
        extensions: ['DWG'],
        sceneKind: 'two_d',
        supportLevel: 'beta',
        available: true,
        canMeasure: true,
      ),
      CadFormatDescriptor(
        id: 'step',
        displayName: 'STEP',
        extensions: ['step', '.stp'],
        sceneKind: 'three_d',
        supportLevel: 'experimental',
        available: false,
        canMeasure: false,
      ),
      CadFormatDescriptor(
        id: 'svg',
        displayName: 'SVG',
        extensions: ['svg', 'svgz'],
        sceneKind: 'two_d',
        supportLevel: 'production',
        available: true,
        canMeasure: true,
      ),
    ];

    expect(availableCadExtensions(formats), ['dwg', 'svg', 'svgz']);
    expect(
      hasCadExtension('Drawing.DWG', availableCadExtensions(formats)),
      isTrue,
    );
    expect(
      hasCadExtension('assembly.step', availableCadExtensions(formats)),
      isFalse,
    );
    expect(
      hasCadExtension('drawing', availableCadExtensions(formats)),
      isFalse,
    );
  });
}
