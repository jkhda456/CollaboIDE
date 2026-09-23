import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../l10n/app_localizations.dart';
import '../platform/platform_features.dart';
import 'adaptive.dart';

/// 폴더를 고른다.
///
/// 데스크톱은 OS 대화상자(file_selector). **iOS·iPadOS** 는 OS 가 폴더 선택을 주지 않으므로
/// 앱 `Documents/` 안을 둘러보는 대화상자를 띄운다(바깥으로는 못 나간다).
Future<String?> pickDirectory(
  BuildContext context, {
  String? initialDirectory,
  String? confirmButtonText,
}) async {
  if (PlatformFeatures.hasSystemFolderPicker) {
    return getDirectoryPath(initialDirectory: initialDirectory, confirmButtonText: confirmButtonText);
  }
  final root = PlatformFeatures.documentsDir;
  if (root == null) return null;
  final initial = initialDirectory == null ? null : PlatformFeatures.remap(initialDirectory);
  final start = initial != null &&
          (p.equals(initial, root) || p.isWithin(root, initial)) &&
          Directory(initial).existsSync()
      ? initial
      : (PlatformFeatures.projectsDir ?? root);
  return showDialog<String>(
    context: context,
    builder: (_) => _FolderPickerDialog(root: root, start: start, confirmText: confirmButtonText),
  );
}

class _FolderPickerDialog extends StatefulWidget {
  const _FolderPickerDialog({required this.root, required this.start, this.confirmText});

  final String root;
  final String start;
  final String? confirmText;

  @override
  State<_FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<_FolderPickerDialog> {
  late String _current = widget.start;
  List<String> _children = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _atRoot => p.equals(_current, widget.root);

  void _load() {
    try {
      final dirs = Directory(_current)
          .listSync(followLinks: false)
          .whereType<Directory>()
          .map((d) => d.path)
          .where((d) => !p.basename(d).startsWith('.'))
          .toList()
        ..sort((a, b) => p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()));
      setState(() {
        _children = dirs;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _children = const [];
        _error = '$e';
      });
    }
  }

  void _go(String dir) {
    _current = dir;
    _load();
  }

  Future<void> _newFolder() async {
    final l = AppLocalizations.of(context);
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.newFolder),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: Text(l.create)),
        ],
      ),
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || trimmed.contains('/') || trimmed.startsWith('.')) return;
    try {
      final dir = await Directory(p.join(_current, trimmed)).create();
      _go(dir.path);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final rel = p.relative(_current, from: widget.root);
    final location = _atRoot ? 'Collabo IDE' : p.join('Collabo IDE', rel);

    return AlertDialog(
      title: Text(l.folderPickerTitle),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      content: SizedBox(
        width: adaptiveDialogWidth(context, 480),
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: l.folderPickerUp,
                  onPressed: _atRoot ? null : () => _go(p.dirname(_current)),
                  icon: const Icon(Icons.arrow_upward),
                ),
                Expanded(
                  child: Text(location,
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                ),
                IconButton(
                  tooltip: l.newFolder,
                  onPressed: _newFolder,
                  icon: const Icon(Icons.create_new_folder_outlined),
                ),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: _error != null
                  ? Center(child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)))
                  : _children.isEmpty
                      ? Center(
                          child: Text(l.folderPickerEmpty,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)))
                      : ListView.builder(
                          itemCount: _children.length,
                          itemBuilder: (_, i) => ListTile(
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(p.basename(_children[i])),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _go(_children[i]),
                          ),
                        ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(l.folderPickerFilesAppHint,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(
          onPressed: () => Navigator.pop(context, _current),
          child: Text(widget.confirmText ?? l.selectButton),
        ),
      ],
    );
  }
}
