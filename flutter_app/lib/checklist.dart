import 'dart:convert';

import 'package:uuid/uuid.dart';

/// A shared checklist: groceries, plans, anything both people can tick.
class Checklist {
  const Checklist({required this.title, required this.items});

  final String title;
  final List<ChecklistItem> items;

  int get doneCount => items.where((item) => item.done).length;

  Checklist copyWith({String? title, List<ChecklistItem>? items}) =>
      Checklist(title: title ?? this.title, items: items ?? this.items);

  Map<String, dynamic> toJson() => {
    'title': title,
    'items': [for (final item in items) item.toJson()],
  };

  String encode() => jsonEncode(toJson());

  factory Checklist.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List<dynamic>? ?? const [];
    return Checklist(
      title: (json['title'] as String? ?? '').trim(),
      items: [
        for (final row in rawItems)
          ChecklistItem.fromJson(row as Map<String, dynamic>),
      ],
    );
  }
}

class ChecklistItem {
  const ChecklistItem({
    required this.id,
    required this.text,
    this.done = false,
  });

  final String id;
  final String text;
  final bool done;

  ChecklistItem copyWith({String? text, bool? done}) =>
      ChecklistItem(id: id, text: text ?? this.text, done: done ?? this.done);

  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'done': done};

  factory ChecklistItem.fromJson(Map<String, dynamic> json) => ChecklistItem(
    id: json['id'] as String? ?? const Uuid().v4(),
    text: (json['text'] as String? ?? '').trim(),
    done: json['done'] as bool? ?? false,
  );
}

const int checklistMaxItems = 30;
const int checklistMaxText = 80;
const int checklistMaxTitle = 60;

/// Builds a list from a title and one item per line, dropping blanks.
Checklist? checklistFromLines(String title, String lines) {
  final items = <ChecklistItem>[];
  for (final line in lines.split(RegExp(r'\r?\n'))) {
    final text = line.trim();
    if (text.isEmpty) continue;
    items.add(
      ChecklistItem(
        id: const Uuid().v4(),
        text: text.length > checklistMaxText
            ? text.substring(0, checklistMaxText)
            : text,
      ),
    );
    if (items.length >= checklistMaxItems) break;
  }
  if (items.isEmpty) return null;
  final trimmedTitle = title.trim();
  return Checklist(
    title: trimmedTitle.length > checklistMaxTitle
        ? trimmedTitle.substring(0, checklistMaxTitle)
        : trimmedTitle,
    items: items,
  );
}

Checklist? parseChecklist(String? body) {
  if (body == null || body.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return null;
    final list = Checklist.fromJson(decoded);
    if (list.items.isEmpty) return null;
    return list;
  } catch (_) {
    return null;
  }
}

Checklist toggleChecklistItem(Checklist list, String itemId) {
  return list.copyWith(
    items: [
      for (final item in list.items)
        if (item.id == itemId) item.copyWith(done: !item.done) else item,
    ],
  );
}
