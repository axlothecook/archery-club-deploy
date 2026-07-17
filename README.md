# Deploy stack repo for Archery club and Dashboard

This repo runs the whole system of public site, backend and admin dashboard on my Raspberry Pi. They are all brought behind one nginx proxy and Cloudflare tunnel.

The repo consists of config files and one bash script that describe how to run the 6 Docker containers together. The instruction files are: docker-compose.prod.yml, nginx.conf, backup-db.sh and .env.example.

## How does GitHub Container Registry (GHCR) work in this project?
After pushing to main branch, GitHub Actions builds the app into a Docker image. Then CI logs into ghcr.io (GHCR - GitHub's storage service for Docker images), tags the image and pushes it as a package stored under my GitHub account, from which the Pi pulls via `docker compose pull` and runs it.

Basically the image is built in GitHub's cloud and the Pi just downloads the finished result. GHCR only receives and stores it.

## Why not build on Pi?
Building the image on Pi would be slow and heavy for the small machine. That's why a registry and CI are used. Any registry could have been used - Docker Hub, GHCR, etc.


# Docker containers
<ul>
  <li>db: PostgreSQL 17</li>
  <li>backend: Express API (from GHCR)</li>
  <li>frontend: the public site (from GHCR)</li>
  <li>dashboard: the admin CMS (from GHCR)</li>
  <li>proxy: nginx</li>
  <li>cloudflared: Cloudflare Tunnel</li>
</ul>

### What does each docker image do

[PostgreSQL](https://www.postgresql.org) container runs the official Postgres standard image, keeps its data in a named volume so deploys don't wipe it, auto-restarts on failure, and reports a healthcheck the backend waits on before it starts.

[Express API](https://expressjs.com) runs the backend image pulled from GHCR, reads all its config and secrets from the .env file, then waits for the database to be healthy before it starts. That's the other half of the db's healthcheck: the API never boots against a database that isn't ready yet.

The public site runs the [SvelteKit](https://svelte.dev/docs/kit/introduction) frontend from GHCR. It trusts nginx's forwarded headers (real https host/protocol) and gets the API URL at runtime. Since the URL is read at runtime and not at build time, the public api base has to be set here. If it isn't, the URL falls back to localhost:3100 so the API fetch fails, and the route loaders quietly default to empty data, which is why the data sections render empty. Which means the page still loads, just with no content from the API.

This container also depends on the backend.

The admin dashboard: a separate SvelteKit server. Its image uses the same concepts of forwarded-header trust and runtime API URL as the public site frontend, and also waits on the backend. The only difference is the requests it receives, the ones for the dashboard's own pages (examples bellow), while everything else goes to the public site.

[nginx](https://nginx.org) Docker image runs with read-only nginx.conf mounted into the container, so the routing rules come straight from this repo, not baked into an image. It waits for three containers to be up - backend, frontend and dashboard. It also doesn't publish any port to the host - nothing is exposed to the internet directly. The only thing that talks to it is the tunnel container by name (proxy:80) and internally only.

[Cloudflare Tunnel](https://developers.cloudflare.com/tunnel/) image runs Cloudflare's tunnel client, authenticated by the tunnel token. It makes an outbound connection to Cloudflare's edge. This way the common archery domain can reach the Pi without opening any ports or needing a static IP. Also depends on the proxy.

How does it do that? The Pi dials out to Cloudflare; Cloudflare sends public traffic back down that connection to the proxy.


# Request flow (runtime) 
I made a diagram of how a request flows through the stack at runtime: from the browser, through the Cloudflare Tunnel to nginx on the Pi, then on to the right service (public site, dashboard, or backend). Everything runs on one home Raspberry Pi, behind a Cloudflare Tunnel, so nothing on the Pi is exposed to the internet directly: cloudflared dials out to Cloudflare, and no ports are exposed to the internet.

![image](https://github.com/user-attachments/assets/e5c592aa-1094-4cbd-a0d3-993f59ff04aa)


## How a request flows
The hostname archery.axlothecook.com receives all requests, whether that be to the api, the public site or dashboard, and nginx decides where it goes.

<ul>
  <li>if the request starts with `/api/` nginx strips the /api prefix and the request goes to the backend</li>
  <li>if the request is a dashboard path, like `/accept-invite, /reset-password` etc, dashboard gets the request</li>
  <li>every other request goes to frontend (the public site)</li>
</ul>

Once a request reaches the backend, it reads and writes its data in the Postgres database. On admin writes only, it also calls two outside services: Cloudflare R2 when an admin uploads an image, and Google Translate to backfill the English text when an admin saves Croatian content.


# The problem that one domain solves
Browsers usually refuse to send the login cookie when the page's domain differs from the API's domain. There was a potential for that problem to happen here too - the backend api domain vs public site domain / dashboard domain. But because they are all hosted under the same domain (archery.axlothecook.com), the login cookie is first-party (`SameSite=Lax`), so it works even in browsers that block cross-site cookies.


# Deployment pipelines 
Each repo (backend, public site, dashboard) has its own GitHub Actions pipeline, and they all follow the same core flow: a push to main runs the tests, then CI builds an arm64 image and pushes it to GHCR, then connects to the Pi over Tailscale and the Pi pulls the image and restarts. If any test fails, nothing gets deployed. The diagrams below show each repo's version and where they differ.

## Backend deployment pipeline
The backend has the heaviest test job of the three: besides the typecheck and unit tests it also runs integration tests, which need a real database. That part gets its own diagram below.

![image](https://github.com/user-attachments/assets/9cdcca97-b8d2-4fac-8bb0-4a31b08d6454)

## Backend integration testing 
Since this testing includes both unit and integration tests, I gave it its own diagram. CI starts a throwaway Postgres database, the job creates and migrates a separate test database, and the integration tests run their queries against that live database. It also checks out the shared TypeScript types repo (archery-contracts) next to the backend so the file dependency resolves.

![image](https://github.com/user-attachments/assets/c66312c9-e569-4227-afed-1942d1e223e4)


## Public site deployment pipeline
The public site's tests are node-only and have no database, so its tests are lighter. Otherwise its pipeline follows the shared flow in the same way.

![image](https://github.com/user-attachments/assets/7095f962-1dee-46af-bd65-f923e08acc4f)


## Dashboard deployment pipeline
The dashboard's deploy is scoped, meaning that instead of restarting the whole stack, it pulls and recreates only its own container, then reloads nginx so nginx picks up the new container's address.

![image](https://github.com/user-attachments/assets/59ad37f9-57f4-447d-9076-bdeebdc47113)



# The config
Since I cannot commit .env to git, and real variable values can live only in the Pi's .env, I created a .env.example that lists what the Pi needs:

<ul>
  <li>Postgres credentials</li>
  <li>SESSION_SECRET</li>
  <li>the Cloudflare TUNNEL_TOKEN</li>
  <li>the API keys for: R2 (images), Google Translate, and Brevo (email)</li>
</ul>


# The fun part - Backups
This is where the `backup-db.sh` shell script comes in. It basically runs a nightly pg_dump of the database, gzipped into ./backups folder. It keeps the data for 14 days, and it also verifies the dump isn't empty or corrupt before deleting old ones. This prevents a failed backup wiping the stored good backups. Additionally, a second tier copies these off the Pi to my PC.
