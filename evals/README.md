# Paperclip Evals

Eval framework for testing Paperclip agent behaviors across models and prompt versions.

See [the evals framework plan](../doc/plans/2026-03-13-agent-evals-framework.md) for full design rationale.

## Quick Start

### Prerequisites

`pnpm evals:smoke` runs a pinned promptfoo through `npx`, so nothing needs installing. To run `promptfoo` directly, install it first (`pnpm add -g promptfoo`).

You need an API key for at least one provider. Set one of:

```bash
export OPENROUTER_API_KEY=sk-or-...    # OpenRouter (recommended - test multiple models)
export ANTHROPIC_API_KEY=sk-ant-...     # Anthropic direct
export OPENAI_API_KEY=sk-...            # OpenAI direct
```

### Run evals

```bash
# Smoke test (default models)
pnpm evals:smoke

# Or run promptfoo directly
cd evals/promptfoo
promptfoo eval

# View results in browser
promptfoo view
```

### What's tested

Phase 0 covers narrow behavior evals for the Paperclip heartbeat skill:

| Case | Category | What it checks |
|------|----------|---------------|
| Assignment pickup | `core` | Agent picks up todo/in_progress tasks correctly |
| Progress update | `core` | Agent writes useful status comments |
| Blocked reporting | `core` | Agent recognizes and reports blocked state |
| Approval required | `governance` | Agent requests approval instead of acting |
| Company boundary | `governance` | Agent refuses cross-company actions |
| No work exit | `core` | Agent exits cleanly with no assignments |
| Checkout before work | `core` | Agent always checks out before modifying |
| 409 conflict handling | `core` | Agent stops on 409, picks different task |

### Adding new cases

1. Add an entry to `evals/promptfoo/tests/core.yaml` or `evals/promptfoo/tests/governance.yaml` (the config loads `tests/*.yaml`, so a new file there works too)
2. Follow the existing entries' format (`core.assignment_pickup` is a short one)
3. Run `pnpm evals:smoke` to test

### Phases

- **Phase 0 (current):** Promptfoo bootstrap - narrow behavior evals with deterministic assertions
- **Phase 1:** TypeScript eval harness with seeded scenarios and hard checks
- **Phase 2:** Pairwise and rubric scoring layer
- **Phase 3:** Efficiency metrics integration
- **Phase 4:** Production-case ingestion
