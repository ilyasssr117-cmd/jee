-- VXTUBE remote control. The app never queries these tables directly.
create table if not exists public.vxtube_app_config (
  config_key text primary key check (config_key = 'production'),
  maintenance_enabled boolean not null default false,
  maintenance_message text not null default 'VXTUBE is temporarily unavailable. Please try again later.',
  force_update boolean not null default false,
  latest_version text not null default '',
  minimum_version text not null default '',
  download_url jsonb not null default '{}'::jsonb,
  features jsonb not null default '{"reels":true,"search":true,"downloads":true,"favorites":true}'::jsonb,
  updated_at timestamptz not null default now(),
  constraint vxtube_config_message_length check (char_length(maintenance_message) <= 500),
  constraint vxtube_config_version_lengths check (
    char_length(latest_version) <= 40 and char_length(minimum_version) <= 40
  ),
  constraint vxtube_config_download_urls_object check (jsonb_typeof(download_url) = 'object'),
  constraint vxtube_config_features_object check (jsonb_typeof(features) = 'object')
);

insert into public.vxtube_app_config (config_key)
values ('production')
on conflict (config_key) do nothing;

create table if not exists public.vxtube_installations (
  installation_id text primary key check (installation_id ~ '^[a-f0-9]{32}$'),
  platform text not null check (platform in ('android','ios','windows','macos','linux','web','fuchsia','unknown')),
  app_version text not null default '0.0.0' check (char_length(app_version) <= 40),
  first_installed_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

create table if not exists public.banned_installations (
  installation_id text primary key check (installation_id ~ '^[a-f0-9]{32}$'),
  banned_at timestamptz not null default now(),
  internal_reason text
);

alter table public.vxtube_app_config enable row level security;
alter table public.vxtube_installations enable row level security;
alter table public.banned_installations enable row level security;

-- No direct client reads or writes, including any public INSERT policy.
revoke all on public.vxtube_app_config from public, anon, authenticated;
revoke all on public.vxtube_installations from public, anon, authenticated;
revoke all on public.banned_installations from public, anon, authenticated;
grant all on public.vxtube_app_config to service_role;
grant all on public.vxtube_installations to service_role;
grant all on public.banned_installations to service_role;

comment on table public.banned_installations is
  'Private admin-managed installation restrictions; never expose internal_reason to clients.';
