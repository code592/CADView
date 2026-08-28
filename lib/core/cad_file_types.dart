import 'cad_engine.dart';

/// File extensions that are both implemented and exposed by the native core.
List<String> availableCadExtensions(Iterable<CadFormatDescriptor> formats) {
  final extensions = <String>{};
  for (final format in formats.where((format) => format.available)) {
    for (final extension in format.extensions) {
      final normalized = extension.trim().toLowerCase().replaceFirst(
        RegExp(r'^\.'),
        '',
      );
      if (normalized.isNotEmpty) extensions.add(normalized);
    }
  }
  return extensions.toList(growable: false)..sort();
}

bool hasCadExtension(String name, Iterable<String> allowedExtensions) {
  final separator = name.lastIndexOf('.');
  if (separator < 0 || separator == name.length - 1) return false;
  final extension = name.substring(separator + 1).toLowerCase();
  return allowedExtensions.any(
    (allowed) =>
        allowed.toLowerCase().replaceFirst(RegExp(r'^\.'), '') == extension,
  );
}
