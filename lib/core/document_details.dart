import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';

Future<void> showDocumentDetails(
  BuildContext context,
  String name,
  String path,
) {
  final l10n = context.l10n;
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.text('fileName')),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(name),
            const SizedBox(height: 16),
            Text(l10n.text('filePath')),
            const SizedBox(height: 8),
            SelectableText(path),
          ],
        ),
      ),
      actions: [
        IconButton(
          tooltip: l10n.text('copyProperties'),
          icon: const Icon(Icons.copy_outlined),
          onPressed: () => Clipboard.setData(ClipboardData(text: path)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(l10n.text('done')),
        ),
      ],
    ),
  );
}
