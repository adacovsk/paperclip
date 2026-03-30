#!/bin/bash
# Resume all agents — run at 4pm MST via cron
API="http://127.0.0.1:3100/api"
for id in 187c9900-9815-447d-b5e6-d73e9e4f56ed 768f05e2-8b15-4710-a343-5fd2f73ed17f 13ec49e3-7dd6-47c0-aed4-5d24d7a53937 b90fa486-644e-4300-8a76-b2e274f58812 49634ba2-e434-4520-a440-e4f843aca9d2; do
  curl -s -X POST "$API/agents/$id/resume" -H 'Content-Type: application/json' -d '{}' > /dev/null 2>&1
done
echo "$(date): All agents resumed"
