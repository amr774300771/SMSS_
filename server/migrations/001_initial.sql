create extension if not exists pgcrypto;

create table if not exists organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);
create table if not exists branches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  unique (organization_id, name)
);
create table if not exists users (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  email text not null unique,
  password_hash text not null,
  display_name text not null,
  role text not null check (role in ('owner','manager','supervisor','seller','collector','viewer','support')),
  disabled_at timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists memberships (
  user_id uuid not null references users(id) on delete cascade,
  branch_id uuid not null references branches(id) on delete cascade,
  primary key (user_id, branch_id)
);
create table if not exists clients (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id),
  name text not null,
  phone text not null,
  opening_balance integer not null default 0,
  version bigint not null default 1,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (organization_id, branch_id, phone)
);
create table if not exists packages (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id),
  code text not null,
  name text not null,
  price integer not null check (price >= 0),
  keywords jsonb not null default '[]',
  version bigint not null default 1,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), deleted_at timestamptz,
  unique (branch_id, code)
);
create table if not exists cards (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id),
  package_id uuid not null references packages(id),
  card_number text not null,
  status text not null default 'available' check (status in ('available','reserved','sold','returned','deleted')),
  version bigint not null default 1,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (branch_id, card_number)
);
create table if not exists sales (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id),
  client_id uuid references clients(id),
  card_id uuid not null unique references cards(id),
  package_id uuid not null references packages(id),
  amount integer not null check (amount >= 0),
  payment_method text not null check (payment_method in ('cash','credit')),
  created_by uuid not null references users(id),
  created_at timestamptz not null default now()
);
create table if not exists ledger_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id),
  client_id uuid not null references clients(id),
  kind text not null check (kind in ('sale','payment','adjustment','reversal','opening')),
  amount integer not null,
  source_id uuid,
  reason text,
  created_by uuid not null references users(id),
  created_at timestamptz not null default now()
);
create table if not exists sync_changes (
  id uuid primary key,
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id),
  entity text not null,
  entity_id uuid not null,
  operation text not null check (operation in ('create','update','delete')),
  payload jsonb not null,
  device_id text not null,
  user_id uuid not null references users(id),
  created_at timestamptz not null default now()
);
create index if not exists sync_changes_cursor on sync_changes(organization_id, created_at, id);
create table if not exists audit_logs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  branch_id uuid not null references branches(id),
  user_id uuid not null references users(id),
  action text not null,
  entity text not null,
  entity_id uuid,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now()
);
