/// Bitfinex 平台公告
class Announcement {
  final int id;
  final String title;
  final String bodyHtml;
  final int publicationTimestamp;
  final bool important;
  final bool? confirmation;

  /// 本地推导：是否在未读集合中
  final bool unread;

  const Announcement({
    required this.id,
    required this.title,
    required this.bodyHtml,
    required this.publicationTimestamp,
    required this.important,
    this.confirmation,
    this.unread = true,
  });

  factory Announcement.fromMap(Map<String, dynamic> m, {bool unread = true}) {
    return Announcement(
      id: (m['id'] as num?)?.toInt() ?? 0,
      title: (m['title'] as String?) ?? '',
      bodyHtml: (m['body'] as String?) ?? '',
      publicationTimestamp: (m['publication_timestamp'] as num?)?.toInt() ?? 0,
      important: m['important'] == true,
      confirmation: m.containsKey('confirmation')
          ? m['confirmation'] == true
          : null,
      unread: unread,
    );
  }

  Announcement copyWith({bool? unread}) {
    return Announcement(
      id: id,
      title: title,
      bodyHtml: bodyHtml,
      publicationTimestamp: publicationTimestamp,
      important: important,
      confirmation: confirmation,
      unread: unread ?? this.unread,
    );
  }

  DateTime get publishedAt =>
      DateTime.fromMillisecondsSinceEpoch(publicationTimestamp);

  /// 将 HTML body 转为可读纯文本（白名单外简单剥离标签）
  String get bodyPlain {
    var s = bodyHtml;
    // 常见块级标签换行
    s = s.replaceAll(
      RegExp(
        r'<(br|BR)\s*/?>|</(p|div|li|h[1-6]|tr)\s*>',
        caseSensitive: false,
      ),
      '\n',
    );
    s = s.replaceAll(RegExp(r'<[^>]*>'), '');
    s = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    // 折叠多余空白
    s = s.replaceAll(RegExp(r'[ \t]+\n'), '\n');
    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return s.trim();
  }
}

/// Incremental update received from the public `announcements` channel.
class AnnouncementEvent {
  final String action;
  final int id;
  final Announcement? announcement;
  final int? unreadCount;

  const AnnouncementEvent({
    required this.action,
    required this.id,
    this.announcement,
    this.unreadCount,
  });

  factory AnnouncementEvent.fromMap(Map<String, dynamic> map) {
    final action = (map['action'] as String? ?? '').toLowerCase();
    final id = (map['id'] as num?)?.toInt() ?? 0;
    return AnnouncementEvent(
      action: action,
      id: id,
      announcement: action == 'new'
          ? Announcement.fromMap(map, unread: false)
          : null,
      unreadCount: (map['unread'] as num?)?.toInt(),
    );
  }

  bool get isNew => action == 'new';
  bool get isDeleted => action == 'deleted';
}
