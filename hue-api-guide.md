# Hue API Guide

A working reference for how this project talks to the Philips Hue Bridge Pro, and for debugging when it doesn't. Everything marked "verified" was tested against the real bridge through the remote API on 2026-09-21.

## Official documentation

Most of the developer portal is behind a free login at [developers.meethue.com](https://developers.meethue.com/). Register an account, then these pages are the ones that matter:

| Page | What it covers |
|------|----------------|
| [Get started](https://developers.meethue.com/develop/get-started-2/) | Public. Local discovery and creating a local app key |
| [New Hue API overview](https://developers.meethue.com/new-hue-api/) | Public. Why CLIP v2 exists, v1 deprecation notes |
| [CLIP v2 API reference](https://developers.meethue.com/develop/hue-api-v2/api-reference/) | Every resource type and its GET/PUT/POST schema. The one you want most |
| [CLIP v2 core concepts](https://developers.meethue.com/develop/hue-api-v2/core-concepts/) | Resources, services, owners, rids |
| [CLIP v2 getting started](https://developers.meethue.com/develop/hue-api-v2/getting-started/) | Local v2 quick start |
| [Cloud2Cloud getting started](https://developers.meethue.com/develop/hue-api-v2/cloud2cloud-getting-started/) | Calling CLIP v2 through the remote API |
| [Remote authentication (OAuth)](https://developers.meethue.com/develop/hue-api/remote-authentication-oauth/) | Token endpoints and lifetimes |
| [Remote API quick start](https://developers.meethue.com/develop/hue-api/remote-api-quick-start-guide/) | End to end remote setup |
| [My apps](https://developers.meethue.com/my-apps/) | Where the remote app (client id and secret) lives |
| [Migration guide v1 to v2](https://developers.meethue.com/develop/hue-api-v2/migration-guide-to-the-new-hue-api/) | Maps v1 concepts to v2 |

Useful outside the login wall:

- [openhue/openhue-api](https://github.com/openhue/openhue-api): community OpenAPI spec for CLIP v2. Mostly accurate. One known error: its `Signaling` PUT schema names the array `color`, but the bridge expects `colors` (verified).
- [Remote Authentication and Controlling Philips Hue API using Postman](https://gotoguy.blog/2020/05/21/remote-authentication-and-controlling-philips-hue-api-using-postman/): the walkthrough this project was originally built from. Still right about the overall flow (register app, authorize, exchange code, remote link button, create username) but its token URLs are the v1 OAuth endpoints, which now return 404. Use the v2 URLs below.
- [Serverless Swift](https://www.ryantoken.com/blog/serverless-swift): the original write-up of this project. The v1 light-state calls it shows have since been replaced by the CLIP v2 calls described here.

## Two APIs, two ways in

**CLIP v1** ("the bridge API"): `/api/<username>/lights/<n>/state`, numeric light ids, `hue`/`sat`/`bri` colors. Still works but frozen; Signify says new features are v2 only and v1 will eventually go away.

**CLIP v2**: `/clip/v2/resource/<type>[/<uuid>]`, UUID ids, CIE `xy` colors, HTTPS only, server-sent events. This project uses v2 for everything except the OAuth flow.

Both are reachable two ways:

| | Local (same network) | Remote (from anywhere, including Lambda) |
|---|---|---|
| v1 base | `https://<bridge-ip>/api/<app-key>/` | `https://api.meethue.com/bridge/<app-key>/` |
| v2 base | `https://<bridge-ip>/clip/v2/resource/` | `https://api.meethue.com/route/clip/v2/resource/` |
| Auth | `hue-application-key: <app-key>` header | `Authorization: Bearer <access-token>` plus `hue-application-key: <app-key>` |
| TLS | Self-signed cert; pin it or use `-k` for curl | Normal |

The remote path is a relay: Hue's cloud forwards the request to the bridge over the bridge's own outbound connection, so nothing needs to reach the home network. The Lambdas only ever call `api.meethue.com`.

Find the bridge on the LAN with `curl https://discovery.meethue.com/` (returns the bridge id and internal IP for your public IP) or mDNS `_hue._tcp`.

## Remote authentication

Credentials live in SSM Parameter Store (`us-east-1`): `hue-client-id`, `hue-client-secret`, `hue-access-token`, `hue-refresh-token`, `hue-remote-username`. Never hardcode or log them.

1. **Register a remote app** at [My apps](https://developers.meethue.com/my-apps/). That gives the client id, client secret, and app id, and you set the callback URL.
2. **Authorize** (browser, once): `GET https://api.meethue.com/v2/oauth2/authorize?client_id=<id>&response_type=code&state=<random>` (verified: the endpoint enforces `response_type` and `client_id`, and the redirect URI must exactly match the whitelisted one). Sign in with the Hue account, approve, and copy `code` from the redirect.
3. **Exchange the code**: `POST https://api.meethue.com/v2/oauth2/token` with `Authorization: Basic base64(client_id:client_secret)`, `Content-Type: application/x-www-form-urlencoded`, body `grant_type=authorization_code&code=<code>`. Response has `access_token` and `refresh_token`.
4. **Refresh**: same endpoint, body `grant_type=refresh_token&refresh_token=<token>`. Every refresh returns a new pair and invalidates the old ones, so both must be stored again. `HueTokenRefresher` does this every 3 days and writes both back to SSM (verified working in logs).
5. **Create the app key** (a.k.a. remote username / whitelist user), once. The physical link button can't be pressed remotely, so: `PUT https://api.meethue.com/bridge` with `{"linkbutton": true}` (Bearer auth), then within 30 seconds `POST https://api.meethue.com/bridge` with `{"devicetype": "sports-home-automation"}`. The response contains `username`; that is `hue-remote-username`, and it is the value sent as `hue-application-key` on every v2 call.

Token lifetimes are documented as 7 days for the access token and 112 days for the refresh token (the `expires_in` field in the token response is the authoritative number). The 3-day refresh keeps both current. The v1 OAuth endpoints (`/oauth2/token`, `/oauth2/refresh`) were deprecated in July 2020 and are now gone.

## CLIP v2 essentials

Every response is `{"data": [...], "errors": [...]}`. Resources have an `id` (UUID), a `type`, and usually an `id_v1` like `/lights/24` that maps back to the v1 numeric id. A `device` owns services (`light`, `zigbee_connectivity`, ...); a `room` contains devices; a `zone` contains light services directly. Rooms and zones each expose a `grouped_light` service, which is how you address all of their lights in one request.

Status codes seen from the bridge: `200` OK, `201` created (POST), `207` Multi-Status meaning the request was accepted but at least one light couldn't be reached (check `errors[].error_code == "communication_error"`), `4xx` with an `errors` array explaining why.

Common `PUT /light/<id>` and `PUT /grouped_light/<id>` fields:

```json
{
  "on": {"on": true},
  "dimming": {"brightness": 100},
  "color": {"xy": {"x": 0.4263, "y": 0.4203}},
  "color_temperature": {"mirek": 366},
  "dynamics": {"duration": 400},
  "alert": {"action": "breathe"},
  "signaling": {"signal": "alternating", "duration": 10000, "colors": [{"xy": {"x": 0.4263, "y": 0.4203}}, {"xy": {"x": 0.1541, "y": 0.081}}]}
}
```

- `dynamics.duration` is the fade time in ms for that change. Verified on lights and grouped lights.
- `signaling` makes the bridge blink the light by itself: `on_off`, `on_off_color` (one color), or `alternating` (two colors), for `duration` ms (max 65534000, rounded to 1 s). Verified: it works even when the light is off, the light returns to its previous state when the signal ends, the array key is `colors`, and `dynamics` is ignored so the changes snap rather than fade. The cadence is fixed by the bridge. This project tried it and moved to scheduled `color` updates because the snaps looked harsh.
- Colors are CIE xy. To convert a v1 `hue`/`sat` you like: set it with v1 (`PUT .../lights/<n>/state {"hue":..,"sat":..}`), then `GET /clip/v2/resource/light/<uuid>` and read `color.xy`. That is how the values below were produced.
- Rate guidance from Hue is roughly 10 light commands/s and 1 group command/s. A group command is a Zigbee broadcast, and the bridge paces those: grouped_light PUTs sent every 800 ms were applied with visible, scattered stutter, while every 1000 ms they were even (verified by eye, twice). The remote relay also serializes requests to one bridge at about 100 ms each (observed), so five parallel per-light PUTs arrive over roughly half a second while one grouped_light PUT lands at once.
- The CLIP v2 event stream (`/eventstream/clip/v2`) is not available through the remote relay (`404`), so bridge-side timing can only be checked by watching the lights.

## How this project uses it

`ScoreProcessor` flashes the zone named **Game Day**. On each trigger it:

1. Reads `hue-remote-username` and `hue-access-token` from SSM.
2. `GET /route/clip/v2/resource/zone`, finds the zone by name, takes its `grouped_light` service rid and its `children` light rids.
3. `GET /route/clip/v2/resource/light` and keeps a snapshot of each zone light: `on.on`, `dimming.brightness`, and either `color_temperature.mirek` (when `mirek_valid`) or `color.xy`.
4. Every 1000 ms for 10 steps, `PUT /route/clip/v2/resource/grouped_light/<rid>` alternating the team's two colors with a 400 ms fade. The first PUT is awaited on its own, so an expired token or unreachable zone fails once and stops the flash. The remaining nine run as child tasks started at fixed deadlines (`ContinuousClock.sleep(until:)`), so a slow response neither delays the next step nor bunches up the rest. A `207` counts as applied since the other lights still change.
5. One step after the last change, `PUT /route/clip/v2/resource/light/<id>` for each light in parallel with its saved brightness and xy or mirek (400 ms fade). A light that was off gets a second PUT with `{"on": {"on": false}}` after that, so it comes back on later in its old color rather than the last flash color.

Known limit: the snapshot is live bridge state, so if two invocations ever overlap (two monitored teams scoring within the same ~10 s), the second would snapshot the first one's flash colors and restore to those. DynamoDB Streams runs one invocation per shard at a time and this table has a single shard, so records are processed one after another today; this only becomes possible if the table ever splits into multiple shards.

To change which lights flash, edit the Game Day zone in the Hue app (Settings > Rooms & zones). No code change. If the zone is deleted or renamed, the Lambda logs `No Hue zone named Game Day found` and does nothing.

Teams and their colors live in `Sources/Models/Teams.swift`. Colors are xy plus a brightness percent (derived from the original v1 hue/sat values):

| Color | xy | Brightness | v1 origin |
|-------|----|-----------|-----------|
| Gold (Tulsa, Missouri) | 0.4263, 0.4203 | 100 | hue 10500, sat 120 |
| Tulsa blue | 0.1541, 0.081 | 100 | hue 46000, sat 254 |
| Missouri black | none | 0 | none; a light can't emit black, so this is the lowest brightness the light supports (`brightness: 0` means "lowest possible" in CLIP v2, verified). No xy is sent so the fade from gold only dims; sending a color made the fade pass through that color on the way down (verified) |
| Eagles midnight green | 0.1637, 0.4554 | 100 | hue 33660, sat 254 |
| Eagles silver | 0.3718, 0.3757 | 100 | hue 37145, sat 10 |

Lights in the zone as of 2026-09-21 (all gamut C, all support `alternating`):

| id_v1 | Name | v2 id |
|-------|------|-------|
| /lights/1 | Big Lamp Bulb 2 | 85e874ea-a112-4c43-91b0-a65334eabce0 |
| /lights/3 | Big Lamp Bulb 1 | 7d06b3b9-dfa0-4fd2-83d0-cfef552609ec |
| /lights/4 | Front Room Lamp 1 | ee31a8b6-7aca-46ac-ac60-dc5121597656 |
| /lights/16 | Front Room Lamp 2 | 81a21efb-6f3e-45ca-aca2-2f3b6a0f5acc |
| /lights/24 | Hue lightstrip 1 | f76a2591-8a04-49ee-be6f-3e1275aa53ef |

## Debugging

Pull the credentials into shell variables without echoing them:

```bash
TOKEN=$(aws ssm get-parameter --region us-east-1 --name hue-access-token --query Parameter.Value --output text)
APPKEY=$(aws ssm get-parameter --region us-east-1 --name hue-remote-username --query Parameter.Value --output text)
H=(-H "Authorization: Bearer $TOKEN" -H "hue-application-key: $APPKEY" -H "Content-Type: application/json")
BASE=https://api.meethue.com/route/clip/v2/resource
```

Then:

```bash
curl -s "${H[@]}" $BASE/light | jq '.data[] | {id, id_v1, name: .metadata.name, on: .on.on}'
curl -s "${H[@]}" $BASE/zone  | jq '.data[] | {name: .metadata.name, grouped_light: (.services[] | select(.rtype=="grouped_light") | .rid)}'
curl -s "${H[@]}" $BASE/zigbee_connectivity | jq '.data[] | select(.status != "connected")'
curl -s "${H[@]}" -X PUT $BASE/grouped_light/<rid> -d '{"color":{"xy":{"x":0.4263,"y":0.4203}},"dynamics":{"duration":400}}'
```

| Symptom | Likely cause |
|---------|--------------|
| `401` with empty body on `/route/clip/v2/...` | Access token invalid, expired, or just rotated (verified). Check `HueTokenRefresher` ran (every 3 days, `rate(4320 minutes)`). A flash that starts seconds before a refresh can hit this once; it self-heals on the next event |
| `403` with empty body on `/route/clip/v2/...` | `hue-application-key` header missing or not a username created on this bridge (verified) |
| `invalid_client` from `/v2/oauth2/token` | Basic auth header is wrong, or client id/secret in SSM don't match the app in My apps |
| `207` with `communication_error` | That light is unreachable over Zigbee (switched off at the wall, out of range). Other lights in the group still change |
| `No Hue zone named Game Day found` | Zone was renamed or deleted in the Hue app |
| Lights flash but out of sync | Something is PUTting per light instead of to the zone's `grouped_light` |
| Local `https://<bridge-ip>` fails TLS | Expected; the bridge cert is self-signed. Use `curl -k` or pin the cert |

Lambda logs: `/aws/lambda/prod-score-processor-*` in CloudWatch. Every Hue request logs `PUT grouped_light/... succeeded` or the status and error body.

## Hue Bridge Pro notes

The Bridge Pro speaks the same CLIP v1 and v2 APIs as the v2 square bridge; nothing in this project is Pro-specific. Pro additions exposed through the API are the MotionAware motion areas (documented in the CLIP v2 reference) and higher device limits. If a v2 call behaves differently from the docs, check the bridge's software version first (`GET /route/clip/v2/resource/bridge` and the `device` resource for the bridge), since features like `signaling` and `effects_v2` arrived in firmware updates.

## Terminology

**CLIP**: Connected Lighting Interface Protocol. Hue's name for the REST API the bridge itself serves. Every Hue bridge is a small HTTPS web server on your network, and CLIP is what you speak to it. "The Hue API", "the bridge API", and "CLIP" all mean the same thing. There is also a debug page on the bridge at `https://<bridge-ip>/debug/clip.html` for hand-building requests.

**CLIP v1 vs CLIP v2**: two generations of that same API. v1 (2012) uses paths like `/api/<username>/lights/3/state`, numeric ids, and `hue`/`sat`/`bri` colors. v2 (2021) uses `/clip/v2/resource/<type>/<uuid>`, UUID ids, `xy` colors, HTTPS only, and an event stream. Both still run on the bridge today. New features only land in v2.

**Remote API / Cloud2Cloud**: not a different API, just a different way to reach the bridge. Instead of calling the bridge's LAN address you call `api.meethue.com`, Hue's cloud, which relays the request to your bridge over the connection the bridge keeps open to Hue. Same CLIP requests, different base URL, plus an OAuth bearer token to prove who you are to the cloud. "Cloud2Cloud" is Hue's name for this in the v2 docs. The Lambdas use it because they are not on your network.

**Local API**: calling the bridge directly by IP on the LAN. No OAuth needed, only the app key. The bridge's TLS certificate is self-signed.

**App key / username / whitelist user / `hue-application-key`**: four names for one thing: the credential the bridge issues when you register an app by pressing the link button. v1 calls it `username` and puts it in the URL path; v2 calls it the application key and sends it in the `hue-application-key` header. In this project it is stored as `hue-remote-username` in SSM.

**Link button**: the physical button on the bridge. Pressing it opens a 30 second window during which a new app key can be created. Remotely, `PUT https://api.meethue.com/bridge {"linkbutton": true}` does the same thing.

**`devicetype`**: the app's self-chosen name sent when creating an app key (`{"devicetype": "sports-home-automation"}`). Cosmetic; it shows up in the Hue app's list of connected apps.

**Access token / refresh token / client id / client secret**: standard OAuth 2.0. The client id and secret identify this project's registered remote app to Hue's cloud. The access token is the short-lived (7 day) bearer token sent on remote calls. The refresh token is the long-lived (112 day) token used to mint a new pair. Each refresh invalidates the previous pair.

**Resource**: v2's unit of everything: a `light`, a `device`, a `room`, a `zone`, a `scene`, the `bridge`, and so on. Each has a `type` and a UUID `id`.

**`rid` / `rtype`**: a reference to another resource: its id and its type. Rooms list their `children` as `{"rid": "<device uuid>", "rtype": "device"}`; a zone lists `{"rid": "<light uuid>", "rtype": "light"}`.

**Service / owner**: v2 splits a physical product into a `device` and the services it offers. A color bulb is a `device` that owns a `light` service and a `zigbee_connectivity` service. The `light` resource is what you PUT colors to; its `owner` points back at the device.

**`id_v1`**: the v1 path for the same thing (`/lights/24`), included on v2 resources so you can map between the two generations.

**Room vs zone**: a room contains devices, and a device can be in only one room. A zone contains light services and a light can be in any number of zones. Both get a `grouped_light`. Zones are the right tool for "these lights, wherever they are", which is why this project uses one.

**`grouped_light`**: the virtual light that stands for all lights in a room or zone. A PUT to it is broadcast to every member at once, which is both faster and better synchronized than PUTting to each light.

**`xy`**: a color as a point in the CIE 1931 chromaticity diagram, two numbers between 0 and 1. This is how v2 expresses color. It is device-independent, unlike v1's `hue`/`sat` which the bridge interpreted per bulb.

**Gamut / gamut type**: the triangle of `xy` colors a given bulb can physically produce. Gamut C is the current wide-gamut Hue color bulbs. If you ask for an `xy` outside a bulb's gamut, the bulb shows the nearest color it can.

**Mirek**: color temperature for white light, in reciprocal megakelvin (1,000,000 / kelvin). 153 is coolest, 500 warmest. Used by `color_temperature.mirek`. Older docs say "mired".

**Dimming / brightness**: v2 brightness is a percentage (0 to 100). v1 `bri` was 1 to 254.

**Dynamics**: in a PUT, `dynamics.duration` is how long (ms) the light takes to fade to the new state. In a GET it reports whether a dynamic scene is playing.

**Alert**: a one-off "breathe" pulse in the current color. v2 `{"alert": {"action": "breathe"}}`, v1 `{"alert": "select"}`.

**Signaling**: the bridge blinks the light on its own for a duration: `on_off`, `on_off_color`, or `alternating` between two colors. Instant transitions only. See CLIP v2 essentials above.

**Effects / `effects_v2`**: bridge-driven animations built into newer bulbs (candle, fire, prism, sparkle, and so on). Not team-color friendly.

**Scene**: a saved set of light states for a room or zone, recalled in one call. A dynamic scene cycles a color palette across the lights over time.

**Event stream / SSE**: `GET /eventstream/clip/v2` on the bridge returns server-sent events for every state change in real time, so apps don't have to poll. v2 only. Not used here.

**Entertainment API**: a separate low-latency UDP streaming protocol for syncing lights to games and video at up to 25 updates per second. Local network only, so not usable from Lambda.

**Zigbee**: the wireless mesh protocol between the bridge and the bulbs. `zigbee_connectivity.status` of `connectivity_issue` means the bridge can't reach that bulb (usually powered off at a wall switch). Every bulb also relays for its neighbors, so an unpowered bulb can weaken the mesh for others.

**207 Multi-Status**: HTTP status the bridge returns when it accepted a request but couldn't apply it everywhere, typically because one light in a group is unreachable. The `errors` array says which.

**MotionAware**: Bridge Pro feature that uses the Zigbee radio signals between bulbs to detect motion without motion sensors. Exposed in CLIP v2 as motion areas. Not used here.

**mDNS / `discovery.meethue.com`**: two ways to find the bridge's LAN IP. mDNS advertises the bridge as `_hue._tcp`; the discovery URL returns bridges seen from your public IP.
