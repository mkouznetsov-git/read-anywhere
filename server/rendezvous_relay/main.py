from __future__ import annotations

import asyncio
import json
import secrets
import time
from collections import defaultdict
from typing import DefaultDict, Dict

from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect, status
from fastapi.responses import JSONResponse
from starlette.websockets import WebSocketState

app = FastAPI(title="ReadArc Rendezvous Relay", version="0.2.1")

# In-memory only. The relay intentionally stores no books and writes nothing to
# disk. Sprint 3 hotfix 2 keeps the latest *metadata snapshots* in RAM so a newly
# connected device can recover the current library even if peer_joined/request
# messages race each other on mobile networks. Restarting the relay drops it all.
_rooms: DefaultDict[str, Dict[WebSocket, str]] = defaultdict(dict)
_snapshot_cache: DefaultDict[str, Dict[str, str]] = defaultdict(dict)
_pairing_codes: Dict[str, dict] = {}
_lock = asyncio.Lock()
MAX_MESSAGE_BYTES = 1024 * 1024 * 16  # text metadata/control frames
MAX_BINARY_MESSAGE_BYTES = 1024 * 1024 * 4  # encrypted binary file chunks
MAX_CACHED_SNAPSHOT_BYTES = 1024 * 1024  # metadata only; book chunks are never cached.
PAIRING_TTL_SECONDS = 5 * 60


@app.get("/")
async def root() -> JSONResponse:
    return JSONResponse({
        "ok": True,
        "service": "ReadArc Rendezvous Relay",
        "version": app.version,
        "websocket": "/ws/{account_id}/{device_id}",
    })


@app.get("/health")
async def health() -> JSONResponse:
    await _cleanup_expired_pairing_codes()
    async with _lock:
        rooms = {
            account_id: {
                "devices": sorted(device_ids.values()),
                "cached_snapshots": len(_snapshot_cache.get(account_id, {})),
            }
            for account_id, device_ids in _rooms.items()
        }
        active_pairing_codes = len(_pairing_codes)
    return JSONResponse({"ok": True, "rooms": rooms, "pairing_codes": active_pairing_codes})


@app.post("/pairing/start")
async def start_pairing(request: Request) -> JSONResponse:
    payload = await request.json()
    account_id = str(payload.get("accountId") or "").strip()
    owner_device_id = str(payload.get("ownerDeviceId") or "").strip()
    owner_device_name = str(payload.get("ownerDeviceName") or "Устройство").strip()
    owner_device_public_key = str(payload.get("ownerDevicePublicKey") or "").strip()
    account_encryption_key = str(payload.get("accountEncryptionKey") or "").strip()
    relay_url = str(payload.get("relayUrl") or "").strip()
    try:
        expires_seconds = int(payload.get("expiresSeconds") or PAIRING_TTL_SECONDS)
    except (TypeError, ValueError):
        expires_seconds = PAIRING_TTL_SECONDS
    expires_seconds = max(30, min(expires_seconds, PAIRING_TTL_SECONDS))

    if not account_id or not owner_device_id or not relay_url:
        return JSONResponse(
            {"ok": False, "message": "accountId, ownerDeviceId and relayUrl are required"},
            status_code=400,
        )

    code = await _generate_pairing_code()
    expires_at = time.time() + expires_seconds
    async with _lock:
        _pairing_codes[code] = {
            "accountId": account_id,
            "ownerDeviceId": owner_device_id,
            "ownerDeviceName": owner_device_name or "Устройство",
            "ownerDevicePublicKey": owner_device_public_key,
            "accountEncryptionKey": account_encryption_key,
            "relayUrl": relay_url,
            "createdAt": time.time(),
            "expiresAt": expires_at,
            "claimedBy": None,
        }

    return JSONResponse({
        "ok": True,
        "code": code,
        "expiresAt": expires_at,
        "expiresInSeconds": expires_seconds,
        "relayUrl": relay_url,
    })


@app.post("/pairing/claim")
async def claim_pairing(request: Request) -> JSONResponse:
    await _cleanup_expired_pairing_codes()
    payload = await request.json()
    code = _normalize_pairing_code(str(payload.get("code") or ""))
    new_device_id = str(payload.get("deviceId") or "").strip()
    new_device_name = str(payload.get("deviceName") or "Устройство").strip()
    new_device_public_key = str(payload.get("devicePublicKey") or "").strip()
    if not code or not new_device_id:
        return JSONResponse({"ok": False, "message": "code and deviceId are required"}, status_code=400)

    async with _lock:
        record = _pairing_codes.pop(code, None)
    if record is None:
        return JSONResponse({"ok": False, "message": "Pairing code is invalid or expired"}, status_code=404)
    if record["expiresAt"] < time.time():
        return JSONResponse({"ok": False, "message": "Pairing code expired"}, status_code=410)

    return JSONResponse({
        "ok": True,
        "accountId": record["accountId"],
        "relayUrl": record["relayUrl"],
        "ownerDeviceId": record["ownerDeviceId"],
        "ownerDeviceName": record["ownerDeviceName"],
        "ownerDevicePublicKey": record.get("ownerDevicePublicKey", ""),
        "accountEncryptionKey": record.get("accountEncryptionKey", ""),
        "acceptedDeviceId": new_device_id,
        "acceptedDevicePublicKey": new_device_public_key,
        "acceptedDeviceName": new_device_name or "Устройство",
    })


@app.websocket("/ws/{account_id}/{device_id}")
async def websocket_endpoint(websocket: WebSocket, account_id: str, device_id: str) -> None:
    await websocket.accept()
    async with _lock:
        _rooms[account_id][websocket] = device_id
        peer_ids = sorted(set(_rooms[account_id].values()) - {device_id})
        cached_messages = [
            raw
            for owner_device_id, raw in _snapshot_cache.get(account_id, {}).items()
            if owner_device_id != device_id
        ]

    # Tell the newcomer who is already online. The previous relay only notified
    # existing peers, so the newly joined device had to rely on its own outbound
    # request being delivered immediately after connect.
    await websocket.send_json({
        "type": "peer_list",
        "accountId": account_id,
        "deviceId": "relay",
        "peers": peer_ids,
    })

    # Replay the latest in-memory metadata snapshots. This is not file storage:
    # only compact library/progress/bookmark manifests are cached, and only until
    # the relay process restarts.
    for raw in cached_messages:
        await _send_text_safely(websocket, raw)

    await _broadcast_system(account_id, {
        "type": "peer_joined",
        "accountId": account_id,
        "deviceId": device_id,
    }, exclude=websocket)

    try:
        while True:
            incoming = await websocket.receive()
            if "text" in incoming and incoming["text"] is not None:
                message = incoming["text"]
                if len(message.encode("utf-8")) > MAX_MESSAGE_BYTES:
                    await websocket.close(
                        code=status.WS_1009_MESSAGE_TOO_BIG,
                        reason="Message too large. Use binary chunked file transfer.",
                    )
                    break

                try:
                    decoded = json.loads(message)
                except json.JSONDecodeError:
                    await websocket.send_json({"type": "error", "message": "Invalid JSON"})
                    continue

                if not isinstance(decoded, dict):
                    await websocket.send_json({"type": "error", "message": "Invalid message shape"})
                    continue

                message_type = decoded.get("type")
                envelope_account_id = decoded.get("accountId")
                envelope_device_id = decoded.get("deviceId") or device_id
                if envelope_account_id != account_id:
                    await websocket.send_json({
                        "type": "error",
                        "message": "Envelope accountId does not match websocket room",
                    })
                    continue

                if message_type == "library_snapshot":
                    await _cache_library_snapshot(account_id, str(envelope_device_id), message)
                elif message_type == "library_snapshot_requested":
                    await _send_cached_snapshots(
                        account_id=account_id,
                        target=websocket,
                        exclude_device_id=str(envelope_device_id),
                    )

                await _broadcast_raw(account_id, message, exclude=websocket)
                continue

            if "bytes" in incoming and incoming["bytes"] is not None:
                data = incoming["bytes"]
                if len(data) > MAX_BINARY_MESSAGE_BYTES:
                    await websocket.close(
                        code=status.WS_1009_MESSAGE_TOO_BIG,
                        reason="Binary chunk too large.",
                    )
                    break
                await _broadcast_binary(account_id, data, exclude=websocket)
                continue

            if incoming.get("type") == "websocket.disconnect":
                break
    except WebSocketDisconnect:
        pass
    finally:
        async with _lock:
            _rooms[account_id].pop(websocket, None)
            if not _rooms[account_id]:
                _rooms.pop(account_id, None)
        await _broadcast_system(account_id, {
            "type": "peer_left",
            "accountId": account_id,
            "deviceId": device_id,
        })


async def _generate_pairing_code() -> str:
    await _cleanup_expired_pairing_codes()
    for _ in range(20):
        raw = secrets.randbelow(1_000_000)
        code = f"{raw:06d}"
        async with _lock:
            if code not in _pairing_codes:
                return code
    raise RuntimeError("Could not generate unique pairing code")


def _normalize_pairing_code(code: str) -> str:
    return "".join(ch for ch in code if ch.isdigit())


async def _cleanup_expired_pairing_codes() -> None:
    now = time.time()
    async with _lock:
        expired = [code for code, record in _pairing_codes.items() if record.get("expiresAt", 0) < now]
        for code in expired:
            _pairing_codes.pop(code, None)


async def _cache_library_snapshot(account_id: str, device_id: str, message: str) -> None:
    if len(message.encode("utf-8")) > MAX_CACHED_SNAPSHOT_BYTES:
        return
    async with _lock:
        _snapshot_cache[account_id][device_id] = message


async def _send_cached_snapshots(
    *,
    account_id: str,
    target: WebSocket,
    exclude_device_id: str,
) -> None:
    async with _lock:
        cached_messages = [
            raw
            for owner_device_id, raw in _snapshot_cache.get(account_id, {}).items()
            if owner_device_id != exclude_device_id
        ]
    for raw in cached_messages:
        await _send_text_safely(target, raw)


async def _broadcast_raw(account_id: str, message: str, exclude: WebSocket | None = None) -> None:
    async with _lock:
        peers = list(_rooms.get(account_id, {}).keys())
    for peer in peers:
        if peer is exclude:
            continue
        await _send_text_safely(peer, message, account_id=account_id)



async def _broadcast_binary(account_id: str, message: bytes, exclude: WebSocket | None = None) -> None:
    async with _lock:
        peers = list(_rooms.get(account_id, {}).keys())
    for peer in peers:
        if peer is exclude:
            continue
        await _send_bytes_safely(peer, message, account_id=account_id)


async def _broadcast_system(account_id: str, payload: dict, exclude: WebSocket | None = None) -> None:
    await _broadcast_raw(account_id, json.dumps(payload), exclude=exclude)


async def _send_text_safely(
    peer: WebSocket,
    message: str,
    account_id: str | None = None,
) -> None:
    # Disconnects are expected during reconnects, mobile app backgrounding and
    # Tailscale/Funnel network changes. Do not let a stale peer make the relay
    # print a full ASGI traceback while broadcasting peer_left/snapshot events.
    try:
        if peer.client_state == WebSocketState.DISCONNECTED:
            raise WebSocketDisconnect(code=1005)
        await peer.send_text(message)
    except Exception as exc:  # Starlette/uvicorn/websockets use different disconnect exceptions.
        name = exc.__class__.__name__
        module = exc.__class__.__module__
        is_disconnect = (
            isinstance(exc, (RuntimeError, WebSocketDisconnect))
            or name in {
                'ClientDisconnected',
                'ConnectionClosed',
                'ConnectionClosedOK',
                'ConnectionClosedError',
            }
            or 'websockets.' in module
        )
        if not is_disconnect:
            raise
        if account_id is not None:
            async with _lock:
                room = _rooms.get(account_id)
                if room is not None:
                    room.pop(peer, None)


async def _send_bytes_safely(peer: WebSocket, message: bytes, account_id: str | None = None) -> None:
    try:
        if peer.client_state == WebSocketState.DISCONNECTED:
            raise WebSocketDisconnect(code=1005)
        await peer.send_bytes(message)
    except Exception as exc:
        name = exc.__class__.__name__
        module = exc.__class__.__module__
        is_disconnect = (
            isinstance(exc, (RuntimeError, WebSocketDisconnect))
            or name in {
                'ClientDisconnected',
                'ConnectionClosed',
                'ConnectionClosedOK',
                'ConnectionClosedError',
            }
            or 'websockets.' in module
        )
        if not is_disconnect:
            raise
        if account_id is not None:
            async with _lock:
                room = _rooms.get(account_id)
                if room is not None:
                    room.pop(peer, None)
