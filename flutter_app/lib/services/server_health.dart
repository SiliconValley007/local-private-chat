import '../api_client.dart';

/// How worried the app should be about one server reading.
enum HealthLevel { ok, warn, critical }

/// Identity of the machine answering this chat.
class ServerHost {
  const ServerHost({
    required this.kind,
    required this.label,
    required this.python,
    required this.lowMemory,
  });

  factory ServerHost.fromJson(Map<String, dynamic> json) => ServerHost(
    kind: (json['kind'] as String?) ?? 'unknown',
    label: (json['label'] as String?) ?? 'Unknown host',
    python: (json['python'] as String?) ?? '',
    lowMemory: json['low_memory'] == true,
  );

  /// One of `termux`, `android`, `windows`, `linux`, `macos`, `unknown`.
  final String kind;

  /// Human line such as `Termux on Android · aarch64`.
  final String label;

  final String python;

  /// True when the server was started with `LOCALCHAT_LOW_MEMORY=1`.
  final bool lowMemory;

  /// Whether this host is a phone, which is the fragile case worth watching.
  bool get isPhone => kind == 'termux' || kind == 'android';
}

/// RAM on the host, and how much of it this server process holds.
class ServerMemory {
  const ServerMemory({
    required this.totalBytes,
    required this.availableBytes,
    this.processBytes,
  });

  factory ServerMemory.fromJson(Map<String, dynamic> json) => ServerMemory(
    totalBytes: (json['total_bytes'] as num?)?.toInt() ?? 0,
    availableBytes: (json['available_bytes'] as num?)?.toInt() ?? 0,
    processBytes: (json['process_bytes'] as num?)?.toInt(),
  );

  final int totalBytes;
  final int availableBytes;

  /// Resident size of the server process, when the host reports it.
  final int? processBytes;

  int get usedBytes => (totalBytes - availableBytes).clamp(0, totalBytes);

  double get usedFraction {
    if (totalBytes <= 0) return 0;
    return (usedBytes / totalBytes).clamp(0.0, 1.0);
  }
}

/// Battery of the phone or laptop hosting the server.
class ServerBattery {
  const ServerBattery({
    required this.percent,
    required this.charging,
    required this.status,
  });

  factory ServerBattery.fromJson(Map<String, dynamic> json) => ServerBattery(
    percent: (json['percent'] as num?)?.toInt() ?? 0,
    charging: json['charging'] == true,
    status: (json['status'] as String?) ?? 'unknown',
  );

  final int percent;
  final bool charging;
  final String status;
}

/// Disk on the volume holding the database and uploads.
class ServerDisk {
  const ServerDisk({required this.totalBytes, required this.freeBytes});

  factory ServerDisk.fromJson(Map<String, dynamic> json) => ServerDisk(
    totalBytes: (json['total_bytes'] as num?)?.toInt() ?? 0,
    freeBytes: (json['free_bytes'] as num?)?.toInt() ?? 0,
  );

  final int totalBytes;
  final int freeBytes;

  int get usedBytes => (totalBytes - freeBytes).clamp(0, totalBytes);

  double get usedFraction {
    if (totalBytes <= 0) return 0;
    return (usedBytes / totalBytes).clamp(0.0, 1.0);
  }
}

/// How long the server process, and the host under it, have been up.
class ServerUptime {
  const ServerUptime({required this.serverSeconds, this.hostSeconds});

  factory ServerUptime.fromJson(Map<String, dynamic> json) => ServerUptime(
    serverSeconds: (json['server_seconds'] as num?)?.toDouble() ?? 0,
    hostSeconds: (json['host_seconds'] as num?)?.toDouble(),
  );

  final double serverSeconds;

  /// Absent on hosts that do not publish boot time, such as Windows.
  final double? hostSeconds;
}

/// Everything `/api/system/info` reports, with the unknown parts left null.
class ServerHealth {
  const ServerHealth({
    required this.host,
    required this.disk,
    required this.uptime,
    this.memory,
    this.battery,
  });

  factory ServerHealth.fromJson(Map<String, dynamic> json) {
    final memory = json['memory'];
    final battery = json['battery'];
    return ServerHealth(
      host: ServerHost.fromJson(
        (json['host'] as Map<String, dynamic>?) ?? const {},
      ),
      disk: ServerDisk.fromJson(
        (json['storage'] as Map<String, dynamic>?) ?? const {},
      ),
      uptime: ServerUptime.fromJson(
        (json['uptime'] as Map<String, dynamic>?) ?? const {},
      ),
      memory: memory is Map<String, dynamic>
          ? ServerMemory.fromJson(memory)
          : null,
      battery: battery is Map<String, dynamic>
          ? ServerBattery.fromJson(battery)
          : null,
    );
  }

  final ServerHost host;
  final ServerDisk disk;
  final ServerUptime uptime;
  final ServerMemory? memory;
  final ServerBattery? battery;

  /// The worst of the individual readings, which drives the summary banner.
  HealthLevel get level {
    final levels = [
      memoryLevel(memory),
      diskLevel(disk),
      batteryLevel(battery),
    ];
    if (levels.contains(HealthLevel.critical)) return HealthLevel.critical;
    if (levels.contains(HealthLevel.warn)) return HealthLevel.warn;
    return HealthLevel.ok;
  }
}

/// RAM headroom. Below a tenth free, Android starts killing background work.
HealthLevel memoryLevel(ServerMemory? memory) {
  if (memory == null || memory.totalBytes <= 0) return HealthLevel.ok;
  final free = memory.availableBytes / memory.totalBytes;
  if (free < 0.07) return HealthLevel.critical;
  if (free < 0.15) return HealthLevel.warn;
  return HealthLevel.ok;
}

/// Mirrors the thresholds the share sheet already uses for server storage.
HealthLevel diskLevel(ServerDisk disk) {
  if (disk.totalBytes <= 0) return HealthLevel.ok;
  final free = disk.freeBytes;
  final fraction = free / disk.totalBytes;
  if (free < 256 * 1024 * 1024 || fraction < 0.02) return HealthLevel.critical;
  if (free < 1024 * 1024 * 1024 || fraction < 0.10) return HealthLevel.warn;
  return HealthLevel.ok;
}

/// A charging server is safe at any level; a draining one is on a clock.
HealthLevel batteryLevel(ServerBattery? battery) {
  if (battery == null) return HealthLevel.ok;
  if (battery.charging) return HealthLevel.ok;
  if (battery.percent <= 15) return HealthLevel.critical;
  if (battery.percent <= 30) return HealthLevel.warn;
  return HealthLevel.ok;
}

/// What to do about the worst reading, in the user's own terms.
String healthAdvice(ServerHealth health) {
  if (memoryLevel(health.memory) == HealthLevel.critical) {
    return 'The server is almost out of memory. Close other apps on the '
        'server device, then restart the server.';
  }
  if (diskLevel(health.disk) == HealthLevel.critical) {
    return 'The server disk is nearly full. New photos and messages may fail '
        'to save until space is freed.';
  }
  if (batteryLevel(health.battery) == HealthLevel.critical) {
    return 'The server battery is critically low. Plug in the server device '
        'to keep the chat online.';
  }
  if (memoryLevel(health.memory) == HealthLevel.warn) {
    return 'Server memory is tight. Avoid running other heavy apps on the '
        'server device.';
  }
  if (diskLevel(health.disk) == HealthLevel.warn) {
    return 'Server space is running low. Clear some uploads soon.';
  }
  if (batteryLevel(health.battery) == HealthLevel.warn) {
    return 'The server battery is getting low. Plug in the server device.';
  }
  return 'The server is healthy.';
}

/// Coarse, readable duration: `3d 4h`, `5h 12m`, `42m`, `18s`.
String formatUptime(double? seconds) {
  if (seconds == null || seconds < 0) return 'Unknown';
  final total = seconds.floor();
  final days = total ~/ 86400;
  final hours = (total % 86400) ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  if (days > 0) return '${days}d ${hours}h';
  if (hours > 0) return '${hours}h ${minutes}m';
  if (minutes > 0) return '${minutes}m';
  return '${total}s';
}

/// Short badge for the host, e.g. `Termux` or `Windows`.
String hostBadge(String kind) {
  switch (kind) {
    case 'termux':
      return 'Termux';
    case 'android':
      return 'Android';
    case 'windows':
      return 'Windows';
    case 'linux':
      return 'Linux';
    case 'macos':
      return 'macOS';
    default:
      return 'Unknown';
  }
}

/// Reads a health snapshot from the authenticated Local Chat server.
Future<ServerHealth> readServerHealth(ApiClient api) async =>
    ServerHealth.fromJson(await api.fetchServerInfo());
