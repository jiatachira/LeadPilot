part of '../main.dart';

// ─────────────────────────────────────────────────────────────────────────────
// RecentsScreen — shows call history with recording playback
// ─────────────────────────────────────────────────────────────────────────────

enum _RecentsFilter { all, missed, recorded }

class RecentsScreen extends StatefulWidget {
  const RecentsScreen({
    required this.students,
    required this.onOpenStudent,
    required this.onCallNumber,
    required this.onOpenDialpad,
    this.onAddStudentWithPhone,
    super.key,
  });

  final List<Student> students;
  final void Function(Student) onOpenStudent;
  final Future<void> Function(String phone) onCallNumber;
  final VoidCallback onOpenDialpad;
  final void Function(String phone)? onAddStudentWithPhone;

  @override
  State<RecentsScreen> createState() => _RecentsScreenState();
}

class _RecentsScreenState extends State<RecentsScreen> {
  List<Map<String, dynamic>> _callLogs = [];
  List<Map<String, dynamic>> _recordings = [];
  _RecentsFilter _filter = _RecentsFilter.all;
  bool _isLoading = true;
  String? _playingPath;
  bool _isPlaying = false;
  Timer? _playbackPollTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _playbackPollTimer?.cancel();
    CallerIdService.stopPlayback();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      // Use system call log as the SOLE source of truth for call history.
      // Internal logs are only used as a fallback when system log permission is denied.
      final systemLogs = await CallerIdService.getSystemCallLogs(limit: 200);

      List<Map<String, dynamic>> sourceLogs;
      if (systemLogs.isNotEmpty) {
        // System log available — deduplicate within 2 minutes for same number
        sourceLogs = [];
        for (final log in systemLogs) {
          final phone = _digitsOnly(log['phone'] as String? ?? '');
          final ts = (log['timestamp'] as num?)?.toInt() ?? 0;
          final type = log['type'] as String? ?? '';
          final isDuplicate = sourceLogs.any((existing) {
            final ePhone = _digitsOnly(existing['phone'] as String? ?? '');
            final eTs = (existing['timestamp'] as num?)?.toInt() ?? 0;
            final eType = existing['type'] as String? ?? '';
            final sameNum = phone.isNotEmpty &&
                ePhone.isNotEmpty &&
                (phone == ePhone ||
                    (phone.length >= 7 && ePhone.endsWith(phone)) ||
                    (ePhone.length >= 7 && phone.endsWith(ePhone)));
            return sameNum && type == eType && (ts - eTs).abs() < 120000;
          });
          if (!isDuplicate) sourceLogs.add(log);
        }
      } else {
        // Fallback: internal logs when system log not accessible
        final internalLogs = await CallerIdService.getCallHistory();
        sourceLogs = [];
        for (final log in internalLogs) {
          final phone = _digitsOnly(log['phone'] as String? ?? '');
          final ts = (log['timestamp'] as num?)?.toInt() ?? 0;
          final isDuplicate = sourceLogs.any((existing) {
            final ePhone = _digitsOnly(existing['phone'] as String? ?? '');
            final eTs = (existing['timestamp'] as num?)?.toInt() ?? 0;
            final sameNum = phone.isNotEmpty &&
                ePhone.isNotEmpty &&
                (phone == ePhone ||
                    (phone.length >= 7 && ePhone.endsWith(phone)) ||
                    (ePhone.length >= 7 && phone.endsWith(ePhone)));
            return sameNum && (ts - eTs).abs() < 120000;
          });
          if (!isDuplicate) sourceLogs.add(log);
        }
        sourceLogs.sort((a, b) {
          final tsA = (a['timestamp'] as num?)?.toInt() ?? 0;
          final tsB = (b['timestamp'] as num?)?.toInt() ?? 0;
          return tsB.compareTo(tsA);
        });
      }

      final recordings = await CallerIdService.listRecordings();
      if (!mounted) return;
      setState(() {
        _callLogs = sourceLogs;
        _recordings = recordings;
        _isLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _digitsOnly(String phone) => phone.replaceAll(RegExp(r'[^\d]'), '');

  bool _phonesMatch(String a, String b) {
    final da = _digitsOnly(a);
    final db = _digitsOnly(b);
    if (da.isEmpty || db.isEmpty) return false;
    return da == db || da.endsWith(db) || db.endsWith(da);
  }

  Student? _matchStudent(String phone) {
    for (final s in widget.students) {
      if (_phonesMatch(s.phone, phone) ||
          (s.whatsappNumber.isNotEmpty &&
              _phonesMatch(s.whatsappNumber, phone))) {
        return s;
      }
    }
    return null;
  }

  Map<String, dynamic>? _recordingForCall(
    String phone,
    int callTimestampMs,
    int durationSec,
  ) {
    final matching = _recordings.where((r) {
      final rp = r['phone'] as String? ?? '';
      return _phonesMatch(rp, phone);
    }).toList();
    if (matching.isEmpty) return null;
    if (callTimestampMs <= 0) return matching.first;

    final maxWindowMs =
        (durationSec * 1000) + 120000; // duration + 2 min buffer
    for (final r in matching) {
      final recTs = (r['timestampMs'] as num?)?.toInt() ?? 0;
      if (recTs > 0 && (callTimestampMs - recTs).abs() <= maxWindowMs) {
        return r;
      }
    }
    return null;
  }

  List<Map<String, dynamic>> get _filtered {
    switch (_filter) {
      case _RecentsFilter.missed:
        return _callLogs
            .where((l) => l['type'] == 'missed' || l['type'] == 'rejected')
            .toList();
      case _RecentsFilter.recorded:
        return _callLogs.where((l) {
          final phone = l['phone'] as String? ?? '';
          final ts = (l['timestamp'] as num?)?.toInt() ?? 0;
          final dur = (l['duration'] as num?)?.toInt() ?? 0;
          return _recordingForCall(phone, ts, dur) != null;
        }).toList();
      case _RecentsFilter.all:
        return _callLogs;
    }
  }

  String _formatDuration(int seconds) {
    if (seconds <= 0) return '';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String _relativeTime(int timestampMs) {
    final diff = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(timestampMs),
    );
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  Future<void> _togglePlayback(String path) async {
    if (path.isEmpty) return;
    if (_playingPath == path && _isPlaying) {
      _playbackPollTimer?.cancel();
      await CallerIdService.stopPlayback();
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _playingPath = null;
        });
      }
    } else {
      _playbackPollTimer?.cancel();
      if (_playingPath != null) await CallerIdService.stopPlayback();
      final ok = await CallerIdService.playRecording(path);
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not play recording or file is unavailable'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      setState(() {
        _playingPath = ok ? path : null;
        _isPlaying = ok;
      });
      if (ok) {
        _playbackPollTimer = Timer.periodic(const Duration(milliseconds: 500), (
          _,
        ) async {
          final status = await CallerIdService.getPlaybackStatus();
          final playing = status['isPlaying'] as bool? ?? false;
          if (!playing && mounted) {
            _playbackPollTimer?.cancel();
            setState(() {
              _isPlaying = false;
              _playingPath = null;
            });
          }
        });
      }
    }
  }

  Future<void> _deleteRecording(Map<String, dynamic> rec) async {
    final path = rec['path'] as String? ?? '';
    if (path.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Recording?'),
        content: const Text('This recording will be permanently deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (_playingPath == path) {
      _playbackPollTimer?.cancel();
      await CallerIdService.stopPlayback();
      _playingPath = null;
      _isPlaying = false;
    }
    await CallerIdService.deleteRecording(path);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _filtered;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              floating: true,
              title: const Text('Recent Calls'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: 'Refresh call history',
                  onPressed: _load,
                ),
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(52),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Row(
                    children: [
                      for (final f in _RecentsFilter.values)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: FilterChip(
                            label: Text(switch (f) {
                              _RecentsFilter.all => 'All',
                              _RecentsFilter.missed => 'Missed',
                              _RecentsFilter.recorded => 'Recorded',
                            }),
                            selected: _filter == f,
                            onSelected: (_) => setState(() => _filter = f),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (_isLoading)
              const SliverFillRemaining(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (filtered.isEmpty)
              SliverFillRemaining(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.phone_missed_rounded,
                        size: 64,
                        color: theme.colorScheme.outlineVariant,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _filter == _RecentsFilter.all
                            ? 'No recent calls'
                            : 'No calls match this filter',
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              SliverList.separated(
                itemCount: filtered.length,
                separatorBuilder: (_, _) => Divider(
                  height: 1,
                  indent: 72,
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.5,
                  ),
                ),
                itemBuilder: (ctx, i) =>
                    _buildCallTile(ctx, filtered[i], theme),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'fab_recents_dialpad',
        onPressed: widget.onOpenDialpad,
        backgroundColor: theme.colorScheme.secondaryContainer,
        foregroundColor: theme.colorScheme.onSecondaryContainer,
        elevation: 3,
        child: const Icon(Icons.dialpad_rounded),
      ),
    );
  }

  Widget _buildCallTile(
    BuildContext context,
    Map<String, dynamic> log,
    ThemeData theme,
  ) {
    final phone = log['phone'] as String? ?? '';
    final type = log['type'] as String? ?? 'unknown';
    final durationSec = (log['duration'] as num?)?.toInt() ?? 0;
    final timestampMs = (log['timestamp'] as num?)?.toInt() ?? 0;
    final student = _matchStudent(phone);
    final recording = _recordingForCall(phone, timestampMs, durationSec);

    final (dirIcon, dirColor) = switch (type) {
      'incoming' => (Icons.call_received_rounded, Colors.green),
      'outgoing' => (Icons.call_made_rounded, Colors.blue),
      'missed' || 'rejected' => (Icons.call_missed_rounded, Colors.red),
      _ => (Icons.call_rounded, theme.colorScheme.onSurface),
    };

    final title = student != null && student.name.isNotEmpty
        ? student.name
        : (phone.isNotEmpty ? phone : 'Unknown');
    final dur = durationSec > 0
        ? _formatDuration(durationSec)
        : (type == 'outgoing'
              ? 'Unanswered'
              : (type == 'missed'
                    ? 'Missed call'
                    : (type == 'rejected' ? 'Declined' : '')));
    final subtitleParts = <String>[
      if (student != null) phone,
      if (student != null && student.callStatus.isNotEmpty) student.callStatus,
      if (dur.isNotEmpty) dur,
    ];
    final subtitle = subtitleParts.isNotEmpty
        ? subtitleParts.join(' • ')
        : type;
    final relTime = timestampMs > 0 ? _relativeTime(timestampMs) : '';
    final recPath = recording?['path'] as String? ?? '';
    final isThisPlaying =
        recPath.isNotEmpty && _playingPath == recPath && _isPlaying;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        backgroundColor: dirColor.withValues(alpha: 0.12),
        child: Icon(dirIcon, color: dirColor, size: 20),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: type == 'missed' || type == 'rejected'
                    ? Colors.red
                    : null,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (relTime.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(
              relTime,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          if (recording != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  SizedBox(
                    height: 28,
                    child: FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => _togglePlayback(recPath),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isThisPlaying
                                ? Icons.stop_rounded
                                : Icons.play_arrow_rounded,
                            size: 16,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isThisPlaying ? 'Stop' : 'Play Recording',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    height: 28,
                    width: 28,
                    child: IconButton.outlined(
                      icon: const Icon(Icons.delete_outline_rounded, size: 16),
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red, width: 0.5),
                        padding: const EdgeInsets.all(4),
                      ),
                      onPressed: () => _deleteRecording(recording),
                      tooltip: 'Delete recording',
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      trailing: phone.isNotEmpty
          ? IconButton(
              icon: const Icon(Icons.call_rounded),
              color: Colors.green,
              tooltip: 'Call $phone',
              onPressed: () => widget.onCallNumber(phone),
            )
          : null,
      onTap: () {
        if (student != null) {
          widget.onOpenStudent(student);
        } else if (phone.isNotEmpty) {
          showModalBottomSheet<void>(
            context: context,
            builder: (ctx) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(
                      Icons.call_rounded,
                      color: Colors.green,
                    ),
                    title: Text('Call $phone'),
                    onTap: () {
                      Navigator.pop(ctx);
                      widget.onCallNumber(phone);
                    },
                  ),
                  if (widget.onAddStudentWithPhone != null)
                    ListTile(
                      leading: const Icon(Icons.person_add_alt_1_rounded),
                      title: const Text('Add to Leads'),
                      onTap: () {
                        Navigator.pop(ctx);
                        widget.onAddStudentWithPhone!(phone);
                      },
                    ),
                ],
              ),
            ),
          );
        }
      },
    );
  }
}
