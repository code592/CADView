/// Older imports prefixed file names with an ID. Remove only the known import
/// naming scheme, never a similarly named file outside our imports directory.
String documentDisplayName(String path, String fallback) {
  final segments = path.replaceAll('\\', '/').split('/');
  if (segments.length < 2 || segments[segments.length - 2] != 'imports') {
    return fallback;
  }
  const uuid = r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}';
  return fallback
      .replaceFirst(
        RegExp(
          '^(?:[0-9]{13,16}_)?$uuid'
          '_',
        ),
        '',
      )
      .replaceFirst(RegExp(r'^[0-9]{16}_'), '');
}
