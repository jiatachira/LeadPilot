part of '../main.dart';

class PinScreen extends StatefulWidget {
  const PinScreen({
    required this.isFirstTime,
    required this.storedPin,
    required this.onPinCreated,
    required this.onAuthenticated,
    this.biometricEnabled = false,
    this.onBiometricAuth,
    super.key,
  });

  final bool isFirstTime;
  final String? storedPin;
  final Future<void> Function(String) onPinCreated;
  final VoidCallback onAuthenticated;
  final bool biometricEnabled;
  final Future<bool> Function()? onBiometricAuth;

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  String _enteredPin = '';
  String? _setupPin;
  String? _message;
  bool _hasError = false;
  bool _showSuccess = false;
  bool _isSavingPin = false;
  // Fingerprint: how many times biometric failed — after 3 show PIN only.
  int _biometricFailCount = 0;
  bool _biometricRunning = false;

  static const _maxBiometricAttempts = 3;

  bool get _showBiometricButton =>
      widget.biometricEnabled &&
      !widget.isFirstTime &&
      _biometricFailCount < _maxBiometricAttempts;

  @override
  void initState() {
    super.initState();
    // Auto-trigger biometric prompt when screen appears (if enabled).
    if (widget.biometricEnabled && !widget.isFirstTime) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _doBiometricAuth(isAutoTrigger: true);
      });
    }
  }

  Future<void> _doBiometricAuth({bool isAutoTrigger = false}) async {
    if (_biometricRunning || widget.onBiometricAuth == null) return;
    setState(() => _biometricRunning = true);
    try {
      final success = await widget.onBiometricAuth!();
      if (!mounted) return;
      setState(() => _biometricRunning = false);
      if (!success) {
        if (isAutoTrigger) {
          // User simply dismissed the prompt to enter PIN or prompt closed cleanly.
          // Do NOT count as a failed attempt or show error text on initial startup.
          return;
        }
        setState(() {
          _biometricFailCount++;
          if (_biometricFailCount >= _maxBiometricAttempts) {
            _message = 'Fingerprint failed 3 times. Enter your PIN.';
            _hasError = true;
          } else {
            _message =
                'Fingerprint not recognised. '
                '${_maxBiometricAttempts - _biometricFailCount} tries left.';
            _hasError = true;
          }
        });
        return;
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _biometricRunning = false;
          if (!isAutoTrigger) {
            _biometricFailCount++;
            if (_biometricFailCount >= _maxBiometricAttempts) {
              _message = 'Fingerprint failed 3 times. Enter your PIN.';
              _hasError = true;
            } else {
              _message = 'Could not read fingerprint. Try again or enter PIN.';
              _hasError = true;
            }
          }
        });
      }
      return;
    }
  }

  String get _heading {
    if (!widget.isFirstTime) {
      return _showBiometricButton
          ? 'Welcome Back'
          : 'Welcome Back - Enter PIN';
    }
    return _setupPin == null ? 'Create Your 4-Digit PIN' : 'Confirm Your PIN';
  }

  String get _subtitle {
    if (!widget.isFirstTime) {
      return _showBiometricButton
          ? 'Use fingerprint or enter your PIN.'
          : 'Enter your PIN to access your directory.';
    }
    return _setupPin == null
        ? 'Set up a secure PIN to protect your student directory.'
        : 'Enter your new PIN once more to confirm.';
  }

  void _addDigit(String digit) {
    if (_enteredPin.length == 4 || _isSavingPin) return;
    setState(() {
      _enteredPin += digit;
      _message = null;
      _hasError = false;
      _showSuccess = false;
    });
    if (_enteredPin.length == 4) unawaited(_submitPin());
  }

  Future<void> _submitPin() async {
    if (widget.isFirstTime) {
      if (_setupPin == null) {
        setState(() {
          _setupPin = _enteredPin;
          _enteredPin = '';
          _message = 'PIN saved. Enter it again to confirm.';
          _showSuccess = true;
        });
        return;
      }

      if (_enteredPin != _setupPin) {
        _showPinError('PINs do not match. Please try again.');
        return;
      }

      setState(() {
        _isSavingPin = true;
        _message = 'Saving your PIN securely…';
      });
      try {
        await widget.onPinCreated(_enteredPin);
      } on Exception catch (error) {
        if (mounted) _showPinError('Could not save your PIN: $error');
      } finally {
        if (mounted) setState(() => _isSavingPin = false);
      }
      return;
    }

    if (_enteredPin != widget.storedPin) {
      _showPinError('That PIN isn’t correct. Please try again.');
      return;
    }

    widget.onAuthenticated();
  }

  void _showPinError(String message) {
    setState(() {
      _enteredPin = '';
      _message = message;
      _hasError = true;
      _showSuccess = false;
    });
  }

  void _deleteDigit() {
    if (_enteredPin.isEmpty || _isSavingPin) return;
    setState(() {
      _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1);
      _message = null;
      _hasError = false;
      _showSuccess = false;
    });
  }

  void _clearPin() {
    if (_enteredPin.isEmpty || _isSavingPin) return;
    setState(() {
      _enteredPin = '';
      _message = null;
      _hasError = false;
      _showSuccess = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFEAF1F8), Color(0xFFF7FAFC), Color(0xFFEAF5F1)],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 48,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 390),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const _BrandHeader(),
                        const SizedBox(height: 32),
                        Card(
                          elevation: 8,
                          shadowColor: _navy.withValues(alpha: 0.09),
                          color: Colors.white.withValues(alpha: 0.94),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(24, 26, 24, 22),
                            child: Column(
                              children: [
                                Text(
                                  _heading,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(
                                        color: _navy,
                                        fontWeight: FontWeight.w800,
                                      ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _subtitle,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: _muted,
                                    height: 1.4,
                                  ),
                                ),
                                const SizedBox(height: 26),
                                _PinIndicators(
                                  count: _enteredPin.length,
                                  hasError: _hasError,
                                  showSuccess: _showSuccess,
                                ),
                                const SizedBox(height: 12),
                                SizedBox(
                                  height: 22,
                                  child: Text(
                                    _message ?? ' ',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: _hasError
                                          ? const Color(0xFFC94343)
                                          : _green,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                _PinKeypad(
                                  onDigit: _addDigit,
                                  onClear: _clearPin,
                                  onBackspace: _deleteDigit,
                                ),
                                // 🔑 Fingerprint button — shown when biometric
                                // is enabled and hasn't failed 3 times yet.
                                if (_showBiometricButton) ...[
                                  const SizedBox(height: 18),
                                  TextButton.icon(
                                    onPressed: _biometricRunning
                                        ? null
                                        : () => _doBiometricAuth(isAutoTrigger: false),
                                    icon: _biometricRunning
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: _green,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.fingerprint_rounded,
                                            size: 28,
                                            color: _green,
                                          ),
                                    label: Text(
                                      _biometricRunning
                                          ? 'Scanning…'
                                          : 'Use Fingerprint',
                                      style: const TextStyle(
                                        color: _green,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 22),
                        const Text(
                          'Your student directory, protected.',
                          style: TextStyle(color: _muted, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PinIndicators extends StatelessWidget {
  const _PinIndicators({
    required this.count,
    required this.hasError,
    required this.showSuccess,
  });

  final int count;
  final bool hasError;
  final bool showSuccess;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (index) {
        final isFilled = index < count;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 48,
          height: 54,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: isFilled ? const Color(0xFFE9F6F1) : const Color(0xFFF7F9FB),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: hasError
                  ? const Color(0xFFC94343)
                  : isFilled || showSuccess
                  ? _green
                  : const Color(0xFFE4EAF0),
              width: isFilled || showSuccess ? 1.5 : 1,
            ),
          ),
          alignment: Alignment.center,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: isFilled ? 11 : 9,
            width: isFilled ? 11 : 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isFilled || showSuccess ? _green : const Color(0xFFD8E0E8),
            ),
          ),
        );
      }),
    );
  }
}

class _PinKeypad extends StatelessWidget {
  const _PinKeypad({
    required this.onDigit,
    required this.onClear,
    required this.onBackspace,
  });

  final ValueChanged<String> onDigit;
  final VoidCallback onClear;
  final VoidCallback onBackspace;

  @override
  Widget build(BuildContext context) {
    final keys = <Widget>[
      for (var digit = 1; digit <= 9; digit++)
        _DigitKey(label: '$digit', onPressed: () => onDigit('$digit')),
      _UtilityKey(label: 'Clear', onPressed: onClear),
      _DigitKey(label: '0', onPressed: () => onDigit('0')),
      _UtilityKey(
        icon: Icons.backspace_outlined,
        label: 'Delete',
        onPressed: onBackspace,
      ),
    ];

    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 12,
      childAspectRatio: 1.42,
      children: keys,
    );
  }
}

class _DigitKey extends StatelessWidget {
  const _DigitKey({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFF5F8FA),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onPressed,
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              color: _navy,
              fontSize: 23,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _UtilityKey extends StatelessWidget {
  const _UtilityKey({required this.label, required this.onPressed, this.icon});

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: _muted,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      child: icon == null
          ? Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            )
          : Icon(icon, size: 21, semanticLabel: label),
    );
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 72,
          width: 72,
          decoration: BoxDecoration(
            color: _navy,
            borderRadius: BorderRadius.circular(23),
            boxShadow: [
              BoxShadow(
                color: _navy.withValues(alpha: 0.18),
                blurRadius: 22,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: const Icon(
            Icons.school_rounded,
            color: Colors.white,
            size: 36,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'LeadPilot',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: _navy,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
      ],
    );
  }
}

