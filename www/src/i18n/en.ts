// English copy. `fr.ts` mirrors this shape exactly, typed against it, so a
// missing or renamed key is a build error rather than a silent fallback.
//
// Shell commands are not translated: they are the same on every machine.
// Only prose, labels and descriptions live here.
//
// House style: say what the thing does. No slogans, no absolutes the code
// cannot back up ("cannot escape", "nothing leaves"), no sentence whose job
// is to sound good.

export const en = {
  meta: {
    lang: 'en',
    label: 'English',
    title: 'agent-vm | a disposable Linux VM per project for AI coding agents',
    description:
      'agent-vm gives every project its own Linux VM and runs the coding agent there with permissions bypassed. Your SSH keys, your browser sessions and the rest of your disk are invisible to it. Built on Lima. MIT.',
    skipToContent: 'Skip to content',
  },

  nav: {
    sections: {
      install: 'Install',
      usage: 'Usage',
      architecture: 'Architecture',
      contribute: 'Contribute',
      credits: 'Credits',
    },
    github: 'GitHub',
    menu: 'Menu',
    language: 'Language',
  },

  hero: {
    title: 'Give agents a machine they can wreck.',
    titleAccent: 'Keep yours.',
    lede:
      'AI coding agents need broad permissions to be useful: they install dependencies, run builds, start servers. agent-vm gives each project its own Linux VM and runs the agent in there instead. Your SSH keys, your browser sessions and the rest of your disk are invisible to it.',
    installLabel: 'Get started',
    ctaPrimary: 'Install it',
    ctaSecondary: 'How it works',
    meta: 'MIT licensed · macOS and Linux · built on Lima',
    terminalCaption:
      'Only the project directory is mounted. One VM per directory, created on first use and reused afterwards.',
    points: [
      {
        title: 'Lima is the only host dependency',
        body: 'No Node, no npm, no Docker Desktop on your machine: the toolchain lives in the VM. On Linux, Lima also needs QEMU and access to KVM.',
      },
      {
        title: 'A separate kernel, not a namespace',
        body: 'On Linux, escaping a container puts you on the host. Escaping a VM means getting through the hypervisor first.',
      },
      {
        title: 'Ports are forwarded for you',
        body: 'A dev server started in the VM answers on localhost at the same port. Lima does it; there is no flag and no config.',
      },
      {
        title: 'Five agents, one command',
        body: 'OpenCode, Claude Code, Codex CLI and Mistral Vibe, each launched with its own auto-approve flag. Pi, opt-in, never asks in the first place.',
      },
    ],
  },

  threat: {
    eyebrow: 'Why this exists',
    title: 'Why not just run the agent on your machine?',
    lede:
      'Every agent has a flag that turns approvals off, and many people run them that way. When that happens in your home directory, three things can go wrong.',
    reasons: [
      {
        title: 'Dependency installs run arbitrary code',
        body: 'Every `npm install` executes third-party install scripts before anyone has read them. In 2025 the Shai-Hulud worm used that to spread through thousands of npm packages: it collected npm tokens, GitHub PATs, SSH keys and cloud credentials, then republished itself using them. Nothing about the installs looked unusual.',
      },
      {
        title: 'Approval prompts stop working',
        body: 'The alternative is approving each command by hand. After the first few dozen prompts the answer is reflexive, and the one that mattered gets the same yes as the rest. That is why the bypass flag exists, and why it gets used.',
      },
      {
        title: 'The agent is not reliable either',
        body: 'No compromised package needed. Agents read issues, web pages and READMEs, and anything they read can try to give them instructions. They also make plain mistakes: the wrong path, a `git checkout .` over uncommitted work.',
      },
    ],
    closing:
      'A VM limits what a mistake or a compromised agent can reach: your source tree and whatever you put in [its env file](#share-secrets-across-vms), but not your SSH keys, your git credentials or your browser session. [`--readonly`](#tighten-the-session) narrows it further, and the host enforces it, so root in the guest cannot lift it. The shared project is guarded too: with a Lima that has `sshfs.readonlyNames`, every `.git` in it is read-only for the VM, so the agent cannot plant a hook or a config that git on your host would then run (see [Protecting .git](#git) below). What stays open is the network: the agent can send data anywhere, and Lima puts your host loopback at `192.168.5.2`, so a dev database listening on localhost is reachable from the VM.',
  },

  install: {
    eyebrow: 'Install',
    title: 'Install, build a template, run an agent.',
    lede:
      'agent-vm is a few shell scripts, with no daemon. To remove it: `agent-vm destroy-all`, `agent-vm uninstall` (or `brew uninstall agent-vm`), then delete its directory and `~/.agent-vm`.',
    prerequisitesTitle: 'Prerequisites',
    prerequisites: [
      { name: 'macOS or Linux', note: 'Windows is not supported.', href: '' },
      {
        name: 'Lima',
        note: 'agent-vm setup offers to install it with Homebrew, as a build that keeps `.git` read-only until that is merged upstream. On Linux, QEMU and KVM too.',
        href: 'https://lima-vm.io/docs/installation/',
      },
      {
        name: 'An agent subscription or API key',
        note: 'Authentication happens inside the VM, per VM.',
        href: '',
      },
    ],
    methodsTitle: 'Install the command',
    methodsBody: 'Pick one. Each puts `agent-vm` on your `PATH` without root.',
    methodsLabel: 'Install method',
    methods: [
      {
        id: 'curl',
        label: 'curl',
        code: 'curl -fsSL https://www.agent-vm.org/install.sh | sh',
        note: 'Downloads the latest release from GitHub, checks it against the release’s `SHA256SUMS`, unpacks it in `~/.local/share/agent-vm` and links `agent-vm` into `~/.local/bin`. It also offers to source it from your shell rc, then to run step 2 right away. Run it again to update. `sh -s -- --version X.Y.Z` installs a given release, `sh -s -- --git` a clone of `main`.',
      },
      {
        id: 'brew',
        label: 'Homebrew',
        code: 'brew install sylvinus/tap/agent-vm',
        note: 'macOS, or Linux with Homebrew. `brew upgrade agent-vm` updates it.',
      },
      {
        id: 'git',
        label: 'git',
        code: 'git clone https://github.com/sylvinus/agent-vm.git\ncd agent-vm && ./agent-vm.sh install',
        note: '`install` symlinks `agent-vm` onto your `PATH`, so `git pull` in the clone is the update. It also offers to source it from your shell rc, then to run step 2 right away.',
      },
    ],
    steps: [
      {
        title: 'Build the base template',
        body: 'Run once. It first checks that Lima can keep `.git` read-only for the VMs, and offers to install a Lima build that can if not. It also asks to set `safe.bareRepository` in your git config (see [Protecting .git](#git)). Then it creates a Debian 13 VM, installs the toolchain and the agents, and keeps it, stopped, as a reusable template. The wizard offers a default set; press Enter to accept it.',
        code: 'agent-vm setup',
      },
      {
        title: 'Run an agent in your project',
        body: 'Clones the template into a VM for this directory, mounts the working directory, launches the agent with permissions already granted.',
        code: 'cd your-project\nagent-vm opencode     # or: agent-vm claude',
      },
    ],
    preinstallTitle: 'Choosing what goes in the template',
    preinstallBody:
      'Lowercase, comma-separated. `default` is everything except Ruby, Rust, Go, Pi and the Playwright MCP. `all` is everything, `none` is nothing. `codex` and `pi` pull in `node`, and so does `mcp-chrome` when `chromium` and an agent are selected, because those installs use `npm` and `npx`. Both MCP servers are skipped without `node` and `chromium`. With no terminal attached, the wizard is skipped and the default set is installed. `setup` also takes `--disk`, `--memory` and `--cpus` for the template itself.',
    preinstallNames:
      'python · node · ruby · rust · golang · docker · chromium · gh · claude · opencode · codex · vibe · pi · mcp-chrome · mcp-playwright',
    preinstallCode:
      'agent-vm setup                                       # interactive wizard\nagent-vm setup --preinstall=default                  # no prompts\nagent-vm setup --preinstall=default,rust             # plus Rust\nagent-vm setup --preinstall=python,docker,claude     # minimal Claude setup\nagent-vm setup --preinstall=node,chromium,opencode   # no MCP wired in\nagent-vm setup --disk 50 --memory 16 --cpus 8        # heavier workloads',
    setupHeaders: ['Flag', 'What it does', 'Default'],
    setup: [
      ['--disk GB', 'Base template disk size.', '10'],
      ['--memory GB', 'Base template memory.', '3'],
      ['--cpus N', 'Base template CPU count.', '1'],
      ['--preinstall=LIST', 'Install only this comma-separated subset. Skips the wizard.', 'wizard'],
    ],
    updateTitle: 'Updating',
    updateBody:
      'Installed with curl: run the installer again. With Homebrew: `brew upgrade agent-vm`. From a clone: `git pull`, nothing to reinstall. `agent-vm uninstall` removes the link that curl and git installs make.',
  },


  usage: {
    eyebrow: 'Usage',
    title: 'Everyday commands.',
    lede:
      'Every VM is keyed to a directory. Run an agent command twice in the same folder and you get the same machine back, with its packages, its containers and its logins intact.',
    cards: [
      {
        title: 'Run an agent',
        body: 'Extra arguments are forwarded to the agent as-is, so anything its own CLI accepts works here.',
        code: 'agent-vm opencode                        # OpenCode\nagent-vm claude                          # Claude Code\nagent-vm codex                           # Codex CLI\nagent-vm vibe                            # Mistral Vibe\n\nagent-vm claude -p "fix all lint errors"\nagent-vm opencode run "update the changelog"',
      },
      {
        title: 'Reach the dev server',
        body: 'Lima forwards ports opened inside the VM to the host. Start a server from the agent or from a shell and it answers on localhost at the same port, in your browser. It also means that anything the agent listens on inside the VM shows up on your own localhost: treat those ports as the agent’s.',
        code: 'agent-vm run npm run dev   # then open localhost:5173\nagent-vm shell             # same for docker compose up',
      },
      {
        title: 'Get inside',
        body: 'A shell to poke around, or a single command when you already know what you want.',
        code: 'agent-vm shell                    # zsh in the VM\nagent-vm run npm install          # one-off command\nagent-vm run --tty opencode       # allocate a PTY for TUIs\nagent-vm sh -c "ls -la | grep config"',
      },
      {
        title: 'Connect an IDE over SSH',
        body: 'VS Code Remote-SSH, JetBrains Gateway or a GUI agent can keep their window on the host and run the rest in the VM. Lima writes an SSH config per VM with the current port, under the alias `agent-vm info` prints as `ssh_host`. Put the lines below at the top of `~/.ssh/config`, above any `Host *`: ssh takes the first value it finds, and a `ForwardAgent yes` there would hand the VM every key in your SSH agent. For a tool that saves the port instead of the alias, `--ssh-port` fixes it (`0` goes back to a new one on each start).',
        code: '# top of ~/.ssh/config\nInclude ~/.lima/*/ssh.config\nHost lima-agent-vm-*\n  ForwardAgent no\n  ForwardX11 no\n\nagent-vm info | grep ^ssh_host   # the alias to use\nagent-vm --ssh-port 2222 shell   # a fixed port',
      },
      {
        title: 'Manage the fleet',
        body: 'The current directory is marked with `>` in `status`. If a directory is renamed, `list` is the only way to find its VM again.',
        code: 'agent-vm status        # all VMs, current one marked\nagent-vm list          # names only\nagent-vm stop          # stop, keep the disk\nagent-vm rm            # stop and delete\nagent-vm destroy-all   # every VM, base template included\nagent-vm doctor        # what is wrong, and what to run',
      },
      {
        title: 'Tighten the session',
        body: 'Useful for review and audit work, where the agent has no business writing anything. `--readonly` makes every host share read-only: the project and the [`~/.agent-vm/volumes`](#customisation-files) entries, `rw` ones included, since a writable volume containing the project would be a second way in. It is set on the Lima shares, so the host refuses the writes (the hypervisor, or Lima’s SFTP server on the shares that protect `.git`) and root in the VM cannot lift it. Where Lima would only apply it inside the guest, agent-vm refuses the flag: `reverse-sshfs` without `readonlyNames`, and virtiofs under QEMU. Changing the mode restarts the VM. The VM’s own disk, `$HOME` and `/tmp` stay writable, so the agent can still install packages and write caches. Anything it writes inside the project fails, including `node_modules`, its own state directory, and whatever a runtime script writes: the mode is applied before those run.',
        code: 'agent-vm --readonly shell     # nothing on the host is writable\nagent-vm --rm run npm test    # destroy the VM on exit',
      },
      {
        title: 'Resize on the fly',
        body: 'Defaults are 10 GB of disk, 3 GB of memory and 1 CPU. Pass the flag again and the VM is stopped, reconfigured and restarted. Disk can grow, never shrink. CPU and memory are clamped to half the host per VM, which is not a budget across all of them: VMs persist, so several running at once add up. `agent-vm status` shows what you have, `rm` and `destroy-all` reclaim it.',
        code: 'agent-vm --disk 50 opencode\nagent-vm --memory 16 --cpus 8 shell\nagent-vm --reset claude   # re-clone from the base template',
      },
      {
        title: 'Share secrets across VMs',
        body: 'Plain `KEY=value` lines in `~/.agent-vm/env`, pushed into every VM on every invocation and loaded in its shells. Use the subcommands rather than editing the file by hand: a shell sources it, so one unescaped quote breaks every secret in the file, not just that line.',
        code: 'agent-vm env set GH_TOKEN github_pat_xxxx\nagent-vm env list              # names only, never values\nagent-vm env has ANTHROPIC_API_KEY\n\n# scoped to this project only\nagent-vm project-env set SOME_PATH ./config',
      },
      {
        title: 'Ask from a script',
        body: 'If you wrap agent-vm from another tool, use these rather than parsing human-facing output or reading `~/.agent-vm` directly: VM naming, the template name and the state files are implementation details and will change. `version --min` exits `0` when the engine is recent enough, `1` with a message when it is older, and `2` when the call itself is malformed, so a typo in the required version cannot read as "engine too old". One catch: an engine predating `--min` ignores the flag and exits `0`. In `info`, booleans are `1` or `0` and anything undeterminable reads `unknown`; all four commands work without Lima installed.',
        code: 'agent-vm version --min 0.2.0 || exit 1  # silent when OK\nagent-vm name [dir]    # VM name for a directory\nagent-vm info [dir]    # one key=value per line\nagent-vm help          # the built-in help\n\n# info keys: version, template, state_dir,\n# project_env, dir, vm_name, base_exists,\n# vm_exists, vm_running, vm_stale,\n# ssh_host, ssh_config',
      },
    ],
    customTitle: 'Customisation files',
    customLede:
      'Six optional files, none of them needed to get started. The per-user ones sit in `~/.agent-vm/`, the per-project ones in the project itself.',
    customTable: {
      headers: ['File', 'Scope', 'Runs when'],
      rows: [
        ['~/.agent-vm/env', 'All VMs', 'Pushed in on every invocation'],
        ['~/.agent-vm/volumes', 'All VMs, or the projects an entry names', 'Mounted at VM creation'],
        ['~/.agent-vm/setup.sh', 'Base template', 'Once, during agent-vm setup'],
        ['~/.agent-vm/runtime.sh', 'All VMs', 'Every command that enters a VM, first'],
        ['.agent-vm.runtime.sh', 'Single project', 'Every command that enters its VM, after the global one'],
        ['.agent-vm.env', 'Single project', 'Pushed in after the shared env, so it wins'],
      ],
    },
    volumesTitle: 'Extra mounts: ~/.agent-vm/volumes',
    volumesBody:
      'One `source[:destination][:mode][:project]` per line, `~` expanded on the left, `#` for comments. The mode is `ro` (default) or `rw`, and `rw` only works for directories. Without a destination, the path is mounted at the same place in the VM. A relative destination is inside the project, over whatever the project has there. The fourth field, after an explicit mode, limits the entry to the projects it matches, `*` matching anything.',
    volumesCode:
      '# ~/.agent-vm/volumes\n~/.gitconfig    # same path, read-only\n~/.cache/shared:/home/you.guest/.cache/shared:rw\n\n# only in ~/work/webapp, as its .claude, read-only\n~/.claude-vm/webapp:.claude:ro:~/work/webapp\n\n# every project under ~/work\n~/.cache/pip:/home/you.guest/.cache/pip:rw:~/work/*',
    volumesNote:
      'Kept on your side and not in the project on purpose: the agent can write the project, and a mount list there would let it mount any host directory into its own VM. For the same reason, a relative destination that leaves the project with `..` or goes through a symlink in it is skipped. agent-vm creates a missing mount point in the project on your machine, so an empty `.claude` shows up there too. Changes apply to new VMs: `--reset` re-applies them.',
    gitTitle: 'Letting the agent commit',
    gitBody:
      'git reads its identity from the environment, so the shared env file covers it with no `git config` inside the VM. All four variables are needed: git refuses to commit without a committer, not just an author.',
    gitCode:
      '# ~/.agent-vm/env\nGIT_AUTHOR_NAME=Your Name\nGIT_AUTHOR_EMAIL=12345+you@users.noreply.github.com\nGIT_COMMITTER_NAME=Your Name\nGIT_COMMITTER_EMAIL=12345+you@users.noreply.github.com',
    gitNote:
      '`gh` picks up `GH_TOKEN` on its own, so `gh pr create` works with nothing else. Plain `git push` over HTTPS needs a credential helper: one `gh auth setup-git` line in your [runtime script](#customisation-files).',
    gitHumanTitle: 'That said, keep the commits human',
    gitHumanBody:
      'Being able to commit is not a reason to let it. A commit says you read the diff, so let the agent write the code, read it, and commit it yourself. With a Lima that [keeps `.git` read-only](#git), that is the only way: the agent cannot commit in the shared project, unless you turn the protection off, which gives it a way to run commands on your host.',
    gitGuardTitle: 'Protecting .git',
    gitGuardBody:
      'Git on your machine runs what a repository’s `.git/config` and hooks name: `core.fsmonitor` on every `git status`, hooks on commit. Your editor and shell prompt run `git status` on their own, so a VM able to write `.git` could run commands on your host within seconds, and nothing of it would show in `git diff`. With a Lima that has `sshfs.readonlyNames`, every `.git` in the shares is read-only for the VM, at any depth, and Lima’s SFTP server enforces it on the host: the agent reads the history but cannot commit. It is not merged upstream yet ([lima-vm/lima#5529](https://github.com/lima-vm/lima/issues/5529)), so `agent-vm setup` offers a build that has it. The shares then use `reverse-sshfs`, slower on many files (see [Node.js](#node)).',
    gitGuardCode:
      'brew unlink lima; brew install sylvinus/tap/lima-sylvinus\nagent-vm doctor                          # where you stand\nagent-vm --unsafe-writable-git claude    # let it commit anyway\n# no Homebrew: build github.com/sylvinus/lima',
    gitGuardNote:
      'Existing VMs switch on their next start: `agent-vm stop` a running one. The `.git` name is not the only way in: a folder the VM fills with git’s internal files (`HEAD`, `objects/`, `refs/`, a `config`) is a repository to git under any name, and git on your machine runs the commands its `config` names when you use git in that folder: the one set to display output, for example, as soon as you type `git log`. `git config --global safe.bareRepository explicit` makes git ignore such folders: `agent-vm setup` asks to set it, and `doctor` warns while it is not. `--unsafe-writable-git`, or `AGENT_VM_UNSAFE_WRITABLE_GIT=1` in your shell, turns the protection off so the agent can commit, and reopens that path to your host: a warning says so on every run.',
    gitGuardEditor:
      'Your editor is the same kind of door. The agent can write a `.vscode/tasks.json`, workspace settings, an `eslint.config.js` or a `build.rs`, which VS Code and its extensions can run. When VS Code asks, leave the project untrusted (Restricted Mode), and do not trust a parent folder: that trusts everything below it. JetBrains IDEs have the same choice (Safe Mode).',
    nodeTitle: 'Node.js: node_modules in the VM',
    nodeBody:
      'Hundreds of thousands of files are slow across the share, and native packages differ between macOS and Linux anyway. Mount a folder of the VM’s own disk over `node_modules` from the project’s [runtime script](#customisation-files), which runs on every command:',
    nodeCode:
      '#!/bin/bash\n# .agent-vm.runtime.sh\nset -e\nmkdir -p "$HOME/node_modules" node_modules\nmountpoint -q node_modules ||\n  sudo mount --bind "$HOME/node_modules" node_modules',
    nodeNote: 'The host sees an empty `node_modules`, or keeps its own: install there too if your editor needs the packages. `--reset` and `rm` delete the VM’s copy. A dev server in the VM may need polling to see edits made on the host (Vite: `server.watch.usePolling`).',
    refTitle: 'Every command',
    refNote: 'Call the command, do not source the file: a shell function is not inherited by child processes, so a tool that spawns a shell cannot see one.',
    commandGroups: [
      {
        title: 'Run an agent',
        rows: [
          ['opencode [args]', 'Run OpenCode with `--auto`.'],
          ['claude [args]', 'Run Claude Code with `--dangerously-skip-permissions`.'],
          ['codex [args]', 'Run Codex CLI with `--dangerously-bypass-approvals-and-sandbox`.'],
          ['vibe [args]', 'Run Mistral Vibe with `--agent auto-approve`.'],
          ['pi [args]', 'Run Pi, which has no permission prompts. Opt-in at setup.'],
        ],
      },
      {
        title: 'Get inside',
        rows: [
          ['shell, sh', 'Open a zsh shell in the VM. `-c "…"` runs a one-shot command through a login shell.'],
          ['run <cmd> [args]', 'Run a command with no shell. `--tty` allocates a PTY for TUIs.'],
        ],
      },
      {
        title: 'Manage the fleet',
        rows: [
          ['status', 'Status of all VMs, current directory marked with `>`.'],
          ['list', 'List all agent-vm VMs.'],
          ['stop [vm-name]', 'Stop this directory’s VM, or the named one. The disk survives.'],
          ['rm [vm-name]', 'Stop and delete. A name from `list` reaches a VM whose directory is gone.'],
          ['destroy-all', 'Stop and delete every agent-vm VM, the base template included. `setup` rebuilds it.'],
          ['doctor', 'Check the host, Lima, the base template and this directory, and say what to run. Changes nothing.'],
        ],
      },
      {
        title: 'Set up and configure',
        rows: [
          ['install', 'Put `agent-vm` on your `PATH`, from the clone: `./agent-vm.sh install`. The curl installer runs it for you.'],
          ['uninstall', 'Remove that link. VMs and `~/.agent-vm` stay.'],
          ['setup', 'Create the base VM template. Run once.'],
          ['env <sub>', '`set`, `get`, `has`, `unset`, `list` on the secrets shared by every VM.'],
          ['project-env <sub>', 'Same subcommands, scoped to this project. Wins over the shared file.'],
          ['help', 'Show the built-in help.'],
        ],
      },
      {
        title: 'Ask, from a script',
        rows: [
          ['version', 'Print the version. `--min X.Y.Z` checks it instead of printing it.'],
          ['info [dir]', 'Machine-readable state, one `key=value` per line.'],
          ['name [dir]', 'Print the VM name for a directory. Defaults to the working directory.'],
        ],
      },
    ],
    optionsTitle: 'VM options',
    optionsNote: 'For `claude`, `opencode`, `codex`, `vibe`, `pi`, `shell` and `run`, placed before the command or right after its name. Anything later belongs to the command: in `agent-vm run docker run --rm x`, `--rm` is docker’s.',
    optionsHeaders: ['Flag', 'What it does', 'Default'],
    options: [
      ['--disk GB', 'VM disk size. Can grow, never shrink.', '10'],
      ['--memory GB', 'VM memory. Clamped to half the host, per VM.', '3'],
      ['--cpus N', 'CPU count. Clamped to half the host, per VM.', '1'],
      ['--ssh-port N', 'Fixed host port for the VM’s SSH, for tools that save it. `0` goes back to a new one on each start. Restarts the VM.', 'a new one per start'],
      ['--reset', 'Destroy and re-clone the VM from the base template.', 'off'],
      ['--readonly', 'Every host share read-only (project and volumes), host-side. Restarts the VM.', 'off'],
      ['--unsafe-writable-git', 'Leave every `.git` writable so the agent can commit, with a warning. See [Protecting .git](#git).', 'off'],
      ['--rm', 'Destroy the VM once the command exits.', 'off'],
    ],
  },



  architecture: {
    eyebrow: 'Architecture',
    title: 'A template, then a clone per directory.',
    lede:
      'Setup pays the provisioning cost once. Every project after that is a clone of a VM that already has the toolchain in it.',
    steps: [
      {
        n: '01',
        title: 'setup builds the template',
        body: 'Lima creates a Debian 13 VM. `agent-vm.setup.sh` installs the dev tools, Docker, Chromium and the agents inside it, then the VM is stopped and kept as a base template.',
      },
      {
        n: '02',
        title: 'The first run clones it',
        body: 'Running an agent in a directory clones the template into a persistent VM keyed to that path, mounts the working directory, and runs the [runtime scripts](#customisation-files): the per-user one first, the per-project one second.',
      },
      {
        n: '03',
        title: 'The agent works unattended',
        body: 'It is launched with its own auto-approve flag. Lima forwards the ports it opens inside the VM, so a dev server is reachable in your browser as usual.',
      },
      {
        n: '04',
        title: 'The VM outlives the session',
        body: 'It persists after the agent exits. Any later command in the same directory reuses it, with its containers and its logins intact, until `rm` or `--rm`.',
      },
    ],
    diagram: {
      hostTitle: 'Your machine',
      hostItems: ['SSH keys', 'API tokens', 'Browser sessions', 'git config', 'Everything else'],
      hostNote: 'Only Lima installed',
      boundaryLabel: 'Hypervisor boundary',
      vmTitle: 'The VM',
      vmItems: ['The agent', 'node, python, docker, ...', 'Headless Chromium, ...', 'Ports, forwarded out'],
      vmNote: 'Separate kernel',
      sharedLabel: 'Shared',
      sharedTitle: '~/work/your-project',
      sharedBody:
        'Your project directory, mounted into the VM at the same path. Your editor and the agent work on the same files, so there is nothing to copy back. Read-write by default, read-only with `--readonly`. Anything else that crosses is something you chose: the env file, and extra mounts listed in `~/.agent-vm/volumes`.',
    },
    isolationNote:
      'Each VM authenticates on its own: `claude login` happens inside it. Credentials persist across restarts of that VM and are shared with neither the host nor any other VM.',
    contentsTitle: 'What is in the VM',
    contentsLede:
      'The wizard’s default install and `--preinstall=default` produce the same set: everything below except the opt-in languages.',
    contentsHeaders: ['Category', 'Packages', 'Name', 'Default'],
    contents: [
      ['Core', 'git, curl, wget, jq, zsh, build-essential, ripgrep, fd-find, htop', 'always', 'yes'],
      ['Build libs', 'libssl-dev, libreadline-dev, zlib1g-dev, libyaml-dev, libffi-dev', 'always', 'yes'],
      ['Version manager', 'mise', 'always', 'yes'],
      ['Python', 'python3, pip, venv', 'python', 'yes'],
      ['Node.js', 'Node.js 24 LTS via NodeSource', 'node', 'yes'],
      ['Ruby', 'ruby-full', 'ruby', 'no'],
      ['Rust', 'rustup, stable toolchain', 'rust', 'no'],
      ['Go', 'golang-go', 'golang', 'no'],
      ['GitHub CLI', 'gh', 'gh', 'yes'],
      ['Browser', 'Chromium headless, xvfb', 'chromium', 'yes'],
      ['Containers', 'Docker Engine, Docker Compose', 'docker', 'yes'],
      ['AI agents', 'Claude Code, OpenCode, Codex CLI, Mistral Vibe', 'claude, opencode, codex, vibe', 'yes'],
      ['AI agents', 'Pi', 'pi', 'no'],
      ['MCP', 'Chrome DevTools MCP, wired into every installed agent but Pi (no MCP support)', 'mcp-chrome', 'yes'],
      ['MCP', 'Playwright MCP, reusing the same Chromium', 'mcp-playwright', 'no'],
    ],
    contentsNote:
      'This is only what the template ships, so a first run is not spent downloading a toolchain. The agent is root in the VM and has the network, so it installs whatever else it needs: `apt install`, `pip`, `cargo`, a language runtime that is not on the list.',
    dockerTitle: 'Why not Docker',
    dockerLede:
      'On Linux, containers share the host kernel, so a compromised dependency that finds a kernel bug is on your host. On macOS, Docker Desktop already runs a VM, which narrows the gap, but it is one VM shared by every container rather than one per project. A VM brings its own kernel, and root inside it still has the hypervisor between it and your machine. The practical differences matter as much as the security one.',
    dockerHeaders: ['', 'No sandbox', 'Docker / devcontainer', 'agent-vm'],
    docker: [
      ['Agent can run any command', 'Yes', 'Yes', 'Yes'],
      ['Host files it can reach', 'All of them', 'What you mount', 'The project directory'],
      [
        'git credentials, SSH agent',
        'Yours',
        'None with plain Docker, forwarded by VS Code devcontainers',
        'Nothing, beyond what you put in ~/.agent-vm/env',
      ],
      ['Outbound network', 'Open', 'Open by default', 'Open (see [the roadmap](#roadmap))'],
      ['Shares the host kernel', 'Yes', 'On Linux; on macOS, the Docker Desktop VM’s', 'No'],
      [
        'Reaching the host needs',
        'Nothing',
        'A kernel bug, plus a hypervisor bug on macOS',
        'A hypervisor bug',
      ],
      ['Docker inside', 'Yes', 'Needs DinD or a socket mount', 'Yes, natively'],
      ['Headless browser', 'On the host', 'Up to your image', 'Chromium, included'],
      [
        'Environment definition',
        'None, your machine',
        'A devcontainer.json versioned with the project',
        'One base template, the same for every project',
      ],
    ],
    dockerNote:
      'Docker runs natively inside the VM with no Docker-in-Docker, headless Chromium works out of the box, and Lima forwards ports on its own. On a Mac, this replaces Docker Desktop.',
  },

  roadmap: {
    title: 'Known gaps.',
    items: [
      {
        status: 'Needs Lima',
        title: 'Block outbound network',
        body: '`--offline` existed and was removed: it set iptables rules inside the VM, where the agent has root and could drop them. Blocking on the host needs a Lima setting that does not exist. QEMU has the flag already (`-netdev user,restrict=on`); on `vz` the user-mode network is Lima’s own gvisor stack, so it would go there. The same block would also close the host loopback, which the guest reaches at `192.168.5.2` today.',
      },
      {
        status: 'Needs an M3',
        title: 'Run a VM inside the VM',
        body: 'A `--allow-nested-vm` flag, for testing VM tooling from in there. Lima supports nested virtualization, but it is off by default and cannot be turned on unconditionally: below an Apple M3, `limactl start` fails outright instead of degrading, so every VM would stop starting. The flag would have to detect host support first. Nothing here has an M3 to test it on. It would also hand the agent a hypervisor interface.',
      },
      {
        status: 'Designed, not built',
        title: 'Run the VMs on another machine',
        body: 'One install on your laptop driving VMs on a box you rent. Close the laptop, the agent keeps working. Open questions: addressing a VM by name rather than by working directory, and who owns deleting a workspace.',
      },
    ],
  },

  contribute: {
    eyebrow: 'Contribute',
    title: 'Patches welcome.',
    lede:
      'agent-vm is a small, readable Bash codebase with a test suite that creates no VMs and needs no network. Bug reports, engine fixes and support for new agents are all welcome.',
    testsTitle: 'Run the tests',
    testsBody:
      'The suite runs against a stub `limactl` in a throwaway `HOME`. No VM is created, started or deleted, your real `~/.agent-vm` is untouched, and nothing is downloaded. It covers VM naming, resource comparison, staleness, the `info`, `version` and `name` surface, the `--preinstall` parser, the MCP config writer, and the project mount mode that `--readonly` rides on. `./test-e2e.sh` is the other half: it builds a real VM with `--preinstall=none` and checks what a stub cannot, starting with whether root in the guest can lift `--readonly`. It runs in its own `LIMA_HOME`, so your own VMs are never touched.',
    testsCode: './test.sh        # fast, no VM\n./test-e2e.sh    # real VM, needs Lima',
    shellsTitle: 'Test the shells that matter',
    shellsBody:
      'macOS still ships bash 3.2, which is stricter about empty array expansion under `set -u` than modern bash. A change that passes on bash 5 can still break on a stock Mac.',
    shellsCode: 'docker run --rm -v "$PWD:/w" -w /w bash:3.2 ./test.sh\nzsh ./test.sh',
    structureTitle: 'Where things live',
    structureHeaders: ['File', 'What it is'],
    structure: [
      ['agent-vm.sh', 'The command: settings, the lib/ loader, starting a VM, the commands. What goes on your PATH.'],
      ['lib/', 'The rest of the command, one file per concern: mounts, .git protection, env, doctor, setup…'],
      ['agent-vm.setup.sh', 'Package installation, runs inside the base VM during setup.'],
      ['install.sh', 'Former installer, now a wrapper for ./agent-vm.sh install.'],
      ['test.sh', 'Test suite. Stub limactl, no VMs, no network. Runs tests/, in order.'],
      ['test-e2e.sh', 'End-to-end suite. Builds a real VM in a throwaway LIMA_HOME.'],
      ['runtime.example.sh', 'Commented template for ~/.agent-vm/runtime.sh.'],
      ['CHANGELOG.md', 'What changed in each release.'],
      ['www/', 'This website. Astro, static, deployed to GitHub Pages.'],
    ],
    guidelinesTitle: 'Before you open a PR',
    guidelines: [
      'Keep it bash 3.2 compatible, and run `./test.sh` under `bash:3.2` as well as your own shell.',
      'Every code path should be safe to re-run: check state before acting rather than assuming a clean machine.',
      'New behaviour gets a test in `test.sh`. The stub `limactl` makes that cheap.',
      'Integrator-facing surfaces (`info`, `env`, `version`) are contracts. Adding keys is fine, changing meanings is not.',
      'No secret, token or personal path in a commit, a test fixture or an issue.',
    ],
    issuesLabel: 'Open an issue',
    issuesHref: 'https://github.com/sylvinus/agent-vm/issues',
    prLabel: 'Browse pull requests',
    prHref: 'https://github.com/sylvinus/agent-vm/pulls',
    repoLabel: 'Read the source',
    repoHref: 'https://github.com/sylvinus/agent-vm',
  },

  credits: {
    eyebrow: 'Credits',
    title: 'Built on other people’s work.',
    lede:
      'agent-vm is a thin layer over software other people wrote. Most of what makes it work is on this list.',
    groups: [
      {
        title: 'The machine',
        items: [
          { name: 'Lima', note: 'Linux VMs on macOS and Linux. The only host dependency.', href: 'https://lima-vm.io/' },
          { name: 'Debian', note: 'The guest distribution. Debian 13.', href: 'https://www.debian.org/' },
          { name: 'mise', note: 'Runtime version manager inside the VM.', href: 'https://mise.jdx.dev/' },
        ],
      },
      {
        title: 'The agents',
        items: [
          { name: 'Claude Code', note: 'Anthropic.', href: 'https://claude.ai/code' },
          { name: 'OpenCode', note: 'Open-source terminal agent.', href: 'https://github.com/anomalyco/opencode' },
          { name: 'Codex CLI', note: 'OpenAI.', href: 'https://github.com/openai/codex' },
          { name: 'Mistral Vibe', note: 'Mistral AI.', href: 'https://docs.mistral.ai/vibe/code/cli/install-setup' },
          { name: 'Pi', note: 'Minimal open-source harness. Opt-in.', href: 'https://pi.dev' },
        ],
      },
      {
        title: 'Browser access',
        items: [
          {
            name: 'Chrome DevTools MCP',
            note: 'Wired into every installed agent by default.',
            href: 'https://github.com/ChromeDevTools/chrome-devtools-mcp',
          },
          {
            name: 'Playwright MCP',
            note: 'Opt-in, pointed at the same Chromium.',
            href: 'https://github.com/microsoft/playwright-mcp',
          },
        ],
      },
    ],
    authorTitle: 'Maintainer',
    authorBody: 'Built and maintained by Sylvain Zimmer.',
    authorHref: 'https://github.com/sylvinus',
    authorName: 'sylvinus',
    licenseTitle: 'License',
    licenseBody: 'MIT: use, copy, modify and redistribute it, as long as the copyright and license notice stay with it. No warranty.',
    licenseHref: 'https://github.com/sylvinus/agent-vm/blob/main/LICENSE',
  },

  footer: {
    tagline: 'A disposable Linux VM per project for AI coding agents.',
    license: 'MIT',
    backToTop: 'Back to top',
  },

  ui: {
    copy: 'Copy',
    copied: 'Copied',
    copyFailed: 'Copy failed',
    copyLabel: 'Copy code to clipboard',
    anchorLabel: 'Link to this section (copies it)',
    linkCopied: 'Link copied',
  },
};

// Not `as const`: the literal types it would produce are exactly what every
// other locale fails to match. Widened to string, the shape still has to line
// up, which is the part worth enforcing.
export type Dictionary = typeof en;
