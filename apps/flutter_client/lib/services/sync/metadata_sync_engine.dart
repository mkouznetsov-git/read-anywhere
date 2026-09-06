import '../../models/manifest.dart';
import '../storage_service.dart';
import 'merge.dart';

class ProtocolCompatibilityException implements Exception {
  const ProtocolCompatibilityException(this.protocolVersion);

  final int protocolVersion;

  @override
  String toString() =>
      'Неподдерживаемая версия sync-протокола $protocolVersion '
      '(поддерживаются ${SyncEnvelope.minimumProtocolVersion}–${SyncEnvelope.currentProtocolVersion})';
}

enum SnapshotApplyStatus { applied, duplicate }

class SnapshotApplyResult {
  const SnapshotApplyResult({required this.status, required this.manifest});

  final SnapshotApplyStatus status;
  final LibraryManifest manifest;
}

/// Owns metadata conflict resolution and durable operation idempotency.
class MetadataSyncEngine {
  MetadataSyncEngine(this._storage);

  static const maxAppliedOperationIds = 4096;

  final StorageService _storage;

  void validateProtocol(int version) {
    if (version < SyncEnvelope.minimumProtocolVersion || version > SyncEnvelope.currentProtocolVersion) {
      throw ProtocolCompatibilityException(version);
    }
  }

  Future<SnapshotApplyResult> applySnapshot({
    required LibraryManifest remote,
    required String operationId,
    required int protocolVersion,
  }) async {
    validateProtocol(protocolVersion);
    var status = SnapshotApplyStatus.applied;
    final saved = await _storage.mutateManifest((current) {
      if (remote.accountId != current.accountId) {
        throw StateError('Snapshot accountId does not match local account');
      }
      if (current.appliedOperationIds.contains(operationId)) {
        status = SnapshotApplyStatus.duplicate;
        return current;
      }
      final merged = mergeManifests(current, remote);
      final applied = [...merged.appliedOperationIds, operationId];
      final bounded = applied.length <= maxAppliedOperationIds
          ? applied
          : applied.sublist(applied.length - maxAppliedOperationIds);
      return merged.copyWith(
        logicalClock: merged.logicalClock > current.logicalClock ? merged.logicalClock : current.logicalClock,
        appliedOperationIds: bounded,
      );
    });
    return SnapshotApplyResult(status: status, manifest: saved);
  }
}
