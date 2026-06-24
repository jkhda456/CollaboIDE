import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../l10n/app_localizations.dart';

/// 프로젝트 이름 유효성 오류 종류(다국어 메시지 매핑용).
enum ProjectNameError { empty, invalidChars, invalidName, trailingDot, reserved }

/// 프로젝트 이름(=폴더명) 유효성 검사. 문제가 있으면 오류 종류, 없으면 null.
///
/// Windows/Linux/macOS 에서 모두 폴더명으로 쓸 수 없는 경우를 모두 막는다.
ProjectNameError? validateProjectName(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return ProjectNameError.empty;
  // 3개 OS 공통 금지: < > : " / \ | ? * 및 제어문자(0x00-0x1F).
  if (RegExp(r'[<>:"/\\|?*\x00-\x1F]').hasMatch(name)) {
    return ProjectNameError.invalidChars;
  }
  if (name == '.' || name == '..') return ProjectNameError.invalidName;
  // Windows: 마침표/공백으로 끝날 수 없음.
  if (name.endsWith('.') || name.endsWith(' ')) {
    return ProjectNameError.trailingDot;
  }
  // Windows 예약어(확장자 유무 무관).
  const reserved = {
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };
  if (reserved.contains(name.split('.').first.toUpperCase())) {
    return ProjectNameError.reserved;
  }
  return null;
}

/// 이름 오류를 현재 언어 메시지로 변환.
String projectNameErrorText(AppLocalizations l, ProjectNameError e) =>
    switch (e) {
      ProjectNameError.empty => l.nameEmpty,
      ProjectNameError.invalidChars => l.nameInvalidChars,
      ProjectNameError.invalidName => l.nameInvalidName,
      ProjectNameError.trailingDot => l.nameTrailingDot,
      ProjectNameError.reserved => l.nameReserved,
    };

/// 새 프로젝트 다이얼로그를 띄운다. 생성에 성공하면 새 프로젝트 폴더 경로를 반환.
/// [initialDir] 가 있으면 상위 경로 기본값으로 미리 채운다(직전 워크스페이스).
Future<String?> showNewProjectDialog(BuildContext context, {String? initialDir}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _NewProjectDialog(initialDir: initialDir),
  );
}

class _NewProjectDialog extends StatefulWidget {
  const _NewProjectDialog({this.initialDir});

  final String? initialDir;

  @override
  State<_NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends State<_NewProjectDialog> {
  final TextEditingController _name = TextEditingController();
  String? _parentDir;
  String? _ioError; // 폴더 생성 실패 등 비동기 오류
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _parentDir = widget.initialDir; // 직전 워크스페이스를 기본값으로
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _trimmedName => _name.text.trim();

  String? get _targetPath =>
      _parentDir != null && _trimmedName.isNotEmpty
          ? p.join(_parentDir!, _trimmedName)
          : null;

  /// 이름 자체의 유효성(빈 값 제외 — 빈 값은 버튼 비활성으로 처리).
  ProjectNameError? get _nameError =>
      _name.text.isEmpty ? null : validateProjectName(_name.text);

  /// 대상 경로가 이미 존재하는지.
  bool get _exists {
    final t = _targetPath;
    return t != null && (Directory(t).existsSync() || File(t).existsSync());
  }

  bool get _canCreate =>
      _parentDir != null &&
      _trimmedName.isNotEmpty &&
      validateProjectName(_name.text) == null &&
      !_exists &&
      !_creating;

  Future<void> _pickDir() async {
    final dir = await getDirectoryPath(
        initialDirectory: _parentDir,
        confirmButtonText: AppLocalizations.of(context).selectButton);
    // 경로를 고르면 경로 관련 오류 표시는 자동으로 사라진다(실시간 재계산).
    if (dir != null) setState(() => _parentDir = dir);
  }

  Future<void> _create() async {
    final l = AppLocalizations.of(context);
    final target = _targetPath;
    if (target == null || !_canCreate) return;
    // 생성 직전 한 번 더 존재 확인(경합 방지).
    if (Directory(target).existsSync() || File(target).existsSync()) {
      setState(() => _ioError = l.pathExists);
      return;
    }
    setState(() {
      _creating = true;
      _ioError = null;
    });
    try {
      await Directory(target).create(recursive: true);
      if (mounted) Navigator.of(context).pop(target);
    } catch (e) {
      if (mounted) {
        setState(() {
          _creating = false;
          _ioError = l.createFailed('$e');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    final pathMissing = _parentDir == null;
    final nameErr = _nameError;
    final nameErrText = nameErr != null ? projectNameErrorText(l, nameErr) : null;
    // 존재 오류는 이름/경로가 둘 다 정해지고 이름이 유효할 때만 의미가 있다.
    final existsError =
        (!pathMissing && _trimmedName.isNotEmpty && nameErr == null && _exists)
            ? l.pathExists
            : null;

    return AlertDialog(
      title: Text(l.newProjectTitle),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _parentDir ?? l.selectParentPath,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: pathMissing ? theme.colorScheme.error : null,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _pickDir,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: Text(l.selectPath),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l.projectNameLabel,
                border: const OutlineInputBorder(),
                errorText: nameErrText ?? existsError,
              ),
              // 입력이 바뀌면 모든 관련 표시를 실시간 재계산한다.
              onChanged: (_) => setState(() => _ioError = null),
              onSubmitted: (_) => _create(),
            ),
            if (_targetPath != null && existsError == null) ...[
              const SizedBox(height: 10),
              Text(l.createLocation(_targetPath!), style: theme.textTheme.bodySmall),
            ],
            if (_ioError != null) ...[
              const SizedBox(height: 10),
              Text(_ioError!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.cancel),
        ),
        FilledButton(
          onPressed: _canCreate ? _create : null,
          child: _creating
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(l.create),
        ),
      ],
    );
  }
}
