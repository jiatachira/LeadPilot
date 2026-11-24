part of '../../main.dart';

class _LeadReportsSheet extends StatelessWidget {
  const _LeadReportsSheet({
    required this.notInterestedCount,
    required this.notPotentialCount,
    required this.inactiveCount,
  });

  final int notInterestedCount;
  final int notPotentialCount;
  final int inactiveCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.fromLTRB(
        22,
        12,
        22,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Lead reports',
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Export closed leads as separate CSV reports.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Card(
              color: theme.colorScheme.surfaceContainerLow,
              child: Column(
                children: [
                  _reportTile(
                    context,
                    title: 'Not Interested',
                    count: notInterestedCount,
                    action: _LeadReportAction.notInterested,
                  ),
                  Divider(
                    height: 1,
                    indent: 56,
                    color: theme.colorScheme.outlineVariant,
                  ),
                  _reportTile(
                    context,
                    title: 'Not Potential',
                    count: notPotentialCount,
                    action: _LeadReportAction.notPotential,
                  ),
                  Divider(
                    height: 1,
                    indent: 56,
                    color: theme.colorScheme.outlineVariant,
                  ),
                  _reportTile(
                    context,
                    title: 'Inactive (Unreachable)',
                    count: inactiveCount,
                    action: _LeadReportAction.inactive,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reportTile(
    BuildContext context, {
    required String title,
    required int count,
    required _LeadReportAction action,
  }) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(
        Icons.file_download_outlined,
        color: count == 0 ? theme.colorScheme.onSurfaceVariant : _green,
      ),
      title: Text(title),
      subtitle: Text('$count student(s) · Export CSV'),
      enabled: count > 0,
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: count == 0 ? null : () => Navigator.pop(context, action),
    );
  }
}

