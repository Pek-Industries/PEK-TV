#!/bin/sh
# Runs the lapsed-plan tests against a real SQLite database (needs Node 22 or newer). From this folder: sh run.sh
cd "$(dirname "$0")" || exit 1
cp ../../cloud/worker.js worker.mjs && cp ../../cloud/billing-worker.js billing.mjs || exit 1
node --no-warnings test_lifecycle.mjs && node --no-warnings test_billing.mjs
