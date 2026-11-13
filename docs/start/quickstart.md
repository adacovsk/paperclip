---
title: Quickstart
summary: Get Paperclip running in minutes
---

Get Paperclip running locally in under 5 minutes.

## Run from source

This build is not published to npm; `npx paperclipai` installs a different project's package. Run it from a clone. Prerequisites: Node.js 22.22+ or 24.15+ and pnpm 10.16+.

```sh
git clone https://github.com/adacovsk/paperclip.git
cd paperclip
pnpm install
pnpm dev
```

This starts the API server and UI at [http://localhost:3100](http://localhost:3100).

No external database required — Paperclip uses an embedded PostgreSQL instance by default.

You can also use:

```sh
pnpm paperclipai run
```

This auto-onboards if config is missing, runs health checks with auto-repair, and starts the server.

## What's Next

Once Paperclip is running:

1. Name your instance in the onboarding wizard
2. Define the instance goal
3. Create a CEO agent and configure its adapter
4. Build out the org chart with more agents
5. Set budgets and assign initial tasks
6. Hit go — agents start their heartbeats and the instance runs

<Card title="Core Concepts" href="/start/core-concepts">
  Learn the key concepts behind Paperclip
</Card>
