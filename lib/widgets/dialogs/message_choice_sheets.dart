part of '../../main.dart';

class WhatsAppChoiceSheet extends StatelessWidget {
  const WhatsAppChoiceSheet({super.key, required this.student});

  final Student student;

  @override
  Widget build(BuildContext context) {
    return MessageChoiceSheet(student: student, isSms: false);
  }
}

class SmsChoiceSheet extends StatelessWidget {
  const SmsChoiceSheet({super.key, required this.student});

  final Student student;

  @override
  Widget build(BuildContext context) {
    return MessageChoiceSheet(student: student, isSms: true);
  }
}

class MessageChoiceSheet extends StatelessWidget {
  const MessageChoiceSheet({
    super.key,
    required this.student,
    this.isSms = false,
  });

  final Student student;
  final bool isSms;

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
              const SizedBox(height: 18),
              Text(
                isSms ? 'Send SMS Message' : 'Send WhatsApp Message',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                isSms ? 'SMS to ${student.name}' : 'Message to ${student.name}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              Card(
                color: theme.colorScheme.surfaceContainerLow,
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(
                        isSms ? Icons.sms_outlined : Icons.chat_bubble_outline,
                        color: isSms ? const Color(0xFF2E6FA3) : null,
                      ),
                      title: const Text('Custom'),
                      subtitle: Text(
                        isSms
                            ? 'Open SMS app with a blank message'
                            : 'Open WhatsApp with a blank chat',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () =>
                          Navigator.pop(context, _MessageChoice.custom),
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    ListTile(
                      leading: const Icon(Icons.text_snippet_outlined),
                      title: const Text('Template'),
                      subtitle:
                          const Text('Choose a pre-written message template'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () =>
                          Navigator.pop(context, _MessageChoice.template),
                    ),
                    Divider(
                      height: 1,
                      indent: 56,
                      color: theme.colorScheme.outlineVariant,
                    ),
                    ListTile(
                      leading: const Icon(
                        Icons.auto_awesome_rounded,
                        color: Color(0xFF8B5CF6),
                      ),
                      title: Row(
                        children: [
                          const Text('Generate with AI'),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF8B5CF6)
                                  .withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'Gemini',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF8B5CF6),
                              ),
                            ),
                          ),
                        ],
                      ),
                      subtitle: const Text(
                        'Personalized message based on call notes',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.pop(context, _MessageChoice.ai),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

