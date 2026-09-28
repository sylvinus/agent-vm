#!/usr/bin/env bash
exec bash "$(dirname "$0")/agent-vm.sh" "$([ "${1:-}" = --uninstall ] && echo uninstall || echo install)"
