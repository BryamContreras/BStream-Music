#!/usr/bin/env python3
"""TikTok LIVE chat bridge for BStream Music.

The Flutter app launches this script as a subprocess and reads newline-delimited
JSON events from stdout. Keep this helper focused on chat ingestion so the music
engine stays isolated from TikTok's unofficial/reverse-engineered protocol.
"""

from __future__ import annotations

import argparse
import asyncio
import ctypes
import json
import os
import re
import sys
import traceback
from typing import Any, Optional, Tuple


sys.dont_write_bytecode = True

RECONNECT_DELAYS_SECONDS = (2, 5, 10)


def load_tiktok_live() -> tuple[Any, Any, Any, Any, Any, Any, Any]:
    from TikTokLive import TikTokLiveClient
    from TikTokLive.events import (
        CommentEvent,
        ConnectEvent,
        DisconnectEvent,
        LiveEndEvent,
    )
    from TikTokLive.client.errors import UserNotFoundError, UserOfflineError

    return (
        TikTokLiveClient,
        CommentEvent,
        ConnectEvent,
        DisconnectEvent,
        LiveEndEvent,
        UserNotFoundError,
        UserOfflineError,
    )


def emit(event_type: str, **payload: Any) -> None:
    print(
        json.dumps({"type": event_type, **payload}, ensure_ascii=False),
        flush=True,
    )


def normalize_creator(value: str) -> str:
    text = value.strip()
    if not text:
        return ""

    match = re.search(r"tiktok\.com/@([^/?#\s]+)", text, flags=re.IGNORECASE)
    if match:
        text = match.group(1)

    text = text.strip().removeprefix("@")
    text = text.split("?", 1)[0].split("#", 1)[0].split("/", 1)[0]
    return re.sub(r"[^A-Za-z0-9._-]", "", text)


def command_from_comment(text: str) -> dict[str, str] | None:
    message = text.strip()
    if not message:
        return None

    lowered = message.lower()
    if lowered == "revoke!":
        return {"action": "revoke", "query": ""}

    if not message.startswith("!"):
        return None

    payload = message[1:].strip()
    if not payload:
        return None

    parts = payload.split(maxsplit=1)
    action = parts[0].lower()
    query = parts[1].strip() if len(parts) > 1 else ""

    if action == "play" and query:
        return {"action": "play", "query": query}
    if action in {"skip", "next"}:
        return {"action": "skip", "query": ""}
    if action in {"revoke", "stop"}:
        return {"action": "revoke", "query": ""}
    return None


def user_name(event_user: Any) -> str:
    for attr in ("unique_id", "nickname", "user_id"):
        value = getattr(event_user, attr, None)
        if value:
            return str(value)
    return "unknown"


def user_is_moderator(event_user: Any) -> bool:
    """Read the moderator badge exposed by TikTokLive's extended user model."""
    if event_user is None:
        return False
    try:
        value = getattr(event_user, "is_moderator", False)
        return bool(value() if callable(value) else value)
    except Exception:
        return False


async def run_bridge(raw_user: str) -> int:
    creator = normalize_creator(raw_user)
    if not creator:
        emit("error", message="Usuario o link de TikTok LIVE invalido.")
        return 2

    try:
        (
            TikTokLiveClient,
            CommentEvent,
            ConnectEvent,
            DisconnectEvent,
            LiveEndEvent,
            UserNotFoundError,
            UserOfflineError,
        ) = load_tiktok_live()
    except ModuleNotFoundError:
        emit(
            "error",
            message=(
                "Falta TikTokLive en el entorno virtual. La app intenta "
                "instalarlo automaticamente; reparacion manual: "
                "py -3 -m pip install -r scripts\\requirements-tiktok.txt"
            ),
        )
        return 3

    live_ended = False
    room_id: Optional[int] = None

    async def connect_once(
        use_cached_room: bool,
    ) -> Tuple[str, bool, Optional[Exception]]:
        nonlocal live_ended, room_id

        connected_this_attempt = False
        client = TikTokLiveClient(unique_id=f"@{creator}")

        @client.on(ConnectEvent)
        async def on_connect(event: ConnectEvent) -> None:
            nonlocal connected_this_attempt, room_id
            connected_this_attempt = True
            resolved_room_id = getattr(client, "room_id", None)
            if resolved_room_id is not None:
                room_id = int(resolved_room_id)
            emit(
                "connected",
                user=getattr(event, "unique_id", creator),
                room_id=str(resolved_room_id or ""),
                message=f"Conectado a @{creator}",
            )

        @client.on(CommentEvent)
        async def on_comment(event: CommentEvent) -> None:
            text = str(getattr(event, "comment", "") or "").strip()
            command = command_from_comment(text)
            if command is None:
                return
            emit(
                "command",
                action=command["action"],
                query=command["query"],
                user=user_name(getattr(event, "user", None)),
                is_moderator=user_is_moderator(getattr(event, "user", None)),
                text=text,
            )

        @client.on(DisconnectEvent)
        async def on_disconnect(_: DisconnectEvent) -> None:
            if not live_ended:
                emit(
                    "status",
                    status="connecting",
                    user=creator,
                    message="Conexion LIVE cerrada. Preparando reconexion...",
                )

        @client.on(LiveEndEvent)
        async def on_live_end(_: LiveEndEvent) -> None:
            nonlocal live_ended
            live_ended = True
            emit("live_ended", user=creator, message="El live finalizo.")

        try:
            kwargs: dict[str, Any] = {
                "process_connect_events": False,
                "compress_ws_events": True,
            }
            if use_cached_room and room_id is not None:
                kwargs["room_id"] = room_id

            await client.connect(**kwargs)
            if live_ended:
                return "live_ended", connected_this_attempt, None
            return "disconnected", connected_this_attempt, None
        except UserOfflineError:
            live_ended = True
            emit("live_ended", user=creator, message=f"@{creator} no esta en vivo.")
            return "live_ended", connected_this_attempt, None
        except UserNotFoundError:
            live_ended = True
            emit(
                "live_ended",
                user=creator,
                message=f"No encontre un live activo para @{creator}.",
            )
            return "live_ended", connected_this_attempt, None
        except KeyboardInterrupt:
            return "stopped", connected_this_attempt, None
        except Exception as error:  # noqa: BLE001 - reconnect before reporting unexpected errors.
            return "error", connected_this_attempt, error
        finally:
            try:
                await client.close()
            except Exception:
                pass

    emit("status", status="connecting", user=creator, message=f"Conectando a @{creator}")
    status, connected, last_error = await connect_once(use_cached_room=False)
    if status in {"live_ended", "stopped"}:
        return 0

    while True:
        if connected:
            last_error = None

        reconnected = False
        for attempt, delay in enumerate(RECONNECT_DELAYS_SECONDS, start=1):
            await asyncio.sleep(delay)
            emit(
                "status",
                status="connecting",
                user=creator,
                message=f"Reconectando LIVE... intento {attempt}/3",
            )
            status, connected, last_error = await connect_once(
                use_cached_room=room_id is not None,
            )
            if status in {"live_ended", "stopped"}:
                return 0
            if connected:
                reconnected = True
                break

        if reconnected:
            continue

        emit(
            "status",
            status="connecting",
            user=creator,
            message="Revalidando live y room_id...",
        )
        await asyncio.sleep(3)
        status, connected, last_error = await connect_once(use_cached_room=False)
        if status in {"live_ended", "stopped"}:
            return 0
        if connected:
            continue

        message = "No se pudo reconectar al LIVE despues de revalidar la sala."
        if last_error is not None:
            message = f"{message} {last_error}"
        emit(
            "error",
            user=creator,
            message=message,
            traceback=traceback.format_exception_only(type(last_error), last_error)[-1].strip()
            if last_error is not None
            else "",
        )
        return 1


def process_is_running(process_id: int) -> bool:
    if process_id <= 0:
        return False
    if sys.platform == "win32":
        process_query_limited_information = 0x1000
        still_active = 259
        handle = ctypes.windll.kernel32.OpenProcess(
            process_query_limited_information,
            False,
            process_id,
        )
        if not handle:
            return False
        try:
            exit_code = ctypes.c_ulong()
            succeeded = ctypes.windll.kernel32.GetExitCodeProcess(
                handle,
                ctypes.byref(exit_code),
            )
            return bool(succeeded) and exit_code.value == still_active
        finally:
            ctypes.windll.kernel32.CloseHandle(handle)

    try:
        os.kill(process_id, 0)
        return True
    except OSError:
        return False


async def watch_parent(parent_pid: int) -> None:
    """Terminate the bridge if its BStream parent is no longer running."""
    if parent_pid <= 0:
        return
    while True:
        await asyncio.sleep(2)
        if not process_is_running(parent_pid):
            os._exit(0)


async def run_bridge_with_parent(raw_user: str, parent_pid: int) -> int:
    watcher = asyncio.create_task(watch_parent(parent_pid))
    try:
        return await run_bridge(raw_user)
    finally:
        watcher.cancel()


def main() -> int:
    parser = argparse.ArgumentParser(description="BStream TikTok LIVE bridge")
    parser.add_argument("--user", help="@usuario o link del live")
    parser.add_argument(
        "--parent-pid",
        type=int,
        default=0,
        help="PID de BStream; el puente se cierra cuando termina la app.",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Verifica que el ejecutable incluya las dependencias necesarias.",
    )
    args = parser.parse_args()
    if args.self_test:
        try:
            load_tiktok_live()
        except ModuleNotFoundError as error:
            emit("error", message=f"Dependencia faltante: {error.name}")
            return 3
        emit("status", status="ok", message="TikTok LIVE bridge listo.")
        return 0
    if not args.user:
        parser.error("--user es requerido salvo que uses --self-test")
    return asyncio.run(run_bridge_with_parent(args.user, args.parent_pid))


if __name__ == "__main__":
    raise SystemExit(main())
