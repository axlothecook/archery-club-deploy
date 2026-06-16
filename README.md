# Archery club (VSK) — deploy stack

Production deployment for **archery.axlothecook.com**, self-hosted on the home
Raspberry Pi alongside the gaming-shop and create-resume stacks. Same proven
pattern: GHCR images built by CI (arm64), pulled by the Pi; a dedicated Cloudflare
Tunnel; same-origin topology (one hostname, nginx proxies `/api`).

## Architecture

```
Cloudflare edge ──(tunnel)──► cloudflared ─► proxy(nginx:80)
                                               ├─ /        ─► frontend (SvelteKit adapter-node :3000)
                                               └─ /api/*   ─► backend  (Express+Prisma :3100, prefix stripped)
                                                              backend ─► db (Postgres 17)
                                                              backend ─► R2 (images.axlothecook.com) + Google Translate
```

One origin (`archery.axlothecook.com`) → first-party `SameSite=Lax` session cookie,
so admin login works on strict browsers. The API mounts at root in the backend; the
proxy strips the `/api` prefix.

## Repos / images
- Frontend → `ghcr.io/axlothecook/archery-club-frontend:latest`
- Backend  → `ghcr.io/axlothecook/archery-club-backend:latest`
- Each repo's `.github/workflows/deploy.yml` builds+pushes on push to `main`, then
  SSHes to the Pi (over Tailscale) and runs `pull` + `up -d`.

## CI secrets (set on BOTH archery repos)
Reuse the SAME values as the game-shop / create-resume repos:
- `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET` — Tailscale OAuth (tag:ci)
- `PI_TAILSCALE_IP`, `PI_USER`, `PI_SSH_KEY` — Pi SSH over the tailnet
- `GITHUB_TOKEN` — auto-provided (GHCR push)

## First deploy (on the Pi)
1. **Clone this folder** to `~/archery-club-deploy` on the Pi.
2. **Create `.env`** from `.env.example`; fill in:
   - `POSTGRES_PASSWORD` (`openssl rand -hex 24`) — and put the same value in `DATABASE_URL`.
   - `SESSION_SECRET` (`node -e "console.log(require('crypto').randomBytes(48).toString('hex'))"`).
   - `R2_*` (same as the local backend `.env`), `GOOGLE_TRANSLATE_KEY`.
   - `TUNNEL_TOKEN` (see below).
3. **Cloudflare Tunnel:** Zero Trust → Networks → Tunnels → create `archery`; copy its
   token into `TUNNEL_TOKEN`. Add ONE public hostname on it:
   `archery.axlothecook.com` → HTTP → `proxy:80`. Ensure DNS for the subdomain points
   through the tunnel. Enable "Always Use HTTPS" on the zone (Secure cookies need https).
4. **Pull + start:**
   ```bash
   docker compose -f docker-compose.prod.yml pull
   docker compose -f docker-compose.prod.yml up -d
   ```
5. **Initialise the DB** (fresh Postgres — run the backend's scripts inside its container):
   ```bash
   docker compose -f docker-compose.prod.yml exec backend npx prisma migrate deploy
   docker compose -f docker-compose.prod.yml exec backend npm run import-seed
   docker compose -f docker-compose.prod.yml exec backend npx tsx scripts/translate-backfill.ts
   docker compose -f docker-compose.prod.yml exec backend npm run create-admin
   ```
6. **Verify:** `https://archery.axlothecook.com` loads; HR/EN switch works; `/api/health`
   returns ok; admin login works.

## Backups (2-tier, mirrors game-shop)
- **Tier 1 (Pi):** `backup-db.sh` → nightly `pg_dump` gzip to `./backups`, prunes > 14 days.
  Cron: `15 22 * * * /home/<user>/archery-club-deploy/backup-db.sh >> .../backups/backup.log 2>&1`
- **Tier 2 (PC):** the shared `pull-pi-backups.ps1` scps the Pi backups to the PC nightly.
- **Restore:** `gunzip -c archery_<stamp>.sql.gz | docker compose -f docker-compose.prod.yml exec -T db psql -U $POSTGRES_USER -d $POSTGRES_DB`

## Updating
Push to `main` on either repo → CI builds + deploys automatically. Manual:
`docker compose -f docker-compose.prod.yml pull && docker compose -f docker-compose.prod.yml up -d`
