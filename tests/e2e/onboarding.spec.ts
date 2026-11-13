import { test, expect } from "@playwright/test";

/**
 * E2E: Onboarding wizard flow (skip_llm mode).
 *
 * Walks through the 4-step OnboardingWizard:
 *   Step 1 — Name your instance (instance name + optional first goal)
 *   Step 2 — Create your first agent (adapter selection + config)
 *   Step 3 — Give it something to do (task creation)
 *   Step 4 — Ready to launch (summary + open issue)
 *
 * By default this runs in skip_llm mode: we do NOT assert that an LLM
 * heartbeat fires. Set PAPERCLIP_E2E_SKIP_LLM=false to enable LLM-dependent
 * assertions (requires a valid ANTHROPIC_API_KEY).
 */

const SKIP_LLM = process.env.PAPERCLIP_E2E_SKIP_LLM !== "false";

const INSTANCE_NAME = `E2E-Test-${Date.now()}`;
const GOAL_TITLE = `E2E goal ${Date.now()}`;
const AGENT_NAME = "CEO";
const TASK_TITLE = "E2E test task";

test.describe("Onboarding wizard", () => {
  test("completes full wizard flow", async ({ page }) => {
    await page.goto("/onboarding");

    await expect(
      page.locator("h3", { hasText: "Name your instance" })
    ).toBeVisible({ timeout: 15_000 });

    const instanceNameInput = page.locator('input[placeholder="My Paperclip"]');
    await instanceNameInput.fill(INSTANCE_NAME);

    const goalInput = page.locator(
      'textarea[placeholder="What should this instance achieve?"]'
    );
    await goalInput.fill(GOAL_TITLE);

    await page.getByRole("button", { name: "Next" }).click();

    await expect(
      page.locator("h3", { hasText: "Create your first agent" })
    ).toBeVisible({ timeout: 10_000 });

    const agentNameInput = page.locator('input[placeholder="CEO"]');
    await expect(agentNameInput).toHaveValue(AGENT_NAME);

    await expect(
      page.locator("button", { hasText: "Claude Code" }).locator("..")
    ).toBeVisible();

    await page.getByRole("button", { name: "More Agent Adapter Types" }).click();
    await expect(page.getByRole("button", { name: "Process" })).toHaveCount(0);

    await page.getByRole("button", { name: "Next" }).click();

    await expect(
      page.locator("h3", { hasText: "Give it something to do" })
    ).toBeVisible({ timeout: 10_000 });

    const taskTitleInput = page.locator(
      'input[placeholder="e.g. Research competitor pricing"]'
    );
    await taskTitleInput.clear();
    await taskTitleInput.fill(TASK_TITLE);

    await page.getByRole("button", { name: "Next" }).click();

    await expect(
      page.locator("h3", { hasText: "Ready to launch" })
    ).toBeVisible({ timeout: 10_000 });

    // Scoped to the summary: the instance name is also in the sidebar and the
    // page heading, and an unscoped text locator fails strict mode on three
    // matches.
    const summary = page.getByTestId("launch-summary");
    await expect(summary.getByText(INSTANCE_NAME, { exact: true })).toBeVisible();
    await expect(summary.getByText(AGENT_NAME, { exact: true })).toBeVisible();
    await expect(summary.getByText(TASK_TITLE, { exact: true })).toBeVisible();

    await page.getByRole("button", { name: "Create & Open Issue" }).click();

    await expect(page).toHaveURL(/\/issues\//, { timeout: 10_000 });

    const baseUrl = page.url().split("/").slice(0, 3).join("/");

    const profileRes = await page.request.get(`${baseUrl}/api/instance/profile`);
    expect(profileRes.ok()).toBe(true);
    const profile = await profileRes.json();
    expect(profile.name).toBe(INSTANCE_NAME);

    const goalsRes = await page.request.get(`${baseUrl}/api/goals`);
    expect(goalsRes.ok()).toBe(true);
    const goals = await goalsRes.json();
    const goal = goals.find(
      (g: { title: string }) => g.title === GOAL_TITLE
    );
    expect(goal).toBeTruthy();
    expect(goal.level).toBe("instance");

    const agentsRes = await page.request.get(`${baseUrl}/api/agents`);
    expect(agentsRes.ok()).toBe(true);
    const agents = await agentsRes.json();
    const ceoAgent = agents.find(
      (a: { name: string }) => a.name === AGENT_NAME
    );
    expect(ceoAgent).toBeTruthy();
    expect(ceoAgent.role).toBe("ceo");
    expect(ceoAgent.adapterType).not.toBe("process");

    const instructionsBundleRes = await page.request.get(
      `${baseUrl}/api/agents/${ceoAgent.id}/instructions-bundle`
    );
    expect(instructionsBundleRes.ok()).toBe(true);
    const instructionsBundle = await instructionsBundleRes.json();
    expect(
      instructionsBundle.files.map((file: { path: string }) => file.path).sort()
    ).toEqual(["AGENTS.md"]);

    const issuesRes = await page.request.get(`${baseUrl}/api/issues`);
    expect(issuesRes.ok()).toBe(true);
    const issues = await issuesRes.json();
    const task = issues.find(
      (i: { title: string }) => i.title === TASK_TITLE
    );
    expect(task).toBeTruthy();
    expect(task.assigneeAgentId).toBe(ceoAgent.id);
    expect(task.goalId).toBe(goal.id);

    // The list projection nulls `description` on purpose (see `issueListColumns`
    // in server/src/services/issues.ts) — a list row's NULL body says nothing
    // about whether the issue has one. Read the body from the detail route.
    const taskDetailRes = await page.request.get(`${baseUrl}/api/issues/${task.id}`);
    expect(taskDetailRes.ok()).toBe(true);
    const taskDetail = await taskDetailRes.json();
    expect(taskDetail.description).toContain(
      "You are the CEO. You set the direction for the instance."
    );

    if (!SKIP_LLM) {
      await expect(async () => {
        const res = await page.request.get(
          `${baseUrl}/api/issues/${task.id}`
        );
        const issue = await res.json();
        expect(["in_progress", "done"]).toContain(issue.status);
      }).toPass({ timeout: 120_000, intervals: [5_000] });
    }
  });
});
