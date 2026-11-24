part of '../main.dart';

class EditDetailsScreen extends StatefulWidget {
  const EditDetailsScreen({
    super.key,
    required this.student,
  });

  final Student student;

  @override
  State<EditDetailsScreen> createState() => _EditDetailsScreenState();
}

class _EditDetailsScreenState extends State<EditDetailsScreen> {
  final _formKey = GlobalKey<FormState>();

  late final _nameController = TextEditingController(text: widget.student.name);
  late final _phoneController = TextEditingController(
    text: widget.student.phone,
  );
  late final _examYearController = TextEditingController(
    text: widget.student.examYear,
  );
  late final _locationController = TextEditingController(
    text: widget.student.location,
  );
  late final _englishController = TextEditingController(
    text: widget.student.olEnglish,
  );
  late final _mathsController = TextEditingController(
    text: widget.student.olMaths,
  );
  late final _whatsappController = TextEditingController(
    text: widget.student.whatsappNumber,
  );

  static const _examTypes = ['O/L', 'A/L'];
  late String? _examType = _examTypes.contains(widget.student.examType)
      ? widget.student.examType
      : null;
  late bool _sameAsContact = widget.student.whatsappSameAsContact ||
      widget.student.whatsappNumber == widget.student.phone;

  @override
  void initState() {
    super.initState();
    if (_sameAsContact) _whatsappController.text = widget.student.phone;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _examYearController.dispose();
    _locationController.dispose();
    _englishController.dispose();
    _mathsController.dispose();
    _whatsappController.dispose();
    super.dispose();
  }

  void _onSave() {
    if (!_formKey.currentState!.validate()) return;
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    final updated = widget.student.copyWith(
      name: name,
      phone: phone,
      examType: _examType ?? '',
      examYear: _examYearController.text.trim(),
      location: _locationController.text.trim(),
      olEnglish: _englishController.text.trim().toUpperCase(),
      olMaths: _mathsController.text.trim().toUpperCase(),
      whatsappNumber: _sameAsContact ? phone : _whatsappController.text.trim(),
      whatsappSameAsContact: _sameAsContact,
    );
    Navigator.of(context).pop(updated);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Edit Details · ${widget.student.name}'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const ValueKey('edit-name-input'),
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Student name',
                    prefixIcon: Icon(Icons.person_outline_rounded),
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Enter a student name'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('edit-phone-input'),
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Contact number',
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                  validator: (value) =>
                      value == null || normalizeContactPhone(value).isEmpty
                          ? 'Enter a valid contact number'
                          : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _examType,
                  decoration: const InputDecoration(
                    labelText: 'Exam type',
                    prefixIcon: Icon(Icons.school_outlined),
                  ),
                  hint: const Text('Select exam type'),
                  items: _examTypes
                      .map(
                        (type) =>
                            DropdownMenuItem(value: type, child: Text(type)),
                      )
                      .toList(),
                  onChanged: (value) => setState(() => _examType = value),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _examYearController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Exam Year',
                    hintText: 'e.g. 2026',
                    prefixIcon: Icon(Icons.calendar_today_outlined),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) return null;
                    if (!RegExp(r'^\d{4}$').hasMatch(value.trim())) {
                      return 'Enter a 4-digit exam year';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _locationController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Location / City',
                    prefixIcon: Icon(Icons.location_city_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _englishController,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                          labelText: 'O/L English',
                          hintText: 'A / B / C / S',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _mathsController,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                          labelText: 'O/L Maths',
                          hintText: 'A / B / C / S',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _whatsappController,
                  keyboardType: TextInputType.phone,
                  enabled: !_sameAsContact,
                  decoration: const InputDecoration(
                    labelText: 'WhatsApp number',
                    prefixIcon: Icon(Icons.chat_outlined),
                  ),
                ),
                Material(
                  color: Colors.transparent,
                  child: CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _sameAsContact,
                    activeColor: _green,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text(
                      'Same as contact number',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onChanged: (value) {
                      final checked = value ?? false;
                      setState(() {
                        _sameAsContact = checked;
                        if (checked) {
                          _whatsappController.text =
                              _phoneController.text.trim();
                        } else if (_whatsappController.text ==
                            _phoneController.text.trim()) {
                          _whatsappController.clear();
                        }
                      });
                    },
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: _onSave,
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('Save'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _green,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
