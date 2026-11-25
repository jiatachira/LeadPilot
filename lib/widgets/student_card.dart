part of '../main.dart';

class StudentCard extends StatelessWidget {
  const StudentCard({
    required this.student,
    required this.onTap,
    required this.onLongPress,
    required this.onCall,
    required this.onWhatsApp,
    required this.onSms,
    required this.onNote,
    required this.onSaveContact,
    this.isSelectionMode = false,
    this.isSelected = false,
    super.key,
  });

  final Student student;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onCall;
  final VoidCallback onWhatsApp;
  final VoidCallback onSms;
  final VoidCallback onNote;
  final VoidCallback onSaveContact;
  final bool isSelectionMode;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final activity = studentActivityStatus(student);

    final statusColor = switch (student.callStatus) {
      'Very Interested' || 'Interested' || 'Answered' => _green,
      'Minimal Interested' ||
      'No Answer' ||
      'Not Responding' ||
      'Line Busy' ||
      'Call Back' ||
      'Future' => const Color(0xFFB36B16),
      'Not Interested' ||
      'Not Potential' ||
      'Not Protencial' ||
      'Wrong number' ||
      'Call Cut' => const Color(0xFFB54747),
      _ => theme.colorScheme.onSurfaceVariant,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: theme.colorScheme.outlineVariant,
            width: 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: isSelectionMode ? onLongPress : onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Badge(
                  isLabelVisible:
                      !isSelectionMode && activity.unansweredStreak >= 3,
                  alignment: Alignment.topRight,
                  backgroundColor: activity.unansweredStreak >= 5
                      ? const Color(0xFFD64545)
                      : const Color(0xFFE58A18),
                  largeSize: 18,
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  label: Text(
                    '${activity.unansweredStreak}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 10,
                      color: Colors.white,
                    ),
                  ),
                  child: CircleAvatar(
                    radius: 22,
                    backgroundColor: isSelectionMode && isSelected
                        ? _green
                        : isDark
                        ? const Color(0xFF17382F)
                        : const Color(0xFFEAF3F1),
                    child: isSelectionMode
                        ? Icon(
                            isSelected
                                ? Icons.check_rounded
                                : Icons.circle_outlined,
                            color: isSelected
                                ? Colors.white
                                : theme.colorScheme.onSurfaceVariant,
                          )
                        : Text(
                            student.initials,
                            style: const TextStyle(
                              color: _green,
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        student.name,
                        style: TextStyle(
                          color: theme.colorScheme.onSurface,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        student.phone,
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (student.callStatus.isNotEmpty ||
                          tryParseDate(student.nextCallDateTime) != null) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            if (student.callStatus.isNotEmpty)
                              _StudentTag(
                                text: student.callStatus,
                                background: statusColor.withValues(alpha: 0.12),
                                foreground: statusColor,
                              ),
                            if (tryParseDate(student.nextCallDateTime)
                                case final reminder?) ...[
                              () {
                                final isOverdue =
                                    !reminder.isAfter(DateTime.now());
                                return _StudentTag(
                                  text: 'Call · ${_formatReminder(reminder)}',
                                  background: isOverdue
                                      ? (isDark
                                          ? const Color(0xFF4A2525)
                                          : const Color(0xFFFFEBEB))
                                      : (isDark
                                          ? const Color(0xFF44351F)
                                          : const Color(0xFFFFF3DF)),
                                  foreground: isOverdue
                                      ? (isDark
                                          ? const Color(0xFFFF8B8B)
                                          : const Color(0xFFD32F2F))
                                      : (isDark
                                          ? const Color(0xFFFFC56E)
                                          : const Color(0xFF9A5A00)),
                                );
                              }(),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                if (!isSelectionMode) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Call history',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    onPressed: onNote,
                    icon: Icon(
                      Icons.history_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 2),
                  IconButton.filled(
                    tooltip: 'Call student',
                    style: IconButton.styleFrom(
                      backgroundColor: _green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.all(9),
                    ),
                    onPressed: onCall,
                    icon: const Icon(Icons.call_rounded, size: 20),
                  ),
                  PopupMenuButton<String>(
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      Icons.more_vert_rounded,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    tooltip: 'More actions',
                    onSelected: (action) {
                      switch (action) {
                        case 'whatsapp':
                          onWhatsApp();
                          break;
                        case 'sms':
                          onSms();
                          break;
                        case 'history':
                          onNote();
                          break;
                        case 'save':
                          onSaveContact();
                          break;
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'history',
                        child: Row(
                          children: [
                            Icon(Icons.history_rounded, size: 18),
                            SizedBox(width: 12),
                            Text('History'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'whatsapp',
                        child: Row(
                          children: [
                            FaIcon(
                              FontAwesomeIcons.whatsapp,
                              size: 18,
                              color: _green,
                            ),
                            SizedBox(width: 12),
                            Text('WhatsApp'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'sms',
                        child: Row(
                          children: [
                            Icon(Icons.sms_outlined, size: 18),
                            SizedBox(width: 12),
                            Text('SMS'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'save',
                        child: Row(
                          children: [
                            Icon(Icons.person_add_alt_1_rounded, size: 18),
                            SizedBox(width: 12),
                            Text('Save contact'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StudentTag extends StatelessWidget {
  const _StudentTag({
    required this.text,
    required this.background,
    required this.foreground,
  });

  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: foreground,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _EmptySearchState extends StatelessWidget {
  const _EmptySearchState({required this.isSearching});

  final bool isSearching;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.person_search_rounded,
              size: 48,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.65),
            ),
            const SizedBox(height: 12),
            Text(
              isSearching ? 'No students found' : 'No students yet',
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              isSearching
                  ? 'Try another name or phone number.'
                  : 'Tap Add student to add your first contact.',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
