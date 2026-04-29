from __future__ import annotations

import asyncio
import json
from collections import defaultdict
from typing import DefaultDict, Set

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, status
from fastapi.responses import JSONResponse

app = FastAPI(title="Read Anywhere Rendezvous Relay", version="0.1.0")

# In-memory only. The relay intentionally stores no books, bookmarks, progress,
# manifests, or message history. Restarting the process drops all rooms.
_rooms: DefaultDict[str, Set[WebSocket]] = defaultdict(set)
_lock = asyncio.Lock()
MAX_MESSAGE_BYTES = 1024 * 1024 * 8  # 8 MB; production should use smaller chunks.


@app.get("/health")
async def health() -> JSONResponse:
    return JSONResponse({"ok": True, "rooms": len(_rooms)})


@app.websocket("/ws/{account_id}/{device_id}")
async def websocket_endpoint(websocket: WebSocket, account_id: str, device_id: str) -> None:
    await websocket.accept()
    async with _lock:
        _rooms[account_id].add(websocket)

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

            # Validate only that this is JSON. The payload is expected to be E2E
            # encrypted by clients in production; relay must not inspect it.
            try:
                json.loads(message)
            except json.JSONDecodeError:
                await websocket.send_json({"type": "error", "message": "Invalid JSON"})
                continue

            await _broadcast_raw(account_id, message, exclude=websocket)
    except WebSocketDisconnect:
        pass
    finally:
        async with _lock:
            _rooms[account_id].discard(websocket)
            if not _rooms[account_id]:
                _rooms.pop(account_id, None)
        await _broadcast_system(account_id, {
            "type": "peer_left",
            "accountId": account_id,
            "deviceId": device_id,
        })


async def _broadcast_raw(account_id: str, message: str, exclude: WebSocket | None = None) -> None:
    peers = list(_rooms.get(account_id, set()))
    for peer in peers:
        if peer is exclude:
            continue
        try:
            await peer.send_text(message)
        except RuntimeError:
            async with _lock:
                _rooms[account_id].discard(peer)


async def _broadcast_system(account_id: str, payload: dict, exclude: WebSocket | None = None) -> None:
    await _broadcast_raw(account_id, json.dumps(payload), exclude=exclude)
