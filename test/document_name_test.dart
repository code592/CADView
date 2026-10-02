import 'package:cad_view/core/document_name.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const id = 'f13f23ad-abcd-1234-1234-123456789abc';
  test('legacy importer prefixes are hidden, not real drawing names', () {
    for (final name in [
      '${id}_图框.dwg',
      '1727770000000_${id}_图框.dwg',
      '1727770000000000_图框.dwg',
    ]) {
      expect(documentDisplayName('/app/imports/$name', name), '图框.dwg');
      expect(documentDisplayName('/Downloads/$name', name), name);
      expect(documentDisplayName('/app/imports/$id/$name', name), name);
    }
    expect(
      documentDisplayName('/app/imports/$id/R20-0000_1.dxf', 'R20-0000_1.dxf'),
      'R20-0000_1.dxf',
    );
  });
}
