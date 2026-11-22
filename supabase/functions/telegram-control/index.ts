import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type Json = Record<string, unknown>;
type Config = {
  maintenance_enabled: boolean;
  maintenance_message: string;
  force_update: boolean;
  latest_version: string;
  minimum_version: string;
  download_url: Record<string, string>;
  features: Record<string, boolean>;
};
type Counts = {
  total: number;
  android: number;
  ios: number;
  windows: number;
  other: number;
};

const CONFIG_KEY = "production";
const FEATURE_KEYS = ["reels", "search", "downloads", "favorites"] as const;
const PLATFORMS = ["android", "ios", "windows"] as const;
const INSTALLATION_PAGE_SIZE = 5;
const VERSION_RE =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;
const isMaintenanceMessage = (value: string) =>
  value.length <= 500 &&
  !/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/.test(value);
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
const html = (value: unknown) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
      })[c]!,
  );
const onOff = (value: boolean) => (value ? "ON" : "OFF");
const bool = (value: unknown, fallback = false) =>
  typeof value === "boolean" ? value : fallback;

function readConfig(row: Json): Config {
  const rawUrls =
    row.download_url &&
    typeof row.download_url === "object" &&
    !Array.isArray(row.download_url)
      ? (row.download_url as Json)
      : {};
  const rawFeatures =
    row.features &&
    typeof row.features === "object" &&
    !Array.isArray(row.features)
      ? (row.features as Json)
      : {};
  const urls: Record<string, string> = {};
  for (const [key, value] of Object.entries(rawUrls))
    if (typeof value === "string") urls[key] = value;
  const features: Record<string, boolean> = {};
  for (const key of FEATURE_KEYS) features[key] = bool(rawFeatures[key], true);
  return {
    maintenance_enabled: bool(row.maintenance_enabled),
    maintenance_message:
      typeof row.maintenance_message === "string"
        ? row.maintenance_message
        : "",
    force_update: bool(row.force_update),
    latest_version:
      typeof row.latest_version === "string" ? row.latest_version : "Unknown",
    minimum_version:
      typeof row.minimum_version === "string" ? row.minimum_version : "Unknown",
    download_url: urls,
    features,
  };
}

function buttons(
  rows: string[][],
): { text: string; callback_data: string }[][] {
  return rows.map((row) =>
    row.map((item) => {
      const [text, callback_data] = item.split("|", 2);
      return { text, callback_data };
    }),
  );
}
const navRows = (back = "nav:dashboard", page = "dashboard") =>
  buttons([["Back|" + back, `Refresh|nav:refresh:${page}`]]);

Deno.serve(async (request) => {
  if (request.method !== "POST")
    return json({ error: "Method not allowed" }, 405);
  const expectedSecret = Deno.env.get("TELEGRAM_WEBHOOK_SECRET");
  if (
    !expectedSecret ||
    request.headers.get("X-Telegram-Bot-Api-Secret-Token") !== expectedSecret
  ) {
    return json({ error: "Unauthorized" }, 401);
  }
  const botToken = Deno.env.get("TELEGRAM_BOT_TOKEN");
  const adminId = Deno.env.get("TELEGRAM_ADMIN_ID");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const adminToken = Deno.env.get("VXTUBE_ADMIN_TOKEN");
  if (!botToken || !adminId || !supabaseUrl || !serviceKey || !adminToken) {
    console.error("telegram-control configuration unavailable");
    return json({ error: "Service unavailable" }, 503);
  }
  let update: Json;
  try {
    const value: unknown = await request.json();
    if (!value || typeof value !== "object" || Array.isArray(value))
      return json({ error: "Invalid update" }, 400);
    update = value as Json;
  } catch {
    return json({ error: "Invalid update" }, 400);
  }

  const tg = async (method: string, payload: Json): Promise<Json> => {
    try {
      const response = await fetch(
        `https://api.telegram.org/bot${botToken}/${method}`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload),
        },
      );
      const result: unknown = await response.json();
      if (
        !response.ok ||
        !result ||
        typeof result !== "object" ||
        !(result as Json).ok
      ) {
        const telegramError =
          result &&
          typeof result === "object" &&
          typeof (result as Json).error_code === "number"
            ? ((result as Json).error_code as number)
            : undefined;
        const description =
          result &&
          typeof result === "object" &&
          typeof (result as Json).description === "string"
            ? ((result as Json).description as string)
            : "";
        if (
          method === "editMessageText" &&
          description.toLowerCase().includes("message is not modified")
        ) {
          return { ok: true };
        }
        console.error(
          `Telegram ${method} request failed (HTTP ${response.status}${telegramError ? `, API ${telegramError}` : ""})`,
        );
        return { ok: false };
      }
      return result as Json;
    } catch {
      console.error(`Telegram ${method} request failed`);
      return { ok: false };
    }
  };
  const supabase = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const getState = async (): Promise<{ config: Config; counts: Counts }> => {
    const [configResult, totalResult, ...platformResults] = await Promise.all([
      supabase
        .from("vxtube_app_config")
        .select(
          "maintenance_enabled,maintenance_message,force_update,latest_version,minimum_version,download_url,features",
        )
        .eq("config_key", CONFIG_KEY)
        .maybeSingle(),
      supabase
        .from("vxtube_installations")
        .select("installation_id", { count: "exact", head: true }),
      ...PLATFORMS.map((platform) =>
        supabase
          .from("vxtube_installations")
          .select("installation_id", { count: "exact", head: true })
          .eq("platform", platform),
      ),
    ]);
    if (
      configResult.error ||
      !configResult.data ||
      totalResult.error ||
      platformResults.some((r) => r.error)
    ) {
      console.error("Supabase dashboard read failed");
      throw new Error("backend_read_failed");
    }
    const counts: Counts = {
      total: totalResult.count ?? 0,
      android: platformResults[0].count ?? 0,
      ios: platformResults[1].count ?? 0,
      windows: platformResults[2].count ?? 0,
      other: Math.max(
        0,
        (totalResult.count ?? 0) -
          platformResults.reduce((sum, r) => sum + (r.count ?? 0), 0),
      ),
    };
    return { config: readConfig(configResult.data as Json), counts };
  };
  const getInstallationPage = async (page: number) => {
    const safePage = Math.max(0, Math.min(9999, Math.floor(page)));
    const from = safePage * INSTALLATION_PAGE_SIZE;
    const { data, count, error } = await supabase
      .from("vxtube_installations")
      .select("installation_id,platform,app_version,first_installed_at,last_seen_at", { count: "exact" })
      .order("last_seen_at", { ascending: false })
      .range(from, from + INSTALLATION_PAGE_SIZE - 1);
    if (error) {
      console.error("Installation list read failed");
      throw new Error("installation_list_failed");
    }
    return { items: (data ?? []) as Json[], total: count ?? 0, page: safePage };
  };
  let lastMutationError = "";
  const mutate = async (payload: Json): Promise<boolean> => {
    try {
      const response = await fetch(
        `${supabaseUrl.replace(/\/$/, "")}/functions/v1/vxtube-admin`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${adminToken}`,
          },
          body: JSON.stringify(payload),
        },
      );
      const raw = await response.text();
      let result: Json = {};
      try {
        const parsed: unknown = JSON.parse(raw);
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
          result = parsed as Json;
        }
      } catch {
        // Keep the diagnostic limited to HTTP status when the gateway returns non-JSON.
      }
      if (!response.ok || result.ok !== true) {
        const reason = typeof result.error === "string" ? result.error : "Admin API rejected the request";
        const code = typeof result.code === "string" ? ` [${result.code}]` : "";
        const detail = typeof result.detail === "string" ? `: ${result.detail}` : "";
        lastMutationError = `HTTP ${response.status}: ${reason}${code}${detail}`.slice(0, 350);
        console.error(`vxtube-admin ${String(payload.action)} failed: ${lastMutationError}`);
        return false;
      }
      lastMutationError = "";
      return true;
    } catch {
      lastMutationError = "Network error calling vxtube-admin";
      console.error(`vxtube-admin ${String(payload.action)} request failed`);
      return false;
    }
  };
  const menuKeyboard = buttons([
    ["Dashboard|nav:dashboard", "Maintenance|nav:maintenance"],
    ["Features|nav:features", "App Updates|nav:updates"],
    ["Installations|nav:installations", "Ban / Unban|nav:banmenu"],
    ["Refresh|nav:refresh:dashboard"],
  ]);
  const render = async (
    page: string,
  ): Promise<{
    text: string;
    keyboard: { text: string; callback_data: string }[][];
  }> => {
    const { config: c, counts } = await getState();
    if (page === "dashboard" || page === "refresh")
      return {
        text: `<b>VXTUBE Admin Dashboard</b>\n\nMaintenance: ${onOff(c.maintenance_enabled)}\nLatest version: <code>${html(c.latest_version)}</code>\nMinimum version: <code>${html(c.minimum_version)}</code>\nForce update: ${onOff(c.force_update)}\n\nFeatures: Reels ${onOff(c.features.reels)}, Search ${onOff(c.features.search)}, Downloads ${onOff(c.features.downloads)}, Favorites ${onOff(c.features.favorites)}\n\nInstallations: <b>${counts.total}</b>\nAndroid: ${counts.android} | iOS: ${counts.ios} | Windows: ${counts.windows} | Other: ${counts.other}`,
        keyboard: menuKeyboard,
      };
    if (page === "maintenance")
      return {
        text: `<b>Maintenance</b>\nStatus: ${onOff(c.maintenance_enabled)}\nMessage: ${html(c.maintenance_message || "(empty)")}`,
        keyboard: [
          ...buttons([
            [
              `${c.maintenance_enabled ? "Disable" : "Enable"} maintenance|maint:toggle`,
              "Change message|maint:message",
            ],
          ]),
          ...navRows("nav:dashboard", "maintenance"),
        ],
      };
    if (page === "features")
      return {
        text: `<b>Feature flags</b>\nChoose a feature to toggle. Other flags are preserved.`,
        keyboard: [
          ...buttons(
            FEATURE_KEYS.map((key) => [
              `${key[0].toUpperCase()}${key.slice(1)}: ${onOff(c.features[key])}|feature:${key}`,
            ]),
          ),
          ...navRows("nav:dashboard", "features"),
        ],
      };
    if (page === "updates")
      return {
        text: `<b>App Updates</b>\nLatest: <code>${html(c.latest_version)}</code>\nMinimum: <code>${html(c.minimum_version)}</code>\nForce update: ${onOff(c.force_update)}\n${PLATFORMS.map((p) => `${p}: ${html(c.download_url[p] || "not set")}`).join("\n")}\n\nCommands: <code>/setlatest 2.1.0</code>, <code>/setminimum 2.0.0</code>, <code>/seturl android https://example.com/file</code>`,
        keyboard: [
          ...buttons([[`Force update: ${onOff(c.force_update)}|update:force`]]),
          ...navRows("nav:dashboard", "updates"),
        ],
      };
    if (page === "installations")
      return {
        text: `<b>Installations</b>\nTotal: ${counts.total}\nAndroid: ${counts.android}\niOS: ${counts.ios}\nWindows: ${counts.windows}\nOther: ${counts.other}\n\nOpen the device list to view each Installation ID, version and last seen time.`,
        keyboard: [
          ...buttons([["View installation IDs|instlist:0"]]),
          ...navRows("nav:dashboard", "installations"),
        ],
      };
    const listMatch = page.match(/^instlist:(\d{1,4})$/);
    if (listMatch) {
      const pageIndex = Number(listMatch[1]);
      const result = await getInstallationPage(pageIndex);
      const keyboardRows = result.items.flatMap((item) => {
        const id = typeof item.installation_id === "string" ? item.installation_id : "";
        if (!/^[a-f0-9]{32}$/.test(id)) return [];
        const platform = typeof item.platform === "string" ? item.platform.toUpperCase() : "UNKNOWN";
        const version = typeof item.app_version === "string" ? item.app_version : "unknown";
        return [[`${platform} — ${version}|instview:${id}:${pageIndex}`]];
      });
      const keyboard = buttons(keyboardRows);
      if (pageIndex > 0 || (pageIndex + 1) * INSTALLATION_PAGE_SIZE < result.total) {
        const pager: string[] = [];
        if (pageIndex > 0) pager.push(`Previous|instlist:${pageIndex - 1}`);
        if ((pageIndex + 1) * INSTALLATION_PAGE_SIZE < result.total) pager.push(`Next|instlist:${pageIndex + 1}`);
        keyboard.push(buttons([pager])[0]);
      }
      keyboard.push(...buttons([["Back|nav:installations", `Refresh|instlist:${pageIndex}`]]));
      const first = result.total === 0 ? 0 : pageIndex * INSTALLATION_PAGE_SIZE + 1;
      const last = Math.min((pageIndex + 1) * INSTALLATION_PAGE_SIZE, result.total);
      return {
        text: `<b>Installation List</b>\nShowing ${first}-${last} of ${result.total}\nTap a device to view its full Installation ID and controls.`,
        keyboard,
      };
    }
    const detailMatch = page.match(/^instview:([a-f0-9]{32}):(\d{1,4})$/);
    if (detailMatch) {
      const id = detailMatch[1];
      const backPage = Math.min(9999, Number(detailMatch[2]));
      const { data, error } = await supabase
        .from("vxtube_installations")
        .select("installation_id,platform,app_version,first_installed_at,last_seen_at")
        .eq("installation_id", id)
        .maybeSingle();
      if (error) throw new Error("installation_detail_failed");
      if (!data) return {
        text: "<b>Installation not found</b>\nIt may have been removed from the registry.",
        keyboard: buttons([[ "Back|instlist:" + backPage, "Refresh|instview:" + id + ":" + backPage ]]),
      };
      const device = data as Json;
      const platform = typeof device.platform === "string" ? device.platform : "unknown";
      const version = typeof device.app_version === "string" ? device.app_version : "unknown";
      const installed = typeof device.first_installed_at === "string" ? device.first_installed_at : "unknown";
      const seen = typeof device.last_seen_at === "string" ? device.last_seen_at : "unknown";
      return {
        text: `<b>Installation Details</b>\nPlatform: <b>${html(platform)}</b>\nApp version: <code>${html(version)}</code>\nInstallation ID:\n<code>${html(id)}</code>\nFirst installed: <code>${html(installed)}</code>\nLast seen: <code>${html(seen)}</code>`,
        keyboard: [
          ...buttons([[ "Ban this device|confirm:ban:" + id, "Unban device|confirm:unban:" + id ]]),
          ...buttons([[ "Back to list|instlist:" + backPage, "Refresh|instview:" + id + ":" + backPage ]]),
        ],
      };
    }
    if (page === "banmenu")
      return {
        text: `<b>Ban / Unban</b>\nUse <code>/ban INSTALLATION_ID</code> or <code>/unban INSTALLATION_ID</code>. You will be asked to confirm.`,
        keyboard: navRows("nav:installations", "banmenu"),
      };
    return {
      text: `<b>VXTUBE Admin</b>\nUse /menu to open the dashboard.`,
      keyboard: menuKeyboard,
    };
  };
  const show = async (
    chatId: number | string,
    page: string,
    messageId?: number,
  ) => {
    try {
      const view = await render(page);
      const payload: Json = {
        chat_id: chatId,
        text: view.text,
        parse_mode: "HTML",
        reply_markup: { inline_keyboard: view.keyboard },
      };
      if (messageId) {
        const edited = await tg("editMessageText", {
          ...payload,
          message_id: messageId,
        });
        if (edited.ok) return;
      }
      await tg("sendMessage", payload);
    } catch {
      await tg("sendMessage", {
        chat_id: chatId,
        text: "Could not load the dashboard. Please try again.",
        reply_markup: { inline_keyboard: menuKeyboard },
      });
    }
  };
  const ask = async (chatId: number | string, text: string) => {
    await tg("sendMessage", {
      chat_id: chatId,
      text,
      reply_markup: {
        force_reply: true,
        selective: true,
        input_field_placeholder: "Enter message",
      },
    });
  };

  try {
    const callback =
      update.callback_query && typeof update.callback_query === "object"
        ? (update.callback_query as Json)
        : null;
    const message =
      update.message && typeof update.message === "object"
        ? (update.message as Json)
        : null;
    const actor = (callback?.from ?? message?.from) as Json | undefined;
    if (!actor || String(actor.id) !== adminId) {
      if (callback && typeof callback.id === "string")
        await tg("answerCallbackQuery", {
          callback_query_id: callback.id,
          text: "Unauthorized",
        });
      return json({ ok: true });
    }
    const msg =
      callback?.message && typeof callback.message === "object"
        ? (callback.message as Json)
        : message;
    const chat =
      msg?.chat && typeof msg.chat === "object" ? (msg.chat as Json) : null;
    if (!chat || String(chat.id) !== adminId || chat.type !== "private") {
      if (callback && typeof callback.id === "string")
        await tg("answerCallbackQuery", {
          callback_query_id: callback.id,
          text: "Use the bot in a private chat.",
        });
      return json({ ok: true });
    }
    const chatId = chat.id as number | string;
    if (callback) {
      if (typeof callback.id === "string")
        await tg("answerCallbackQuery", { callback_query_id: callback.id });
      const data = typeof callback.data === "string" ? callback.data : "";
      const messageId =
        typeof msg?.message_id === "number" ? msg.message_id : undefined;
      const confirm = data.match(/^confirm:(maint|force|ban|unban):(.+)$/);
      if (confirm) {
        const isValidConfirmation =
          confirm[1] === "maint" || confirm[1] === "force"
            ? confirm[2] === "yes"
            : /^[a-f0-9]{32}$/.test(confirm[2]);
        if (!isValidConfirmation) {
          await tg("editMessageText", {
            chat_id: chatId,
            message_id: messageId,
            text: "This confirmation is invalid or expired. Refresh the dashboard and try again.",
            reply_markup: { inline_keyboard: navRows() },
          });
          return json({ ok: true });
        }
        let action: Json | null = null;
        if (confirm[1] === "maint") {
          const { config } = await getState();
          action = {
            action: "update_config",
            maintenance_enabled: true,
            maintenance_message: config.maintenance_message,
          };
        } else if (confirm[1] === "force") {
          const { config } = await getState();
          const missingUrls = PLATFORMS.filter((platform) =>
            !config.download_url[platform] || !config.download_url[platform].startsWith("https://")
          );
          if (!config.latest_version || !config.minimum_version || missingUrls.length > 0) {
            await tg("editMessageText", {
              chat_id: chatId,
              message_id: messageId,
              text: "Force update was not enabled. First set Latest version, Minimum version, and an HTTPS website URL for Android, iOS and Windows in App Updates.",
              reply_markup: { inline_keyboard: navRows("nav:updates", "updates") },
            });
            return json({ ok: true });
          }
          action = { action: "update_config", force_update: true };
        } else
          action = {
            action:
              confirm[1] === "ban" ? "ban_installation" : "unban_installation",
            installation_id: confirm[2],
          };
        const ok = action ? await mutate(action) : false;
        const edit = await tg("editMessageText", {
          chat_id: chatId,
          message_id: messageId,
          text: ok
            ? "Change applied."
            : `Could not apply the change. ${html(lastMutationError || "No diagnostic returned; refresh and retry.")}`,
          reply_markup: { inline_keyboard: navRows() },
        });
        if (!edit.ok)
          await tg("sendMessage", {
            chat_id: chatId,
            text: ok
              ? "Change applied."
              : "Could not apply the change. Please refresh and try again.",
            reply_markup: { inline_keyboard: navRows() },
          });
        return json({ ok: true });
      }
      if (data.startsWith("nav:refresh:")) {
        const page = data.slice("nav:refresh:".length);
        await show(
          chatId,
          [
            "dashboard",
            "maintenance",
            "features",
            "updates",
            "installations",
            "banmenu",
          ].includes(page)
            ? page
            : "dashboard",
          messageId,
        );
      } else if (data.startsWith("nav:")) {
        const page = data.slice(4);
        await show(
          chatId,
          [
            "dashboard",
            "maintenance",
            "features",
            "updates",
            "installations",
            "banmenu",
          ].includes(page)
            ? page
            : "dashboard",
          messageId,
        );
      } else if (data === "maint:toggle") {
        const { config } = await getState();
        if (!config.maintenance_enabled)
          await tg("sendMessage", {
            chat_id: chatId,
            text: "Enable maintenance for all users? Confirm to continue.",
            reply_markup: {
              inline_keyboard: buttons([
                ["Confirm|confirm:maint:yes", "Cancel|nav:maintenance"],
              ]),
            },
          });
        else {
          const ok = await mutate({
            action: "update_config",
            maintenance_enabled: false,
            maintenance_message: config.maintenance_message,
          });
          await show(chatId, "maintenance", messageId);
          if (!ok)
            await tg("sendMessage", {
              chat_id: chatId,
              text: "Could not update maintenance. Please refresh and try again.",
            });
        }
      } else if (data === "maint:message")
        await ask(
          chatId,
          "Send the new maintenance message (up to 500 characters).",
        );
      else if (data.startsWith("feature:")) {
        const key = data.slice(8);
        if ((FEATURE_KEYS as readonly string[]).includes(key)) {
          const { config } = await getState();
          const features = { ...config.features, [key]: !config.features[key] };
          const ok = await mutate({ action: "update_config", features });
          if (!ok)
            await tg("sendMessage", {
              chat_id: chatId,
              text: "Could not update feature. Please refresh and try again.",
            });
          await show(chatId, "features", messageId);
        }
      } else if (data === "update:force") {
        const { config } = await getState();
        if (!config.force_update) {
          const missingUrls = PLATFORMS.filter((platform) =>
            !config.download_url[platform] || !config.download_url[platform].startsWith("https://")
          );
          if (!config.latest_version || !config.minimum_version || missingUrls.length > 0) {
            await tg("sendMessage", {
              chat_id: chatId,
              text: "Before enabling Force update, set Latest version, Minimum version, and an HTTPS website URL for Android, iOS and Windows. You can use /seturl all https://vxtube.vercel.app/.",
              reply_markup: { inline_keyboard: navRows("nav:updates", "updates") },
            });
          } else {
            await tg("sendMessage", {
              chat_id: chatId,
              text: "Force update will block every app version below the Minimum version. The new version and newer versions will remain available. Confirm only after you have built and tested the new release.",
              reply_markup: {
                inline_keyboard: buttons([
                  ["Confirm|confirm:force:yes", "Cancel|nav:updates"],
                ]),
              },
            });
          }
        }
        else {
          const ok = await mutate({
            action: "update_config",
            force_update: false,
          });
          await show(chatId, "updates", messageId);
          if (!ok)
            await tg("sendMessage", {
              chat_id: chatId,
              text: "Could not update force update. Please refresh and try again.",
            });
        }
      } else if (/^instlist:\d{1,4}$/.test(data) || /^instview:[a-f0-9]{32}:\d{1,4}$/.test(data)) {
        await show(chatId, data, messageId);
      } else {
        await tg("sendMessage", {
          chat_id: chatId,
          text: "Unknown action. Open /menu to continue.",
          reply_markup: { inline_keyboard: menuKeyboard },
        });
      }
      return json({ ok: true });
    }

    const text = typeof message?.text === "string" ? message.text : "";
    const command = text.trim().split(/\s+/, 1)[0].toLowerCase().split("@")[0];
    const reply =
      message?.reply_to_message && typeof message.reply_to_message === "object"
        ? (message.reply_to_message as Json)
        : null;
    const replyPrompt = typeof reply?.text === "string" ? reply.text : "";
    if (replyPrompt.includes("new maintenance message")) {
      if (!isMaintenanceMessage(text)) {
        await tg("sendMessage", {
          chat_id: chatId,
          text: "Maintenance message must be 500 characters or fewer and contain no control characters.",
        });
      } else {
        const { config } = await getState();
        const ok = await mutate({
          action: "update_config",
          maintenance_message: text,
          maintenance_enabled: config.maintenance_enabled,
        });
        await tg("sendMessage", {
          chat_id: chatId,
          text: ok
            ? "Maintenance message updated."
            : "Could not update the maintenance message.",
        });
      }
      return json({ ok: true });
    }
    if (command === "/start" || command === "/menu")
      await show(chatId, "dashboard");
    else if (command === "/installations" || command === "/devices")
      await show(chatId, "installations");
    else if (command === "/status") {
      try {
        const { config, counts } = await getState();
        await tg("sendMessage", {
          chat_id: chatId,
          text: `Backend: reachable\nConfiguration: loaded\nMaintenance: ${onOff(config.maintenance_enabled)}\nLatest: <code>${html(config.latest_version)}</code> | Minimum: <code>${html(config.minimum_version)}</code>\nInstallations: ${counts.total}`,
          parse_mode: "HTML",
          reply_markup: { inline_keyboard: navRows() },
        });
      } catch {
        await tg("sendMessage", {
          chat_id: chatId,
          text: "Backend/configuration unavailable. Please try again later.",
        });
      }
    } else if (command === "/help")
      await tg("sendMessage", {
        chat_id: chatId,
        text: "Commands:\n/menu | /status | /installations\n/setlatest X.Y.Z\n/setminimum X.Y.Z\n/seturl all|android|ios|windows HTTPS_URL\n/ban INSTALLATION_ID\n/unban INSTALLATION_ID",
        reply_markup: { inline_keyboard: menuKeyboard },
      });
    else if (command === "/setlatest" || command === "/setminimum") {
      const version = text.trim().split(/\s+/)[1] ?? "";
      if (!VERSION_RE.test(version))
        await tg("sendMessage", {
          chat_id: chatId,
          text: "Use a semantic version such as 2.1.0.",
        });
      else {
        const field =
          command === "/setlatest" ? "latest_version" : "minimum_version";
        const ok = await mutate({ action: "update_config", [field]: version });
        await tg("sendMessage", {
          chat_id: chatId,
          text: ok
            ? `${field} set to ${html(version)}.`
            : "Update failed. Check the current configuration and try again.",
          parse_mode: "HTML",
          reply_markup: { inline_keyboard: navRows("nav:updates", "updates") },
        });
      }
    } else if (command === "/seturl") {
      const [, platform, url, ...extra] = text.trim().split(/\s+/);
      const safePlatform = platform ?? "";
      const safeUrl = url ?? "";
      let parsed: URL | null = null;
      try {
        if (safeUrl) parsed = new URL(safeUrl);
      } catch {
        parsed = null;
      }
      if (
        (!(PLATFORMS as readonly string[]).includes(safePlatform) && safePlatform !== "all") ||
        extra.length ||
        !parsed ||
        parsed.protocol !== "https:" ||
        !parsed.hostname ||
        parsed.username ||
        parsed.password ||
        safeUrl.length > 2048
      ) {
        await tg("sendMessage", {
          chat_id: chatId,
          text: "Use /seturl all|android|ios|windows https://example.com/file",
        });
      } else {
        const { config } = await getState();
        const download_url = safePlatform === "all"
          ? { ...config.download_url, ...Object.fromEntries(PLATFORMS.map((platform) => [platform, safeUrl])) }
          : { ...config.download_url, [safePlatform]: safeUrl };
        const ok = await mutate({ action: "update_config", download_url });
        await tg("sendMessage", {
          chat_id: chatId,
          text: ok
            ? `${html(safePlatform)} download URL updated.`
            : "URL update failed. Please try again.",
          parse_mode: "HTML",
          reply_markup: { inline_keyboard: navRows("nav:updates", "updates") },
        });
      }
    } else if (command === "/ban" || command === "/unban") {
      const id = text.trim().split(/\s+/)[1] ?? "";
      if (!/^[a-f0-9]{32}$/.test(id))
        await tg("sendMessage", {
          chat_id: chatId,
          text: `Use /${command.slice(1)} followed by a 32-character installation ID.`,
        });
      else
        await tg("sendMessage", {
          chat_id: chatId,
          text: `Confirm ${command === "/ban" ? "ban" : "unban"} for installation <code>${html(id)}</code>?`,
          parse_mode: "HTML",
          reply_markup: {
            inline_keyboard: buttons([
              [
                `Confirm|confirm:${command === "/ban" ? "ban" : "unban"}:${id}`,
                "Cancel|nav:installations",
              ],
            ]),
          },
        });
    } else if (text.startsWith("/"))
      await tg("sendMessage", {
        chat_id: chatId,
        text: "Unknown command. Use /menu or /help.",
        reply_markup: { inline_keyboard: menuKeyboard },
      });
    return json({ ok: true });
  } catch {
    console.error("telegram-control update processing failed");
    return json({ ok: true });
  }
});