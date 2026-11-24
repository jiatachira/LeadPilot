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
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
      _ => Theme.of(context).colorScheme.onSurfaceVariant,
    };

    final cardWidget = Card(
      margin: EdgeInsets.zero,
      elevation: 2,
      shadowColor: _navy.withValues(alpha: isDark ? 0.25 : 0.07),
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: isDark
              ? const Color(0xFF344453)
              : const Color(0xFFF0F2F5),
          width: 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: isSelectionMode ? onLongPress : onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
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
                  radius: 25,
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
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        )
                      : Text(
                          student.initials,
                          style: const TextStyle(
                            color: _green,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      student.name,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          Icons.phone_outlined,
                          size: 14,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            student.phone,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (student.source.isNotEmpty ||
                        student.addedDate.isNotEmpty ||
                        student.location.isNotEmpty ||
                        student.examType.isNotEmpty ||
                        student.callStatus.isNotEmpty ||
                        student.nextCallDateTime.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (student.source.isNotEmpty)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? const Color(0xFF17382F)
                                      : const Color(0xFFEAF6F2),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  student.source,
                                  style: const TextStyle(
                                    color: _green,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            if (student.examType.isNotEmpty)
                              _StudentTag(
                                text: student.examType,
                                background: isDark
                                    ? const Color(0xFF2B3947)
                                    : const Color(0xFFEEF1F7),
                                foreground: Theme.of(context)
                                    .colorScheme
                                    .onSurface,
                              ),
                            if (student.examYear.isNotEmpty)
                              _StudentTag(
                                text: 'Exam ${student.examYear}',
                                background: isDark
                                    ? const Color(0xFF2B3947)
                                    : const Color(0xFFF1F4F8),
                                foreground: Theme.of(context)
                                    .colorScheme
                                    .onSurface,
                              ),
                            if (student.location.isNotEmpty)
                              _StudentTag(
                                text: student.location,
                                background: isDark
                                    ? const Color(0xFF17382F)
                                    : const Color(0xFFEAF3F1),
                                foreground: _green,
                              ),
                            if (student.callStatus.isNotEmpty)
                              _StudentTag(
                                text: student.callStatus,
                                background: statusColor.withValues(alpha: 0.12),
                                foreground: statusColor,
                              ),
                            if (activity.unansweredStreak >= 3)
                              _StudentTag(
                                text: activity.unansweredStreak >= 5
                                    ? '🚨 ${activity.unansweredStreak}x No Answer'
                                    : '⚠️ ${activity.unansweredStreak}x No Answer',
                                background: activity.color.withValues(alpha: 0.15),
                                foreground: activity.color,
                              ),
                            if (tryParseDate(student.nextCallDateTime)
                                case final reminder?)
                              _StudentTag(
                                text: !reminder.isAfter(DateTime.now())
                                    ? '⚠️ Overdue · ${_formatReminder(reminder)}'
                                    : 'Call · ${_formatReminder(reminder)}',
                                background: !reminder.isAfter(DateTime.now())
                                    ? (isDark ? const Color(0xFF4A2525) : const Color(0xFFFFEBEB))
                                    : (isDark ? const Color(0xFF44351F) : const Color(0xFFFFF3DF)),
                                foreground: !reminder.isAfter(DateTime.now())
                                    ? (isDark ? const Color(0xFFFF8B8B) : const Color(0xFFD32F2F))
                                    : (isDark ? const Color(0xFFFFC56E) : const Color(0xFF9A5A00)),
                              ),
                            if (student.addedDate.isNotEmpty)
                              Text(
                                student.addedDate,
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                  fontSize: 10,
                                ),
                              ),
                          ],
                        ),
                      ),
                    if (!isSelectionMode) ...[
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _QuickActionButton(
                              icon: const Icon(
                                Icons.history_rounded,
                                size: 19,
                              ),
                              tooltip: 'Call history',
                              onPressed: onNote,
                              backgroundColor: isDark
                                  ? const Color(0xFF2B3947)
                                  : const Color(0xFFF2F5F8),
                              foregroundColor: Theme.of(context)
                                  .colorScheme
                                  .onSurface,
                            ),
                            const SizedBox(width: 8),
                            _QuickActionButton(
                              icon: const FaIcon(
                                FontAwesomeIcons.whatsapp,
                                size: 19,
                              ),
                              tooltip: 'Open WhatsApp chat',
                              onPressed: onWhatsApp,
                              backgroundColor: isDark
                                  ? const Color(0xFF17382F)
                                  : const Color(0xFFE9F6F1),
                              foregroundColor: _green,
                            ),
                            const SizedBox(width: 6),
                            _QuickActionButton(
                              icon: const Icon(Icons.sms_outlined, size: 19),
                              tooltip: 'Send SMS',
                              onPressed: onSms,
                              backgroundColor: isDark
                                  ? const Color(0xFF1F3548)
                                  : const Color(0xFFEAF2FA),
                              foregroundColor: const Color(0xFF2E6FA3),
                            ),
                            const SizedBox(width: 6),
                            _QuickActionButton(
                              icon: const Icon(Icons.call_rounded, size: 19),
                              tooltip: 'Call student',
                              onPressed: onCall,
                              backgroundColor: isDark
                                  ? const Color(0xFF17382F)
                                  : const Color(0xFFE9F6F1),
                              foregroundColor: _green,
                            ),
                            const SizedBox(width: 6),
                            _QuickActionButton(
                              icon: const Icon(
                                Icons.person_add_alt_1_rounded,
                                size: 19,
                              ),
                              tooltip: 'Save contact',
                              onPressed: onSaveContact,
                              backgroundColor: isDark
                                  ? const Color(0xFF17382F)
                                  : const Color(0xFFE9F6F1),
                              foregroundColor: _green,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (isSelectionMode) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: cardWidget,
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Dismissible(
        key: ValueKey(
          'swipe_${student.phone}_${student.name}_${student.addedDate}',
        ),
        direction: DismissDirection.horizontal,
        confirmDismiss: (direction) async {
          if (direction == DismissDirection.startToEnd) {
            unawaited(HapticFeedback.mediumImpact());
            onCall();
          } else if (direction == DismissDirection.endToStart) {
            unawaited(HapticFeedback.mediumImpact());
            onWhatsApp();
          }
          return false;
        },
        background: Container(
          decoration: BoxDecoration(
            color: _green,
            borderRadius: BorderRadius.circular(18),
          ),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: const Row(
            children: [
              Icon(
                Icons.phone_forwarded_rounded,
                color: Colors.white,
                size: 24,
              ),
              SizedBox(width: 8),
              Text(
                'Direct Call',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
        secondaryBackground: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF25D366),
            borderRadius: BorderRadius.circular(18),
          ),
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                'WhatsApp',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              SizedBox(width: 8),
              FaIcon(
                FontAwesomeIcons.whatsapp,
                color: Colors.white,
                size: 24,
              ),
            ],
          ),
        ),
        child: cardWidget,
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

class _SyncStatusRow extends StatelessWidget {
  const _SyncStatusRow({
    required this.status,
    required this.isSyncing,
    required this.isConnected,
    required this.lastSyncTime,
    required this.onSync,
    this.offlineQueueCount = 0,
  });

  final String status;
  final bool isSyncing;
  final bool isConnected;
  final String? lastSyncTime;
  final VoidCallback onSync;
  final int offlineQueueCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final hasPendingOffline = offlineQueueCount > 0;
    final color = isSyncing
        ? theme.colorScheme.primary
        : hasPendingOffline
        ? const Color(0xFFE58A18)
        : isConnected
        ? theme.colorScheme.secondary
        : theme.colorScheme.onSurfaceVariant;
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isDark
                  ? hasPendingOffline
                        ? const Color(0xFF382914)
                        : isConnected
                        ? const Color(0xFF17382F)
                        : const Color(0xFF263440)
                  : hasPendingOffline
                  ? const Color(0xFFFEF6EC)
                  : isConnected
                  ? const Color(0xFFEAF6F2)
                  : const Color(0xFFF0F3F6),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                if (isSyncing)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.primary,
                    ),
                  )
                else
                  Icon(
                    hasPendingOffline
                        ? Icons.cloud_upload_outlined
                        : isConnected
                        ? Icons.cloud_done_outlined
                        : Icons.cloud_off_outlined,
                    size: 17,
                    color: color,
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (hasPendingOffline) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE58A18).withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$offlineQueueCount queued',
                      style: const TextStyle(
                        color: Color(0xFFE58A18),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ] else if (lastSyncTime != null && isConnected) ...[
                  const SizedBox(width: 6),
                  Text(
                    lastSyncTime!,
                    style: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        TextButton.icon(
          onPressed: isSyncing ? null : onSync,
          icon: const Icon(Icons.sync_rounded, size: 17),
          label: const Text('Sync now'),
          style: TextButton.styleFrom(
            foregroundColor: _green,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
        ),
      ],
    );
  }
}

class _QuickActionButton extends StatelessWidget {
  const _QuickActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: () {
        HapticFeedback.lightImpact();
        onPressed();
      },
      style: IconButton.styleFrom(
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
        fixedSize: const Size(40, 40),
        padding: EdgeInsets.zero,
      ),
      icon: icon,
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

