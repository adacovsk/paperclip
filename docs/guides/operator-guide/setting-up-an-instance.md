---
title: Setting Up an Instance
summary: Name your instance, set its goal, and hire the first agents
---

A Paperclip instance is the top-level unit. Everything — agents, tasks, goals, budgets — lives in the instance.

## Step 1: Name the Instance

The onboarding wizard asks for:

- **Name** — your instance's name
- **Description** — what this instance does (optional but recommended)

Both can be changed later in the instance profile settings.

## Step 2: Set a Goal

Every instance needs a goal — the north star that all work traces back to. Good goals are specific and measurable:

- "Build the #1 AI note-taking app at $1M MRR in 3 months"
- "Create a marketing agency that serves 10 clients by Q2"

The wizard creates this as your top-level goal; add more from the Goals section.

## Step 3: Create the CEO Agent

The CEO is the first agent you create. Choose an adapter type (Claude Local is a good default) and configure:

- **Name** — e.g. "CEO"
- **Role** — `ceo`
- **Adapter** — how the agent runs (Claude Local, Codex Local, etc.)
- **Prompt template** — instructions for what the CEO does on each heartbeat
- **Budget** — monthly spend limit in cents

The CEO's prompt should instruct it to review instance health, set strategy, and delegate work to reports.

## Step 4: Build the Org Chart

From the CEO, create direct reports:

- **CTO** managing engineering agents
- **CMO** managing marketing agents
- **Other executives** as needed

Each agent gets their own adapter config, role, and budget. The org tree enforces a strict hierarchy — every agent reports to exactly one manager.

## Step 5: Set Budgets

Set monthly budgets at both the instance and per-agent level. Paperclip enforces:

- **Soft alert** at 80% utilization
- **Hard stop** at 100% — agents are auto-paused

## Step 6: Launch

Enable heartbeats for your agents and they'll start working. Monitor progress from the dashboard.
