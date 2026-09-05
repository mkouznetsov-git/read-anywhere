/// Lamport revision used to order sync mutations without trusting wall clocks.
///
/// Counters are compared first. Concurrent revisions with the same counter are
/// deterministically ordered by device id, so every client reaches the same
/// result even when their system clocks disagree.
class SyncRevision implements Comparable<SyncRevision> {
  const SyncRevision({required this.counter, required this.deviceId});

  static const zero = SyncRevision(counter: 0, deviceId: '');

  final int counter;
  final String deviceId;

  bool get isZero => counter == 0;

  @override
  int compareTo(SyncRevision other) {
    final counterOrder = counter.compareTo(other.counter);
    if (counterOrder != 0) return counterOrder;
    return deviceId.compareTo(other.deviceId);
  }

  Map<String, dynamic> toJson() => {'counter': counter, 'deviceId': deviceId};

  factory SyncRevision.fromJson(Object? raw, {int legacyCounter = 0, String legacyDeviceId = ''}) {
    if (raw is Map) {
      final json = Map<String, dynamic>.from(raw);
      return SyncRevision(
        counter: ((json['counter'] as num?)?.toInt() ?? 0).clamp(0, 1 << 62).toInt(),
        deviceId: json['deviceId']?.toString() ?? '',
      );
    }
    return SyncRevision(counter: legacyCounter.clamp(0, 1 << 62).toInt(), deviceId: legacyDeviceId);
  }

  @override
  bool operator ==(Object other) => other is SyncRevision && other.counter == counter && other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(counter, deviceId);

  @override
  String toString() => '$counter@$deviceId';
}
