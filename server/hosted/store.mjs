import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
export const random = () => randomBytes(32).toString('base64url');
export const hash = value => createHash('sha256').update(value).digest('base64url');
export const equal = (a, b) => typeof a === 'string' && typeof b === 'string' && Buffer.byteLength(a) === Buffer.byteLength(b) && timingSafeEqual(Buffer.from(a), Buffer.from(b));
export const expires = seconds => new Date(Date.now() + seconds * 1000);

// All queries use parameters. Every data read/write is scoped by the authenticated user.
export class Store {
  constructor(pool) { this.pool = pool; }
  async query(sql, values = []) { return (await this.pool.query(sql, values)).rows; }
  async transaction(work) {
    const connection = await this.pool.connect();
    try {
      await connection.query('BEGIN');
      const result = await work(new Store(connection));
      await connection.query('COMMIT');
      return result;
    } catch (error) { await connection.query('ROLLBACK'); throw error; }
    finally { connection.release(); }
  }
  async limit(key, max, seconds = 60) {
    const [row] = await this.query(`INSERT INTO lectern_limits (key,count,expires_at) VALUES ($1,1,$2)
      ON CONFLICT (key) DO UPDATE SET count = CASE WHEN lectern_limits.expires_at < now() THEN 1 ELSE lectern_limits.count+1 END,
      expires_at = CASE WHEN lectern_limits.expires_at < now() THEN $2 ELSE lectern_limits.expires_at END RETURNING count`, [key, expires(seconds)]);
    return row.count <= max;
  }
  async putPending(kind, data, seconds = 600) {
    const token = random();
    await this.query('INSERT INTO lectern_pending VALUES ($1,$2,$3,$4)', [hash(token), kind, data, expires(seconds)]);
    return token;
  }
  async pending(token, kind) {
    return (await this.query('SELECT data FROM lectern_pending WHERE hash=$1 AND kind=$2 AND expires_at>now()', [hash(token), kind]))[0]?.data;
  }
  async consumePending(token, kind) {
    return (await this.query('DELETE FROM lectern_pending WHERE hash=$1 AND kind=$2 AND expires_at>now() RETURNING data', [hash(token), kind]))[0]?.data;
  }
  async user(identity) {
    return (await this.query(`INSERT INTO lectern_users (id,google_sub,email) VALUES ($1,$2,$3)
      ON CONFLICT (google_sub) DO UPDATE SET email=EXCLUDED.email RETURNING *`, [random(), identity.sub, identity.email]))[0];
  }
  async session(token) {
    if (!token) return null;
    return (await this.query(`SELECT s.*,u.email FROM lectern_sessions s JOIN lectern_users u ON s.user_id=u.id
      WHERE s.hash=$1 AND s.expires_at>now()`, [hash(token)]))[0];
  }
  async newSession(userID) {
    const token = random();
    await this.query('INSERT INTO lectern_sessions VALUES ($1,$2,$3,$4)', [hash(token), userID, random(), expires(86400 * 7)]);
    return token;
  }
  async client(id) { return (await this.query('SELECT * FROM lectern_clients WHERE id=$1', [id]))[0]; }
  async tokenPair(grantID) {
    const access = random(), refresh = random();
    await this.query(`INSERT INTO lectern_tokens (hash,grant_id,kind,expires_at) VALUES ($1,$2,'access',$3),($4,$2,'refresh',$5)`,
      [hash(access), grantID, expires(3600), hash(refresh), expires(86400 * 30)]);
    return { access_token: access, refresh_token: refresh, token_type: 'Bearer', expires_in: 3600 };
  }
  async access(token, scope, resource) {
    if (!token || token.length > 200) return null;
    return (await this.query(`SELECT g.* FROM lectern_tokens t JOIN lectern_grants g ON t.grant_id=g.id
      WHERE t.hash=$1 AND t.kind='access' AND t.expires_at>now() AND NOT g.revoked AND g.scope=$2 AND g.resource=$3`, [hash(token), scope, resource]))[0];
  }
  async redeemCode(code, clientID, redirect, verifier, resource) {
    return this.transaction(async tx => {
      const preview = await tx.pending(code, 'code');
      if (!preview) return null;
      await tx.query('SELECT id FROM lectern_users WHERE id=$1 FOR UPDATE', [preview.userID]);
      const data = await tx.consumePending(code, 'code');
      if (!data || data.clientID !== clientID || data.redirect !== redirect || !equal(data.challenge, hash(verifier)) || (resource && resource !== data.resource)) return null;
      const grantID = random();
      await tx.query('INSERT INTO lectern_grants (id,user_id,client_id,scope,resource) VALUES ($1,$2,$3,$4,$5)', [grantID, data.userID, clientID, data.scope, data.resource]);
      return { ...await tx.tokenPair(grantID), scope: data.scope };
    });
  }
  async refresh(token, clientID, resource) {
    return this.transaction(async tx => {
      // Lock the grant too, serializing refresh rotation with account revocation and sync.
      const [row] = await tx.query(`SELECT t.used,t.expires_at,g.* FROM lectern_tokens t JOIN lectern_grants g ON t.grant_id=g.id
        WHERE t.hash=$1 AND t.kind='refresh' FOR UPDATE OF t,g`, [hash(token)]);
      if (!row || row.client_id !== clientID || row.revoked || new Date(row.expires_at) <= new Date() || (resource && resource !== row.resource)) return null;
      if (row.used) {
        await tx.query('UPDATE lectern_grants SET revoked=true WHERE id=$1', [row.id]);
        return null; // Commit reuse revocation; do not throw/roll it back.
      }
      await tx.query('UPDATE lectern_tokens SET used=true WHERE hash=$1', [hash(token)]);
      return { ...await tx.tokenPair(row.id), scope: row.scope };
    });
  }
  async revokeToken(token, clientID) {
    await this.query(`UPDATE lectern_grants SET revoked=true WHERE client_id=$2 AND id IN
      (SELECT grant_id FROM lectern_tokens WHERE hash=$1)`, [hash(token), clientID]);
  }
  async library(userID) {
    return (await this.query('SELECT snapshot,revision,updated_at FROM lectern_libraries WHERE user_id=$1', [userID]))[0] ?? { snapshot: { courses: [], lectures: [] }, revision: 0, updated_at: null };
  }
  async replaceLibrary(grant, snapshot, expectedRevision) {
    return this.transaction(async tx => {
      // User lock serializes writers from different devices and deletion.
      await tx.query('SELECT id FROM lectern_users WHERE id=$1 FOR UPDATE', [grant.user_id]);
      const [active] = await tx.query('SELECT id FROM lectern_grants WHERE id=$1 AND NOT revoked FOR UPDATE', [grant.id]);
      if (!active) return { error: 'revoked' };
      const current = await tx.library(grant.user_id);
      if (current.revision !== expectedRevision) return { error: 'conflict', revision: current.revision };
      const [saved] = await tx.query(`INSERT INTO lectern_libraries (user_id,snapshot) VALUES ($1,$2)
        ON CONFLICT (user_id) DO UPDATE SET snapshot=$2,revision=lectern_libraries.revision+1,updated_at=now()
        RETURNING revision,updated_at`, [grant.user_id, snapshot]);
      return saved;
    });
  }
  async erase(userID) {
    await this.transaction(async tx => {
      await tx.query('SELECT id FROM lectern_users WHERE id=$1 FOR UPDATE', [userID]);
      await tx.query('UPDATE lectern_grants SET revoked=true WHERE user_id=$1', [userID]);
      await tx.query('DELETE FROM lectern_libraries WHERE user_id=$1', [userID]);
      await tx.query('DELETE FROM lectern_uploads WHERE user_id=$1', [userID]);
      // Pending authorization codes/consents must not mint new tokens after erasure.
      await tx.query("DELETE FROM lectern_pending WHERE data->>'userID'=$1", [userID]);
    });
  }
  async cleanup() {
    await this.query('DELETE FROM lectern_uploads WHERE expires_at<now()');
    await this.query('DELETE FROM lectern_pending WHERE expires_at<now()');
    await this.query('DELETE FROM lectern_sessions WHERE expires_at<now()');
    await this.query('DELETE FROM lectern_tokens WHERE expires_at<now()');
    await this.query('DELETE FROM lectern_limits WHERE expires_at<now()');
  }
}
