import '../../models/manifest.dart';

enum SyncCapability { metadata, fileTransfer }

class SyncAuthorization {
  const SyncAuthorization();

  bool allows(LibraryManifest manifest, String deviceId, SyncCapability capability) {
    for (final device in manifest.trustedDevices) {
      if (device.deviceId != deviceId || device.isRevoked) continue;
      return switch (capability) {
        SyncCapability.metadata => device.canSyncMetadata,
        SyncCapability.fileTransfer => device.canTransferFiles,
      };
    }
    return false;
  }
}
