# Supabase remote control

VXTUBE uses `supabase_flutter` against project `igoqkqbkctcubozyaxnx`. The
publishable key in the client is intentionally public. Do not add a service
role key, Telegram bot token, admin token, or webhook secret to Flutter, CI
build arguments, or app configuration.

The supplied `telegram-control` function is for the Telegram control bot. It
currently responds `405 Method not allowed` to GET and `401 Unauthorized` to a
non-mutating `health` POST using the provided publishable key. VXTUBE therefore
uses a separate `vxtube-control` function and does not change the bot endpoint.

## Deploy

Install and authenticate the Supabase CLI, then from the repository root:

```sh
supabase login
supabase link --project-ref igoqkqbkctcubozyaxnx
supabase db push
supabase functions deploy vxtube-control --no-verify-jwt
supabase secrets set VXTUBE_ADMIN_TOKEN='<long-random-admin-secret>'
supabase functions deploy vxtube-admin --no-verify-jwt
```

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are supplied to Edge Functions
by Supabase. The service role key is used only server-side to read/write the
private tables. Never copy it to the application. `vxtube-control` has gateway
JWT verification disabled because Flutter clients use a publishable key and
have no user login; it validates inputs and performs its own server-side work.
The admin function requires `VXTUBE_ADMIN_TOKEN` and must be called only by an
authorized operator from a trusted environment.

The migration enables RLS and grants no table access to `anon` or
`authenticated`; there are no public table write policies. The app can only
invoke the Edge Function. Configuration and ban administration run through
`vxtube-admin` with the server-held secret.

## Admin function requests

Call `https://igoqkqbkctcubozyaxnx.supabase.co/functions/v1/vxtube-admin` with
`Authorization: Bearer <VXTUBE_ADMIN_TOKEN>` and JSON content type.

Set public app configuration:

```json
{
  "action": "update_config",
  "maintenance_enabled": false,
  "maintenance_message": "VXTUBE is temporarily unavailable. Please try again later.",
  "force_update": false,
  "latest_version": "2.0.0",
  "minimum_version": "2.0.0",
  "download_url": {
    "android": "https://example.org/vxtube.apk",
    "ios": "https://example.org/vxtube.ipa",
    "windows": "https://example.org/vxtube-windows.zip",
    "default": "https://example.org/vxtube"
  },
  "features": {
    "reels": true,
    "search": true,
    "downloads": true,
    "favorites": true
  }
}
```

Ban or unban an installation using its 32-character lowercase hex ID:

```json
{"action":"ban_installation","installation_id":"<installation-id>","internal_reason":"<private operator note>"}
```

```json
{"action":"unban_installation","installation_id":"<installation-id>"}
```

The internal reason is never returned by `vxtube-control`. Keep the admin
bearer token private and rotate it if exposed. Prefer operator tooling with a
secret store; do not paste the secret into shell history if avoidable.

## Client behavior and privacy

- Startup restores the last valid JSON config from local preferences, then
  schedules a bounded seven-second network bootstrap after the first frame.
- Configuration refreshes every 30 minutes and whenever the app resumes.
- Network errors retain cached config and do not delay startup. A confirmed
  restriction remains in force through transient failures until the server
  returns a different status.
- Secure storage holds a random 128-bit installation ID and first local install
  time. The server stores its own first-seen timestamp and updates last-seen;
  the client cannot rewrite the server's first-seen value.
- Registration includes only installation ID, platform and app version. No
  names, emails, phone numbers, passwords, search text or precise location are
  sent to Supabase.
- Existing PostHog code and events are unchanged.

Installation bans are not strong identity enforcement: a determined user can
clear app data, reinstall, or modify the client to use another installation
ID. Stronger enforcement needs authenticated accounts or a server-mediated
resource, neither of which this app currently has. Do not treat the anonymous
installation ID as proof of a person's identity.

## Platform compatibility

`supabase_flutter` 2.15.4 and `url_launcher` support Android, iOS and Windows.
The installation ID uses `flutter_secure_storage` already in the project
(Android Keystore, Apple Keychain and Windows secure storage). Platform
entitlements/signing requirements still apply to release builds. The package
platform list is not proof that each release has been built on this machine;
see the current build report before claiming a platform was verified.

## Manual acceptance checks after deployment

1. Start each platform with no network: cached/default UI appears without a
   startup wait.
2. Open a new install online and confirm `vxtube_installations` receives only
   anonymous ID/platform/version timestamps.
3. Change config through `vxtube-admin`; confirm the app refreshes on launch,
   foreground and the periodic interval.
4. Toggle maintenance; verify the maintenance screen and recovery after it is
   disabled.
5. Increase `latest_version` only; verify a dismissible update notice and URL.
6. Set `force_update` and a higher `minimum_version`; verify the mandatory
   update screen. Confirm invalid/non-HTTPS URLs are not launched.
7. Toggle each feature and verify its entry/action is unavailable, then
   re-enable it and verify existing local data remains intact.
8. Add an installation ID to `banned_installations` through the admin function;
   verify a neutral restricted message, then unban it.
9. Disconnect after a successful config fetch and verify cached behavior.
10. Play a video and confirm existing PostHog events are unaffected in its
    dashboard.

The above remote cases require the migration and both functions to be deployed.
