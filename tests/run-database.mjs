/** Isolated PostgreSQL regression suite. No network or production connections.
 * Download/extract @electric-sql/pglite outside the repository, then:
 *   $env:PGLITE_MODULE = 'C:\path\to\package\dist\index.js'
 *   node tests/run-database.mjs
 * No application dependencies or package manifest are required.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const modulePath = process.env.PGLITE_MODULE;
if (!modulePath) {
  console.error('Set PGLITE_MODULE to an extracted @electric-sql/pglite dist/index.js (tested with 0.5.8), then run this script again.');
  process.exit(1);
}
const { PGlite } = await import(pathToFileURL(path.resolve(modulePath)).href);
const { unaccent } = await import(pathToFileURL(path.join(path.dirname(path.resolve(modulePath)), 'contrib/unaccent.js')).href);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const db = new PGlite({ extensions: { unaccent } });
try {
  // Only Supabase auth primitives are shimmed. Tables, RLS, triggers and SQL
  // functions under review run unchanged in the actual PostgreSQL engine.
  await db.exec(`
    create role anon nologin;
    create role authenticated nologin;
    create role service_role nologin bypassrls;
    create schema auth;
    create schema extensions;
    create table auth.users (id uuid primary key, email text);
    create function auth.uid() returns uuid language sql stable as $$
      select (nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'sub')::uuid
    $$;
    grant usage on schema auth, public to anon, authenticated, service_role;
    grant execute on function auth.uid() to anon, authenticated, service_role;
  `);
  const migrations = path.join(root, 'supabase/migrations');
  const files = fs.readdirSync(migrations).filter(f => f.endsWith('.sql')).sort();
  for (const file of files) {
    await db.exec(fs.readFileSync(path.join(migrations, file), 'utf8'));
    console.log('Applied', file);
  }
  await db.exec(fs.readFileSync(path.join(migrations, files.at(-1)), 'utf8'));
  console.log('Reapplied latest migration successfully');
  for (const file of ['tests.sql', 'integrity_tests.sql']) {
    const results = await db.exec(fs.readFileSync(path.join(root, 'supabase', file), 'utf8'));
    const passed = results.flatMap(r => r.rows || []).filter(r => typeof r.result === 'string' && r.result.includes('PASSED'));
    if (!passed.length) throw new Error(`${file} did not produce its success marker`);
    passed.forEach(r => console.log(r.result));
  }
} catch (error) {
  console.error(error.message);
  if (error.detail) console.error(error.detail);
  if (error.where) console.error(error.where);
  process.exitCode = 1;
} finally {
  await db.close();
}
