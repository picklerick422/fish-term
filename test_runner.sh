#!/bin/bash
cd /mnt/linux_share/DevEcoStudioProjects/wand-term
echo "Running node tests..."
node --test tools/verify/fontscale.test.mjs
echo "Exit code: $?"
