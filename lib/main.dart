import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const MethodChannel platform = MethodChannel('installed_apps');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

 await Supabase.initialize(
    url: 'https://ifhgdipxetfordemdlyw.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImlmaGdkaXB4ZXRmb3JkZW1kbHl3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDMyNDU0MzIsImV4cCI6MjA1ODgyMTQzMn0.mN5TR5BALux0JOE4HSy4AfnhOQ-tcnBak5WeRbwaBoY',
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: "Installed Apps",
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final SupabaseClient supabase = Supabase.instance.client;
  List<Map<String, dynamic>> installedApps = [];
  Map<String, Uint8List> appIcons = {};
  bool showSystemApps = false;
  bool isLoading = false;
  String deviceId = "UNKNOWN";

  Future<void> initializeSupabaseSession() async {
    final session = supabase.auth.currentSession;
    if (session == null) {
      await supabase.auth.signInAnonymously();
    }
    try {
      final id = await platform.invokeMethod<String>('getDeviceIdentifier');
      if (id != null && id.isNotEmpty) {
        deviceId = id;
        // Register device in devices table with retry logic
        bool registered = await _registerDeviceWithRetry(id, maxRetries: 3);
        if (!registered) {
          print("Warning: Could not register device. Ensure internet connection is available.");
        }
      }
    } catch (e) {
      print("Error getting device identifier: $e");
      deviceId = "UNKNOWN";
    }
  }

  Future<bool> _registerDeviceWithRetry(String macAddress, {int maxRetries = 3}) async {
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        print("Registering device (attempt $attempt/$maxRetries)...");
        await supabase.from('devices').upsert({
          "mac_address": macAddress,
          "created_at": DateTime.now().toIso8601String(),
        }, onConflict: "mac_address");
        print("✓ Device registered successfully: $macAddress");
        return true;
      } catch (e) {
        print("✗ Device registration failed (attempt $attempt): $e");
        if (attempt < maxRetries) {
          // Wait before retrying (exponential backoff: 1s, 2s, 4s)
          await Future.delayed(Duration(seconds: 1 << (attempt - 1)));
        }
      }
    }
    return false;
  }

  Future<void> getInstalledApps({required bool systemApps}) async {
    setState(() => isLoading = true);
    try {
      final List<dynamic> apps = await platform.invokeMethod('getInstalledApps', {
        "system": systemApps
      });

      List<Map<String, dynamic>> fetchedApps = [];
      for (var app in apps) {
        final String packageName = app["packageName"];
        // Use icon bytes provided by native getInstalledApps to avoid extra platform calls
        final Uint8List? iconBytes = (app["icon"] is Uint8List) ? app["icon"] as Uint8List : null;

        fetchedApps.add({
          "name": app["name"],
          "packageName": packageName,
          "isSystem": systemApps,
        });
        if (iconBytes != null) {
          appIcons[packageName] = iconBytes;
        }
      }

      setState(() {
        installedApps = fetchedApps;
      });

      await saveAppsData(fetchedApps);

      // Removed automatic background fetching of details to improve stability.
      // Users can tap an app to fetch live details interactively.
    } catch (e) {
      print("Failed to get installed apps: $e");
    } finally {
      setState(() => isLoading = false);
    }
  }

  Future<void> saveAppsData(List<Map<String, dynamic>> apps) async {
    if (deviceId == "UNKNOWN") {
      print("⚠ Cannot save app data - device ID is unknown");
      return;
    }
    
    // Verify device exists in database before saving app data
    if (!(await _deviceExists(deviceId))) {
      print("⚠ Device not registered yet. Attempting to register...");
      bool registered = await _registerDeviceWithRetry(deviceId, maxRetries: 2);
      if (!registered) {
        print("✗ Cannot save app data - device registration failed. Check internet connection.");
        return;
      }
    }
    
    for (var app in apps) {
      try {
        await supabase.from('app_usage').upsert({
          "name": app["name"],
          "package_name": app["packageName"],
          "mac_address": deviceId,
          "created_at": DateTime.now().toIso8601String(),
        }, onConflict: "package_name");
      } catch (e) {
        print("✗ Error saving app data for ${app["packageName"]}: $e");
      }
    }
  }

  Future<bool> _deviceExists(String macAddress) async {
    try {
      final response = await supabase
          .from('devices')
          .select()
          .eq('mac_address', macAddress)
          .maybeSingle();
      return response != null;
    } catch (e) {
      print("⚠ Error checking if device exists: $e");
      return false;
    }
  }

Future<void> showAppDetails(String packageName, {bool showPopup = false, bool interactive = false}) async {
  try {
    // Execute all platform calls concurrently instead of sequentially
    final results = await Future.wait([
      platform.invokeMethod<Map<Object?, Object?>>('getAppUsageDetails', {
        "packageName": packageName,
      }),
      platform.invokeMethod<Map<Object?, Object?>>('getBatteryUsage', {
        "packageName": packageName,
      }),
      platform.invokeMethod<Map<Object?, Object?>>('getDataUsage', {
        "packageName": packageName,
      }),
    ], eagerError: false);

    final Map<Object?, Object?>? rawUsageDetails = results[0] as Map<Object?, Object?>?;
    final Map<Object?, Object?>? batteryUsageResponse = results[1] as Map<Object?, Object?>?;
    final Map<Object?, Object?>? dataUsageResponse = results[2] as Map<Object?, Object?>?;

    final int batteryUsage = (batteryUsageResponse?["batteryUsage"] as num?)?.toInt() ?? -1;
    final String rawDataUsage = (dataUsageResponse?["dataUsage"] as String?) ?? "0";

    final double dataUsage = double.tryParse(rawDataUsage.replaceAll(RegExp(r'[^\d.]'), '')) ?? 0.0;
    final String formattedDataUsage = "${dataUsage.toStringAsFixed(2)} MB";

    if (rawUsageDetails != null) {
      final Map<String, dynamic> usageDetails = rawUsageDetails.map(
        (key, value) => MapEntry(key.toString(), value ?? 0),
      );

      final int firstInstallTime = (usageDetails["firstInstallTime"] as num?)?.toInt() ?? 0;
      final int lastTimeUsed = (usageDetails["lastTimeUsed"] as num?)?.toInt() ?? 0;
      final double totalTimeInForeground = (usageDetails["totalTimeInForeground"] as num?)?.toDouble() ?? 0.0;

      // Format timestamps
      final String formattedInstallTime = firstInstallTime > 0
          ? DateTime.fromMillisecondsSinceEpoch(firstInstallTime).toString().split('.').first + "." +
              DateTime.fromMillisecondsSinceEpoch(firstInstallTime).millisecond.toString().padLeft(3, '0')
          : "N/A";

      final String formattedLastUsed = lastTimeUsed > 0
          ? DateTime.fromMillisecondsSinceEpoch(lastTimeUsed).toString().split('.').first + "." +
              DateTime.fromMillisecondsSinceEpoch(lastTimeUsed).millisecond.toString().padLeft(3, '0')
          : "N/A";

      final String formattedForegroundTime = "${(totalTimeInForeground / 60000).toStringAsFixed(2)} min";
      final String formattedBatteryUsage = batteryUsage >= 0 ? "$batteryUsage%" : "N/A";

      // Verify device is registered before saving detailed usage data
      if (deviceId != "UNKNOWN") {
        if (!(await _deviceExists(deviceId))) {
          print("⚠ Device not registered. Attempting registration before saving details...");
          bool registered = await _registerDeviceWithRetry(deviceId, maxRetries: 2);
          if (!registered) {
            if (interactive && mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text("Cannot save data: Device not registered. Check internet connection."),
                  duration: Duration(seconds: 3),
                ),
              );
            }
            return;
          }
        }

        try {
          await supabase.from('app_usage').upsert({
            "name": installedApps.firstWhere((app) => app["packageName"] == packageName)["name"] ?? "Unknown",
            "package_name": packageName,
            "type": showSystemApps ? "system" : "user",
            "first_install_time": formattedInstallTime,
            "last_time_used": formattedLastUsed,
            "total_time_in_foreground": formattedForegroundTime,
            "data_usage": formattedDataUsage,
            "battery_usage": formattedBatteryUsage,
            "mac_address": deviceId,
            "created_at": DateTime.now().toIso8601String(),
          }, onConflict: "package_name");
          print("✓ App details saved for $packageName");
        } catch (e) {
          print("✗ Error saving app details for $packageName: $e");
          if (interactive && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text("Failed to save details: $e"),
                duration: const Duration(seconds: 3),
              ),
            );
          }
        }
      }

      if (mounted && showPopup) {
        // Use Future.delayed to prevent dialog conflicts with graphics rendering
        Future.delayed(Duration.zero, () {
          if (!mounted) return;
          showDialog(
            context: context,
            barrierDismissible: true,
            builder: (context) {
              return AlertDialog(
                title: const Text("📱 App Usage Details"),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("📅 First Installed: $formattedInstallTime"),
                      Text("📅 Last Used: $formattedLastUsed"),
                      Text("⏳ Foreground Time: $formattedForegroundTime"),
                      Text("🔋 Battery Usage: $formattedBatteryUsage"),
                      Text("📊 Data Usage: $formattedDataUsage"),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text("OK"),
                  )
                ],
              );
            },
          );
        });
      }
    }
  } on PlatformException catch (e) {
    if (e.code == "PERMISSION_DENIED" && interactive) {
      if (!mounted) return;
      await showDialog(
        context: context,
        barrierDismissible: true,
        builder: (context) {
          return AlertDialog(
            title: const Text("Permission required: Usage Access"),
            content: const Text(
              "To show accurate app usage details, enable \"Usage access\" for this app:\n\n"
              "1) Tap \"Open Settings\" below.\n"
              "2) Find and select this app.\n"
              "3) Enable \"Allow usage access\".\n"
              "4) Return to this app and tap \"Retry\"."
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Cancel"),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(context);
                  await platform.invokeMethod('requestUsageAccess');
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text("After enabling access, tap the app again or press Retry to fetch details."),
                      ),
                    );
                  }
                },
                child: const Text("Open Settings"),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.pop(context);
                  await showAppDetails(packageName, showPopup: showPopup, interactive: true);
                },
                child: const Text("Retry"),
              ),
            ],
          );
        },
      );
    } else {
      print("Error fetching app details: '${e.message}'");
      if (interactive && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: ${e.message}")),
        );
      }
    }
  } catch (e) {
    print("Unexpected error in showAppDetails: $e");
    if (interactive && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Unexpected error: $e")),
      );
    }
  }
}


  @override
  void initState() {
    super.initState();
    initializeSupabaseSession();
    getInstalledApps(systemApps: false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Installed Apps")),
      body: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(
                onPressed: () {
                  setState(() => showSystemApps = false);
                  getInstalledApps(systemApps: false);
                },
                child: const Text("User Installed Apps"),
              ),
              ElevatedButton(
                onPressed: () {
                  setState(() => showSystemApps = true);
                  getInstalledApps(systemApps: true);
                },
                child: const Text("System Apps"),
              ),
            ],
          ),
          Expanded(
            child: isLoading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: installedApps.length,
                    itemBuilder: (context, index) {
                      String pkg = installedApps[index]["packageName"];
                      return ListTile(
                        leading: appIcons[pkg] != null
                            ? Image.memory(appIcons[pkg]!, width: 40, height: 40)
                            : const Icon(Icons.apps, size: 40),
                        title: Text(installedApps[index]["name"]),
                        onTap: () => showAppDetails(pkg, showPopup: true, interactive: true),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
