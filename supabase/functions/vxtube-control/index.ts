import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

const defaultConfig = {
  maintenance_enabled: false,
  maintenance_message: "VXTUBE is temporarily unavailable. Please try again later.",
  force_update: false,
  latest_version: "",
  minimum_version: "",
  download_url: {},
  features: { reels: true, search: true, downloads: true, favorites: true },
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
  // This is a public-client endpoint. No admin credential is accepted from the
  // client; a publishable API key is required only to reject anonymous noise.
  if (!request.headers.get("apikey")) return json({ error: "Unauthorized" }, 401);

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
  if (body.action !== "bootstrap") return json({ error: "Unknown action" }, 400);

  const installationId = body.installation_id;
  const platform = body.platform;
  const appVersion = body.app_version;
  if (typeof installationId !== "string" || !/^[a-f0-9]{32}$/.test(installationId) ||
      typeof platform !== "string" || platform.length > 16 ||
      typeof appVersion !== "string" || appVersion.length > 40) {
    return json({ error: "Invalid installation metadata" }, 400);
  }

  const url = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceRoleKey) return json({ error: "Service unavailable" }, 503);
  const admin = createClient(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const now = new Date().toISOString();
  const { error: registrationError } = await admin
    .from("vxtube_installations")
    .upsert({
      installation_id: installationId,
      platform,
      app_version: appVersion,
      last_seen_at: now,
    }, { onConflict: "installation_id" });
  if (registrationError) return json({ error: "Service unavailable" }, 503);

  const [{ data: restriction, error: restrictionError }, { data: configRow, error: configError }] =
    await Promise.all([
      admin.from("banned_installations").select("installation_id")
        .eq("installation_id", installationId).maybeSingle(),
      admin.from("vxtube_app_config").select(
        "maintenance_enabled,maintenance_message,force_update,latest_version,minimum_version,download_url,features",
      ).eq("config_key", "production").maybeSingle(),
    ]);
  if (restrictionError || configError) return json({ error: "Service unavailable" }, 503);

  const config = configRow ?? defaultConfig;
  const urls = config.download_url && typeof config.download_url === "object"
    ? config.download_url as Record<string, unknown>
    : {};
  const requestedUrl = urls[platform] ?? urls.default;
  const updateUrl = typeof requestedUrl === "string" &&
      requestedUrl.startsWith("https://") && requestedUrl.length <= 2048
    ? requestedUrl
    : null;
  return json({ config, restricted: restriction !== null, update_url: updateUrl });
});
