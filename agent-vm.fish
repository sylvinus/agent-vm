#!/usr/bin/env fish
#
# agent-vm: Fish shell wrapper for agent-vm.sh
# 
# Source this file in your Fish config:
#   source /path/to/agent-vm/agent-vm.fish

set -l _avm_file (status --current-filename)
set -g _AGENT_VM_SCRIPT_DIR (dirname (realpath $_avm_file))

function agent-vm
    bash -c "source '$_AGENT_VM_SCRIPT_DIR/agent-vm.sh' && agent-vm \"\$@\"" bash $argv
end
