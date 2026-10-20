import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import pg from 'pg';
import { randomUUID } from 'node:crypto';

const { Pool } = pg;
const pool = new Pool({ connectionString: process.env.DATABASE_URL });
const app = express();
app.use(cors({ origin: process.env.CORS_ORIGIN || '*' }));
app.use(express.json({ limit: '2mb' }));

const jwtSecret = process.env.JWT_SECRET || 'development-only-change-me';
const roles = new Set(['owner', 'manager', 'supervisor', 'seller', 'collector', 'viewer', 'support']);
const permissions = {
  owner: ['*'], manager: ['read', 'sell', 'inventory', 'clients', 'payments', 'reports', 'users'],
  supervisor: ['read', 'sell', 'inventory', 'clients', 'payments', 'reports'],
  seller: ['read', 'sell', 'clients'], collector: ['read', 'clients', 'payments'],
  viewer: ['read', 'reports'], support: ['read', 'clients'],
};
const can = (user, permission) => permissions[user.role]?.includes('*') || permissions[user.role]?.includes(permission);

function sign(user) {
  return jwt.sign({ sub: user.id, org: user.organization_id, role: user.role }, jwtSecret, { expiresIn: '12h' });
}
async function auth(req, res, next) {
  try {
    const token = req.headers.authorization?.replace(/^Bearer\s+/i, '');
    if (!token) return res.status(401).json({ error: 'AUTH_REQUIRED' });
    const claims = jwt.verify(token, jwtSecret);
    const result = await pool.query('select id, organization_id, role, display_name from users where id=$1 and disabled_at is null', [claims.sub]);
    if (!result.rowCount) return res.status(401).json({ error: 'USER_DISABLED' });
    req.user = result.rows[0]; next();
  } catch { res.status(401).json({ error: 'INVALID_TOKEN' }); }
}
function requirePermission(permission) { return (req, res, next) => can(req.user, permission) ? next() : res.status(403).json({ error: 'FORBIDDEN', permission }); }
async function requireBranch(req, res, next) {
  const branchId = req.body.branchId || req.query.branchId;
  if (!branchId) return res.status(400).json({ error: 'BRANCH_REQUIRED' });
  const result = await pool.query('select 1 from memberships m join branches b on b.id=m.branch_id where m.user_id=$1 and m.branch_id=$2 and b.organization_id=$3', [req.user.id, branchId, req.user.organization_id]);
  if (!result.rowCount && req.user.role !== 'owner') return res.status(403).json({ error: 'BRANCH_FORBIDDEN' });
  req.branchId = branchId; next();
}

app.get('/health', (_req, res) => res.json({ ok: true, service: 'qaidi-sync-api' }));
app.post('/v1/auth/register', async (req, res) => {
  const { organizationName, branchName = 'الفرع الرئيسي', email, password, displayName = 'المالك' } = req.body;
  if (!organizationName || !email || !password || password.length < 8) return res.status(400).json({ error: 'INVALID_REGISTRATION' });
  const client = await pool.connect();
  try {
    await client.query('begin');
    const org = (await client.query('insert into organizations(name) values($1) returning id', [organizationName])).rows[0];
    const branch = (await client.query('insert into branches(organization_id,name) values($1,$2) returning id', [org.id, branchName])).rows[0];
    const user = (await client.query('insert into users(organization_id,email,password_hash,display_name,role) values($1,$2,$3,$4,$5) returning id,organization_id,role,display_name', [org.id, email.toLowerCase(), await bcrypt.hash(password, 12), displayName, 'owner'])).rows[0];
    await client.query('insert into memberships(user_id,branch_id) values($1,$2)', [user.id, branch.id]);
    await client.query('commit');
    res.status(201).json({ token: sign(user), user, branch });
  } catch (e) { await client.query('rollback'); res.status(409).json({ error: 'REGISTRATION_FAILED', detail: e.code === '23505' ? 'EMAIL_EXISTS' : undefined }); } finally { client.release(); }
});
app.post('/v1/auth/login', async (req, res) => {
  const userResult = await pool.query('select id,organization_id,role,display_name,password_hash from users where email=$1 and disabled_at is null', [String(req.body.email || '').toLowerCase()]);
  const user = userResult.rows[0];
  if (!user || !(await bcrypt.compare(req.body.password || '', user.password_hash))) return res.status(401).json({ error: 'INVALID_CREDENTIALS' });
  delete user.password_hash; res.json({ token: sign(user), user });
});
app.get('/v1/me', auth, async (req, res) => res.json({ user: req.user, permissions: permissions[req.user.role] || [], branches: (await pool.query('select b.* from branches b join memberships m on m.branch_id=b.id where m.user_id=$1', [req.user.id])).rows }));
app.get('/v1/users', auth, requirePermission('users'), async (req, res) => {
  const users = await pool.query('select id,email,display_name,role,disabled_at,created_at from users where organization_id=$1 order by created_at', [req.user.organization_id]);
  res.json({ users: users.rows });
});
app.post('/v1/users', auth, requirePermission('users'), async (req, res) => {
  const { email, password, displayName, role = 'seller', branchId } = req.body;
  if (!email || !password || password.length < 8 || !displayName || !roles.has(role) || !branchId) return res.status(400).json({ error: 'INVALID_USER' });
  const membership = await pool.query('select 1 from branches where id=$1 and organization_id=$2', [branchId, req.user.organization_id]);
  if (!membership.rowCount) return res.status(400).json({ error: 'INVALID_BRANCH' });
  try {
    const user = (await pool.query('insert into users(organization_id,email,password_hash,display_name,role) values($1,$2,$3,$4,$5) returning id,email,display_name,role,created_at', [req.user.organization_id, email.toLowerCase(), await bcrypt.hash(password, 12), displayName, role])).rows[0];
    await pool.query('insert into memberships(user_id,branch_id) values($1,$2)', [user.id, branchId]);
    res.status(201).json({ user });
  } catch (e) { res.status(409).json({ error: e.code === '23505' ? 'EMAIL_EXISTS' : 'USER_CREATE_FAILED' }); }
});
app.post('/v1/users/:id/disable', auth, requirePermission('users'), async (req, res) => {
  if (req.params.id === req.user.id) return res.status(400).json({ error: 'CANNOT_DISABLE_SELF' });
  const result = await pool.query('update users set disabled_at=coalesce(disabled_at, now()) where id=$1 and organization_id=$2 returning id,disabled_at', [req.params.id, req.user.organization_id]);
  if (!result.rowCount) return res.status(404).json({ error: 'USER_NOT_FOUND' });
  res.json({ user: result.rows[0] });
});
app.get('/v1/devices', auth, requirePermission('users'), async (req, res) => {
  const result = await pool.query('select id,user_id,device_key,name,app_version,last_seen_at,revoked_at from devices where organization_id=$1 order by last_seen_at desc', [req.user.organization_id]);
  res.json({ devices: result.rows });
});
app.post('/v1/devices/:id/revoke', auth, requirePermission('users'), async (req, res) => {
  const result = await pool.query('update devices set revoked_at=coalesce(revoked_at, now()) where id=$1 and organization_id=$2 returning id,revoked_at', [req.params.id, req.user.organization_id]);
  if (!result.rowCount) return res.status(404).json({ error: 'DEVICE_NOT_FOUND' });
  res.json({ device: result.rows[0] });
});
app.get('/v1/audit', auth, requirePermission('reports'), async (req, res) => {
  const limit = Math.min(Number(req.query.limit || 100), 500);
  const result = await pool.query('select a.*, u.display_name from audit_logs a join users u on u.id=a.user_id where a.organization_id=$1 order by a.created_at desc limit $2', [req.user.organization_id, limit]);
  res.json({ entries: result.rows });
});
app.get('/v1/reports/summary', auth, requirePermission('reports'), async (req, res) => {
  const branchId = req.query.branchId;
  const args = [req.user.organization_id];
  const branch = branchId ? ' and s.branch_id=$2' : '';
  if (branchId) args.push(branchId);
  const sales = await pool.query(`select count(*)::int as count, coalesce(sum(s.amount),0)::int as revenue, coalesce(sum(case when s.sale_source='manual' then s.profit_amount else s.amount - coalesce(c.cost_price,0) end),0)::int as profit from sales s left join cards c on c.id=s.card_id where s.organization_id=$1${branch}`, args);
  const stock = await pool.query(`select p.id,p.name,count(c.id)::int as available from packages p left join cards c on c.package_id=p.id and c.status='available' where p.organization_id=$1${branch.replace('s.branch_id', 'p.branch_id')} group by p.id,p.name order by p.name`, args);
  res.json({ sales: sales.rows[0], stock: stock.rows });
});
app.post('/v1/messages/:id/status', auth, async (req, res) => {
  const { status, error } = req.body;
  if (!['pending', 'submitted', 'failed'].includes(status)) return res.status(400).json({ error: 'INVALID_MESSAGE_STATUS' });
  const result = await pool.query('update message_deliveries set status=$1,attempts=attempts+1,last_error=$2,updated_at=now() where id=$3 and organization_id=$4 returning *', [status, error || null, req.params.id, req.user.organization_id]);
  if (!result.rowCount) return res.status(404).json({ error: 'MESSAGE_NOT_FOUND' });
  res.json({ delivery: result.rows[0] });
});
app.get('/v1/conflicts', auth, requirePermission('reports'), async (req, res) => {
  const result = await pool.query("select * from sync_conflicts where organization_id=$1 and status='open' order by created_at desc", [req.user.organization_id]);
  res.json({ conflicts: result.rows });
});

app.get('/v1/sync/pull', auth, requireBranch, async (req, res) => {
  const after = req.query.after || '1970-01-01T00:00:00Z';
  const result = await pool.query('select id,entity,entity_id,operation,payload,device_id,user_id,created_at from sync_changes where organization_id=$1 and branch_id=$2 and created_at > $3 order by created_at,id limit 1000', [req.user.organization_id, req.branchId, after]);
  res.json({ changes: result.rows, cursor: result.rows.at(-1)?.created_at || after, hasMore: result.rowCount === 1000 });
});
app.post('/v1/sync/push', auth, requirePermission('read'), requireBranch, async (req, res) => {
  const changes = Array.isArray(req.body.changes) ? req.body.changes.slice(0, 1000) : [];
  const client = await pool.connect(); const accepted = []; const rejected = [];
  try {
    await client.query('begin');
    for (const change of changes) {
      if (!change.id || !change.entity || !change.entityId || !change.operation) { rejected.push({ id: change.id, error: 'INVALID_CHANGE' }); continue; }
      try {
        await client.query('insert into sync_changes(id,organization_id,branch_id,entity,entity_id,operation,payload,device_id,user_id) values($1,$2,$3,$4,$5,$6,$7,$8,$9) on conflict (id) do nothing', [change.id, req.user.organization_id, req.branchId, change.entity, change.entityId, change.operation, change.payload || {}, change.deviceId || 'unknown', req.user.id]);
        accepted.push(change.id);
      } catch (e) { rejected.push({ id: change.id, error: e.code || 'PUSH_FAILED' }); }
    }
    await client.query('commit'); res.json({ accepted, rejected });
  } catch (e) { await client.query('rollback'); res.status(500).json({ error: 'PUSH_FAILED' }); } finally { client.release(); }
});

app.post('/v1/sales', auth, requirePermission('sell'), async (req, res) => {
  const { branchId, cardId, clientId, paymentMethod = 'credit', deviceId = 'unknown', idempotencyKey } = req.body;
  if (!branchId || !cardId) return res.status(400).json({ error: 'CARD_REQUIRED' });
  const db = await pool.connect();
  try {
    await db.query('begin');
    const card = (await db.query('select c.*, p.price from cards c join packages p on p.id=c.package_id where c.id=$1 and c.branch_id=$2 for update', [cardId, branchId])).rows[0];
    if (!card || card.status !== 'available') { await db.query('rollback'); return res.status(409).json({ error: 'CARD_UNAVAILABLE' }); }
    const saleId = idempotencyKey || randomUUID();
    const sale = (await db.query('insert into sales(id,organization_id,branch_id,client_id,card_id,package_id,amount,payment_method,created_by) values($1,$2,$3,$4,$5,$6,$7,$8,$9) on conflict (card_id) do nothing returning *', [saleId, req.user.organization_id, branchId, clientId || null, card.id, card.package_id, card.price, paymentMethod, req.user.id])).rows[0];
    if (!sale) { await db.query('rollback'); return res.status(409).json({ error: 'CARD_ALREADY_SOLD' }); }
    await db.query("update cards set status='sold',version=version+1,updated_at=now() where id=$1", [card.id]);
    if (clientId && paymentMethod === 'credit') await db.query('insert into ledger_entries(organization_id,branch_id,client_id,kind,amount,source_id,created_by) values($1,$2,$3,$4,$5,$6,$7)', [req.user.organization_id, branchId, clientId, 'sale', card.price, sale.id, req.user.id]);
    await db.query('insert into audit_logs(organization_id,branch_id,user_id,action,entity,entity_id,metadata) values($1,$2,$3,$4,$5,$6,$7)', [req.user.organization_id, branchId, req.user.id, 'sale', 'sale', sale.id, JSON.stringify({ cardId: card.id, deviceId })]);
    await db.query('commit'); res.status(201).json({ sale, card: { ...card, status: 'sold' } });
  } catch (e) { await db.query('rollback'); res.status(500).json({ error: 'SALE_FAILED' }); } finally { db.release(); }
});
app.post('/v1/manual-sales', auth, requirePermission('sell'), async (req, res) => {
  const { branchId, clientId, description = '', quantity = 1, unitPrice, unitCost = 0, paymentMethod = 'cash', idempotencyKey } = req.body;
  const qty = Number(quantity); const price = Number(unitPrice); const cost = Number(unitCost);
  if (!branchId || !description.trim() || !Number.isInteger(qty) || qty < 1 || !Number.isInteger(price) || price < 0 || !Number.isInteger(cost) || cost < 0 || !['cash', 'credit'].includes(paymentMethod)) return res.status(400).json({ error: 'INVALID_MANUAL_SALE' });
  const total = qty * price; const profit = qty * (price - cost);
  const db = await pool.connect();
  try {
    await db.query('begin');
    const saleId = idempotencyKey || randomUUID();
    const sale = (await db.query('insert into sales(id,organization_id,branch_id,client_id,card_id,package_id,amount,payment_method,created_by,sale_source,quantity,unit_price,unit_cost,profit_amount,description) values($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15) on conflict (id) do nothing returning *', [saleId, req.user.organization_id, branchId, clientId || null, null, null, total, paymentMethod, req.user.id, 'manual', qty, price, cost, profit, description.trim()])).rows[0];
    if (!sale) { await db.query('rollback'); return res.status(409).json({ error: 'SALE_ALREADY_RECORDED' }); }
    if (clientId && paymentMethod === 'credit') await db.query('insert into ledger_entries(organization_id,branch_id,client_id,kind,amount,source_id,created_by) values($1,$2,$3,$4,$5,$6,$7)', [req.user.organization_id, branchId, clientId, 'sale', total, sale.id, req.user.id]);
    await db.query('insert into audit_logs(organization_id,branch_id,user_id,action,entity,entity_id,metadata) values($1,$2,$3,$4,$5,$6,$7)', [req.user.organization_id, branchId, req.user.id, 'manual_sale', 'sale', sale.id, JSON.stringify({ quantity: qty, total, paymentMethod })]);
    await db.query('commit'); res.status(201).json({ sale, debtEffect: paymentMethod === 'credit' ? total : 0, profit });
  } catch (e) { await db.query('rollback'); res.status(500).json({ error: 'MANUAL_SALE_FAILED' }); } finally { db.release(); }
});

app.listen(Number(process.env.PORT || 8080), () => console.log(`qaidi-sync-api listening on ${process.env.PORT || 8080}`));
