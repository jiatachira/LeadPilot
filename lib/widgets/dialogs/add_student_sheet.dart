part of '../../main.dart';

class _AddStudentSheet extends StatefulWidget {
  const _AddStudentSheet();

  @override
  State<_AddStudentSheet> createState() => _AddStudentSheetState();
}

class _AddStudentSheetState extends State<_AddStudentSheet> {
  final _formKey = GlobalKey<FormState>();
  final _entriesController = TextEditingController();
  static const _sources = ['Facebook', 'Hotline', 'Database', 'WhatsApp'];
  String _source = 'Facebook';

  @override
  void dispose() {
    _entriesController.dispose();
    super.dispose();
  }

  String? _validateEntries(String? value) {
    final lines = (value ?? '')
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return 'Enter at least one student.';

    for (var index = 0; index < lines.length; index++) {
      final separator = lines[index].indexOf('-');
      if (separator <= 0 ||
          separator == lines[index].length - 1 ||
          lines[index].substring(0, separator).trim().isEmpty ||
          lines[index].substring(separator + 1).trim().isEmpty) {
        return 'Line ${index + 1}: use Name - Contact Number.';
      }
    }
    return null;
  }

  List<Student> _parseEntries() {
    final now = DateTime.now();
    final addedDate =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';

    return _entriesController.text
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().isNotEmpty)
        .map((line) {
          final separator = line.indexOf('-');
          return Student(
            name: line.substring(0, separator).trim(),
            phone: line.substring(separator + 1).trim(),
            source: _source,
            addedDate: addedDate,
          );
        })
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        22,
        12,
        22,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    height: 4,
                    width: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFFDDE3E9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  'Add New Student',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Add one contact per line using Name - Contact Number.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 18),
                TextFormField(
                  controller: _entriesController,
                  autofocus: true,
                  minLines: 4,
                  maxLines: 6,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    alignLabelWithHint: true,
                    labelText: 'Student names and contact numbers',
                    hintText:
                        'Achira Maneth - 0701061244\nMia Patel - 555-0104',
                    prefixIcon: Padding(
                      padding: EdgeInsets.only(bottom: 58),
                      child: Icon(Icons.people_outline_rounded),
                    ),
                  ),
                  validator: _validateEntries,
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: _source,
                  decoration: const InputDecoration(
                    labelText: 'Data source',
                    prefixIcon: Icon(Icons.source_outlined),
                  ),
                  items: _sources
                      .map(
                        (source) => DropdownMenuItem(
                          value: source,
                          child: Text(source),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => _source = value);
                  },
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 52,
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Theme.of(context)
                                .colorScheme
                                .onSurface,
                            side: BorderSide(
                              color: Theme.of(context)
                                  .colorScheme
                                  .outlineVariant,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: const Text('Cancel'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 52,
                        child: ElevatedButton(
                          onPressed: () {
                            if (!_formKey.currentState!.validate()) return;
                            Navigator.of(context).pop(_parseEntries());
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _green,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: const Text(
                            'Save Student(s)',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

