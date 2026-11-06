import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
  const expected = Deno.env.get("VXTUBE_ADMIN_TOKEN");
  const supplied = request.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
  // This long random bearer secret exists only in Supabase Edge secrets and
  // must never be shipped in the Flutter application.
  if (!expected || !supplied || supplied !== expected) {
    return json({ error: "Unauthorized" }, 401);
  }

  let body: Record<string, unknown>;
  try {
    const value: unknown = await request.json();
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return json({ error: "Invalid request" }, 400);
    }
    body = value as Record<string, unknown>;
  } catch {
    return json({ error: "Invalid request" }, 400);
  }
  const url = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceRoleKey) return json({ error: "Service unavailable" }, 503);
  const admin = createClient(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  if (body.action === "update_config") {
    const allowed = [
      "maintenance_enabled", "maintenance_message", "force_update",
      "latest_version", "minimum_version", "download_url", "features",
    ];
    const patch: Record<string, unknown> = {};
    for (const key of allowed) if (key in body) patch[key] = body[key];
    if (Object.keys(patch).length === 0) return json({ error: "No config fields" }, 400);
    for (const key of ["maintenance_enabled", "force_update"] as const) {
      if (key in patch && typeof patch[key] !== "boolean") {
        return json({ error: `Invalid ${key}` }, 400);
      }
    }
    if ("maintenance_message" in patch &&
        (typeof patch.maintenance_message !== "string" ||
          patch.maintenance_message.length > 500)) {
      return json({ error: "Invalid maintenance_message" }, 400);
    }
    const versionPattern = /^\d+(\.\d+){0,3}([+-][0-9A-Za-z.-]+)?$/;
    for (const key of ["latest_version", "minimum_version"] as const) {
      if (key in patch && (typeof patch[key] !== "string" ||
          (patch[key] !== "" && !versionPattern.test(patch[key] as string)))) {
        return json({ error: `Invalid ${key}` }, 400);
      }
    }
    if ("download_url" in patch) {
      const urls = patch.download_url;
      if (!urls || typeof urls !== "object" || Array.isArray(urls)) {
        return json({ error: "Invalid download_url" }, 400);
      }
      for (const value of Object.values(urls as Record<string, unknown>)) {
        let parsed: URL | null = null;
        try {
          if (typeof value === "string") parsed = new URL(value);
        } catch {
          parsed = null;
        }
        if (!parsed || parsed.protocol !== "https:" || !parsed.hostname ||
            parsed.username || parsed.password || (value as string).length > 2048) {
          return json({ error: "Download URLs must use HTTPS" }, 400);
        }
      }
    }
    if ("features" in patch) {
      const features = patch.features;
      if (!features || typeof features !== "object" || Array.isArray(features)) {
        return json({ error: "Invalid features" }, 400);
      }
      const allowedFeatures = ["reels", "search", "downloads", "favorites"];
      for (const [key, value] of Object.entries(features as Record<string, unknown>)) {
        if (!allowedFeatures.includes(key) || typeof value !== "boolean") {
          return json({ error: "Invalid feature flag" }, 400);
        }
      }
    }
    patch.updated_at = new Date().toISOString();
    const { error } = await admin.from("vxtube_app_config")
      .update(patch).eq("config_key", "production");
    if (error) return json({ error: "Config update failed" }, 400);
    return json({ ok: true });
  }

  const id = body.installation_id;
  if (typeof id !== "string" || !/^[a-f0-9]{32}$/.test(id)) {
    return json({ error: "Invalid installation ID" }, 400);
  }
  if (body.action === "ban_installation") {
    const reason = typeof body.internal_reason === "string"
      ? body.internal_reason.slice(0, 500)
      : null;
    const { error } = await admin.from("banned_installations").upsert({
      installation_id: id,
      internal_reason: reason,
      banned_at: new Date().toISOString(),
    });
    if (error) return json({ error: "Ban operation failed" }, 400);
    return json({ ok: true });
  }
  if (body.action === "unban_installation") {
    const { error } = await admin.from("banned_installations")
      .delete().eq("installation_id", id);
    if (error) return json({ error: "Unban operation failed" }, 400);
    return json({ ok: true });
  }
  return json({ error: "Unknown action" }, 400);
});
