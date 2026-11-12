# Push updates from Home Assistant (experimental)

Issue #47. Both apps behave the same.

## Goal

When the blind, the room lights or a level helper changes in Home Assistant, the screen follows
within about 2 seconds, not after the next poll (30 s on mains, 120 s on battery with *Pause on
battery* off). Battery use must be no worse than polling.

## Rollout: opt-in, config only

- A new key, `homeAssistant.push` (bool, default `false`). With it off, nothing changes.
- There is no Settings toggle and no beta channel in this first version. The docs list it under
  "Experimental" in `docs/setup.md`.
- A Settings toggle can come once it has run well for a while. A beta release channel would be a lot of
  machinery for one switch.

## How it works

1. **Connect.** Open `ws(s)://<host>/api/websocket` (from `homeAssistant.url`, with `http` → `ws` and
   `https` → `wss`).
   - Answer `auth_required` with `{"type":"auth","access_token":…}` using the stored token.
   - On `auth_ok`, send one `subscribe_entities` request with `entity_ids` set to exactly the entities
     Daylit reads:
     - the cover, the lights, `autoSwitch`, `sun` and the daylight sensor (`light`)
     - each monitor's `day`, `blindDown`, `night` and `nightLights` helpers, and its `set` helper
   - The token is never logged, and it never appears in a URL.
2. **Events.** Each `event` message carries added (`a`), changed (`c`) or removed (`r`) entities.
   - **A relevant change** to anything except the daylight sensor asks for a tick at once: a refresh,
     with a debounce: each further change moves the tick to 1 s after it, but never later than 3 s after
     the first change, so a burst runs one tick and a steady stream ticks at most every 3 s.
   - **Daylight sensor changes** ask for a tick at most once every 60 s, or every normal poll interval when
     that is longer (on battery, `batteryPollSeconds`).
   - The tick is the same tick as today. It still reads the full state through the REST template, so
     the brightness rules and the HA row stay exactly as they are. The socket only says *when* to tick.
3. **Polling stays as the safety net.**
   - While the socket is connected and subscribed, the poll interval is 300 s, on mains and on battery.
   - Otherwise it uses today's intervals.
4. **Reconnect.** After a drop, an auth failure, or a missing `pong` to a `ping` sent every 60 s,
   close and retry with backoff: 2 s, 5 s, 15 s, 60 s, then 60 s.
   - Also reconnect on wake from sleep and on a network change.
   - An `auth_invalid` stops retrying until the token or config changes, and shows a problem line like
     today's token errors.
5. **When it is closed.** The socket is closed while the source is not `homeAssistant`, while `push` is
   off, while paused on battery, and while Automatic is off. Each change of these opens or closes it.
   A config reload rebuilds the entity list and resubscribes. With Automatic off the socket is closed, so
   turning Automatic on (also from Home Assistant) is picked up by the normal poll, which reopens it.
6. **Logging,** with the existing once-then-every-10-minutes rule for repeated errors:
   - `push: connected (N entities)`
   - `push: lost (<reason>), retrying in Ns`
   - `push: off`

## Code layout

**Pure core,** tested on both platforms:

- `PushRule` / `Push` in `DaylitCore` and `Rules.cs`:
  - the WebSocket URL from the HA URL
  - the list of entities to subscribe
  - parsing an incoming message into `authRequired`, `authOk`, `authInvalid(reason)`,
    `result(id, ok)`, `event(changed entity ids)`, `pong` or `other`
  - the "tick now / after the daylight delay / ignore" decision for a set of changed ids, given the last
    daylight tick time
  - the backoff sequence
  - the poll interval while the socket is healthy

**App side:**

- macOS: a `PushClient` on `URLSessionWebSocketTask`.
- Windows: a `PushClient` on `ClientWebSocket`.
- Both wired into the existing refresh/tick and the open/close conditions.

## Tests (same cases on both platforms)

- **URL:** `http` → `ws`, `https` → `wss`; a path or trailing slash is kept correct; the port is kept.
- **Entity list:** it includes every configured entity once, leaves out unset ones, and includes
  `nightLights` and `set` when configured.
- **Message parsing:** every type above, including `subscribe_entities` events with `a`, `c` and `r`,
  and malformed JSON → `other`.
- **Decision:**
  - cover, lights and helper changes tick at once
  - a daylight-only change ticks only after 60 s
  - a mix ticks at once
  - an unknown entity is ignored
- **Backoff and poll interval:** as specified.
- **App side:** the auth message is built from the token and never logged. A unit test or a review
  check confirms the log lines carry no token.

## Measuring (by the owner, after merge)

- Compare one hour on battery with `push` on and off: Activity Monitor's Energy Impact, or
  `top -stats power`.
- Time a blind change against the next `auto:` log line.

## Out of scope

- A Settings toggle or a beta channel.
- Replacing the REST template read.
- Pushing anything from Daylit to Home Assistant over the socket. Publishing stays on REST.
