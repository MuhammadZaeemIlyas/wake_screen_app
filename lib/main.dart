import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const ShakeWakeApp());
}

class ShakeWakeApp extends StatelessWidget {
  const ShakeWakeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shake to Wake',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.dark,
      ),
      home: const HomePage(),
    );
  }
}

enum ShakeSensitivity { low, medium, high }

extension ShakeSensitivityX on ShakeSensitivity {
  String get label {
    switch (this) {
      case ShakeSensitivity.low:
        return 'Low (strong shake needed)';
      case ShakeSensitivity.medium:
        return 'Medium (recommended)';
      case ShakeSensitivity.high:
        return 'High (light shake wakes it)';
    }
  }

  /// This value is the g-force threshold sent to the native side.
  /// A LOWER threshold means the phone triggers on a GENTLER shake,
  /// so "High" sensitivity uses the smallest number.
  double get threshold {
    switch (this) {
      case ShakeSensitivity.low:
        return 2.7;
      case ShakeSensitivity.medium:
        return 2.0;
      case ShakeSensitivity.high:
        return 1.4;
    }
  }

  static ShakeSensitivity fromThreshold(double value) {
    if (value >= 2.5) return ShakeSensitivity.low;
    if (value >= 1.8) return ShakeSensitivity.medium;
    return ShakeSensitivity.high;
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const MethodChannel _channel =
      MethodChannel('com.shakewake.app/shake');

  static const String _prefsEnabledKey = 'shake_service_enabled';
  static const String _prefsSensitivityKey = 'shake_service_sensitivity';

  bool _serviceRunning = false;
  bool _loading = true;
  bool _ignoringBatteryOptimizations = false;
  ShakeSensitivity _sensitivity = ShakeSensitivity.medium;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshStatus();
    }
  }

  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    final savedThreshold =
        prefs.getDouble(_prefsSensitivityKey) ?? ShakeSensitivity.medium.threshold;
    _sensitivity = ShakeSensitivityX.fromThreshold(savedThreshold);
    await _refreshStatus();
    setState(() => _loading = false);
  }

  Future<void> _refreshStatus() async {
    bool running = false;
    bool ignoringOpt = false;
    try {
      running = await _channel.invokeMethod<bool>('isServiceRunning') ?? false;
    } on PlatformException {
      running = false;
    }
    try {
      ignoringOpt =
          await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
              false;
    } on PlatformException {
      ignoringOpt = false;
    }
    if (!mounted) return;
    setState(() {
      _serviceRunning = running;
      _ignoringBatteryOptimizations = ignoringOpt;
    });
  }

  Future<void> _persistState(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabledKey, enabled);
    await prefs.setDouble(_prefsSensitivityKey, _sensitivity.threshold);
  }

  Future<void> _toggleService(bool value) async {
    setState(() => _loading = true);
    try {
      if (value) {
        await _channel.invokeMethod('startService', {
          'sensitivity': _sensitivity.threshold,
        });
      } else {
        await _channel.invokeMethod('stopService');
      }
      await _persistState(value);
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.message}')),
        );
      }
    }
    await _refreshStatus();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _updateSensitivity(ShakeSensitivity? value) async {
    if (value == null) return;
    setState(() => _sensitivity = value);
    await _persistState(_serviceRunning);
    if (_serviceRunning) {
      // Push the new threshold to the already-running native service.
      try {
        await _channel.invokeMethod('startService', {
          'sensitivity': _sensitivity.threshold,
        });
      } on PlatformException {
        // ignore, service will pick it up next time it (re)starts
      }
    }
  }

  Future<void> _openBatteryOptimizationSettings() async {
    try {
      await _channel.invokeMethod('openBatteryOptimizationSettings');
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open settings: ${e.message}')),
        );
      }
    }
    // Give the user time to change the setting, then refresh when they come back.
    Future.delayed(const Duration(milliseconds: 500), _refreshStatus);
  }

  Future<void> _showBatteryOptimizationDialog() async {
    return showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Disable battery optimization'),
          content: const Text(
            'Since your power button is broken, this app must run a '
            'background service at all times so it can listen for a '
            'shake and turn the screen on.\n\n'
            'Android\'s battery optimization can stop this service after '
            'a while. Please allow this app to run in the background '
            '("Don\'t optimize" / "Unrestricted") so the shake sensor '
            'keeps working even when the screen has been off for a long '
            'time.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Later'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop();
                _openBatteryOptimizationSettings();
              },
              child: const Text('Open settings'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shake to Wake'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refreshStatus,
            tooltip: 'Refresh status',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refreshStatus,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                _serviceRunning
                                    ? Icons.vibration
                                    : Icons.vibration_outlined,
                                color: _serviceRunning
                                    ? Colors.green
                                    : Colors.grey,
                                size: 36,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _serviceRunning
                                          ? 'Shake service is ON'
                                          : 'Shake service is OFF',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium,
                                    ),
                                    Text(
                                      _serviceRunning
                                          ? 'Shake your phone to turn on the screen.'
                                          : 'Enable it below to use shake-to-wake.',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              Switch(
                                value: _serviceRunning,
                                onChanged: _toggleService,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Shake sensitivity',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<ShakeSensitivity>(
                            initialValue: _sensitivity,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                            ),
                            items: ShakeSensitivity.values
                                .map(
                                  (s) => DropdownMenuItem(
                                    value: s,
                                    child: Text(s.label),
                                  ),
                                )
                                .toList(),
                            onChanged: _updateSensitivity,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    color: _ignoringBatteryOptimizations
                        ? null
                        : Theme.of(context).colorScheme.errorContainer,
                    child: ListTile(
                      leading: Icon(
                        _ignoringBatteryOptimizations
                            ? Icons.battery_charging_full
                            : Icons.warning_amber_rounded,
                        color: _ignoringBatteryOptimizations
                            ? Colors.green
                            : Theme.of(context).colorScheme.error,
                      ),
                      title: Text(
                        _ignoringBatteryOptimizations
                            ? 'Battery optimization is disabled'
                            : 'Battery optimization is still ON',
                      ),
                      subtitle: Text(
                        _ignoringBatteryOptimizations
                            ? 'The background service should keep running reliably.'
                            : 'Android may kill the shake service. Tap to fix.',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _showBatteryOptimizationDialog,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      'How it works',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      '1. Turn the switch above ON.\n'
                      '2. Disable battery optimization for this app.\n'
                      '3. Lock the screen normally (it will time out and '
                      'turn off as usual).\n'
                      '4. Shake the phone firmly — the screen will turn '
                      'back on instantly.\n\n'
                      'A persistent notification stays visible while the '
                      'service is active so Android does not kill it.',
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
