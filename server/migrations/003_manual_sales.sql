alter table if exists sales add column if not exists sale_source text not null default 'inventory' check (sale_source in ('inventory','manual'));
alter table if exists sales alter column card_id drop not null;
alter table if exists sales alter column package_id drop not null;
alter table if exists sales add column if not exists quantity integer not null default 1 check (quantity > 0);
alter table if exists sales add column if not exists unit_price integer not null default 0 check (unit_price >= 0);
alter table if exists sales add column if not exists unit_cost integer not null default 0 check (unit_cost >= 0);
alter table if exists sales add column if not exists profit_amount integer not null default 0;
alter table if exists sales add column if not exists description text not null default '';
create index if not exists sales_source_time on sales(organization_id, sale_source, created_at desc);
