# ClipHub — The Team Registry

**Download a team.**

ClipHub is the public registry where people share, discover, and download Paperclip team configurations. A team template is a portable artifact containing an entire org — agents, reporting structure, adapter configs, role definitions, seed tasks — ready to spin up with one command.

---

## What It Is

ClipHub is to Paperclip what a package registry is to a programming language. Paperclip already supports exportable org configs (see [SPEC.md](./SPEC.md) §2). ClipHub is the public directory where those exports live.

A user builds a working team in Paperclip — a dev shop, a marketing agency, a research lab, a content studio — exports the template, and publishes it to ClipHub. Anyone can browse, search, download, and spin up that team on their own Paperclip instance.

The tagline: **you can literally download a team.**

---

## What Gets Published

A ClipHub package is a **team template export** — the portable artifact format defined in the Paperclip spec. It contains:

| Component | Description |
|---|---|
| **Team metadata** | Name, description, intended use case, category |
| **Org chart** | Full reporting hierarchy — who reports to whom |
| **Agent definitions** | Every agent: name, role, title, capabilities description |
| **Adapter configs** | Per-agent adapter type and configuration (SOUL.md, HEARTBEAT.md, CLAUDE.md, process commands, webhook URLs — whatever the adapter needs) |
| **Seed tasks** | Optional starter tasks and initiatives to bootstrap the team's first run |
| **Budget defaults** | Suggested token/cost budgets per agent and per instance |

Templates are **structure, not state.** No in-progress tasks, no historical cost data, no runtime artifacts. Just the blueprint.

### Sub-packages

Not every use case needs a whole team. ClipHub also supports publishing individual components:

- **Agent templates** — a single agent config (e.g. "Senior TypeScript Engineer", "SEO Content Writer", "DevOps Agent")
- **Team templates** — a subtree of the org chart (e.g. "Marketing Team: CMO + 3 reports", "Engineering Pod: Tech Lead + 4 Engineers")
- **Adapter configs** — reusable adapter configurations independent of any specific agent role

These can be mixed into existing instances. Download an agent, slot it into your org, assign a manager, go.

---

## Core Features

### Browse & Discover

The homepage surfaces team templates across several dimensions:

- **Featured** — editorially curated, high-quality templates
- **Popular** — ranked by downloads, stars, and forks
- **Recent** — latest published or updated
- **Categories** — browseable by use case (see Categories below)

Each listing shows: name, short description, org size (agent count), category, adapter types used, star count, download count, and a mini org chart preview.

### Search

Search is **semantic, not keyword-only.** Powered by vector embeddings so you can search by intent:

- "marketing agency that runs facebook ads" → finds relevant team templates even if those exact words aren't in the title
- "small dev team for building APIs" → finds lean engineering orgs
- "content pipeline with writers and editors" → finds content studio templates

Also supports filtering by: category, agent count range, adapter types, star count, recency.

### Team Detail Page

Clicking into a team template shows:

- **Full description** — what this team does, how it operates, what to expect
- **Interactive org chart** — visual tree of every agent with role, title, and capabilities
- **Agent list** — expandable details for each agent (adapter type, config summary, role description)
- **Seed tasks** — the starter initiatives and tasks included
- **Budget overview** — suggested cost structure
- **Install command** — one-line CLI command to download and create
- **Version history** — changelog, semver, previous versions available
- **Community** — stars, comments, forks count

### Install & Fork

Two ways to use a template:

**Install (fresh start):**
```
paperclip install cliphub:<publisher>/<team-slug>
```
Downloads the template and sets up its agents, projects, and goals in your local Paperclip instance. You add your own API keys, set budgets, customize agents, and hit go.

**Fork:**
Forking creates a copy of the template under your own ClipHub account. You can modify it, republish it as your own variant, and the fork lineage is tracked. This enables evolutionary improvement — someone publishes a marketing agency, you fork it, add a social media team, republish.

### Stars & Comments

- **Stars** — bookmark and signal quality. Star count is a primary ranking signal.
- **Comments** — threaded discussion on each listing. Ask questions, share results, suggest improvements.

### Download Counts & Signals

Every install is counted. The registry tracks:

- Total downloads (all time)
- Downloads per version
- Fork count
- Star count

These signals feed into search ranking and discovery.

---

## Publishing

### Who Can Publish

Anyone with a GitHub account can publish to ClipHub. Authentication is via GitHub OAuth.

### How to Publish

From within Paperclip, export your instance's team as a template, then publish:

```
paperclip export --template my-team
paperclip publish cliphub my-team
```

Or use the web UI to upload a template export directly.

### What You Provide

When publishing, you specify:

| Field | Required | Description |
|---|---|---|
| `slug` | yes | URL-safe identifier (e.g. `lean-dev-shop`) |
| `name` | yes | Display name |
| `description` | yes | What this team does and who it's for |
| `category` | yes | Primary category (see below) |
| `tags` | no | Additional tags for discovery |
| `version` | yes | Semver (e.g. `1.0.0`) |
| `changelog` | no | What changed in this version |
| `readme` | no | Extended documentation (markdown) |
| `license` | no | Usage terms |

### Versioning

Templates use semantic versioning. Each publish creates an immutable version. Users can install any version or default to `latest`. Version history and changelogs are visible on the detail page.

### The `sync` Command

For power users who maintain multiple templates:

```
paperclip cliphub sync
```

Scans your local exported templates and publishes any that are new or updated. Useful for maintaining a portfolio of team templates from a single repo.

---

## Categories

Team templates are organized by use case:

| Category | Examples |
|---|---|
| **Software Development** | Full-stack dev shop, API development team, mobile app studio |
| **Marketing & Growth** | Performance marketing agency, content marketing team, SEO shop |
| **Content & Media** | Content studio, podcast production, newsletter operation |
| **Research & Analysis** | Market research firm, competitive intelligence, data analysis team |
| **Operations** | Customer support org, internal ops team, QA/testing shop |
| **Sales** | Outbound sales team, lead generation, account management |
| **Finance & Legal** | Bookkeeping service, compliance monitoring, financial analysis |
| **Creative** | Design agency, copywriting studio, brand development |
| **General Purpose** | Starter templates, minimal orgs, single-agent setups |

Categories are not exclusive — a template can have one primary category plus tags for cross-cutting concerns.

---

## Moderation & Trust

### Verified Publishers

Publishers who meet certain thresholds (account age, published templates with good signals) earn a verified badge. Verified templates rank higher in search.

### Security Review

Team templates contain adapter configurations, which may include executable commands (process adapter) or webhook URLs (HTTP adapter). The moderation system:

1. **Automated scanning** — checks adapter configs for suspicious patterns (arbitrary code execution, exfiltration URLs, credential harvesting)
2. **Community reporting** — any signed-in user can flag a template. Auto-hidden after multiple reports pending review.
3. **Manual review** — moderators can approve, reject, or request changes

### Account Gating

New accounts have a waiting period before they can publish. This prevents drive-by spam.

---

## Architecture

ClipHub is a **separate service** from Paperclip itself. Paperclip is self-hosted; ClipHub is a hosted registry that Paperclip instances talk to.

### Integration Points

| Layer | Role |
|---|---|
| **ClipHub Web** | Browse, search, discover, comment, star — the website |
| **ClipHub API** | Registry API for publishing, downloading, searching programmatically |
| **Paperclip CLI** | `paperclipai install`, `paperclipai publish`, `paperclipai cliphub sync` — built into Paperclip |
| **Paperclip UI** | "Browse ClipHub" panel in the Paperclip web UI for discovering templates without leaving the app |

### Tech Stack

| Layer | Technology |
|---|---|
| Frontend | React + Vite (consistent with Paperclip) |
| Backend | TypeScript + Hono (consistent with Paperclip) |
| Database | PostgreSQL |
| Search | Vector embeddings for semantic search |
| Auth | GitHub OAuth |
| Storage | Template zips stored in object storage (S3 or equivalent) |

### Data Model (Sketch)

```
Publisher
  id, github_id, username, display_name, verified, created_at

Template
  id, publisher_id, slug, name, description, category,
  tags[], readme, license, created_at, updated_at,
  star_count, download_count, fork_count,
  forked_from_id (nullable)

Version
  id, template_id, version (semver), changelog,
  artifact_url (zip), agent_count, adapter_types[],
  created_at

Star
  id, publisher_id, template_id, created_at

Comment
  id, publisher_id, template_id, body, parent_id (nullable),
  created_at, updated_at

Report
  id, reporter_id, template_id, reason, created_at
```

---

## User Flows

### "I want to start a team"

1. Open ClipHub, browse by category or search "dev shop for building SaaS"
2. Find a template that fits — "Lean SaaS Dev Shop (CEO + CTO + 3 Engineers)"
3. Read the description, inspect the org chart, check the comments
4. Run `paperclipai install cliphub:acme/lean-saas-shop`
5. Paperclip sets up the team locally with all agents pre-configured
6. Set your API keys, adjust budgets, add your initial tasks
7. Hit go

### "I built something great and want to share it"

1. Build and iterate on a team in Paperclip until it works well
2. Export: `paperclipai export --template my-agency`
3. Publish: `paperclipai publish cliphub my-agency`
4. Fill in description, category, tags on the web UI
5. Template is live — others can find and install it

### "I want to improve someone else's team"

1. Find a template on ClipHub that's close to what you need
2. Fork it to your account
3. Install your fork locally, modify the org (add agents, change configs, restructure teams)
4. Export and re-publish as your own variant
5. Fork lineage visible on both the original and your version

### "I just need one great agent, not a whole team"

1. Search ClipHub for agent templates: "senior python engineer"
2. Find a well-starred agent config
3. Install just that agent: `paperclipai install cliphub:acme/senior-python-eng --agent`
4. Assign it to a manager in your existing instance
5. Done

---

## Relationship to Paperclip

ClipHub is **not required** to use Paperclip. You can build teams entirely from scratch without ever touching ClipHub. But ClipHub dramatically lowers the barrier to entry:

- **New users** get a working team in minutes instead of hours
- **Experienced users** share proven configurations with the community
- **The ecosystem** compounds — every good template makes the next team easier to build

ClipHub is to Paperclip what a package registry is to a language runtime: optional, but transformative.

---

## V1 Scope

### Must Have

- [ ] Template publishing (upload via CLI or web)
- [ ] Template browsing (list, filter by category)
- [ ] Template detail page (description, org chart, agent list, install command)
- [ ] Semantic search (vector embeddings)
- [ ] `paperclipai install cliphub:<publisher>/<slug>` CLI command
- [ ] GitHub OAuth authentication
- [ ] Stars
- [ ] Download counts
- [ ] Versioning (semver, version history)
- [ ] Basic moderation (community reporting, auto-hide)

### V2

- [ ] Comments / threaded discussion
- [ ] Forking with lineage tracking
- [ ] Agent and team sub-packages
- [ ] Verified publisher badges
- [ ] Automated security scanning of adapter configs
- [ ] "Browse ClipHub" panel in Paperclip web UI
- [ ] `paperclipai cliphub sync` for bulk publishing
- [ ] Publisher profiles and portfolios

### Not in Scope

- Paid / premium templates (everything is free and public, at least initially)
- Private registries (may be a future enterprise feature)
- Running teams on ClipHub (it's a registry, not a runtime — consistent with Paperclip's own philosophy)
