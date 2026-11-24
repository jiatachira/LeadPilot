part of '../../main.dart';

class _SheetSettingsSheet extends StatefulWidget {
  const _SheetSettingsSheet({
    required this.initialUrl,
    required this.initialName,
    required this.savedSheets,
    required this.isConnected,
  });

  final String initialUrl;
  final String initialName;
  final List<LinkedSheet> savedSheets;
  final bool isConnected;

  @override
  State<_SheetSettingsSheet> createState() => _SheetSettingsSheetState();
}

class _SheetSettingsSheetState extends State<_SheetSettingsSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _urlController = TextEditingController(
    text: widget.initialUrl,
  );
  late final TextEditingController _nameController = TextEditingController(
    text: widget.initialName,
  );
  late LinkedSheet? _selectedSavedSheet = widget.savedSheets
      .where((sheet) => sheet.url == widget.initialUrl)
      .firstOrNull;

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
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
                      color: isDark
                          ? const Color(0xFF526170)
                          : const Color(0xFFDDE3E9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Google Sheets Sync',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    _ConnectionBadge(isConnected: widget.isConnected),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Connect your Google Apps Script Web App to sync student contacts.',
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 18),
                if (widget.savedSheets.isNotEmpty) ...[
                  DropdownButtonFormField<LinkedSheet>(
                    initialValue: _selectedSavedSheet,
                    decoration: const InputDecoration(
                      labelText: 'Previously linked sheets',
                      prefixIcon: Icon(Icons.history_rounded),
                    ),
                    hint: const Text('Choose a saved sheet'),
                    items: widget.savedSheets
                        .map(
                          (sheet) => DropdownMenuItem<LinkedSheet>(
                            value: sheet,
                            child: Text(
                              sheet.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (sheet) {
                      if (sheet == null) return;
                      setState(() {
                        _selectedSavedSheet = sheet;
                        _nameController.text = sheet.name;
                        _urlController.text = sheet.url;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                TextFormField(
                  key: const ValueKey('sheet-name-input'),
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Sheet name',
                    hintText: 'e.g. 2026 A/L Leads',
                    prefixIcon: Icon(Icons.label_outline_rounded),
                  ),
                  validator: (value) => value?.trim().isNotEmpty == true
                      ? widget.savedSheets.any(
                              (sheet) =>
                                  sheet.url != _urlController.text.trim() &&
                                  sheet.name.toLowerCase() ==
                                      value!.trim().toLowerCase(),
                            )
                            ? 'Another linked sheet already uses this name'
                            : null
                      : 'Enter a name for this sheet',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('sheet-url-input'),
                  controller: _urlController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  onChanged: (_) {
                    if (_selectedSavedSheet != null &&
                        _urlController.text != _selectedSavedSheet!.url) {
                      setState(() => _selectedSavedSheet = null);
                    }
                    
                  },
                  decoration: const InputDecoration(
                    labelText: 'Google Apps Script Web App URL',
                    hintText: 'https://script.google.com/macros/s/.../exec',
                    prefixIcon: Icon(Icons.link_rounded),
                  ),
                  validator: (value) {
                    final uri = Uri.tryParse(value?.trim() ?? '');
                    if (uri == null ||
                        uri.scheme != 'https' ||
                        uri.host.isEmpty ||
                        !uri.path.endsWith('/exec')) {
                      return 'Enter a valid HTTPS Web App URL ending in /exec';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.brightness == Brightness.dark
                        ? const Color(0xFF24323E)
                        : const Color(0xFFF3F7F9),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Setup instructions',
                        style: TextStyle(
                          color: theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 7),
                      Text(
                        'Deploy your Apps Script as a Web App and paste its /exec URL. '
                        'GET should return a JSON list of {name, contact} records. '
                        'POST should read the JSON request body with name and contact. '
                        'Restrict access appropriately and validate writes in your script.',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 52,
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: theme.colorScheme.onSurface,
                            side: BorderSide(
                              color: theme.colorScheme.outlineVariant,
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
                        child: ElevatedButton.icon(
                          onPressed: () {
                            if (!_formKey.currentState!.validate()) return;
                            Navigator.of(context).pop(
                              LinkedSheet(
                                name: _nameController.text.trim(),
                                url: _urlController.text.trim(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.sync_rounded, size: 18),
                          label: const Text('Save & Sync'),
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

class _ConnectionBadge extends StatelessWidget {
  const _ConnectionBadge({required this.isConnected});

  final bool isConnected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final color = isConnected
        ? theme.colorScheme.secondary
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: isDark
            ? isConnected
                  ? const Color(0xFF17382F)
                  : const Color(0xFF263440)
            : isConnected
            ? const Color(0xFFEAF6F2)
            : const Color(0xFFF0F3F6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isConnected ? Icons.check_circle_rounded : Icons.circle_outlined,
            color: color,
            size: 14,
          ),
          const SizedBox(width: 5),
          Text(
            isConnected ? 'Connected' : 'Not connected',
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

enum _MessageChoice { custom, template, ai }

