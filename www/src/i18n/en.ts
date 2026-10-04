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
      'agent-vm gives every project its own Linux VM and runs the coding agent there with permissions bypassed. Your SSH keys, your browser sessions, the rest of your disk and your local network are out of its reach. One binary, Lima built in. MIT.',
    skipToContent: 'Skip to content',
  },

  nav: {
    sections: {
      install: 'Install',
      usage: 'Usage',
      reference: 'Reference',
      architecture: 'Architecture',
      security: 'Security',
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
      'agent-vm runs AI coding agents with every permission, in a Linux VM per project. Your SSH keys, your browser sessions, the rest of your disk and your local network are out of their reach.',
    installLabel: 'Get started',
    ctaPrimary: 'Install it',
    ctaSecondary: 'How it works',
    meta: 'MIT licensed · macOS, Linux, Windows (experimental) · Lima built in',
    terminalCaption:
      'Only the project directory is mounted.',
    points: [
      {
        title: 'One binary, [Lima](https://lima-vm.io/) built in',
        body: 'No Lima to install, no Node, no npm, no Docker Desktop on your machine: the toolchain lives in the VM. On Linux, the VMs need QEMU and access to KVM.',
      },
      {
        title: 'A separate kernel, not a namespace',
        body: 'On Linux, escaping a container puts you on the host. Escaping a VM means getting through the hypervisor first.',
      },
      {
        title: 'Ports are forwarded for you',
        body: 'A dev server started in the VM answers on localhost at the same port, with a notification, and no flag or config. A port a program of yours already uses is left to it.',
      },
      {
        title: 'Batteries included, root for the rest',
        body: 'The base VM ships dev tools, Docker, headless Chromium and the agents, picked in a setup wizard. The agent is root in its VM: it installs whatever else it needs.',
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
        body: 'npm ran every package’s install scripts by default until npm 12 (July 2026), pip still runs a source package’s build, Cargo its `build.rs`, and your tests then run whatever got installed. In 2025 the Shai-Hulud worm spread through thousands of npm packages that way: it collected npm tokens, GitHub PATs, SSH keys and cloud credentials, then republished itself using them.',
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
      'A VM limits what a mistake or a compromised agent can reach to the project, the internet, and what you hand it, such as [its env file](#share-secrets-across-vms). Your machine and your local network stay out of reach: see [Security](#security).',
  },

  install: {
    eyebrow: 'Install',
    title: 'Install, build a template, run an agent.',
    lede:
      'agent-vm is one binary, with Lima built in and no daemon: each running VM is served by an agent-vm process of its own.',
    prerequisitesTitle: 'Prerequisites',
    prerequisites: [
      { name: 'macOS, Linux or Windows', note: 'Windows is experimental: not yet tried on a Windows machine.', href: '' },
      {
        name: 'QEMU, on Linux and Windows',
        note: 'macOS needs nothing more. On Linux, KVM too: `agent-vm setup` says what is missing and how to install it. On Windows, QEMU 7.2 or later and the Windows Hypervisor Platform feature.',
        href: '',
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
        note: 'Downloads the latest release’s build for your machine from GitHub, checks it against the release’s `SHA256SUMS`, unpacks it in `~/.local/share/agent-vm` and links `agent-vm` into `~/.local/bin`. It then offers to run step 2 right away. Run it again to update. `sh -s -- --version X.Y.Z` installs a given release, `sh -s -- --git` a clone of `main`.',
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
        note: 'Builds it, with Go (and on macOS the Xcode command line tools), then `install` symlinks `agent-vm` onto your `PATH`. After a `git pull`, run `./agent-vm.sh install` again to rebuild. It then offers to run step 2 right away.',
      },
      {
        id: 'windows',
        label: 'Windows',
        code: '# in Git Bash (experimental)\nwinget install SoftwareFreedom.QEMU\ncurl -fsSL https://www.agent-vm.org/install.sh | sh',
        note: 'Experimental: not yet tried on a Windows machine. Without Git Bash, download `agent-vm-X.Y.Z-windows-amd64.tar.gz` (or `-arm64`) from the GitHub releases, unpack it with `tar -xzf`, and run `agent-vm.exe install` in PowerShell. VMs also need the Windows Hypervisor Platform feature, which an administrator turns on once: see [Windows and WSL](#windows-and-wsl).',
      },
    ],
    steps: [
      {
        title: 'Build the base template',
        body: 'Run once. A wizard picks what goes in the template: Enter takes the default set (see [What is in the VM](#what-is-in-the-vm)). It builds a Debian 13 VM with it and keeps it, stopped, as the template.',
        code: 'agent-vm setup',
      },
      {
        title: 'Run an agent in your project',
        body: 'Clones the template into a VM for this directory, mounts the directory and launches the agent with permissions already granted. A start may first stop on a security question: see [Protecting .git](#git).',
        code: 'cd your-project\nagent-vm opencode     # or: agent-vm claude',
      },
    ],
  },


  usage: {
    eyebrow: 'Usage',
    title: 'Everyday commands.',
    lede:
      'Run them from your project directory. The [Reference](#reference) lists every command, option and file.',
    cards: [
      {
        title: 'Run an agent',
        body: 'Extra arguments are forwarded to the agent as-is, so anything its own CLI accepts works here.',
        code: 'agent-vm opencode                        # OpenCode\nagent-vm claude                          # Claude Code\nagent-vm codex                           # Codex CLI\nagent-vm vibe                            # Mistral Vibe\n\nagent-vm claude -p "fix all lint errors"\nagent-vm opencode run "update the changelog"',
      },
      {
        title: 'Reach the dev server',
        body: 'Every port opened in the VM is forwarded to the same port on your localhost, so a dev server opens in your browser as usual, and a notification says so. A port a program of yours already listens on is not taken: the notification says that too. Treat the forwarded ports as the agent’s.',
        code: 'agent-vm run npm run dev         # then open localhost:5173\nagent-vm run docker compose up',
      },
      {
        title: 'Get inside',
        body: 'A shell to poke around, or a single command when you already know what you want.',
        code: 'agent-vm shell                    # zsh in the VM\nagent-vm run npm install          # one-off command\nagent-vm run --tty opencode       # allocate a PTY for TUIs\nagent-vm sh -c "ls -la | grep config"\nagent-vm code                     # VS Code in the browser, if set up',
      },
      {
        title: 'Manage the fleet',
        body: 'The current directory’s VM is marked with `>` in `list`. If a directory is renamed, `list` is the only way to find its VM again.',
        code: 'agent-vm list          # every VM, the current one marked\nagent-vm stop          # stop, keep the disk\nagent-vm rm            # stop and delete\nagent-vm destroy-all   # every VM, base template included\nagent-vm doctor        # what is wrong, and what to run',
      },
      {
        title: 'Tighten the session',
        body: '`--readonly` makes every host share read-only, `rw` volumes included, and the host enforces it: root in the VM cannot lift it. Packages still install on the VM’s own disk, but nothing lands in the project. `--scratch` mounts nothing of yours: the agent clones the code with a token from `agent-vm env`, pushes its work, and the VM is deleted at exit.',
        code: 'agent-vm --readonly shell   # nothing on the host writable\nagent-vm --scratch claude   # nothing mounted, gone at exit\nagent-vm --rm run npm test  # destroy the VM on exit',
      },
      {
        title: 'Resize on the fly',
        body: 'A new VM gets the template’s 10 GB of disk, 3 GB of memory (4 with code-server picked in the wizard) and 1 CPU. Pass another value and the VM is reconfigured, after asking if it is running. Disk only grows. CPU and memory are capped at half the host, per VM.',
        code: 'agent-vm --disk 50 opencode\nagent-vm --memory 16 --cpus 8 shell\nagent-vm --reset claude   # re-clone from the base template',
      },
      {
        title: 'Share secrets across VMs',
        body: '`KEY=value` lines in `~/.agent-vm/env`, pushed into every VM on each command. Everything in the VM can read them: use narrow tokens you can revoke. Edit with `env set`, since one bad quote in the file breaks all of it.',
        code: 'agent-vm env set GH_TOKEN   # pasted unseen, not in history\nagent-vm env list           # names only, never values\nagent-vm env has ANTHROPIC_API_KEY\n\n# scoped to this project only\nagent-vm project-env set SOME_PATH ./config',
      },
      {
        title: 'Edit with the VM’s tools',
        body: 'For language servers, linters, the debugger and the VM’s packages, run the editor in the VM: `agent-vm code` serves VS Code (code-server) to a browser tab, the only part on your machine. Set it up with `code-server` or a `code-*` name ([What is in the VM](#what-is-in-the-vm)). The tab can still open links, and every VM can send your browser to it, hence a password and a host name per VM ([Network and ports](#network-and-ports)). Do not connect a desktop editor over SSH instead ([SSH from your machine](#ssh-from-your-machine)).',
        code: 'agent-vm setup --preinstall=default,code-claude   # once\nagent-vm code   # prints the address and the password\n                # Ctrl-C stops the editor',
      },
    ],
    gitTitle: 'Letting the agent commit',
    gitBody:
      'git reads its identity from the environment, so the shared env file covers it with no `git config` inside the VM. All four variables are needed: git refuses to commit without a committer, not just an author.',
    gitCode:
      '# ~/.agent-vm/env\nGIT_AUTHOR_NAME=Your Name\nGIT_AUTHOR_EMAIL=12345+you@users.noreply.github.com\nGIT_COMMITTER_NAME=Your Name\nGIT_COMMITTER_EMAIL=12345+you@users.noreply.github.com',
    gitNote:
      'These variables win over `git config`, in every repository of the VM: for per-repository identities, set `user.name` and `user.email` from a runtime script instead. `gh` picks up `GH_TOKEN` on its own, so `gh pr create` works with nothing else. Plain `git push` over HTTPS needs a credential helper: one `gh auth setup-git` line in your [runtime script](#customisation-files).',
    gitHumanTitle: 'That said, keep the commits human',
    gitHumanBody:
      'Being able to commit is not a reason to let it. A commit says you read the diff, so let the agent write the code, read it, and commit it yourself. With `.git` [protected](#git), that is the only way.',
  },

  reference: {
    eyebrow: 'Reference',
    title: 'Every command, option and file.',
    lede: 'What the sections above leave out: the full command set, the configuration files and variables, and what a script can rely on.',
    commandGroups: [
      {
        title: 'Run an agent',
        rows: [
          ['opencode [args]', 'Run OpenCode with `--auto`.'],
          ['claude [args]', 'Run Claude Code with `--dangerously-skip-permissions`.'],
          ['codex [args]', 'Run Codex CLI with `--dangerously-bypass-approvals-and-sandbox`.'],
          ['vibe [args]', 'Run Mistral Vibe with `--agent auto-approve`.'],
          ['pi [args]', 'Run Pi, which has no permission prompts.'],
        ],
      },
      {
        title: 'Get inside',
        rows: [
          ['shell, sh', 'Open a zsh shell in the VM. `-c "…"` runs a one-shot command through a login shell.'],
          ['run <cmd> [args]', 'Run a command with no shell. `--tty` allocates a PTY for TUIs.'],
          ['code', 'Serve VS Code (code-server) from the VM at `http://<vm-name>.localhost:<port>/`, until Ctrl-C, for you to open in your browser. Its password is made in the VM on first use and printed with the address. Needs `code-server` or a `code-*` name at setup ([What is in the VM](#what-is-in-the-vm)).'],
        ],
      },
      {
        title: 'Manage the fleet',
        rows: [
          ['list, status', 'List all agent-vm VMs, the current directory’s marked with `>`, with the agent-vm version that built the base each was cloned from, and when.'],
          ['stop [vm-name]', 'Stop this directory’s VM, or the named one. The disk survives.'],
          ['rm [vm-name]', 'Stop and delete. A name from `list` reaches a VM whose directory is gone.'],
          ['destroy-all', 'Stop and delete every agent-vm VM, the base template included. `setup` rebuilds it.'],
          ['doctor', 'Check the host, the base template, your settings files and this directory, and say what to run. Changes nothing.'],
        ],
      },
      {
        title: 'Set up and configure',
        rows: [
          ['install', 'Put `agent-vm` on your `PATH`: a link to the binary that runs it, in `~/.local/bin`. The curl installer runs it for you.'],
          ['uninstall', 'Remove that link. VMs and `~/.agent-vm` stay.'],
          ['setup', 'Build the base template. `--preinstall=LIST` skips the wizard ([What is in the VM](#what-is-in-the-vm)); `--disk`, `--memory` and `--cpus` size it.'],
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
    optionsNote: 'For `claude`, `opencode`, `codex`, `vibe`, `pi`, `shell`, `run` and `code`, placed before the command or right after its name. Anything later belongs to the command: in `agent-vm run docker run --rm x`, `--rm` is docker’s.',
    optionsHeaders: ['Flag', 'What it does', 'Default'],
    options: [
      ['--disk GB', 'VM disk size. Can grow, never shrink.', 'the template’s (10)'],
      ['--memory GB', 'VM memory. Clamped to half the host, per VM.', 'the template’s (3, or 4 with code-server picked in the wizard)'],
      ['--cpus N', 'CPU count. Clamped to half the host, per VM.', 'the template’s (1)'],
      ['--ssh-port N', 'Fixed host port for the VM’s SSH, for tools that save it. `0` goes back to a new one on each start. Restarts a running VM, asked first.', 'a new one per start'],
      ['--reset', 'Destroy and re-clone the VM from the base template.', 'off'],
      ['--readonly', 'Every host share read-only, project and volumes. Restarts a running VM, asked first.', 'off'],
      ['--unsafe-writable-git', 'Leave every `.git` writable so the agent can commit, with a warning. See [Protecting .git](#git).', 'off'],
      ['--unsafe-disable-security-prompts', 'Go on where a start would stop on a security question (see [Protecting .git](#git)). The warnings are still printed. Same as `AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1`.', 'off'],
      ['--rm', 'Destroy the VM once the command exits.', 'off'],
      ['--scratch', 'A new VM with nothing of yours mounted, deleted when the command ends (asked first on a terminal). `~/.agent-vm/env` and `runtime.sh` go in, the project’s files do not. Several can run at once.', 'off'],
    ],
    envTitle: 'Environment variables',
    envNote: 'Read from your shell, never from a file of the project.',
    envHeaders: ['Variable', 'What it does', 'Default'],
    env: [
      ['AGENT_VM_STATE_DIR', 'Moves `~/.agent-vm`, VMs included, for tests, CI or a second install, without moving `HOME`.', '~/.agent-vm'],
      ['AGENT_VM_LIMA_HOME', 'Where the VMs live. Not your own Lima’s home: agent-vm keeps its VMs apart.', '~/.agent-vm/lima'],
      ['AGENT_VM_PROJECT_ENV', 'The project’s env file, relative to the project or absolute.', '.agent-vm.env'],
      ['AGENT_VM_PROJECT_RUNTIME', 'The project’s runtime script, relative to the project or absolute. Outside the project, the host reads it.', '.agent-vm.runtime.sh'],
      ['AGENT_VM_HOST_SHARE', 'CPU and memory per VM are capped at the host’s divided by this. `1`: the whole host.', '2'],
      ['AGENT_VM_BIN_DIR', 'Where `install` links `agent-vm`.', '~/.local/bin'],
      ['AGENT_VM_SSHFS_CACHE', '`1`: sshfs caches the writable shares too, faster on many files (`git status`, `find`); the VM may then see a file as it was up to 20 seconds before, and write that back. Applies when a VM is next started.', 'unset'],
      ['AGENT_VM_NOTIFY', '`0`: no desktop notification when a port is forwarded, or left to a program of yours.', 'unset'],
      ['AGENT_VM_GUARDED_WRITES', '`deny`: refuse the VM’s writes to [guarded files](#guarded-files) without asking, for a machine with no one at the screen.', 'unset'],
      ['AGENT_VM_UNSAFE_OPEN_NETWORK', '`1`: no [network isolation](#network-and-ports): the VMs reach your machine and your local networks. Applies when a VM is next started.', 'unset'],
      ['AGENT_VM_UNSAFE_WRITABLE_GIT', '`1`: same as `--unsafe-writable-git`.', 'unset'],
      ['AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS', '`1`: same as `--unsafe-disable-security-prompts`.', 'unset'],
    ],
    customTitle: 'Customisation files',
    customLede:
      'Eight optional files, none of them needed to get started. The per-user ones sit in `~/.agent-vm/`, the per-project ones in the project itself.',
    customTable: {
      headers: ['File', 'Scope', 'Runs when'],
      rows: [
        ['~/.agent-vm/env', 'All VMs', 'Pushed in on every invocation'],
        ['~/.agent-vm/volumes', 'All VMs, or the projects an entry names', 'Mounted at VM creation'],
        ['~/.agent-vm/network', 'All VMs: what they may reach ([Network and ports](#network-and-ports))', 'Read when a VM starts'],
        ['~/.agent-vm/guarded', 'All VMs: files to ask about ([Guarded files](#guarded-files))', 'Read when a VM starts'],
        ['~/.agent-vm/setup.sh', 'Base template', 'Once, during agent-vm setup'],
        ['~/.agent-vm/runtime.sh', 'All VMs', 'Every command that enters a VM, first'],
        ['.agent-vm.runtime.sh', 'Single project', 'Every command that enters its VM, after the global one'],
        ['.agent-vm.env', 'Single project', 'Pushed in after the shared env, so it wins'],
      ],
    },
    volumesTitle: 'Extra mounts: ~/.agent-vm/volumes',
    volumesBody:
      'One `source[:destination][:mode][:project]` per line, `~` expanded on the left, `#` for comments. The mode is `ro` (default) or `rw`, and `rw` only works for directories. Without a destination, the path is mounted at the same place in the VM; a relative one is inside the project. The fourth field limits the entry to the projects it matches, `*` matching anything.',
    volumesCode:
      '# ~/.agent-vm/volumes\n~/.gitconfig    # same path, read-only\n~/.cache/shared:/home/you.guest/.cache/shared:rw\n\n# only in ~/work/webapp, as its .claude, read-only\n~/.claude-vm/webapp:.claude:ro:~/work/webapp\n\n# every project under ~/work\n~/.cache/pip:/home/you.guest/.cache/pip:rw:~/work/*\n\n# same path, one project only\n~/datasets::ro:~/work/ml',
    volumesNote:
      'The list lives on your side, not in the project: the agent writes the project, and could otherwise mount any host folder into its VM. A relative destination that leaves the project, through `..` or a symlink, is skipped. Changes apply to new VMs: `--reset` re-applies them.',
    nodeTitle: 'Node.js: node_modules in the VM',
    nodeBody:
      'Hundreds of thousands of files are slow across the share, and native packages differ between macOS and Linux anyway. Mount a folder of the VM’s own disk over `node_modules` from the project’s [runtime script](#customisation-files), which runs on every command:',
    nodeCode:
      '#!/bin/bash\n# .agent-vm.runtime.sh\nset -e\nmkdir -p "$HOME/node_modules" node_modules\nmountpoint -q node_modules ||\n  sudo mount --bind "$HOME/node_modules" node_modules',
    nodeNote: 'The host sees an empty `node_modules`, or keeps its own: install there too if your editor needs the packages. In a workspace, repeat the mount for a package with a large `node_modules` of its own. A dev server in the VM may need polling to see edits made on the host (Vite: `server.watch.usePolling`).',
    scriptsTitle: 'From a script',
    scriptsParas: [
      'Use these commands rather than parsing human-facing output or reading `~/.agent-vm`: VM names and state files are implementation details. None of them starts a VM.',
      '`version --min` exits `0` when recent enough, `1` when older, `2` on a malformed call; an engine predating `--min` ignores it and exits `0`. In `info`, booleans are `1` or `0`, `unknown` when undeterminable, and `base_exists=1` means the template is usable.',
      'A start asks its questions only when stderr is a terminal: otherwise it stops there. `security_questions` in `info` names them beforehand (`hooks`, `git-config`, `bare-repo` or `none`), and `--unsafe-disable-security-prompts` accepts them once the user agreed.',
    ],
    scriptsCode:
      'agent-vm version --min 0.2.0 || exit 1  # silent when OK\nagent-vm name [dir]    # VM name for a directory\nagent-vm info [dir]    # one key=value per line\n\n# info keys: version, template, state_dir,\n# project_env, dir, vm_name, base_exists,\n# vm_exists, vm_running, vm_stale,\n# ssh_host, ssh_config, git_protected,\n# security_questions',
    groups: [
      {
        title: 'Install and update',
        topics: [
          {
            title: 'Installer options',
            paras: [
              'Options go after `sh -s --`: `--version X.Y.Z`, `--git` for a clone of `main`, `--dir DIR` instead of `~/.local/share/agent-vm`. To read the installer first, download it, then run it with `sh`.',
            ],
            list: [],
            code: 'curl -fsSL https://www.agent-vm.org/install.sh |\n  sh -s -- --dir ~/tools/agent-vm\n\n# read it first\ncurl -fsSLO https://www.agent-vm.org/install.sh\nsh install.sh',
          },
          {
            title: 'Updating',
            paras: [
              'Run the curl installer again, `brew upgrade agent-vm`, or `git pull && ./agent-vm.sh install` in a clone. `agent-vm uninstall` removes the link; VMs and `~/.agent-vm` stay.',
              'Running `setup` again rebuilds the template, not the VMs cloned from it: agent-vm warns about those, and `--reset` re-clones one. Its full log is in `~/.agent-vm/setup.log`.',
            ],
            list: [],
            code: '',
          },
          {
            title: 'From 0.2',
            paras: [
              'Lima is built in: Homebrew’s Lima, or the Lima build 0.2 installed, can go, unless you use it for VMs of your own. agent-vm keeps its VMs in `~/.agent-vm/lima`, apart from yours, and names them without the `agent-vm-` prefix: `your-project-1a2b3c4d`, and `base` for the template.',
              'The first command that needs the VMs offers to move 0.2’s from `~/.lima` (or `$LIMA_HOME`), stopping the running ones first: they keep their disks, shares and settings. Declined, it asks again next time; with no terminal to ask on, it moves them. `doctor` and `info` only look, and say when some are still to move.',
              'To update, run the curl installer again, or `git pull && ./agent-vm.sh install` in a clone (Go needed): the link on your `PATH` then leads to the binary. Until then, 0.2’s link to `agent-vm.sh` keeps working (in a clone, after a `git pull`, it builds agent-vm first), and so does a shell rc line sourcing it, which `install` says can go. A VM from a base 0.1.0 built no longer starts: run `agent-vm setup`, then `--reset`.',
            ],
            list: [],
            code: '',
          },
          {
            title: 'Windows and WSL',
            paras: [
              'On Windows, agent-vm runs natively, from PowerShell or Git Bash, with QEMU; it is experimental, not yet tried on a Windows machine. Your folders are `C:/Users/you/project` to it, and `/c/Users/you/project` in the VM, as with 0.2. The volumes file takes `C:/x` or `C:\\x`, and 0.2’s `/c/x`.',
              'VMs need the Windows Hypervisor Platform feature. It is off by default and only an administrator can turn it on, once, in Windows Features or with the command below, then a reboot. On a managed laptop, that is a request to IT. A start that fails for want of it says so.',
              'WSL2 is Linux to agent-vm, and its VMs need KVM, which WSL2 has only with nested virtualization from the Windows host. WSL1 cannot run VMs.',
            ],
            list: [],
            code: '# in PowerShell as administrator, then reboot\nDISM /Online /Enable-Feature `\n  /FeatureName:HypervisorPlatform /All',
          },
          {
            title: 'Paths',
            paras: [
              'Paths with whitespace, quotes, backslashes, control characters, `{{` (Lima reads it as a template) or bytes that are not UTF-8 are refused. iCloud Drive paths have spaces: go through a symlink. A folder name too long for Lima’s socket paths is cut in the VM’s name, which keeps the hash of the whole path.',
            ],
            list: [],
            code: 'ln -s ~/Library/Mobile\\ Documents/com~apple~CloudDocs/Dev \\\n  ~/Dev\ncd ~/Dev/your-project && agent-vm claude',
          },
          {
            title: 'Ports and doctor',
            paras: [
              'A port set with `--ssh-port` stays until `--reset` or `rm`. `doctor` prints no secret, so its output can go into an issue as is.',
            ],
            list: [],
            code: '',
          },
        ],
      },
      {
        title: 'Agents and configuration',
        topics: [
          {
            title: 'How each agent runs',
            paras: [
              'Claude Code also gets bypass mode from managed settings, since it drops the flag when it relaunches itself ([#72479](https://github.com/anthropics/claude-code/issues/72479)). For Pi, setup sets `defaultProjectTrust: "always"`.',
              'Log in inside the VM (`claude login`, `gh auth login`): the login stays with that VM. Mounting your host credentials would hand them to everything in it.',
              'A 24-bit colour terminal that does not set `COLORTERM` (Terminal.app on macOS 26) needs `export COLORTERM=truecolor`.',
            ],
            list: [],
            code: '',
          },
          {
            title: 'MCP servers',
            paras: [
              'Playwright MCP uses the VM’s Chromium and downloads no browser. For another engine, edit its entry (drop `--executable-path`, add `--browser firefox`) and run `npx playwright install firefox`. Add your own servers to `mcpServers` in `~/.claude.json`, from `~/.agent-vm/setup.sh` or inside a VM.',
            ],
            list: [],
            code: '{\n  "mcpServers": {\n    "postgres": {\n      "command": "npx",\n      "args": [\n        "-y",\n        "@modelcontextprotocol/server-postgres",\n        "postgresql://localhost:5432/mydb"\n      ]\n    }\n  }\n}',
          },
          {
            title: 'The env files',
            paras: [
              'agent-vm knows none of the names: `gh` reads `GH_TOKEN`, Claude Code `ANTHROPIC_API_KEY`, Codex `OPENAI_API_KEY`, Vibe `MISTRAL_API_KEY`. Edits need no `--reset`.',
              'The project’s `.agent-vm.env` is pushed after the shared one and wins. It sits in a repository, so keep secrets out: `project-env set` prints the line that gitignores it.',
              '`get` and `has` read the file without running it, and exit `2` on a value that needs a shell. `set` without a value reads it unseen, out of your shell history.',
            ],
            list: [],
            code: '',
          },
          {
            title: 'Extra mounts, in detail',
            paras: [
              'A destination is used as written, with no `~`: the VM home is `/home/<you>.guest` (`.linux` before Lima 2.1). A missing source is skipped with a warning.',
              'A single file is hardlinked into `~/.agent-vm/file-mounts/<vm>/` and bind-mounted. Across filesystems it is copied, and host edits wait for the next start.',
            ],
            list: [],
            code: '# ~/.agent-vm/volumes: your Claude instructions and skills,\n# not the whole ~/.claude, which holds your login on Linux\n~/.claude/CLAUDE.md:/home/you.guest/.claude/CLAUDE.md\n~/.claude/skills:/home/you.guest/.claude/skills',
          },
          {
            title: 'Setup and runtime scripts',
            paras: [
              '`~/.agent-vm/setup.sh` runs once in the template, at the end of `setup`, under zsh with sudo. `~/.agent-vm/runtime.sh`, then the project’s `.agent-vm.runtime.sh`, run on every command that enters the VM, so both must be safe to re-run. [`runtime.example.sh`](https://github.com/sylvinus/agent-vm/blob/main/runtime.example.sh) covers git identity, `gh auth setup-git`, skills and MCP servers.',
              'They are fed on standard input: give a command in them that reads it `</dev/null`. Keep private keys out, the agent can read what they set up.',
            ],
            list: [],
            code: '# .agent-vm.runtime.sh\nmise install\nnpm install\ndocker compose up -d',
          },
        ],
      },
    ],
  },

  security: {
    eyebrow: 'Security',
    title: 'What crosses the boundary.',
    lede: 'The VM cannot leave its shares. What remains is what crosses them: the project folder, which the agent writes and your machine reads, the terminal, and the network.',
    groups: [
      {
        id: 'git',
        title: 'Protecting .git',
        topics: [
          {
            title: 'Why .git',
            paras: [
              'Git on your machine runs what a repository’s `.git/config` and hooks name: `core.fsmonitor` on every `git status`, hooks on commit. Your editor and prompt run `git status` on their own, so a VM able to write `.git` could run commands on your host within seconds, invisible in `git diff`.',
              'Every `.git` and `.hg` in the shares is read-only for the VM, at any depth, enforced on your machine by the SFTP server built into agent-vm (Lima’s `sshfs.readonlyNames`, not merged upstream yet: [lima-vm/lima#5529](https://github.com/lima-vm/lima/issues/5529)). The agent reads the history but cannot commit. The shares use `reverse-sshfs`, slower on many files (see [Node.js](#node)), and without sshfs’s cache on the writable ones, so the VM never writes back a file as it was before you changed it: `AGENT_VM_SSHFS_CACHE=1` trades that for speed.',
            ],
            list: [],
            code: 'agent-vm doctor    # where you stand\n\n# let the agent commit anyway\nagent-vm --unsafe-writable-git claude',
          },
          {
            title: 'Beyond the name .git',
            paras: [
              'The folder a `core.hooksPath` points to in a share (`.husky` for husky) is read-only too, as is a link on the way to it, and the same goes for the repositories in your writable volumes. A folder holding git’s internals (`HEAD`, `objects/`, `refs/`, a `config`) is a repository under any name: setting `safe.bareRepository` to `explicit` in your global git config makes git ignore it, and one in a writable volume is read-only by its name. A config included from a share, a command or a hook git runs from one, or hooks at the top of a share, are the same kind of door.',
              'Before a VM boots with writable shares, agent-vm stops on each of these it finds, and asks: Enter, or no terminal, aborts. `doctor` lists them. `--unsafe-writable-git` (or `AGENT_VM_UNSAFE_WRITABLE_GIT=1` in your shell, never read from the project) lets the agent commit and reopens that path to your host, with a warning on every run.',
            ],
            list: [],
            code: '',
          },
          {
            title: 'Lima, built in',
            paras: [
              'agent-vm builds Lima, its SFTP server (sshocker and pkg/sftp) and its network stack (gvisor-tap-vsock) from their upstream sources, with [patches](https://github.com/sylvinus/agent-vm/blob/main/patches/README.md) kept small enough to be sent upstream: the read-only names, fixes to the SFTP server (an append that crashed the VM, writes applied out of order), network isolation, the port check. Each running VM is served by an agent-vm process, which is Lima’s host agent.',
              'Every share is served by the built-in SFTP server, confined to its folder: agent-vm starts no VM whose config says otherwise, whatever set it. A `default.yaml` or `override.yaml` in `~/.agent-vm/lima/_config` would add to every VM’s config, so agent-vm starts no VM while one is there.',
            ],
            list: [],
            code: '',
          },
        ],
      },
      {
        title: 'What agent-vm does',
        topics: [
          {
            title: 'Refused directories and files',
            paras: [
              'agent-vm will not share your home directory, `/`, its own directory, `~/.agent-vm`, your own Lima’s directory (`~/.lima`), or a directory containing one of them: `cd ~ && agent-vm shell` would hand the VM your dotfiles and SSH keys.',
              'It never reads a file in the project by its path, since the VM can make it a symlink to any file of yours. Its own git calls in a project refuse a bare repository and run no `core.fsmonitor` or pager.',
            ],
            list: [],
            code: '',
          },
          {
            title: '--readonly, in detail',
            paras: [
              '`--readonly` covers every share, `rw` volumes included: a writable volume containing the project would be a second way in. The built-in SFTP server enforces it on your machine, and agent-vm checks each VM’s config before it boots, never the guest’s word.',
              'A running VM in the other mode is restarted, asked first. Declined, or with no terminal, the command fails, so another session’s read-only VM is never made writable under it.',
            ],
            list: [],
            code: '',
          },
        ],
      },
      {
        title: 'What else on your machine reads the project',
        topics: [
          {
            title: 'The rule',
            paras: [
              'Anything on your machine that reads the project and acts on what it finds can run what the agent wrote. agent-vm closes git’s doors (see [Protecting .git](#git)), but cannot lock the files your other tools read without stopping the agent from working.',
              'So on your machine, open the project in your editor and use git in it; run everything else in the VM, with `agent-vm run`. The lists below are examples, not an inventory.',
            ],
            list: [
              'Nothing at all: what runs when you `cd` into the folder, your prompt redraws, your editor opens it. The most dangerous kind.',
              'Something you do anyway: `git commit` runs hooks kept in the working tree, `docker compose up` mounts what the compose file names.',
              'Running project code: `npm test`, `make`, a build. That is the agent’s code: run it in the VM.',
            ],
            code: '',
          },
          {
            title: 'Guarded files',
            paras: [
              'For the first kind, agent-vm guards the files your machine runs on its own: when the VM writes, creates, renames or removes one, at any depth in the shares, a dialog asks you first. A yes holds until the VM stops; a no, for a minute, after which a retry asks again. Where no dialog can be shown (no desktop session), the write is refused and a notification says so; a dialog left unanswered for two minutes refuses it too. `AGENT_VM_GUARDED_WRITES=deny` refuses them all without asking.',
              'Guarded by default: `.envrc` (direnv), `.vscode/tasks.json`, `.vscode/settings.json` and `.vscode/launch.json` (VS Code), `.pre-commit-config.yaml` (pre-commit), `lefthook.yml` and `.lefthook.yml` (lefthook), `mise.toml` and `.mise.toml` (mise). Files the agent edits as a matter of course, such as a `Makefile` or `package.json`, are not: add them in `~/.agent-vm/guarded`, one path per line, read when a VM starts. `!path` removes a default.',
            ],
            list: [],
            code: '# ~/.agent-vm/guarded\nMakefile               # ask before the VM changes any Makefile\n.github/workflows/ci.yml\n!.vscode/settings.json # no longer asked',
          },
          {
            title: 'Keeping your checkout out of reach',
            paras: [
              'Do not give agent-vm the checkout you work in. Clone the project a second time, run agent-vm there, and `git fetch` its work into your checkout once you have read the diff. Fetching does not check files out, so the agent’s files reach your working tree only when you merge. This relies on the clone’s `.git` being read-only for the VM, as it is unless you pass `--unsafe-writable-git`: otherwise the VM can write it, and git then reads it.',
            ],
            list: [],
            code: '# once; --no-local copies objects, no hardlinks\ngit clone --no-local ~/work/app ~/agent/app\n# the agent works there\ncd ~/agent/app && agent-vm claude\n# back in your checkout, when it is done\ncd ~/work/app\ngit fetch ~/agent/app HEAD:agent/review\ngit diff ...agent/review   # read all of it\ngit merge agent/review',
          },
          {
            title: 'Editors and agents',
            paras: [
              'A changed tracked file shows in `git diff`, a new one as untracked; one in an ignored path (`node_modules`, `.venv`, `target/`) shows nowhere.',
            ],
            list: [
              'VS Code: open agent-vm projects in Restricted Mode, and do not trust a parent folder. A trusted workspace runs project code through tasks and extensions: `eslint.config.js`, `vite.config.ts`, `build.rs`.',
              'JetBrains IDEs: “Preview in Safe Mode”. A trusted project runs its Gradle or Maven scripts on import.',
              'Vim: leave `exrc` off. Neovim and Emacs ask before running project config.',
              'Agents on your machine run commands from `.claude/settings.json` hooks, `.mcp.json` or `.cursor/`: review those, and treat `CLAUDE.md` and `AGENTS.md` as the VM’s writing.',
            ],
            code: '',
          },
          {
            title: 'SSH from your machine',
            paras: [
              'Do not connect VS Code Remote-SSH or open-remote-ssh to an agent VM. They run a server in the VM, which root in the VM controls, and the editor on your machine trusts it. Microsoft’s Remote-SSH page says so: “a compromised remote could use the VS Code Remote connection to execute code on your local machine”, and it is by design. Public write-ups show it opening a terminal on the host and running commands there. That removes the boundary agent-vm sets up, which is worse than opening the project in Restricted Mode. JetBrains Gateway does not say it is safer: its security model page says what the backend loads goes to your machine without asking, the backend opens links there (after a prompt), and decides which client version your machine downloads. For language servers and a debugger with the VM’s packages, use [`agent-vm code`](#edit-with-the-vm-s-tools).',
              'For scripts, `scp` or `rsync`, `agent-vm info` prints the SSH alias as `ssh_host`. Put these lines at the top of `~/.ssh/config`: a `ForwardAgent yes` found before them would hand the VM your SSH keys. `lima-*` also matches the VMs of your own Lima, if you have one. `--ssh-port` pins the port for tools that save it.',
            ],
            list: [],
            code: '# top of ~/.ssh/config\nInclude ~/.agent-vm/lima/*/ssh.config\nHost lima-*\n  ForwardAgent no\n  ForwardX11 no\n\nagent-vm info | grep ^ssh_host   # the alias to use\nagent-vm --ssh-port 2222 shell   # a fixed port',
          },
          {
            title: 'Shell, commands, hooks',
            paras: [],
            list: [
              'direnv only loads an `.envrc` you allowed, and a change revokes it; agent-vm also asks before the VM writes one ([Guarded files](#guarded-files)).',
              'mise trusts a config by its path: a VM allowed to change a trusted `mise.toml` makes your shell run its hooks and set its env on the next `cd`, agent-vm’s `AGENT_VM_UNSAFE_*` variables included. agent-vm asks before that write; `mise settings set paranoid true` also ties trust to the content. A config under another name (`mise.local.toml`, `.mise/config.toml`) is guarded only once you list it.',
              '`npm run`, `make`, `./gradlew`, `pytest`, `node_modules/.bin`, an activated `.venv`: each runs files the agent can write. Run them in the VM.',
              '`docker compose up` on your machine can mount any folder of yours into a root container. Docker runs in the VM: use it there.',
              'lefthook and pre-commit keep their commands in the working tree: agent-vm asks before the VM changes their config, but not the scripts it names. husky’s hooks call project scripts. Read them in the diff, or commit with `--no-verify`.',
            ],
            code: '',
          },
          {
            title: 'File managers',
            paras: [],
            list: [
              'macOS: files written through the share carry no quarantine flag, so Gatekeeper does not check an `.app`, `.command` or `.pkg` left there. Do not open them from Finder.',
              'Windows: Explorer contacts the server named in a `.library-ms`, `.url`, `.lnk` or `desktop.ini` it displays, sending your NTLM hash ([CVE-2025-24054](https://research.checkpoint.com/2025/cve-2025-24054-ntlm-exploit-in-the-wild/)). Keep Windows updated and outbound SMB blocked.',
              'Linux: KDE’s Dolphin ran commands from a `.desktop` file in a folder it only displayed (CVE-2019-14744, fixed in KDE Frameworks 5.61).',
            ],
            code: '',
          },
        ],
      },
      {
        title: 'Terminal and network',
        topics: [
          {
            title: 'Terminal escape sequences',
            paras: [
              'What the VM prints reaches your terminal unfiltered, and terminals act on escape sequences. agent-vm cannot filter them without breaking the agents’ full-screen interfaces.',
            ],
            list: [
              'Clipboard: OSC 52 lets a program set your clipboard, and in some terminals read it. Never allow reads, and check what you paste into a host shell.',
              'Replies typed for you: a sequence sent just before exit can make the terminal type into your host shell. Some were real bugs (iTerm2 [CVE-2024-38396](https://www.sentinelone.com/vulnerability-database/cve-2024-38396/)): keep your terminal updated.',
              'Features that act on your machine: iTerm2 file transfer and triggers, kitty remote control (keep it off), links whose text differs from their target.',
              'Spoofing: the VM can print a fake host prompt after a fake exit. Check where you are before typing a secret.',
            ],
            code: '',
          },
          {
            title: 'Network and ports',
            paras: [
              'A VM reaches the internet, not your machine: its loopback (where the other VMs’ ports are forwarded), its own addresses and your local networks (private, link-local and carrier-grade NAT ranges) are refused, on your machine, by the network stack agent-vm runs for each VM. Root in the VM cannot lift it.',
              'There is no `~/.agent-vm/network` by default, and none is needed: without it, the VMs reach the whole internet and nothing of your machine or local networks. Write one to open holes, read when a VM starts, one line each: `allow` an address (`192.168.1.20`), an address and port (`192.168.1.20:5432`, `[fd00::5]:80`), a network (`10.8.0.0/16`), or a service on your machine’s loopback, `localhost:PORT` (`localhost` alone opens every port), which the VM reaches at `192.168.5.2`. An `allow` line covers TCP and UDP.',
              '`domain` lines restrict the internet itself: those domains and their subdomains (`domain github.com` covers `api.github.com`; `*.github.com` means the same) become the only names the VMs resolve, and an address is reachable once agent-vm’s DNS gave it for one of them. `allow` lines still apply. A line it cannot read stops the start, named; `doctor` checks the file. `AGENT_VM_UNSAFE_OPEN_NETWORK=1` in your shell turns isolation off.',
              'Each port a VM listens on is forwarded to your `127.0.0.1`, and a notification says so. A port a program of yours listens on is left to it, with a notification too: on macOS, a VM listening first on 5432 would otherwise receive the connections, and passwords, meant for your local Postgres. On a free port, what you send goes to the VM: check the notification.',
              'No VM reaches the editor of another one any more, but `agent-vm code` still gives each its own password, made in that VM, and its own host name, `<vm-name>.localhost`. A VM can serve a page on a forwarded port and send your browser to another VM’s host name on that port; browsers keep cookies per host name and not per port, so the browser hands it that editor’s cookie. The VM cannot use it against the editor itself, being refused your loopback, but stop `agent-vm code` (Ctrl-C) when you are not using it. Chrome and Firefox resolve `*.localhost` themselves; Safari may not, and then `127.0.0.1` in a private window kept for the editor does the same.',
            ],
            list: [],
            code: '# ~/.agent-vm/network\nallow localhost:11434       # Ollama on this machine, at 192.168.5.2:11434\nallow 192.168.1.20:5432     # a database on the local network\nallow 10.8.0.0/16           # a VPN\n\n# only these on the internet, subdomains included\ndomain github.com\ndomain npmjs.org',
          },
        ],
      },
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
        body: 'agent-vm creates a Debian 13 VM with the Lima built into it. `agent-vm.setup.sh` installs the dev tools, Docker, Chromium and the agents inside it, then the VM is stopped and kept as a base template.',
      },
      {
        n: '02',
        title: 'The first run clones it',
        body: 'Running an agent in a directory clones the template into a persistent VM keyed to that path, mounts the working directory, and runs the [runtime scripts](#customisation-files): the per-user one first, the per-project one second.',
      },
      {
        n: '03',
        title: 'The agent works unattended',
        body: 'It is launched with its own auto-approve flag. It reaches the internet, not your machine. The ports it opens inside the VM are forwarded to yours, so a dev server is reachable in your browser as usual.',
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
      hostNote: 'Only agent-vm installed',
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
      'Each VM authenticates on its own: `claude login` happens inside it. Credentials persist across restarts of that VM and are shared with neither the host nor any other VM. Each VM has its own network stack too, which reaches the internet and not your machine: see [Network and ports](#network-and-ports).',
    contentsTitle: 'What is in the VM',
    contentsLede:
      'The setup wizard offers the default set: everything below except the rows marked no. Answer `n` to pick each item. `--preinstall` takes the names instead, comma-separated, plus `default`, `all` or `none`, and skips the wizard, as does a setup with no terminal.',
    contentsHeaders: ['Category', 'Packages', 'Name', 'Default'],
    contents: [
      ['Core', 'git, curl, wget, jq, zsh, ca-certificates, sshfs, build-essential, pkgconf, patch, unzip, zip, ripgrep, fd-find, htop', 'always', 'yes'],
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
      ['Editor', 'code-server (VS Code in the browser, for `agent-vm code`), dark theme, GitHub Copilot off, no telemetry', 'code-server', 'no'],
      ['Editor', 'The Claude Code, Codex or Mistral Vibe extension, each starting with no permission prompts, with code-server', 'code-claude, code-codex, code-vibe', 'no'],
    ],
    contentsCode:
      'agent-vm setup --preinstall=default                  # no prompts\nagent-vm setup --preinstall=default,rust             # plus Rust\nagent-vm setup --preinstall=python,docker,claude     # minimal Claude setup\nagent-vm setup --preinstall=default,code-claude      # plus the editor\nagent-vm setup --disk 50 --memory 16 --cpus 8        # a bigger template',
    contentsNote:
      '`codex` and `pi` pull in `node`, and so does `mcp-chrome` with `chromium` and an agent. Both MCP servers are skipped without `node` and `chromium`. Each editor extension ships its own copy of its agent (200 to 600 MB): the wizard asks whether to keep the command-line one too. Without it, `agent-vm claude` says it is not installed. This is only what the template ships: the agent is root in the VM and reaches the internet, so it installs whatever else it needs.',
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
      ['Outbound network', 'Open', 'Open by default', 'The internet, not your machine or local network ([Network and ports](#network-and-ports))'],
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
      'Docker runs natively inside the VM with no Docker-in-Docker, and headless Chromium works out of the box. On a Mac, this replaces Docker Desktop.',
  },

  roadmap: {
    title: 'Known gaps.',
    items: [
      {
        status: 'Built, not yet tried',
        title: 'Windows, natively',
        body: 'agent-vm runs on Windows without Git Bash now, its paths handled as `C:/...` and seen by the VM as `/c/...`, as in 0.2, and its tests run on any OS. Nothing of it has run on a Windows machine yet: setup, the shares, the network isolation, the port check. Wanted: someone to try it, on x86_64 or arm64, and a dialog for the guarded files there.',
      },
      {
        status: 'Idea',
        title: 'Review the agent’s writes',
        body: 'Every write of the VM goes through agent-vm’s SFTP server. It could keep them aside and let you review the diff, and apply all or part of it to the real folder. A first step: the list of every path the VM wrote during a session.',
      },
      {
        status: 'Needs an M3',
        title: 'Run a VM inside the VM',
        body: 'A `--allow-nested-vm` flag, for testing VM tooling from in there. Lima supports nested virtualization, but it is off by default and cannot be turned on unconditionally: below an Apple M3, Lima fails to start the VM instead of degrading, so every VM would stop starting. The flag would have to detect host support first. Nothing here has an M3 to test it on. It would also hand the agent a hypervisor interface.',
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
      'agent-vm is a Go program with Lima built in from upstream sources plus small patches, and a test suite that creates no VMs and needs no network. Bug reports, fixes and support for new agents are all welcome.',
    testsTitle: 'Run the tests',
    testsBody:
      'Two suites. Neither touches your VMs, your `~/.agent-vm` or your git config.',
    testsList: [
      '`make test-go` runs against a fake VM backend in throwaway folders: no VM, no network. Where 0.2’s bash version is compared, its results were recorded in `testdata/bashref`.',
      'The end-to-end tests boot real VMs in their own Lima home: the VM suite checks what a fake cannot (root in the guest cannot write `.git` or a guarded file, nor reach this machine’s loopback); the CLI suite runs `setup` and a command in a project.',
      '`make fuzz` runs every fuzzer, `FUZZTIME` each: the SFTP server’s name matching and a hostile client’s requests, the git scan, the env and volumes parsers, paths and names.',
    ],
    testsCode: 'make test-go                                       # fast, no VM\ngo test -tags e2e ./internal/vm/ ./internal/cli/   # real VMs\nmake fuzz FUZZTIME=5m',
    shellsTitle: 'Patch Lima, its SFTP server and its network',
    shellsBody:
      '`third_party/` holds Lima, sshocker, pkg/sftp and gvisor-tap-vsock: each the upstream commit in `third_party/SOURCES` plus the patches in `patches/`, every one small enough to be sent upstream. Never edit `third_party/` by hand: change a patch, then rebuild it. CI checks that nothing else is there.',
    shellsCode: 'scripts/third-party-sync sshocker   # rebuild from SOURCES and patches\nmake check-third-party              # what CI checks\nmake test-third-party               # their own tests, patched',
    structureTitle: 'Where things live',
    structureHeaders: ['File', 'What it is'],
    structure: [
      ['cmd/agent-vm/', 'The command’s entry point.'],
      ['internal/cli/', 'The commands, the start flow and its checks, setup, doctor.'],
      ['internal/vm/', 'The VMs, through the Lima built in.'],
      ['internal/limaembed/', 'Lima’s host agent, run as `agent-vm hostagent`, and the files it needs.'],
      ['internal/mounts/, internal/gitguard/', 'The shares, and the .git protection.'],
      ['internal/netguard/, internal/guard/', 'Network isolation, and the guarded files.'],
      ['third_party/, patches/', 'Lima and its SFTP server and network stack, upstream plus patches.'],
      ['agent-vm.setup.sh', 'Package installation, runs inside the base VM during setup.'],
      ['agent-vm.sh', 'Runs agent-vm: the binary next to it in a release, the one make builds in a clone. 0.2’s links and shell rc lines lead here.'],
      ['runtime.example.sh', 'Commented template for ~/.agent-vm/runtime.sh.'],
      ['CHANGELOG.md', 'What changed in each release.'],
      ['release.sh', 'Checks, tags and publishes a release, a tarball per platform. --dry-run first.'],
      ['www/', 'This website. Astro, static, deployed to GitHub Pages.'],
      ['www/public/install.sh', 'The curl installer, served at /install.sh.'],
    ],
    guidelinesTitle: 'Before you open a PR',
    guidelines: [
      'Every code path should be safe to re-run: check state before acting rather than assuming a clean machine.',
      'New behaviour gets a test, checked to fail without the change. The fake backend (`vmtest.Fake`) makes that cheap.',
      'A change to Lima, sshocker, pkg/sftp or gvisor-tap-vsock is a patch in `patches/`, small enough to be sent upstream.',
      'Integrator-facing surfaces (`info`, `env`, `version`) are contracts. Adding keys is fine, changing meanings is not.',
      'No secret, token or personal path in a commit, a test fixture or an issue.',
    ],
    issuesLabel: 'Open an issue',
    issuesHref: 'https://github.com/sylvinus/agent-vm/issues',
    prLabel: 'Browse pull requests',
    prHref: 'https://github.com/sylvinus/agent-vm/pulls',
    repoLabel: 'Read the source',
    repoHref: 'https://github.com/sylvinus/agent-vm',
    chatLabel: 'Chat on Matrix',
    chatHref: 'https://matrix.to/#/#agent-vm:matrix.org',
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
          { name: 'Lima', note: 'Linux VMs on macOS and Linux, built into agent-vm.', href: 'https://lima-vm.io/' },
          { name: 'sshocker and pkg/sftp', note: 'The SFTP server that serves the shares and keeps .git read-only.', href: 'https://github.com/lima-vm/sshocker' },
          { name: 'gvisor-tap-vsock', note: 'Each VM’s network stack, where the isolation applies.', href: 'https://github.com/containers/gvisor-tap-vsock' },
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
          { name: 'Pi', note: 'Minimal open-source harness.', href: 'https://pi.dev' },
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
            note: 'Pointed at the same Chromium.',
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
