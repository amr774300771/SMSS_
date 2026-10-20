alter table if exists cards add column if not exists cost_price integer not null default 0;
alter table if exists users add column if not exists last_login_at timestamptz;

create table if not exists devices (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  device_key text not null,
  name text not null,
  app_version text,
  last_seen_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique (organization_id, device_key)
);
create table if not exists message_deliveries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id),
  sale_id uuid not null references sales(id) on delete cascade,
  channel text not null check (channel in ('sms','whatsapp')),
  status text not null default 'pending' check (status in ('pending','submitted','failed')),
  attempts integer not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists sync_conflicts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id),
  entity text not null,
  entity_id uuid not null,
  local_payload jsonb not null,
  remote_payload jsonb not null,
  status text not null default 'open' check (status in ('open','resolved','ignored')),
  resolved_by uuid references users(id),
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists backup_snapshots (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  created_by uuid not null references users(id),
  storage_key text not null,
  checksum text not null,
  encrypted boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists audit_org_time on audit_logs(organization_id, created_at desc);
create index if not exists messages_sale on message_deliveries(sale_id, status);
create index if not exists conflicts_open on sync_conflicts(organization_id, status);
