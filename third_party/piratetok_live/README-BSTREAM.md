# BStream PirateTok LIVE fork

This directory is based on `piratetok_live` 0.1.5, upstream commit
`c702c4362abb59e9aba73b8dcd7a95d40bcc18bc`, under the included 0BSD license.

BStream keeps this exact audited source in-tree because TikTok LIVE uses an
unofficial protocol and the application must not silently change transport
behavior during a dependency upgrade. BStream's changes are intentionally
small and covered by its LIVE adapter and protocol tests:

- report `connected` only after the WebSocket upgrade succeeds;
- decode `WebcastChatMessage.user_identity` so moderator-only commands work;
- cancel HTTP setup, WebSocket listeners, and retry delays when a session is
  replaced or stopped;
- revalidate the room after repeated handshakes without decoded traffic;
- acknowledge response envelopes before routing large event batches and allow
  cheap chat-text filtering before nested user profiles are decoded;
- validate the WebSocket upgrade cryptographically and bound headers, frames,
  connect/body reads, and shutdown waits;
- surface socket errors without losing ACK, heartbeat, gzip, or stale-timeout
  behavior.

This integration is not affiliated with or endorsed by TikTok.
