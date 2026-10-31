#!/bin/sh
# worker.js = the shared PEK reader (pek-core.js) + the worker (worker-main.js). Run after editing either: sh build.sh
# The website's reader is the SAME file: copy pek-core.js to public/pektv/js/pek.js too.
set -e
cat pek-core.js worker-main.js > ../worker.js
echo "built ../worker.js - now also copy pek-core.js to public/pektv/js/pek.js"
