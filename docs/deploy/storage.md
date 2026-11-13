---
title: Storage
summary: Where uploaded files are kept
---

Paperclip stores uploaded files (issue attachments, images) on the server's local disk, at:

```
~/.paperclip/instances/default/data/storage
```

No configuration is required. To change the directory:

```sh
pnpm paperclipai configure --section storage
```

or set `PAPERCLIP_STORAGE_LOCAL_DIR`. The setting is stored in the instance config file:

```
~/.paperclip/instances/default/config.json
```

## Why there is no object storage

Paperclip runs as one server. Every user and agent, local or remote, reaches
files through that server, so its disk is already shared by all of them. An
object store (S3 and compatibles) only helps several servers share files, which
the single-instance model does not support. If the server runs in a container,
put this directory on a persistent volume.
