# ADR-002: Internet sync, no DRM, original book preservation

## Status

Accepted for MVP planning.

## Context

Clarifications for the current project stage:

1. Sync must work not only in a local network, but also over the internet.
2. DRM/protected books are not required yet.
3. Family accounts are not required yet.
4. Local conversion is acceptable if it simplifies implementation, but the original imported book file must remain available for saving and transfer.

## Decision

### Internet sync

The application will support internet sync through a self-hosted rendezvous/relay service.

The relay service is allowed to:

- authenticate device sessions;
- help devices discover each other;
- forward encrypted metadata and file chunks when direct P2P is unavailable;
- keep temporary in-memory routing state.

The relay service is not allowed to:

- persist books;
- persist bookmarks;
- persist current reading positions;
- persist account libraries;
- inspect plaintext payloads.

All sync payloads must be end-to-end encrypted between account devices.

### Book storage

For every imported book, the system stores:

- the original file as imported by the user;
- normalized extracted metadata;
- optional locally generated derived representation, for example EPUB/PDF/text cache;
- SHA-256 or stronger content hash of the original file;
- per-device downloaded/not-downloaded status.

Derived converted files can be deleted and rebuilt. Original files must be preserved unless the user explicitly deletes the book from the account library.

### Formats

Initial implementation order:

1. TXT reader MVP.
2. EPUB and PDF.
3. FB2.
4. DOC/DOCX through local conversion or text extraction.
5. DJVU through native adapter or local conversion.

DRM/LCP/encrypted commercial books are out of scope for the current MVP.

### Accounts

Only one-person accounts are in scope. Family accounts, child profiles, shared libraries and permissions are deferred.

## Consequences

- A relay server becomes part of the product, but it is not a cloud storage service.
- Fully offline sync still works when devices meet in LAN.
- Internet sync requires at least one reachable relay endpoint.
- The security model depends on strong device pairing and E2E encryption.
- Storage can grow because original files are preserved alongside optional converted files.

## Checks

- Relay restart must not lose account data because relay must not be the source of truth.
- If relay disk logging is enabled by accident, payloads must still be encrypted and unreadable.
- A new device can see the library manifest first, then selectively request original book files.
- Converted copy deletion must not delete the original.
- Unsupported DRM book import should fail with a clear explanation, not corrupt the library.
