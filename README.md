# Rubotty

Rubotty connects channels on different chat platforms into shared rooms. It runs as a Ruby service and keeps each community's settings, members and moderation separate. An operator dashboard and HTTP API let you manage it while it is running.

Copyright 2026, Spark Software Development, LLC.

## Features

A room brings together endpoints on Telegram, Discord, IRC, Matrix and other supported platforms. Messages cross between them with their author names, attachments and reply context, and the bridge follows later edits, deletions and reactions where the destination supports them.

One deployment can serve several communities. Each community has its own rooms, operators and feature settings, so you can share platform accounts without sharing moderation rules or administrative access.

Moderation commands work across a room rather than on just one platform. Optional filters, FAQs, translation, event reminders and guest access can be enabled per community or room; settings stay in the control-plane database.

The web dashboard provides configuration, advanced moderation and day-to-day operations. The YAML HTTP API supports external clients, room message streams and remote systems that want to participate in the bridge. Operator scripts offer another way to add room-specific behaviour.

The service can use SQLite, PostgreSQL or MariaDB for its control plane. The relay worker and web process share that database, with persistent message mappings and jobs carrying state across restarts.

## Configuration

Set the environment variables below for your deployment. Keep credentials and owner/community configuration in private environment variables or mounted files. The dashboard can manage accounts and topology stored in the database; a static YAML configuration is optional.

| Setting | Purpose |
| --- | --- |
| `BRIDGE_CONFIG`, or `--config` | Optional static YAML configuration file. |
| `LIVE_DB_TYPE` | Storage backend: `sqlite`, `pgsql`, `mdb`, `pstore` or `memory`; the web control plane needs a SQL backend. |
| `SQLITE_FILENAME`, `PGSQL_DATABASE_URL`, `MDB_DATABASE_URL` | Connection setting for the selected SQL backend. |
| `TELEGRAM_BOT_TOKEN`, `DISCORD_BOT_TOKEN` | Platform credentials when the account configuration references these environment names. |
| `DASHBOARD_SECRET`, `DASHBOARD_SESSION_SECRET` | Dashboard root password and session signing secret. |
| `DASHBOARD_URL`, `GUEST_PORTAL_URL`, `RUBOTTY_FILE_STORAGE_URL` | Public URLs used to construct login, guest and file links. |
| `RUBOTTY_PROTECTED_OPERATORS_FILE`, `RUBOTTY_PROTECTED_COMMUNITIES_FILE` | Private owner identities and protected community mappings. |
| `RUBOTTY_SCRIPT_USER` | Separate non-root account for operator scripts; supplementary groups are cleared before execution. |
| `ENVIRONMENT` | Set to `PRODUCTION` to load production community protections. |

Untrusted non-Lua compilation requires Linux seccomp, Landlock ABI 6 or newer, and a separate non-root script account with no supplementary groups. Older hosts can use Lua subject to its runtime requirements; `RUBOTTY_SCRIPT_ISOLATION=optional` permits the compilation fallback only for explicitly trusted code. The required compile policy accepts at most 512 KiB of source, 8 MiB of generated output and 64 KiB per diagnostic stream, and blocks helpers and arbitrary temporary files.

For SQLite, run the worker and web process as the same OS user against the same database path on a shared filesystem, with a writable parent directory for their lock directory. Some optional moderation, translation, FAQ and summary features retain message content in pending jobs or history. Review each feature's retention settings before enabling it. Run `bundle exec ruby bin/rubotty schema` for the complete YAML configuration reference.

## Build & Deploy

Use Ruby 4.0 or newer and a current Node.js installation with npm. From a checkout of this catalogue, install dependencies and build the dashboard:

```sh
bundle install
npm ci
npm run build
ALLOW_EPHEMERAL_STORAGE=1 bundle exec rake check
bundle exec rspec
```

Run `bundle exec ruby bin/rubotty run` for the relay and `bundle exec ruby bin/rubotty web` for the combined web surface, both against the same database. Add `--config path/to/config.yaml` if using a static configuration.

### Build a Docker image

Rubotty releases include the source and [Railpack build configuration](railpack.json). Install Docker and [Railpack 0.43.0](https://github.com/railwayapp/railpack/releases/tag/v0.43.0) on your build machine, then set `BUILDKIT_HOST` using the [Railpack BuildKit setup](https://railpack.com/getting-started/#building). Build from a release tag:

```sh
git clone --branch v0.8.3 --depth 1 https://github.com/sparkdotdev/rubotty.git
cd rubotty
railpack build --name rubotty:0.8.3 \
  --env "SOURCE_COMMIT=$(git rev-parse HEAD)" \
  --env BUNDLE_WITH=postgres:mariadb .
docker image inspect rubotty:0.8.3 --format '{{.Id}}'
```

The build includes Ruby, Lua, the dashboard assets and media tools. `BUNDLE_WITH` adds the optional PostgreSQL and MariaDB drivers alongside SQLite. Supply your bot credentials and private configuration at runtime. Run `bundle exec bin/rubotty run` for the relay and `bundle exec bin/rubotty web` for the web surface from the same image, with a shared database, persistent storage and a web health check at `/healthz`.

## License

PolyForm Strict 1.0.0 with the Rubotty Deployment Addendum 1.0.0. Source-available, but not open-source. You may deploy and operate unmodified instances for non-commercial purposes. Commercial or enterprise operation requires separate written permission from Spark Software Development, LLC. Deployment or use in communities that charge users for Rubotty features is prohibited, including paid roles, memberships or subscriptions that bundle access to those features; operators also must not charge communities for access to or use of their instance. General commercial permission does not waive either prohibition. See [License](LICENSE.MD) for the full terms.

## Forking and Contributions

PolyForm Strict does not grant general permission to modify or redistribute this software. Our [Contribution Policy](CONTRIBUTING.md) grants limited permissions for contribution forks, review and controlled testing. Rights independently available under applicable law or the hosting platform's terms remain separate.

Contributions are welcome. You retain ownership, but Spark may use and commercially relicense submitted contributions, including under proprietary terms, even if a submission is declined or withdrawn. Read and accept the contribution agreement before submitting a change.
