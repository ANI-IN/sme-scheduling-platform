# Setting up from scratch

This gets the whole project running on one computer with no external accounts. Connecting real services is in
[DEPLOYMENT.md](DEPLOYMENT.md).

## 1. Install the tools

| Tool | Version | Notes |
|---|---|---|
| Node.js | 22.22.2+ (22 line), 24.15+ (24 line), or 26+ | Includes npm. `node --version` |
| Docker Desktop | current | Must be running for anything that uses the database |
| Git | current | On Windows, Git Bash is used by some scripts |

The Supabase command line is a package in this repository; do not install it separately.

## 2. Get the code and packages

```bash
git clone https://github.com/ANI-IN/sme-scheduling-platform.git
cd sme-scheduling-platform
npm ci
```

**Windows only:** copy `.npmrc.windows-example` to `.npmrc`. It makes npm run scripts in Git Bash, which scripts such
as `help:screenshots` need, and it copes with folder names that contain `&`. Change the path inside if Git is installed
elsewhere.

## 3. Install the test browser

Needed only for the browser tests and for remaking help pictures.

```bash
npx playwright install chromium
```

## 4. Start the local database

```bash
npm run db:start
```

The first start downloads container images and takes several minutes. It applies every migration, then
`supabase/seed.sql` and `supabase/seed.local.sql` (which marks the database as **Development**, allows `@example.com`
sign in and points links at your computer). It prints the addresses and keys:

| Service | Address |
|---|---|
| API | `http://127.0.0.1:55421` |
| Database | `postgresql://postgres:postgres@127.0.0.1:55422/postgres` |
| Database studio | `http://127.0.0.1:55423` |
| Mail catcher | `http://127.0.0.1:55424` |

## 5. Configure the web app

Copy `app/.env.example` to `app/.env.local` and set:

```text
VITE_SUPABASE_URL=http://127.0.0.1:55421
VITE_SUPABASE_PUBLISHABLE_KEY=<the publishable key printed by db:start>
VITE_ALLOWED_EMAIL_DOMAIN=example.com
VITE_ENABLE_DEV_LOGIN=true
```

## 6. Run it

```bash
npm run dev
```

1. Open <http://localhost:5173>.
2. Enter any address ending in `@example.com` and ask for the sign in link.
3. Open the mail catcher at <http://127.0.0.1:55424> and follow the link.
4. Home shows **Get started**. Add a domain, instructors, modules, a cohort and classes.

The first person to sign in is not an admin. To make yourself one:

```bash
npm run admins:local -w scripts -- add you@example.com
```

## 7. Check that everything works

```bash
npm run check
npm run db:test
npm run mock -- --race
```

## 8. Stop

```bash
npm run db:stop
```

## Ports used

| Ports | Used by |
|---|---|
| 5173 | The app |
| 5542x | Your local database stack |
| 5552x and 5174 | The temporary stack of the browser tests |

## Next

- [DEVELOPMENT.md](DEVELOPMENT.md) to change the code.
- [TESTING.md](TESTING.md) for every test.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) if a step fails.
