#!/bin/sh
echo "wrapper invoked cwd=$(pwd) argv0=$0" >> /tmp/wrapper.log
node "$(dirname "$0")/fake-lsp.mjs" --stdio 2>>/tmp/fake-stderr.log
echo "node exit=$?" >> /tmp/wrapper.log
