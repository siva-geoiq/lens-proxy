# Lens Workflows

## Attach and capture

1. Run `lensctl status` and start the engine if it is stopped.
2. `POST /v1/devices/refresh`, poll the returned operation, then `GET /v1/devices`.
3. Attach the exact serial with `POST /v1/devices/{serial}/attach` and an `Idempotency-Key`.
4. Poll its operation until `succeeded`, trigger the app request, then filter `/v1/flows` by `deviceId` and host.
5. Detach the device at the end only if this workflow attached it.

Stopping Lens restores every attached device proxy before stopping mitmproxy. Restarting or changing `proxyPort` restores devices first, waits for the new engine to authenticate, then reattaches them. Treat these calls as incomplete until their operation succeeds. If cleanup fails, Lens keeps a still-running engine alive when possible and returns the affected device serials in the operation error.

If attachment reports a VPN conflict, do not immediately retry with `stopConflictingVPN`. Ask the user, send `{"stopConflictingVPN":true}`, show the confirmation summary, and only then repeat with its confirmation ID.

## Mock a response

1. Identify one exact flow.
2. `POST /v1/flows/{id}/mappings` with `{"behavior":"localResponse"}`.
3. `GET /v1/mappings`, locate the returned ID, preserve its match fields and response headers, edit the response body/status, then `PUT` it with the current `ETag` in `If-Match`.
4. Trigger the request again and verify `mappedRuleID` on the new flow.

Use `*` in the mapping path to cover a family of endpoints. For example, `/v2/products/*` matches every descendant product path on the rule's exact method, scheme, host, and port. Leave `matchQuery` false to accept any query string. Put narrow exact mappings before broad wildcard mappings because the first enabled matching rule wins.

## Rewrite a request

Create a mapping with `{"behavior":"rewriteRequest"}`. Set `rewriteHeaders` and/or `rewriteBody`; leave either false to pass that portion through unchanged. Trigger a fresh device request because rewrites apply before upstream transmission, not retroactively.

## Simulate a slow network

Set `delayMilliseconds` on any mapping rule. Lens holds each matching request for that long before the client sees a response, so the rule's behavior decides where the wait lands: a `localResponse` rule answers late, and a `rewriteRequest` rule forwards upstream late. Values are capped at 60000 ms and clamped on write.

The presets the Lens editor offers are 0 (no delay), 30 (5G), 100 (4G LTE), 300 (3G) and 800 (2G EDGE); any other value is accepted and shows as Custom. To throttle an endpoint without changing its payload, create a `rewriteRequest` mapping with `rewriteHeaders` and `rewriteBody` both false and only `delayMilliseconds` set.

## Firebase Remote Config

Enable `removeConditionalHeaders` through `/v1/capture/options` before triggering the fetch. Search for `firebaseremoteconfig.googleapis.com` and `firebase:fetch`. A `NO_CHANGE` response usually indicates server/cache behavior; use a local response mapping to return a complete Firebase fetch response when testing configuration changes.

## Sessions

Use absolute `.mitm` paths. Opening replaces the current capture and therefore requires confirmation. Saving over an existing file also requires confirmation. Persisted mapping rules remain independent of sessions.

## Deep Inspection

Check `data.androidDeepInspection.available` in `/v1/capabilities`. Read `/v1/devices/{serial}/inspection/processes`, then set the mode with one of:

```json
{"mode":"automatic"}
{"mode":"package","package":"com.example.app"}
{"mode":"off"}
```

Treat foreground Activity as observational. Use a call site only when the flow carries a high-confidence Android context; do not infer ownership from timestamps alone.

## Inspect or edit Shared Preferences

1. Refresh devices and choose the exact ADB serial. Proxy attachment is not required.
2. Check `data.androidSharedPreferences.available` in `/v1/capabilities`, then list `/v1/devices/{serial}/shared-preferences/apps`.
3. Fetch the exact package and retain its `ETag`. Narrow to a file or key before displaying values because preferences may contain credentials or personal data.
4. Build an apply body containing complete typed `entries` arrays for changed existing files only. Preserve `long` values as decimal strings.
5. POST the body to `/v1/devices/{serial}/shared-preferences/{package}/apply` with `--if-match`, a unique `--idempotency` value, and no confirmation initially.
6. Show the returned confirmation summary to the user. Only after approval, repeat the identical request with `--confirm`.
7. Poll the operation. If the revision changed, fetch the package again and rebuild the edit instead of merging against stale data.
