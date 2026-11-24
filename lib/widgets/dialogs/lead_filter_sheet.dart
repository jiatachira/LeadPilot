part of '../../main.dart';

class _LeadFilterSheet extends StatefulWidget {
  const _LeadFilterSheet({
    required this.initialStatus,
    required this.initialDateFrom,
    required this.initialDateTo,
  });

  final String? initialStatus;
  final DateTime? initialDateFrom;
  final DateTime? initialDateTo;

  @override
  State<_LeadFilterSheet> createState() => _LeadFilterSheetState();
}

class _LeadFilterSheetState extends State<_LeadFilterSheet> {
  static const _statuses = [
    'Pending',
    'Very Interested',
    'Interested',
    'Minimal Interested',
    'Inactive',
    'Answered',
    'No Answer',
    'Not Responding',
    'Wrong number',
    'Call Cut',
    'Line Busy',
    'Call Back',
    'Future',
  ];

  late String? _status = widget.initialStatus;
  late DateTime? _dateFrom = widget.initialDateFrom;
  late DateTime? _dateTo = widget.initialDateTo;
  String? _dateError;

  Future<void> _pickDate({required bool isStart}) async {
    final initial = isStart ? _dateFrom : _dateTo;
    final selected = await showDatePicker(
      context: context,
      initialDate: initial ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: isStart ? 'Select start date' : 'Select end date',
    );
    if (!mounted || selected == null) return;
    setState(() {
      if (isStart) {
        _dateFrom = _dateOnly(selected);
      } else {
        _dateTo = _dateOnly(selected);
      }
      _dateError = null;
    });
  }

  void _selectQuickDate(String period) {
    final now = DateTime.now();
    final today = _dateOnly(now);
    final weekStart = today.subtract(Duration(days: today.weekday - 1));
    final monthStart = DateTime(today.year, today.month);
    setState(() {
      switch (period) {
        case 'Today':
          _dateFrom = today;
          _dateTo = today;
        case 'This week':
          _dateFrom = weekStart;
          _dateTo = today;
        case 'This month':
          _dateFrom = monthStart;
          _dateTo = today;
      }
      _dateError = null;
    });
  }

  void _apply() {
    if (_dateFrom != null && _dateTo != null && _dateFrom!.isAfter(_dateTo!)) {
      setState(() => _dateError = 'Start date must be on or before end date.');
      return;
    }
    Navigator.of(context).pop(
      _LeadFilterSelection(
        callStatus: _status,
        dateFrom: _dateFrom,
        dateTo: _dateTo,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = Theme.of(context).colorScheme.surface;
    final textColor = Theme.of(context).colorScheme.onSurface;

    return Container(
      padding: EdgeInsets.fromLTRB(
        22,
        12,
        22,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  height: 4,
                  width: 40,
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF526170)
                        : const Color(0xFFDDE3E9),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Filter students',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(color: textColor, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: ValueKey(_status ?? 'all-statuses'),
                initialValue: _status,
                decoration: const InputDecoration(
                  labelText: 'Call status',
                  prefixIcon: Icon(Icons.call_outlined),
                ),
                hint: const Text('All statuses'),
                items: [
                  const DropdownMenuItem<String>(
                    value: null,
                    child: Text('All statuses'),
                  ),
                  ..._statuses.map(
                    (status) => DropdownMenuItem<String>(
                      value: status,
                      child: Text(status),
                    ),
                  ),
                ],
                onChanged: (value) => setState(() => _status = value),
              ),
              const SizedBox(height: 18),
              Text(
                'Added date range',
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(color: textColor, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickDate(isStart: true),
                      icon: const Icon(Icons.calendar_today_outlined),
                      label: Text(
                        'From · ${_formatFilterDate(_dateFrom)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickDate(isStart: false),
                      icon: const Icon(Icons.event_outlined),
                      label: Text(
                        'To · ${_formatFilterDate(_dateTo)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                children: [
                  ActionChip(
                    label: const Text('Today'),
                    onPressed: () => _selectQuickDate('Today'),
                  ),
                  ActionChip(
                    label: const Text('This week'),
                    onPressed: () => _selectQuickDate('This week'),
                  ),
                  ActionChip(
                    label: const Text('This month'),
                    onPressed: () => _selectQuickDate('This month'),
                  ),
                ],
              ),
              if (_dateError != null) ...[
                const SizedBox(height: 4),
                Text(
                  _dateError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => setState(() {
                        _status = null;
                        _dateFrom = null;
                        _dateTo = null;
                        _dateError = null;
                      }),
                      child: const Text('Clear filters'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _apply,
                      child: const Text('Apply filters'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

