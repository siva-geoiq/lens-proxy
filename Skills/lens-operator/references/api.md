# Lens API

## Connection

`lensctl` launches Lens, reads `~/Library/Application Support/Lens/api.json`, and authenticates with the Keychain item whose service is `com.lenskart.lens.api` and account is `local-automation`. Direct clients must send `Authorization: Bearer <token>`. Lens accepts loopback HTTP only and rejects browser `Origin` requests.

Every JSON response contains `apiVersion`, `requestId`, and either `data` or `error`. Long operations return HTTP 202 with an operation ID; poll `GET /v1/operations/{id}`. Supply an `Idempotency-Key` when retrying engine, session, or device commands.

## Core endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/v1/status` | Engine, capture, mapping, flow, and device summary |
| GET | `/v1/capabilities` | Feature availability |
| GET | `/v1/openapi.json` | Authoritative OpenAPI 3.1 schema |
| GET | `/v1/events` | SSE stream; reconnect with `Last-Event-ID` |
| POST | `/v1/engine/start`, `/stop`, `/restart` | Engine lifecycle |
| GET | `/v1/engine/log` | Recent bundled mitmproxy log |
| PATCH | `/v1/settings` | Set `proxyPort` through a pollable engine transition |
| POST | `/v1/capture/pause`, `/resume`, `/clear` | Capture lifecycle |
| PUT | `/v1/capture/options` | Set `removeConditionalHeaders` |
| GET | `/v1/flows` | Paginated flow metadata |
| GET | `/v1/search?q=...` | Search every flow field indexed by Lens |
| GET | `/v1/flows/{id}` | Headers, timings, WebSockets, mapping and Android context |
| GET | `/v1/flows/{id}/{request|response}/body` | Original body bytes and truncation headers |
| GET | `/v1/flows/{id}/curl` | Generated cURL command |
| POST | `/v1/flows/{id}/mappings` | Create `localResponse` or `rewriteRequest` mapping |
| GET/POST | `/v1/mappings` | List or create mappings |
| GET/PUT/DELETE | `/v1/mappings/{id}` | Read, replace, or delete a mapping |
| PUT | `/v1/mappings/{id}/enabled` | Enable or disable a mapping |
| POST | `/v1/mappings/{id}/duplicate` | Duplicate a mapping |
| PUT | `/v1/mappings/order` | Replace mapping order |
| POST | `/v1/sessions/save`, `/open` | Save or open an absolute `.mitm` path |
| GET | `/v1/devices` | Connected ADB devices and sync state |
| POST | `/v1/devices/refresh` | Refresh ADB discovery |
| GET/PATCH | `/v1/devices/{serial}` | Read or rename/reset a device |
| POST | `/v1/devices/{serial}/attach`, `/detach` | Change Android proxy attachment |
| GET/PUT | `/v1/devices/{serial}/inspection` | Read or select inspection mode |
| GET | `/v1/devices/{serial}/inspection/processes` | Debuggable processes |
| GET | `/v1/devices/{serial}/shared-preferences/apps` | Apps accessible through Android `run-as` |
| GET | `/v1/devices/{serial}/shared-preferences/{package}` | Preference files, typed entries, and package ETag |
| GET | `/v1/devices/{serial}/shared-preferences/{package}/{file}` | One preference file with the package ETag |
| POST | `/v1/devices/{serial}/shared-preferences/{package}/apply` | Atomically apply complete replacement entries for changed files |

## Flows and pagination

Use `deviceId`, `host`, `method`, `scheme`, `kind`, `search`, `limit`, and opaque `cursor` query parameters. Limits default to 100 and cap at 500. Lists include body metadata but not body bytes. Fetch a body only after narrowing the result set.

## Mapping revisions

Read the mapping collection and retain its `ETag`. Send that value in `If-Match` when updating, deleting, enabling, duplicating, or reordering. On HTTP 412, fetch the collection again and rebuild the intended change. Mapping paths are exact unless they contain `*`; each `*` matches zero or more path characters, including `/`. Query matching remains controlled separately by `matchQuery`. First enabled matching rule of each behavior wins.

## Confirmations

Destructive or disruptive calls can return HTTP 409 with `error.code` equal to `confirmation_required`. Show `error.details.summary` to the user. After approval, repeat the identical method, path, and body within 60 seconds using `--confirm error.details.confirmationId`.

Changing `proxyPort` while Android devices are attached requires confirmation and returns HTTP 202. Poll the returned operation until it succeeds or fails; success means Lens restored the devices, restarted and authenticated mitmproxy on the new port, and reattached the devices. A failed operation leaves successfully restored devices on direct networking and preserves recovery snapshots for devices Lens could not restore.

Shared Preferences apply requires both the package response `ETag` in `If-Match` and an `Idempotency-Key`. Values are typed as `string`, `stringSet`, `boolean`, `int`, `long`, or `float`; longs are decimal JSON strings so 64-bit values remain exact. Apply bodies contain complete replacement `entries` arrays only for changed existing files. A successful apply force-stops the app, atomically replaces the files, and attempts to relaunch its default activity. On HTTP 412, fetch the package again and rebuild the intended edits. Never print unrelated preference values or persist them to a repository.

Do not reuse confirmation IDs or alter the payload between attempts.
