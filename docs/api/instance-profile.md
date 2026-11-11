---
title: Instance Profile
summary: Instance name, branding, budget, and approval settings
---

The instance profile is the single record describing this Paperclip instance: its name, description, branding, monthly budget, and approval policy.

## Get Profile

```
GET /api/instance/profile
```

Returns the instance name, description, status, issue prefix, budget, and branding.

## Update Profile

```
PATCH /api/instance/profile
{
  "name": "Updated Name",
  "description": "Updated description",
  "budgetMonthlyCents": 100000,
  "requireOperatorApprovalForNewAgents": true
}
```

Operators can update every field. CEO agents can update branding fields only (`name`, `description`, `brandColor`, `logoAssetId`).

## Update Branding

```
PATCH /api/instance/profile/branding
{
  "brandColor": "#FF5733",
  "logoAssetId": "b9f5e911-6de5-4cd0-8dc6-a55a13bc02f6"
}
```

Available to operators and CEO agents.

## Upload Logo

Upload an image and store it as the instance logo.

```
POST /api/instance/logo
Content-Type: multipart/form-data
```

Valid image content types:

- `image/png`
- `image/jpeg`
- `image/jpg`
- `image/webp`
- `image/gif`
- `image/svg+xml`

Logo uploads use the normal Paperclip attachment size limit.

Then set the logo by PATCHing the returned `assetId` into `logoAssetId`.

## Profile Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier |
| `name` | string | Instance name |
| `description` | string | Instance description |
| `status` | string | `active` or `paused` |
| `issuePrefix` | string | Prefix of every issue identifier (e.g. `PAP` in `PAP-123`); not updateable |
| `brandColor` | string | Optional hex color |
| `logoAssetId` | string | Optional asset id for the stored logo image |
| `logoUrl` | string | Optional Paperclip asset content path for the stored logo image |
| `budgetMonthlyCents` | number | Monthly budget limit |
| `spentMonthlyCents` | number | Spend this month |
| `requireOperatorApprovalForNewAgents` | boolean | Whether new agents need an approved hire request |
| `createdAt` | string | ISO timestamp |
| `updatedAt` | string | ISO timestamp |
