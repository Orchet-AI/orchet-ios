# iOS architecture (Hybrid: BFF + 1 backend process)

The native app talks to a **BFF** — never directly to the backend
process. The BFF resolves the user's session, forwards the
`X-Orchet-User-Id` header, and proxies upstream to a single
`@orchet/backend` URL. The backend mounts every sub-service under a
stable prefix.

In Hybrid mode there is one BFF: the Next.js `apps/web` deployment on
Vercel. iOS shares it.

```
SwiftUI                      BFF (Next.js)            @orchet/backend
─────────                    ─────────────            ─────────────────
LumoApp.swift  ──HTTPS──▶  apps/web /api/*  ──HTTPS─▶  /auth          (svc-auth)
ChatService                                            /notifications (svc-notifications)
NotificationService                                    /integrations  (svc-integrations)
…                                                      /orchestrator  (svc-orchestrator)
                                                       /mcp           (svc-mcp-client)
                                                       /cron          (svc-cron)
```

`@orchet/backend` listens on one URL (configured via
`ORCHET_BACKEND_URL` for SDK callers) and runs as one Node process.

## Where things live

- **Wire shapes** — generated from the Pydantic schemas in
  [services/ml-brain/lumo_ml/schemas.py](../../services/ml-brain/lumo_ml/schemas.py)
  via [packages/shared-types](../../packages/shared-types/) codegen.
- **Chat SSE** — `apps/web /api/chat` proxies to backend
  `/orchestrator/turn`. Frame contract is identical to the web shell's
  chat surface.
- **Auth** — Bearer-token flow (Supabase session JWT) on iOS;
  cookie-based flow on web. `/auth/me` accepts both.
- **Notifications** — `/notifications/devices` registers the APNs
  token after `application(_:didRegisterForRemoteNotifications-
  WithDeviceToken:)`. The push transport gateway lives in
  `services/notifications/src/transports/push.ts` (stub today; APNs
  sender lands with MOBILE-NOTIF-PUSH-1).

## During the transition

Until `apps/web/app/api/*` is fully cut over to call the backend over
HTTP (deferred Phase 7i + Phase 10 work), the iOS app continues to hit
`apps/web /api/*` directly — same as today, since those routes still
import service code in-process via the `apps/web/lib/*` shim chain.
The wire shapes won't change when the cutover happens.

If iOS ever needs an iOS-shaped projection of any endpoint that
diverges from the web shape, the projection lives in `apps/web/app/api/`
behind a `User-Agent` / `X-Client-Kind` header check rather than in a
separate iOS BFF process — Hybrid mode keeps the deployment surface to
one BFF + one backend.

See also:
- [docs/architecture/restructure-2026-05.md](../../docs/architecture/restructure-2026-05.md) —
  full multi-service overview.
- [README.md](README.md) — Xcode setup + run instructions.
