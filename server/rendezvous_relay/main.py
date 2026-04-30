from __future__ import annotations

import asyncio
import json
from collections import defaultdict
from typing import DefaultDict, Dict

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, status
from fastapi.responses import JSONResponse

app = FastAPI(title="Read Anywhere Rendezvous Relay", version="0.1.1")

# In-memory only. The relay intentionally stores no books and writes nothing to
# disk. Sprint 3 hotfix 2 keeps the latest *metadata snapshots* in RAM so a newly
# connected device can recover the current library even if peer_joined/request
# messages race each other on mobile networks. Restarting the relay drops it all.
_rooms: DefaultDict[str, Dict[WebSocket, str]] = defaultdict(dict)
_snapshot_cache: DefaultDict[str, Dict[str, str]] = defaultdict(dict)
_lock = asyncio.Lock()
MAX_MESSAGE_BYTES = 1024 * 1024 * 8  # 8 MB; production should use binary chunks.
MAX_CACHED_SNAPSHOT_BYTES = 1024 * 1024  # metadata only; book chunks are never cached.


@app.get("/health")
async def health() -> JSONResponse:
    async with _lock:
        rooms = {
            account_id: {
                "devices": sorted(device_ids.values()),
                "cached_snapshots": len(_snapshot_cache.get(account_id, {})),
            }
            for account_id, device_ids in _rooms.items()
        }
    return JSONResponse({"ok": True, "rooms": rooms})


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
            message = await websocket.receive_text()
            if len(message.encode("utf-8")) > MAX_MESSAGE_BYTES:
                await websocket.close(
                    code=status.WS_1009_MESSAGE_TOO_BIG,
                    reason="Message too large. Use chunked file transfer.",
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


async def _broadcast_system(account_id: str, payload: dict, exclude: WebSocket | None = None) -> None:
    await _broadcast_raw(account_id, json.dumps(payload), exclude=exclude)


async def _send_text_safely(
    peer: WebSocket,
    message: str,
    account_id: str | None = None,
) -> None:
    try:
        await peer.send_text(message)
    except RuntimeError:
        if account_id is not None:
            async with _lock:
                _rooms[account_id].pop(peer, None)
