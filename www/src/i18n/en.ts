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
      'agent-vm runs AI coding agents with every permission, in a Linux VM per project. Your SSH keys, your browser sessions and the rest of your disk are invisible to them.',
    installLabel: 'Get started',
    ctaPrimary: 'Install it',
    ctaSecondary: 'How it works',
    meta: 'MIT licensed · macOS, Linux, Windows (experimental) · built on Lima',
    terminalCaption:
      'Only the project directory is mounted.',
    points: [
      {
        title: '[Lima](https://lima-vm.io/) is the only host dependency',
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
      'A VM limits what a mistake or a compromised agent can reach to the project and what you hand it, such as [its env file](#share-secrets-across-vms). What stays open is the network: see [Security](#security).',
  },

  install: {
    eyebrow: 'Install',
    title: 'Install, build a template, run an agent.',
    lede:
      'agent-vm is a few shell scripts, with no daemon.',
    prerequisitesTitle: 'Prerequisites',
    prerequisites: [
      { name: 'macOS, Linux or Windows', note: 'Windows is experimental: Git Bash, QEMU and Lima for Windows required.', href: '' },
      {
        name: 'Lima',
        note: '`agent-vm setup` offers to install it. On Linux, QEMU and KVM too; on Windows, QEMU.',
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
        note: 'Downloads the latest release from GitHub, checks it against the release’s `SHA256SUMS`, unpacks it in `~/.local/share/agent-vm` and links `agent-vm` into `~/.local/bin`. It then offers to run step 2 right away. Run it again to update. `sh -s -- --version X.Y.Z` installs a given release, `sh -s -- --git` a clone of `main`.',
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
        note: '`install` symlinks `agent-vm` onto your `PATH`, so `git pull` in the clone is the update. It then offers to run step 2 right away.',
      },
      {
        id: 'windows',
        label: 'Windows',
        code: '# in Git Bash (experimental)\nwinget install SoftwareFreedom.QEMU\ncurl -fsSL https://www.agent-vm.org/install.sh | sh',
        note: 'Experimental, in Git Bash. `agent-vm setup` then offers a Lima build for Windows: take it, Lima’s own does not keep the VM to its shares. VMs also need the Windows Hypervisor Platform feature, which an administrator turns on once: see [Windows and WSL](#windows-and-wsl).',
      },
    ],
    steps: [
      {
        title: 'Build the base template',
        body: 'Run once. Without Lima, or without the build that keeps `.git` [read-only](#git), it first offers to install it. A wizard then picks what goes in the template: Enter takes the default set (see [What is in the VM](#what-is-in-the-vm)). It builds a Debian 13 VM with it and keeps it, stopped, as the template.',
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
        body: 'Lima forwards every port opened in the VM to the same port on your localhost, so a dev server opens in your browser as usual. Treat those ports as the agent’s.',
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
        body: 'A new VM gets the template’s 10 GB of disk, 3 GB of memory and 1 CPU. Pass another value and the VM is reconfigured, after asking if it is running. Disk only grows. CPU and memory are capped at half the host, per VM.',
        code: 'agent-vm --disk 50 opencode\nagent-vm --memory 16 --cpus 8 shell\nagent-vm --reset claude   # re-clone from the base template',
      },
      {
        title: 'Share secrets across VMs',
        body: '`KEY=value` lines in `~/.agent-vm/env`, pushed into every VM on each command. Everything in the VM can read them: use narrow tokens you can revoke. Edit with `env set`, since one bad quote in the file breaks all of it.',
        code: 'agent-vm env set GH_TOKEN   # pasted unseen, not in history\nagent-vm env list           # names only, never values\nagent-vm env has ANTHROPIC_API_KEY\n\n# scoped to this project only\nagent-vm project-env set SOME_PATH ./config',
      },
      {
        title: 'Edit with the VM’s tools',
        body: 'For language servers, linters, the debugger and the VM’s packages, run the editor in the VM: `agent-vm code` serves VS Code (code-server) to a browser tab, the only part on your machine. Set it up with `code-server` or a `code-*` name ([What is in the VM](#what-is-in-the-vm)). The tab can still open links, and every VM reaches the editor’s port, hence a password and a host name per VM ([Network and ports](#network-and-ports)). Do not connect a desktop editor over SSH instead ([SSH from your machine](#ssh-from-your-machine)).',
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
          ['code', 'Serve VS Code (code-server) from the VM at `http://<vm-name>.localhost:<port>/` and open it in your browser, until Ctrl-C. Its password is made in the VM on first use and printed. Needs `code-server` or a `code-*` name at setup ([What is in the VM](#what-is-in-the-vm)).'],
        ],
      },
      {
        title: 'Manage the fleet',
        rows: [
          ['list, status', 'List all agent-vm VMs, the current directory’s marked with `>`, with the agent-vm version that built the base each was cloned from, and when.'],
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
      ['--memory GB', 'VM memory. Clamped to half the host, per VM.', 'the template’s (3)'],
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
      ['AGENT_VM_STATE_DIR', 'Moves `~/.agent-vm`, for tests, CI or a second install, without moving `HOME` (and Lima’s VMs with it).', '~/.agent-vm'],
      ['AGENT_VM_PROJECT_ENV', 'The project’s env file, relative to the project or absolute.', '.agent-vm.env'],
      ['AGENT_VM_PROJECT_RUNTIME', 'The project’s runtime script, relative to the project or absolute. Outside the project, the host reads it.', '.agent-vm.runtime.sh'],
      ['AGENT_VM_HOST_SHARE', 'CPU and memory per VM are capped at the host’s divided by this. `1`: the whole host.', '2'],
      ['AGENT_VM_BIN_DIR', 'Where `install` links `agent-vm`.', '~/.local/bin'],
      ['AGENT_VM_LIMA_DIR', 'Windows: where `setup` puts its Lima build.', '~/.local/share/lima-sylvinus'],
      ['AGENT_VM_QEMU_DIR', 'Windows: where QEMU is, when not on `PATH`.', '/c/Program Files/qemu'],
      ['AGENT_VM_UNSAFE_WRITABLE_GIT', '`1`: same as `--unsafe-writable-git`.', 'unset'],
      ['AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS', '`1`: same as `--unsafe-disable-security-prompts`.', 'unset'],
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
      'Use these commands rather than parsing human-facing output or reading `~/.agent-vm`: VM names and state files are implementation details. All of them work without Lima.',
      '`version --min` exits `0` when recent enough, `1` when older, `2` on a malformed call; an engine predating `--min` ignores it and exits `0`. In `info`, booleans are `1` or `0`, `unknown` when undeterminable, and `base_exists=1` means the template is usable.',
      'A start asks its questions only when stderr is a terminal: otherwise it stops there. `security_questions` in `info` names them beforehand (`lima`, `lima-unknown`, `hooks`, `git-config`, `bare-repo` or `none`), and `--unsafe-disable-security-prompts` accepts them once the user agreed.',
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
              'Run the curl installer again, `brew upgrade agent-vm`, or `git pull` in a clone. `agent-vm uninstall` removes the link; VMs and `~/.agent-vm` stay.',
              'Running `setup` again rebuilds the template, not the VMs cloned from it: agent-vm warns about those, and `--reset` re-clones one. Its full log is in `~/.agent-vm/setup.log`.',
              'From 0.1.0, run `agent-vm setup`: until then, each VM from a base 0.1.0 built boots once more to install `sshfs`.',
            ],
            list: [],
            code: '',
          },
          {
            title: 'Windows and WSL',
            paras: [
              'VMs need the Windows Hypervisor Platform feature. It is off by default and only an administrator can turn it on, once, in Windows Features or with the command below, then a reboot. On a managed laptop, that is a request to IT.',
              'In WSL2, KVM needs nested virtualization from the Windows host; WSL1 cannot run VMs.',
            ],
            list: [],
            code: '# in PowerShell as administrator, then reboot\nDISM /Online /Enable-Feature `\n  /FeatureName:HypervisorPlatform /All',
          },
          {
            title: 'Paths',
            paras: [
              'Paths with whitespace, quotes, backslashes or control characters are refused. iCloud Drive paths have spaces: go through a symlink.',
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
              'With a Lima that has `sshfs.readonlyNames`, every `.git` and `.hg` in the shares is read-only for the VM, at any depth, enforced on the host by Lima’s SFTP server. The agent reads the history but cannot commit. It is not merged upstream yet ([lima-vm/lima#5529](https://github.com/lima-vm/lima/issues/5529)), so `agent-vm setup` offers a build that has it. The shares then use `reverse-sshfs`, slower on many files (see [Node.js](#node)).',
            ],
            list: [],
            code: 'brew unlink lima; brew install sylvinus/tap/lima-sylvinus\nagent-vm doctor    # where you stand\n\n# let the agent commit anyway\nagent-vm --unsafe-writable-git claude',
          },
          {
            title: 'Beyond the name .git',
            paras: [
              'The folder a `core.hooksPath` points to in the project (`.husky` for husky) is read-only too. A folder holding git’s internals (`HEAD`, `objects/`, `refs/`, a `config`) is a repository under any name: setting `safe.bareRepository` to `explicit` in your global git config makes git ignore it. A config included from the project, or hooks at the top of a repository, are the same kind of door.',
              'Before a VM boots with writable shares, agent-vm stops on each of these it finds, and on a Lima without `readonlyNames`, and asks: Enter, or no terminal, aborts. `doctor` lists them. `--unsafe-writable-git` (or `AGENT_VM_UNSAFE_WRITABLE_GIT=1` in your shell, never read from the project) lets the agent commit and reopens that path to your host, with a warning on every run.',
            ],
            list: [],
            code: '',
          },
          {
            title: 'The Lima build',
            paras: [
              'On Windows, `setup` downloads it and checks it against checksums pinned in agent-vm. Elsewhere, Homebrew installs it, or build it from source.',
              'A Lima whose answer agent-vm cannot read stops the start with an error, rather than passing for one without `readonlyNames`.',
            ],
            list: [],
            code: '# back to Homebrew’s Lima\nbrew uninstall lima-sylvinus && brew link lima\n\n# the Lima build, without Homebrew (needs Go and make)\ngit clone --depth 1 -b v2.3.0-sylvinus.2 https://github.com/sylvinus/lima\ncd lima && make native && sudo make install',
          },
        ],
      },
      {
        title: 'What agent-vm does',
        topics: [
          {
            title: 'Refused directories and files',
            paras: [
              'agent-vm will not share your home directory, `/`, its own directory, `~/.agent-vm`, Lima’s directory, or a directory containing one of them: `cd ~ && agent-vm shell` would hand the VM your dotfiles and SSH keys.',
              'It never reads a file in the project by its path, since the VM can make it a symlink to any file of yours. Its own git calls in a project refuse a bare repository and run no `core.fsmonitor` or pager.',
            ],
            list: [],
            code: '',
          },
          {
            title: '--readonly, in detail',
            paras: [
              '`--readonly` covers every share, `rw` volumes included: a writable volume containing the project would be a second way in. Whether the host enforces it is read from what Lima reports, never from the guest. Where it would not (`reverse-sshfs` without `readonlyNames`, virtiofs under QEMU), the flag is refused.',
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
            title: 'Keeping your checkout out of reach',
            paras: [
              'Do not give agent-vm the checkout you work in. Clone the project a second time, run agent-vm there, and `git fetch` its work into your checkout once you have read the diff. Fetching does not check files out, so the agent’s files reach your working tree only when you merge. This needs a Lima that keeps `.git` read-only: otherwise the VM can write the clone’s `.git`, which git then reads.',
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
              'Do not connect VS Code Remote-SSH or open-remote-ssh to an agent VM. They run a server in the VM, which root in the VM controls, and the editor on your machine trusts it. Microsoft’s Remote-SSH page says so: “a compromised remote could use the VS Code Remote connection to execute code on your local machine”, and it is by design. Public write-ups show it opening a terminal on the host and running commands there. That removes the boundary agent-vm sets up, which is worse than opening the project in Restricted Mode. JetBrains Gateway most likely works the same way; it has not been checked. For language servers and a debugger with the VM’s packages, use [`agent-vm code`](#edit-with-the-vm-s-tools).',
              'For scripts, `scp` or `rsync`, `agent-vm info` prints the SSH alias as `ssh_host`. Put these lines at the top of `~/.ssh/config`: a `ForwardAgent yes` found before them would hand the VM your SSH keys. `--ssh-port` pins the port for tools that save it.',
            ],
            list: [],
            code: '# top of ~/.ssh/config\nInclude ~/.lima/*/ssh.config\nHost lima-agent-vm-*\n  ForwardAgent no\n  ForwardX11 no\n\nagent-vm info | grep ^ssh_host   # the alias to use\nagent-vm --ssh-port 2222 shell   # a fixed port',
          },
          {
            title: 'Shell, commands, hooks',
            paras: [],
            list: [
              'direnv only loads an `.envrc` you allowed, and a change revokes it.',
              'mise trusts a config by its path, so the agent can change a trusted `mise.toml`: your shell runs its hooks and sets its env on the next `cd`, agent-vm’s `AGENT_VM_UNSAFE_*` variables included. `mise settings set paranoid true` ties trust to the content.',
              '`npm run`, `make`, `./gradlew`, `pytest`, `node_modules/.bin`, an activated `.venv`: each runs files the agent can write. Run them in the VM.',
              '`docker compose up` on your machine can mount any folder of yours into a root container. Docker runs in the VM: use it there.',
              'lefthook and pre-commit keep their commands in the working tree, and husky’s hooks call project scripts: read them in the diff, or commit with `--no-verify`.',
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
              'The VM reaches the internet and every service on your machine’s loopback, at `192.168.5.2`. Lima forwards every port a VM listens on to your `127.0.0.1` when it is free: a VM that listens first on 5432 receives the connections, and passwords, meant for your local Postgres. Blocking this is [on the roadmap](#roadmap).',
              'So every VM can reach the editor of every other one. `agent-vm code` gives each its own password, made in that VM, and its own host name, `<vm-name>.localhost`: browsers keep cookies per host name and not per port, so at `127.0.0.1` any page a VM serves would receive the editor sessions of the others, and with them a way in. Chrome and Firefox resolve `*.localhost` themselves; Safari may not, and then `127.0.0.1` in a private window kept for the editor does the same.',
            ],
            list: [],
            code: '',
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
      'Each VM authenticates on its own: `claude login` happens inside it. Credentials persist across restarts of that VM and are shared with neither the host nor any other VM. The network is shared, though: see [Network and ports](#network-and-ports).',
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
      '`codex` and `pi` pull in `node`, and so does `mcp-chrome` with `chromium` and an agent. Both MCP servers are skipped without `node` and `chromium`. Each editor extension ships its own copy of its agent (200 to 600 MB): the wizard asks whether to keep the command-line one too. Without it, `agent-vm claude` says it is not installed. This is only what the template ships: the agent is root in the VM and has the network, so it installs whatever else it needs.',
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
      'Docker runs natively inside the VM with no Docker-in-Docker, and headless Chromium works out of the box. On a Mac, this replaces Docker Desktop.',
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
      'Two suites. Neither touches your VMs, your `~/.agent-vm` or your git config.',
    testsList: [
      '`./test.sh` runs against a stub `limactl` in a throwaway `HOME`: no VM, no network. It covers naming, resources, the `info` and `version` surface, the `--preinstall` parser and the mount modes.',
      '`./test-e2e.sh` builds a real VM with `--preinstall=none` in its own `LIMA_HOME`, and checks what a stub cannot: that root in the guest cannot lift `--readonly` or write `.git`, and that a `--scratch` VM sees nothing of the host.',
      'Unit tests are `tests/NN-*.sh`, run in order in one shell after `tests/helpers.sh`. A new area gets its own file.',
    ],
    testsCode: './test.sh        # fast, no VM\n./test-e2e.sh    # real VM, needs Lima',
    shellsTitle: 'Test the shells that matter',
    shellsBody:
      'macOS still ships bash 3.2, which is stricter about empty array expansion under `set -u` than modern bash. A change that passes on bash 5 can still break on a stock Mac. The `bash:3.2` image has no git, so the tests that need it skip there: add it with `apk`.',
    shellsCode: 'docker run --rm -v "$PWD:/w" -w /w bash:3.2 ./test.sh\n\n# with git, for the tests that need it\ndocker run --rm -v "$PWD:/w" -w /w bash:3.2 sh -c \'\n  set -e\n  apk add -q git\n  git config --global safe.directory "*"\n  ./test.sh\'',
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
      ['release.sh', 'Checks, tags and publishes a release. --dry-run first.'],
      ['www/', 'This website. Astro, static, deployed to GitHub Pages.'],
      ['www/public/install.sh', 'The curl installer, served at /install.sh.'],
    ],
    guidelinesTitle: 'Before you open a PR',
    guidelines: [
      'Keep it bash 3.2 compatible, and run `./test.sh` under `bash:3.2` as well as your own shell.',
      'Every code path should be safe to re-run: check state before acting rather than assuming a clean machine.',
      'New behaviour gets a test in `tests/` (a new area gets its own `NN-*.sh`). The stub `limactl` makes that cheap.',
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
          { name: 'Lima', note: 'Linux VMs on macOS, Linux and Windows. The only host dependency, with QEMU on Windows.', href: 'https://lima-vm.io/' },
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
