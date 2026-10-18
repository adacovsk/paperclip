# @paperclipai/ui

Published static assets for the Paperclip operator UI.

## What gets published

The npm package contains the production build under `dist/`. It does not ship the UI source tree or workspace-only dependencies.

## Typical use

Install the package, then serve or copy the built files from `node_modules/@paperclipai/ui/dist`.

## Local development

The server does not read this package. It serves the UI from `server/ui-dist`, falling back to `ui/dist` (`scripts/prepare-server-ui-dist.sh` builds it), and `pnpm dev` at the repo root serves the UI through Vite with the API at `http://localhost:3100`.
