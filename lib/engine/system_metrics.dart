import 'dart:io';

class SystemMetrics {
  const SystemMetrics({this.cpuPercent, this.memoryBytes});
  final double? cpuPercent;
  final int? memoryBytes;
}

class SystemMetricsSampler {
  Future<SystemMetrics> sample() async {
    final memory = ProcessInfo.currentRss;
    if (!Platform.isLinux) return SystemMetrics(memoryBytes: memory);
    try {
      final stat = await File('/proc/self/stat').readAsString();
      final fields = stat.split(' ');
      final user = int.parse(fields[13]);
      final system = int.parse(fields[14]);
      return SystemMetrics(
        cpuPercent: (user + system) / 100.0,
        memoryBytes: memory,
      );
    } catch (_) {
      return SystemMetrics(memoryBytes: memory);
    }
  }
}
