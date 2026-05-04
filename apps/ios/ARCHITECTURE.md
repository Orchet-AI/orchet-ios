# iOS architecture (post multi-service refactor)

The native app talks to **`apps/bff-ios`** — never directly to backend
services. The BFF resolves the user's session, forwards the
`X-Orchet-User-Id` header, and proxies upstream to the relevant
service:

```
SwiftUI                       Express BFF                Express services
─────────                     ────────────               ─────────────────
LumoApp.swift  ──HTTPS──▶  apps/bff-ios            ──▶  services/auth          (:4001)
ChatService                   :4010                       services/notifications (:4002)
NotificationService                                       services/integrations  (:4003)
…                                                         services/orchestrator  (:4005)
                                                          services/mcp-client    (:4006)
```

## Where things live

- **Wire shapes** — generated from the Pydantic schemas in
  [services/ml-brain/lumo_ml/schemas.py](../../services/ml-brain/lumo_ml/schemas.py)
  via [packages/shared-types](../../packages/shared-types/) codegen.
- **Chat SSE** — `apps/bff-ios` proxies POST `/api/chat` to
  `services/orchestrator /turn`. Frame contract is identical to the
  web shell's chat surface.
- **Auth** — Bearer-token flow (Supabase session JWT) on iOS;
  cookie-based flow on web. `services/auth` `/me` accepts both.
- **Notifications** — `services/notifications` `/devices` registers
  the APNs token after `application(_:didRegisterForRemoteNotifications-
  WithDeviceToken:)`. The push transport gateway lives in
  `services/notifications/src/transports/push.ts` (stub today; APNs
  sender lands with MOBILE-NOTIF-PUSH-1).

## During the transition

Until the apps/web → BFF rewire is done, the iOS app continues to hit
`apps/web /api/*` (which is what `LumoAPIBase` defaults to). When the
BFF takes over, switch `LumoAPIBase` in `Info.plist` to the
`apps/bff-ios` URL and the same SwiftUI code keeps working — the
frame shapes don't change.

See also:
- [docs/architecture/restructure-2026-05.md](../../docs/architecture/restructure-2026-05.md) —
  full multi-service overview.
- [README.md](README.md) — Xcode setup + run instructions.
