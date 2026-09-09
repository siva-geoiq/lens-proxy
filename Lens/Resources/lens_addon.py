import asyncio
import base64
import json
import os
import re
import time
import urllib.parse
from pathlib import Path

from mitmproxy import ctx, http, io, version


PROTOCOL_VERSION = 2
MAX_BODY_BYTES = 10 * 1024 * 1024
# Mapping snapshots contain base64-encoded bodies and routinely exceed asyncio's
# 64 KiB default. Keep an explicit upper bound and report larger commands without
# dropping the authenticated control connection.
MAX_CONTROL_MESSAGE_BYTES = 64 * 1024 * 1024
# A delayed request holds its connection for the whole wait. Mirror the cap the
# Lens editor enforces so a malformed rule cannot pin connections open.
MAX_DELAY_SECONDS = 60.0


def path_matches(pattern, request_path):
    if "*" not in pattern:
        return pattern == request_path
    expression = re.escape(pattern).replace(r"\*", ".*")
    return re.fullmatch(expression, request_path) is not None


def rule_delay_seconds(rule):
    """Simulated network delay for a matched rule, in seconds."""
    if not rule:
        return 0.0
    try:
        milliseconds = int(rule.get("delayMilliseconds") or 0)
    except (TypeError, ValueError):
        return 0.0
    return max(0.0, min(milliseconds / 1000.0, MAX_DELAY_SECONDS))


class LensAddon:
    def __init__(self):
        self.token = os.environ.get("LENS_CONTROL_TOKEN", "")
        self.clients = set()
        self.capture_enabled = True
        self.no_caching_enabled = False
        self.mappings = []
        self.flows = {}
        self.events = asyncio.Queue(maxsize=1000)
        self.server = None
        self.broadcast_task = None

    async def running(self):
        self.server = await asyncio.start_server(
            self.handle_client,
            "127.0.0.1",
            0,
            limit=MAX_CONTROL_MESSAGE_BYTES + 1,
        )
        port = self.server.sockets[0].getsockname()[1]
        print(f"LENS_CONTROL_PORT={port}", flush=True)
        self.broadcast_task = asyncio.create_task(self.broadcast_events())

    async def done(self):
        if self.broadcast_task:
            self.broadcast_task.cancel()
        if self.server:
            self.server.close()
            await self.server.wait_closed()

    async def request(self, flow: http.HTTPFlow):
        self.remove_conditional_cache_headers(flow)
        rewrite_rule = self.apply_request_rewrite(flow)
        mapping_rule = next(self.matching_rules(flow, "localResponse"), None)
        self.flows[flow.id] = flow
        delay = max(rule_delay_seconds(rewrite_rule), rule_delay_seconds(mapping_rule))
        if delay > 0:
            # Show the request while it is held so a throttled flow reads as
            # in-flight rather than as a stalled proxy, then answer it late so
            # the reported duration includes the simulated network delay.
            self.emit_flow(flow)
            await asyncio.sleep(delay)
        if mapping_rule is not None:
            self.apply_response_mapping(flow, mapping_rule)
        self.flows[flow.id] = flow
        self.emit_flow(flow)

    def response(self, flow: http.HTTPFlow):
        self.flows[flow.id] = flow
        self.emit_flow(flow)

    def error(self, flow: http.HTTPFlow):
        self.flows[flow.id] = flow
        self.emit_flow(flow)

    def websocket_message(self, flow: http.HTTPFlow):
        self.flows[flow.id] = flow
        self.emit_flow(flow)

    async def handle_client(self, reader, writer):
        await self.write(writer, "hello", {
            "engine": "mitmproxy",
            "mitmproxyVersion": version.VERSION,
            "protocolVersion": PROTOCOL_VERSION,
        })
        authenticated = False
        try:
            while not reader.at_eof():
                try:
                    line = await reader.readline()
                except ValueError:
                    await self.write_error(
                        writer,
                        "command_too_large",
                        f"Lens bridge commands must not exceed {MAX_CONTROL_MESSAGE_BYTES} bytes.",
                    )
                    continue
                if not line:
                    break
                if len(line) > MAX_CONTROL_MESSAGE_BYTES:
                    await self.write_error(
                        writer,
                        "command_too_large",
                        f"Lens bridge commands must not exceed {MAX_CONTROL_MESSAGE_BYTES} bytes.",
                    )
                    continue
                try:
                    message = json.loads(line)
                except json.JSONDecodeError as error:
                    await self.write_error(writer, "invalid_json", str(error))
                    continue
                if message.get("protocolVersion") != PROTOCOL_VERSION:
                    await self.write_error(writer, "protocol_mismatch", "Unsupported Lens bridge protocol.")
                    continue
                message_type = message.get("type")
                payload = message.get("payload") or {}
                if not authenticated:
                    if message_type != "authenticate" or payload.get("token") != self.token:
                        await self.write_error(writer, "unauthorized", "Invalid Lens bridge token.")
                        break
                    authenticated = True
                    self.clients.add(writer)
                    await self.write(writer, "authenticated", {
                        "captureEnabled": self.capture_enabled,
                        "noCachingEnabled": self.no_caching_enabled,
                    })
                    continue
                await self.handle_command(writer, message_type, payload, message.get("requestID"))
        finally:
            self.clients.discard(writer)
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass

    async def handle_command(self, writer, message_type, payload, request_id):
        try:
            if message_type == "setMappings":
                self.mappings = sorted(payload.get("rules", []), key=lambda rule: rule.get("order", 0))
                await self.write(writer, "mappingsUpdated", {"count": len(self.mappings)}, request_id)
            elif message_type == "setCaptureEnabled":
                self.capture_enabled = bool(payload.get("enabled", True))
                await self.write(writer, "captureState", {"enabled": self.capture_enabled}, request_id)
            elif message_type == "setNoCaching":
                self.no_caching_enabled = bool(payload.get("enabled", False))
                await self.write(
                    writer,
                    "noCachingState",
                    {"enabled": self.no_caching_enabled},
                    request_id,
                )
            elif message_type == "clearFlows":
                self.flows.clear()
                await self.write(writer, "sessionReset", {}, request_id)
            elif message_type == "saveSession":
                self.save_session(payload.get("path", ""))
                await self.write(writer, "sessionSaved", {"path": payload.get("path")}, request_id)
            elif message_type == "openSession":
                loaded = self.open_session(payload.get("path", ""))
                await self.write(writer, "sessionReset", {}, request_id)
                for flow in loaded:
                    await self.events.put(self.envelope("flowUpsert", self.serialize_flow(flow)))
            elif message_type == "annotateFlow":
                flow_id = payload.get("flowID")
                flow = self.flows.get(flow_id)
                if not flow:
                    raise ValueError(f"Unknown flow: {flow_id}")
                flow.metadata["lens_android_context"] = payload.get("androidContext")
                self.emit_flow(flow)
                await self.write(writer, "flowAnnotated", {"flowID": flow_id}, request_id)
            elif message_type == "shutdown":
                await self.write(writer, "shuttingDown", {}, request_id)
                ctx.master.shutdown()
            else:
                await self.write_error(writer, "unknown_command", f"Unknown command: {message_type}", request_id)
        except Exception as error:
            await self.write_error(writer, "command_failed", str(error), request_id)

    def remove_conditional_cache_headers(self, flow: http.HTTPFlow):
        if not self.no_caching_enabled:
            return
        for name in ("if-none-match", "if-modified-since", "if-range"):
            if name in flow.request.headers:
                del flow.request.headers[name]

    def matching_rules(self, flow: http.HTTPFlow, behavior):
        request = flow.request
        split = urllib.parse.urlsplit(request.pretty_url)
        request_port = request.port or (443 if request.scheme == "https" else 80)
        for rule in self.mappings:
            if not rule.get("enabled", True):
                continue
            if rule.get("behavior", "localResponse") != behavior:
                continue
            if rule.get("method", "").upper() != request.method.upper():
                continue
            if rule.get("scheme", "").lower() != request.scheme.lower():
                continue
            if rule.get("host", "").lower() != request.host.lower():
                continue
            if int(rule.get("port", request_port)) != request_port:
                continue
            if not path_matches(rule.get("path", "/"), split.path):
                continue
            if rule.get("matchQuery", False) and (rule.get("query") or "") != (split.query or ""):
                continue
            yield rule

    def apply_request_rewrite(self, flow: http.HTTPFlow):
        """Applies the first matching rewrite and returns it, or None."""
        request = flow.request
        for rule in self.matching_rules(flow, "rewriteRequest"):
            rewrite_body = bool(rule.get("rewriteBody", False))
            if rule.get("rewriteHeaders", False):
                blocked = {"content-length", "transfer-encoding", "host"}
                if rewrite_body:
                    blocked.add("content-encoding")
                request.headers = http.Headers([
                    (item.get("name", "").encode("latin-1"), item.get("value", "").encode("latin-1"))
                    for item in rule.get("requestHeaders", [])
                    if item.get("name") and item.get("name", "").lower() not in blocked
                ])
            if rewrite_body:
                body = rule.get("requestBody") or {}
                body_data = base64.b64decode(body.get("data", ""))
                request.headers.pop("content-encoding", None)
                request.headers.pop("transfer-encoding", None)
                request.headers.pop("content-length", None)
                request.content = body_data
            flow.metadata["lens_rewrite_id"] = rule.get("id")
            flow.metadata["lens_rewrite_name"] = rule.get("name")
            return rule
        return None

    def apply_response_mapping(self, flow: http.HTTPFlow, rule):
        body = rule.get("responseBody") or {}
        body_data = base64.b64decode(body.get("data", ""))
        headers = http.Headers([
            (item.get("name", "").encode("latin-1"), item.get("value", "").encode("latin-1"))
            for item in rule.get("responseHeaders", [])
            if item.get("name")
        ])
        flow.response = http.Response.make(int(rule.get("statusCode", 200)), body_data, headers)
        flow.metadata["lens_mapping_id"] = rule.get("id")
        flow.metadata["lens_mapping_name"] = rule.get("name")

    def emit_flow(self, flow):
        if not self.capture_enabled:
            return
        event = self.envelope("flowUpsert", self.serialize_flow(flow))
        if self.events.full():
            try:
                self.events.get_nowait()
            except asyncio.QueueEmpty:
                pass
        self.events.put_nowait(event)

    async def broadcast_events(self):
        while True:
            event = await self.events.get()
            data = (json.dumps(event, separators=(",", ":")) + "\n").encode()
            failed = []
            for writer in list(self.clients):
                try:
                    writer.write(data)
                    await writer.drain()
                except Exception:
                    failed.append(writer)
            for writer in failed:
                self.clients.discard(writer)

    def serialize_flow(self, flow: http.HTTPFlow):
        request = flow.request
        response = flow.response
        peer = flow.client_conn.peername
        ended_at = response.timestamp_end if response else None
        duration = ended_at - request.timestamp_start if ended_at else None
        websocket_messages = []
        if flow.websocket:
            for index, message in enumerate(flow.websocket.messages):
                content = message.content
                websocket_messages.append({
                    "id": f"{flow.id}-{index}",
                    "fromClient": message.from_client,
                    "isText": message.is_text,
                    "content": content.decode("utf-8", errors="replace") if message.is_text and isinstance(content, bytes)
                    else content if isinstance(content, str)
                    else base64.b64encode(content).decode(),
                    "timestamp": message.timestamp,
                })
        return {
            "id": flow.id,
            "clientAddress": peer[0] if peer else "Unknown",
            "clientPort": peer[1] if peer and len(peer) > 1 else None,
            "method": request.method,
            "scheme": request.scheme,
            "host": request.host,
            "port": request.port or (443 if request.scheme == "https" else 80),
            "path": request.path,
            "url": request.pretty_url,
            "requestHeaders": self.serialize_headers(request.headers),
            "requestBody": self.serialize_body(request, request.headers),
            "responseStatus": response.status_code if response else None,
            "responseReason": response.reason if response else None,
            "responseHeaders": self.serialize_headers(response.headers) if response else [],
            "responseBody": self.serialize_body(response, response.headers) if response else None,
            "startedAt": request.timestamp_start,
            "endedAt": ended_at,
            "duration": duration,
            "size": len(response.raw_content or b"") if response else 0,
            "mappedRuleID": flow.metadata.get("lens_mapping_id"),
            "mappedRuleName": flow.metadata.get("lens_mapping_name"),
            "rewrittenRuleID": flow.metadata.get("lens_rewrite_id"),
            "rewrittenRuleName": flow.metadata.get("lens_rewrite_name"),
            "error": flow.error.msg if flow.error else None,
            "websocketMessages": websocket_messages,
            "androidContext": flow.metadata.get("lens_android_context"),
        }

    def serialize_headers(self, headers):
        return [{"name": name, "value": value} for name, value in headers.items(multi=True)]

    def serialize_body(self, message, headers):
        try:
            data = message.get_content(strict=False) or b""
        except Exception:
            data = message.raw_content or b""
        truncated = len(data) > MAX_BODY_BYTES
        data = data[:MAX_BODY_BYTES]
        content_type = headers.get("content-type", "")
        lowered = content_type.lower()
        is_text = any(value in lowered for value in ("json", "text", "xml", "javascript", "form"))
        if not is_text:
            try:
                data.decode("utf-8")
                is_text = True
            except UnicodeDecodeError:
                pass
        return {
            "data": base64.b64encode(data).decode(),
            "isText": is_text,
            "truncated": truncated,
            "mimeType": content_type or None,
        }

    def save_session(self, path):
        if not path:
            raise ValueError("A session path is required.")
        with open(path, "wb") as stream:
            writer = io.FlowWriter(stream)
            for flow in self.flows.values():
                writer.add(flow)

    def open_session(self, path):
        if not path or not Path(path).exists():
            raise ValueError("The selected session does not exist.")
        loaded = []
        with open(path, "rb") as stream:
            for flow in io.FlowReader(stream).stream():
                if isinstance(flow, http.HTTPFlow):
                    self.flows[flow.id] = flow
                    loaded.append(flow)
        return loaded

    def envelope(self, message_type, payload, request_id=None, error=None):
        return {
            "protocolVersion": PROTOCOL_VERSION,
            "requestID": request_id,
            "type": message_type,
            "payload": payload,
            "error": error,
        }

    async def write(self, writer, message_type, payload, request_id=None):
        writer.write((json.dumps(self.envelope(message_type, payload, request_id)) + "\n").encode())
        await writer.drain()

    async def write_error(self, writer, code, message, request_id=None):
        payload = self.envelope("engineError", None, request_id, {"code": code, "message": message})
        writer.write((json.dumps(payload) + "\n").encode())
        await writer.drain()


addons = [LensAddon()]
