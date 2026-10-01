import 'package:flutter/material.dart';

/// 「从储存中删除」前的确认。
///
/// 这是整个应用里唯一会动用户文件的操作，而且**不可恢复**，所以不管是一次删一首
/// （长按菜单）还是多选删一批，都必须先过这一道。
///
/// 话要说具体：删几个、会不会连记录一起没、和「从库中删除」差在哪。
/// 这两件事搞混的代价是丢文件，值得多写两句。
Future<bool> confirmDeleteFromStorage(
  BuildContext context, {
  required int count,
  String? title,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('从储存中删除 $count 个文件？'),
      content: Text(_body(count: count, title: title)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return ok ?? false;
}

String _body({required int count, String? title}) => <String>[
  if (title != null) '「$title」',
  count == 1
      ? '文件会从手机的存储里真正删掉，不能恢复（也不进回收站），曲库里的记录一起清掉。'
      : '这 $count 个文件会从手机的存储里真正删掉，不能恢复（也不进回收站），曲库里的记录一起清掉。',
  '如果只是想让它别出现在曲库里，用「从库中删除」——那个不动文件。',
].join('\n\n');
