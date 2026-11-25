part of '../../main.dart';

class DialpadSheet extends StatefulWidget {
  const DialpadSheet({
    super.key,
    required this.students,
    required this.onCallNumber,
    this.onStudentMatchedTap,
    this.initialNumber = '',
  });

  final List<Student> students;
  final Future<void> Function(String phone, {Student? matchedStudent})
      onCallNumber;
  final ValueChanged<Student>? onStudentMatchedTap;
  final String initialNumber;

  @override
  State<DialpadSheet> createState() => _DialpadSheetState();
}

class _DialpadSheetState extends State<DialpadSheet> {
  late String _digits = widget.initialNumber.trim();

  static const _keys = [
    ('1', ''),
    ('2', 'ABC'),
    ('3', 'DEF'),
    ('4', 'GHI'),
    ('5', 'JKL'),
    ('6', 'MNO'),
    ('7', 'PQRS'),
    ('8', 'TUV'),
    ('9', 'WXYZ'),
    ('*', ''),
    ('0', '+'),
    ('#', ''),
  ];

  Student? _findMatchingStudent() {
    final cleaned = _digits.replaceAll(RegExp(r'\D'), '');
    if (cleaned.length < 3) return null;
    for (final s in widget.students) {
      final phoneDigits = s.phone.replaceAll(RegExp(r'\D'), '');
      final waDigits = s.whatsappNumber.replaceAll(RegExp(r'\D'), '');
      if (phoneDigits.endsWith(cleaned) ||
          cleaned.endsWith(phoneDigits) && phoneDigits.length >= 9 ||
          (waDigits.isNotEmpty && waDigits.endsWith(cleaned))) {
        return s;
      }
    }
    return null;
  }

  void _appendDigit(String char) {
    HapticFeedback.lightImpact();
    setState(() => _digits += char);
  }

  void _backspace() {
    if (_digits.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() => _digits = _digits.substring(0, _digits.length - 1));
  }

  void _clearAll() {
    if (_digits.isEmpty) return;
    HapticFeedback.mediumImpact();
    setState(() => _digits = '');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matchedStudent = _findMatchingStudent();

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                height: 4,
                width: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (matchedStudent != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: widget.onStudentMatchedTap == null
                      ? null
                      : () {
                          Navigator.of(context).pop();
                          widget.onStudentMatchedTap!(matchedStudent);
                        },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: _green.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.person_search_rounded,
                          size: 16,
                          color: _green,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '${matchedStudent.name} • ${matchedStudent.callStatus.isEmpty ? "Lead" : matchedStudent.callStatus}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.onSurface,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Row(
              children: [
                const SizedBox(width: 40),
                Expanded(
                  child: Text(
                    _digits.isEmpty ? 'Enter number' : _digits,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: _digits.isEmpty ? 20 : 28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                      color: _digits.isEmpty
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: _digits.isNotEmpty
                      ? GestureDetector(
                          onLongPress: _clearAll,
                          child: IconButton(
                            tooltip: 'Backspace',
                            onPressed: _backspace,
                            icon: Icon(
                              Icons.backspace_outlined,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 16),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisExtent: 64,
                crossAxisSpacing: 14,
                mainAxisSpacing: 10,
              ),
              itemCount: _keys.length,
              itemBuilder: (context, index) {
                final (digit, sub) = _keys[index];
                return Material(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(18),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => _appendDigit(digit),
                    onLongPress: digit == '0' ? () => _appendDigit('+') : null,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          digit,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        if (sub.isNotEmpty)
                          Text(
                            sub,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.onSurfaceVariant,
                              letterSpacing: 1.2,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: _green,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                ),
                onPressed: _digits.trim().isEmpty
                    ? null
                    : () async {
                        final numberToCall = _digits.trim();
                        Navigator.of(context).pop();
                        await widget.onCallNumber(
                          numberToCall,
                          matchedStudent: matchedStudent,
                        );
                      },
                icon: const Icon(Icons.call_rounded),
                label: Text(
                  matchedStudent != null
                      ? 'Call ${matchedStudent.name}'
                      : 'Call',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
