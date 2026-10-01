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
      'AI coding agents need broad permissions to be useful: they install dependencies, run builds, start servers. agent-vm gives each project its own Linux VM and runs the agent in there instead. Your SSH keys, your browser sessions and the rest of your disk are invisible to it.',
    installLabel: 'Get started',
    ctaPrimary: 'Install it',
    ctaSecondary: 'How it works',
    meta: 'MIT licensed · macOS, Linux, Windows (experimental) · built on Lima',
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
      'A VM limits what a mistake or a compromised agent can reach: your source tree and whatever you put in [its env file](#share-secrets-across-vms), but not your SSH keys, your git credentials or your browser sessions. [`--readonly`](#tighten-the-session) narrows it further, and the host enforces it, so root in the guest cannot lift it. The shared project is guarded too: with a Lima that has `sshfs.readonlyNames`, every `.git` in it is read-only for the VM, so the agent cannot plant a hook or a config in `.git` that git on your host would then run (see [Protecting .git](#git) below). What stays open is the network: the agent can send data anywhere, and Lima puts your host loopback at `192.168.5.2`, so a dev database listening on localhost is reachable from the VM.',
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
        note: 'agent-vm setup offers to install it with Homebrew, as a build that keeps `.git` read-only until that is merged upstream. On Linux, QEMU and KVM too. On Windows, QEMU (winget) and the Windows Hypervisor Platform feature; setup offers the Lima download.',
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
        note: 'Experimental. Run it in Git Bash: it is the curl installer, and `agent-vm setup` then offers a Lima build for Windows. Take it: with Lima’s own, the shares use `reverse-sshfs`, which does not keep the VM to them, and root in the VM may reach your SSH keys and the rest of your disk (a start says so, and asks). VMs also need Windows’ own hypervisor, the Windows Hypervisor Platform feature. It is off by default and only an administrator can turn it on, once (Windows Features, or `DISM /Online /Enable-Feature /FeatureName:HypervisorPlatform /All`, then a reboot). On a managed laptop, that is a request to IT. Without it, VMs do not start.',
      },
    ],
    steps: [
      {
        title: 'Build the base template',
        body: 'Run once. Without Lima, it first offers to install it, the build that keeps `.git` read-only for the VMs. Its wizard then offers a default set; press Enter to accept it. After it, a Lima that cannot keep `.git` read-only gets the same offer. Then it creates a Debian 13 VM, installs the toolchain and the agents, and keeps it, stopped, as a reusable template.',
        code: 'agent-vm setup',
      },
      {
        title: 'Run an agent in your project',
        body: 'Clones the template into a VM for this directory, mounts the working directory, launches the agent with permissions already granted. Before the VM boots, agent-vm may stop on a security question, such as a git setting it offers to make: see [Protecting .git](#git).',
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
      'Installed with curl: run the installer again. With Homebrew: `brew upgrade agent-vm`. From a clone: `git pull`, nothing to reinstall. `agent-vm uninstall` removes the link that curl and git installs make. From 0.1.0, run `agent-vm setup` once: a VM from a base 0.1.0 built boots once more on its next start to install `sshfs`, which keeping `.git` read-only needs, and `--reset` gives it the new base. That migration will be removed in a future release.',
  },


  usage: {
    eyebrow: 'Usage',
    title: 'Everyday commands.',
    lede:
      'Every VM is keyed to a directory, `--scratch` ones excepted. Run an agent command twice in the same folder and you get the same machine back, with its packages, its containers and its logins intact.',
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
        body: 'VS Code Remote-SSH, JetBrains Gateway or a GUI agent can keep their window on the host and run the rest in the VM. Lima writes an SSH config per VM with the current port, under the alias `agent-vm info` prints as `ssh_host`. Put the lines below at the top of `~/.ssh/config`, above any `Host *`: ssh takes the first value it finds, and a `ForwardAgent yes` there would hand the VM every key in your SSH agent, as would VS Code’s `remote.SSH.enableAgentForwarding` without these lines. For a tool that saves the port instead of the alias, `--ssh-port` fixes it (`0` goes back to a new one on each start).',
        code: '# top of ~/.ssh/config\nInclude ~/.lima/*/ssh.config\nHost lima-agent-vm-*\n  ForwardAgent no\n  ForwardX11 no\n\nagent-vm info | grep ^ssh_host   # the alias to use\nagent-vm --ssh-port 2222 shell   # a fixed port',
      },
      {
        title: 'Manage the fleet',
        body: 'The current directory’s VM is marked with `>` in `list`. If a directory is renamed, `list` is the only way to find its VM again.',
        code: 'agent-vm list          # all VMs, current one marked, base of each\nagent-vm stop          # stop, keep the disk\nagent-vm rm            # stop and delete\nagent-vm destroy-all   # every VM, base template included\nagent-vm doctor        # what is wrong, and what to run',
      },
      {
        title: 'Tighten the session',
        body: 'Useful for review and audit work, where the agent has no business writing anything. `--readonly` makes every host share read-only: the project and the [`~/.agent-vm/volumes`](#customisation-files) entries, `rw` ones included, since a writable volume containing the project would be a second way in. It is set on the Lima shares, so the host refuses the writes (the hypervisor, or Lima’s SFTP server on the shares that protect `.git`) and root in the VM cannot lift it. Where Lima would only apply it inside the guest, agent-vm refuses the flag: `reverse-sshfs` without `readonlyNames`, and virtiofs under QEMU. A running VM in the other mode is restarted, asked first (no by default): declined, or with no terminal, the command fails, in either direction, so another session’s read-only VM is not made writable under it. The VM’s own disk, `$HOME` and `/tmp` stay writable, so the agent can still install packages and write caches. Anything it writes inside the project fails, including `node_modules`, its own state directory, and whatever a runtime script writes: the mode is applied before those run. `--scratch` goes further: a new VM with nothing of yours mounted, which the agent fills from the network (a `git clone` with a token from `agent-vm env`), deleted when the command ends; on a terminal it asks first, and a no opens a shell in the VM. Its work leaves the same way, as a push or a pull request. Logins do not survive it, so agents need their token in `agent-vm env`: `ANTHROPIC_API_KEY`, or `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`.',
        code: 'agent-vm --readonly shell     # nothing on the host is writable\nagent-vm --scratch claude     # nothing of yours mounted, deleted on exit\nagent-vm --rm run npm test    # destroy the VM on exit',
      },
      {
        title: 'Resize on the fly',
        body: 'A new VM gets the base template’s: 10 GB of disk, 3 GB of memory and 1 CPU, unless `setup` was given others. Pass a flag with another value and the VM is stopped, reconfigured and restarted; a running one is asked about first (no by default), and declined, or with no terminal, it keeps its settings. Disk can grow, never shrink. CPU and memory are clamped to half the host per VM, which is not a budget across all of them: VMs persist, so several running at once add up. `agent-vm list` shows what you have, `rm` and `destroy-all` reclaim it.',
        code: 'agent-vm --disk 50 opencode\nagent-vm --memory 16 --cpus 8 shell\nagent-vm --reset claude   # re-clone from the base template',
      },
      {
        title: 'Share secrets across VMs',
        body: 'Plain `KEY=value` lines in `~/.agent-vm/env`, pushed into every VM on every invocation and loaded in its shells. Use the subcommands rather than editing the file by hand: a shell sources it, so one unescaped quote breaks every secret in the file, not just that line.',
        code: 'agent-vm env set GH_TOKEN        # paste it: not shown, not in history\nagent-vm env list              # names only, never values\nagent-vm env has ANTHROPIC_API_KEY\n\n# scoped to this project only\nagent-vm project-env set SOME_PATH ./config',
      },
      {
        title: 'Ask from a script',
        body: 'If you wrap agent-vm from another tool, use these rather than parsing human-facing output or reading `~/.agent-vm` directly: VM naming, the template name and the state files are implementation details and will change. `version --min` exits `0` when the engine is recent enough, `1` with a message when it is older, and `2` when the call itself is malformed, so a typo in the required version cannot read as "engine too old". One catch: an engine predating `--min` ignores the flag and exits `0`. In `info`, booleans are `1` or `0` and anything undeterminable reads `unknown`; all four commands work without Lima installed. A start with no terminal stops where it would ask a security question: `security_questions` in `info` lists them beforehand, and `--unsafe-disable-security-prompts` accepts them, or `--readonly` avoids them. A restart it would ask about fails too: `--readonly` on a running writable VM, or the other way round, and a resize of a running VM is left unapplied.',
        code: 'agent-vm version --min 0.2.0 || exit 1  # silent when OK\nagent-vm name [dir]    # VM name for a directory\nagent-vm info [dir]    # one key=value per line\nagent-vm help          # the built-in help\n\n# info keys: version, template, state_dir,\n# project_env, dir, vm_name, base_exists,\n# vm_exists, vm_running, vm_stale,\n# ssh_host, ssh_config, git_protected,\n# security_questions',
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
      'One `source[:destination][:mode][:project]` per line, `~` expanded on the left, `#` for comments. The mode is `ro` (default) or `rw`, and `rw` only works for directories. Without a destination, the path is mounted at the same place in the VM. A relative destination is inside the project, over whatever the project has there. The fourth field, after an explicit mode, limits the entry to the projects it matches, `*` matching anything. An entry that does not read that way is skipped with a warning, never mounted everywhere.',
    volumesCode:
      '# ~/.agent-vm/volumes\n~/.gitconfig    # same path, read-only\n~/.cache/shared:/home/you.guest/.cache/shared:rw\n\n# only in ~/work/webapp, as its .claude, read-only\n~/.claude-vm/webapp:.claude:ro:~/work/webapp\n\n# every project under ~/work\n~/.cache/pip:/home/you.guest/.cache/pip:rw:~/work/*\n\n# same path, one project only\n~/datasets::ro:~/work/ml',
    volumesNote:
      'Kept on your side and not in the project on purpose: the agent can write the project, and a mount list there would let it mount any host directory into its own VM. For the same reason, a relative destination that leaves the project with `..` or goes through a symlink in it is skipped. agent-vm creates a missing mount point in the project on your machine, so an empty `.claude` shows up there too. Changes apply to new VMs: `--reset` re-applies them.',
    gitTitle: 'Letting the agent commit',
    gitBody:
      'git reads its identity from the environment, so the shared env file covers it with no `git config` inside the VM. All four variables are needed: git refuses to commit without a committer, not just an author.',
    gitCode:
      '# ~/.agent-vm/env\nGIT_AUTHOR_NAME=Your Name\nGIT_AUTHOR_EMAIL=12345+you@users.noreply.github.com\nGIT_COMMITTER_NAME=Your Name\nGIT_COMMITTER_EMAIL=12345+you@users.noreply.github.com',
    gitNote:
      'These variables win over `git config`, in every repository of the VM: for per-repository identities, set `user.name` and `user.email` from a runtime script instead. `gh` picks up `GH_TOKEN` on its own, so `gh pr create` works with nothing else. Plain `git push` over HTTPS needs a credential helper: one `gh auth setup-git` line in your [runtime script](#customisation-files).',
    gitHumanTitle: 'That said, keep the commits human',
    gitHumanBody:
      'Being able to commit is not a reason to let it. A commit says you read the diff, so let the agent write the code, read it, and commit it yourself. With a Lima that [keeps `.git` read-only](#git), that is the only way: the agent cannot commit in the shared project, unless you turn the protection off, which gives it a way to run commands on your host.',
    gitGuardTitle: 'Protecting .git',
    gitGuardBody:
      'Git on your machine runs what a repository’s `.git/config` and hooks name: `core.fsmonitor` on every `git status`, hooks on commit. Your editor and shell prompt run `git status` on their own, so a VM able to write `.git` could run commands on your host within seconds, and nothing of it would show in `git diff`. With a Lima that has `sshfs.readonlyNames`, every `.git` in the shares is read-only for the VM, at any depth, and Lima’s SFTP server enforces it on the host: the agent reads the history but cannot commit. It is not merged upstream yet ([lima-vm/lima#5529](https://github.com/lima-vm/lima/issues/5529)), so `agent-vm setup` offers a build that has it. The shares then use `reverse-sshfs`, slower on many files (see [Node.js](#node)).',
    gitGuardCode:
      'brew unlink lima; brew install sylvinus/tap/lima-sylvinus\nagent-vm doctor                          # where you stand\nagent-vm --unsafe-writable-git claude    # let it commit anyway\n# no Homebrew: build github.com/sylvinus/lima\n# Windows (Git Bash): setup offers this download; by hand (AMD64 shown):\nbase=https://github.com/sylvinus/lima/releases/download/v2.3.0-sylvinus.2\ncurl -fsSLO "$base/lima-2.3.0-sylvinus.2-Windows-AMD64.zip" \\\n     -fsSLO "$base/lima-additional-guestagents-2.3.0-sylvinus.2-Windows-AMD64.zip"\nsha256sum -c <<\'EOF\'   # the checksums agent-vm pins\n053f3479b397628b79fe46b0268a50a7f1fc51073691d7d8bce78c9be2ae2787  lima-2.3.0-sylvinus.2-Windows-AMD64.zip\na0828aa4518e21c9519d341be9f32adf07cbeb74a3f8beadaa2f350c45b5933b  lima-additional-guestagents-2.3.0-sylvinus.2-Windows-AMD64.zip\nEOF\nfor z in lima-*-Windows-AMD64.zip; do unzip -q -o "$z" -d ~/.local/share/lima-sylvinus; done\nexport PATH="$HOME/.local/share/lima-sylvinus/bin:$PATH"   # and in ~/.bash_profile',
    gitGuardNote:
      'Every `.hg` is read-only too, and so is the folder each `core.hooksPath` points to in the project (`.husky` for husky). A running VM gets new protections at its next start, which agent-vm offers. The `.git` name is not the only way in, though. A folder the VM fills with git’s internal files (`HEAD`, `objects/`, `refs/`, a `config`) is a repository to git under any name, and git runs the commands its `config` names, such as its pager as soon as you type `git log` there: `git config --global safe.bareRepository explicit` makes git ignore such folders. A config file included from the project, or a setting whose command is a file in it, is the same kind of door. Before a VM boots with writable shares, agent-vm stops on each of these it finds, and on a Lima without `readonlyNames`, and asks whether to go on: Enter, or no terminal, aborts. It offers to set `safe.bareRepository` for you. `doctor` lists them, and `info` names them for scripts. `--unsafe-writable-git`, or `AGENT_VM_UNSAFE_WRITABLE_GIT=1` in your shell, turns the protection off so the agent can commit, and reopens that path to your host: a warning says so on every run.',
    gitGuardEditor:
      'Your editor is the same kind of door. The agent can write a `.vscode/tasks.json`, workspace settings, an `eslint.config.js` or a `build.rs`, which VS Code and its extensions can run. When VS Code asks, leave the project untrusted (Restricted Mode), and do not trust a parent folder: that trusts everything below it. JetBrains IDEs have the same choice (Safe Mode). The rest is in [Security](#what-else-on-your-machine-reads-the-project).',
    nodeTitle: 'Node.js: node_modules in the VM',
    nodeBody:
      'Hundreds of thousands of files are slow across the share, and native packages differ between macOS and Linux anyway. Mount a folder of the VM’s own disk over `node_modules` from the project’s [runtime script](#customisation-files), which runs on every command:',
    nodeCode:
      '#!/bin/bash\n# .agent-vm.runtime.sh\nset -e\nmkdir -p "$HOME/node_modules" node_modules\nmountpoint -q node_modules ||\n  sudo mount --bind "$HOME/node_modules" node_modules',
    nodeNote: 'The host sees an empty `node_modules`, or keeps its own: install there too if your editor needs the packages. `--reset` and `rm` delete the VM’s copy. In a workspace, the root `node_modules` holds nearly everything (npm hoists, pnpm keeps its store in `node_modules/.pnpm`); repeat the mount for a package with a large one of its own. A dev server in the VM may need polling to see edits made on the host (Vite: `server.watch.usePolling`).',
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
      ['--disk GB', 'VM disk size. Can grow, never shrink.', 'the template’s (10)'],
      ['--memory GB', 'VM memory. Clamped to half the host, per VM.', 'the template’s (3)'],
      ['--cpus N', 'CPU count. Clamped to half the host, per VM.', 'the template’s (1)'],
      ['--ssh-port N', 'Fixed host port for the VM’s SSH, for tools that save it. `0` goes back to a new one on each start. Restarts a running VM, asked first.', 'a new one per start'],
      ['--reset', 'Destroy and re-clone the VM from the base template.', 'off'],
      ['--readonly', 'Every host share read-only (project and volumes), host-side. Restarts a running VM, asked first.', 'off'],
      ['--unsafe-writable-git', 'Leave every `.git` writable so the agent can commit, with a warning. See [Protecting .git](#git).', 'off'],
      ['--unsafe-disable-security-prompts', 'Go on where a start would stop to ask a security question (see [Protecting .git](#git)), without offering to change your git config. The warnings are still printed. For scripts with no terminal; `AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1` in your shell does the same.', 'off'],
      ['--rm', 'Destroy the VM once the command exits.', 'off'],
      ['--scratch', 'A new VM with nothing of yours mounted, neither the project nor the volumes, deleted when the command ends, Ctrl-C included. On a terminal, the deletion is asked first (yes by default): no opens a shell in the VM, and leaving it asks again. The project’s env file and runtime script stay out; `~/.agent-vm/env` and `runtime.sh` go in. The folder’s own VM is left alone, and several can run at once. A run killed outright leaves its VM behind: the next `--scratch` run deletes it, and `doctor` lists it until then. See [Tighten the session](#tighten-the-session).', 'off'],
    ],
  },



  reference: {
    eyebrow: 'Reference',
    title: 'The details.',
    lede: 'What the cards above leave out: installer options, what setup does, the configuration files, and the variables for scripts.',
    groups: [
      {
        title: 'Install and setup',
        topics: [
          {
            title: 'Installer options',
            paras: [
              'Options go after `sh -s --`: `--version X.Y.Z`, `--git` for a clone of `main`, `--dir DIR` for another place than `~/.local/share/agent-vm` (or `$XDG_DATA_HOME/agent-vm`). To read the installer first, download it, then run it with `sh`.',
              'It ends with `agent-vm install`, which links `agent-vm` into `~/.local/bin` (`AGENT_VM_BIN_DIR` changes it), or writes a small launcher where Git Bash makes no symlinks. The command works from any shell, fish included: the `source .../agent-vm.sh` line earlier versions added to your shell rc is no longer needed, and `install` says so when it finds one. `./install.sh` remains as a wrapper, for now.',
            ],
            list: [],
            code: 'curl -fsSL https://www.agent-vm.org/install.sh | sh -s -- --dir ~/tools/agent-vm\ncurl -fsSLO https://www.agent-vm.org/install.sh && sh install.sh',
          },
          {
            title: 'What setup does',
            paras: [
              'The wizard first offers the default set; answer `n` to be asked about each component. Creating the VM (the first run downloads a Debian image) and installing packages show their last 10 lines, in place; the full output goes to `~/.agent-vm/setup.log`.',
              'The `mcp-*` names wire an MCP server into every installed agent but Pi, which has no MCP support. Leave them out to keep the agents’ MCP config untouched, when MCP servers are managed per project. `mcp-playwright` does not pull in `node`: list it too.',
              'Running `setup` again rebuilds the template, not the existing VMs: agent-vm warns when a VM comes from an older template, and `--reset` re-clones it. An interrupted `setup` leaves an unusable template, which `info` reports as `base_exists=0`; run `setup` again.',
            ],
            list: [],
            code: '',
          },
          {
            title: 'Windows, WSL and paths',
            paras: [
              'On Windows, `setup` puts the Lima build in `~/.local/share/lima-sylvinus` (`AGENT_VM_LIMA_DIR` moves it) and looks for QEMU in `/c/Program Files/qemu` when it is not on `PATH` (`AGENT_VM_QEMU_DIR` points elsewhere).',
              'In WSL2, KVM needs nested virtualization, which the Windows host has to pass through; WSL1 cannot run VMs. `setup` and `doctor` say which case you are in.',
              'Lima cannot mount a path containing whitespace, and agent-vm refuses one, as it does a path with a quote, a backslash or a control character. iCloud Drive paths contain spaces: go through a symlink.',
            ],
            list: [],
            code: 'ln -s ~/Library/Mobile\\ Documents/com~apple~CloudDocs/Dev ~/Dev\ncd ~/Dev/your-project && agent-vm claude',
          },
        ],
      },
      {
        title: 'Agents',
        topics: [
          {
            title: 'How each agent runs',
            paras: [
              'Claude Code also gets bypass mode from managed settings (`/etc/claude-code/managed-settings.json`): it drops the command-line flag when it relaunches itself ([#72479](https://github.com/anthropics/claude-code/issues/72479)). OpenCode’s `--auto` approves every prompt not explicitly denied. For Pi, setup sets `defaultProjectTrust: "always"`, so a project’s `.pi/` extensions and skills load.',
              'Log in inside the VM (`claude login`, `gh auth login`): the login stays with that VM. Mounting your host credentials instead would hand your main login to everything in the VM.',
              'Lima passes `COLORTERM` into the VM. A terminal with 24-bit colour that does not set it (Terminal.app on macOS 26 may not) needs `export COLORTERM=truecolor`.',
            ],
            list: [],
            code: '',
          },
          {
            title: 'MCP servers',
            paras: [
              'Playwright MCP runs with `--executable-path /usr/bin/chromium` and `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`, so it downloads no browsers of its own. For another engine, edit its entry (drop `--executable-path`, add `--browser firefox`) and run `npx playwright install firefox` in the VM.',
              'To add a server for Claude Code, add it to `mcpServers` in `~/.claude.json`, from `~/.agent-vm/setup.sh` or inside a VM.',
            ],
            list: [],
            code: '{\n  "mcpServers": {\n    "postgres": {\n      "command": "npx",\n      "args": ["-y", "@modelcontextprotocol/server-postgres", "postgresql://localhost:5432/mydb"]\n    }\n  }\n}',
          },
        ],
      },
      {
        title: 'Configuration',
        topics: [
          {
            title: 'The env files',
            paras: [
              'Plain `KEY=value` lines, `#` for comments, pushed into the VM on every command, so edits need no `--reset`. agent-vm knows none of the names: `gh` reads `GH_TOKEN`, Claude Code `ANTHROPIC_API_KEY` when not logged in, Codex `OPENAI_API_KEY`, Vibe `MISTRAL_API_KEY`.',
              'Everything in the VM can read them, the agent and its dependencies included, and send them out. Use dedicated, narrowly scoped tokens you can revoke.',
              'The project’s file, `.agent-vm.env` (`AGENT_VM_PROJECT_ENV` moves it, relative to the project or absolute), is pushed after the shared one and wins. It sits in a repository, so keep secrets out: `project-env set` prints the line that gitignores it, or the `git rm --cached` when it is already tracked. The VM can make it a symlink, so the VM reads it at each start, and `project-env` refuses a link, checked with `perl` so the VM cannot race it.',
              '`get` and `has` read the file, never the environment, and never run it. They accept what `set` writes and plain dotenv lines (`KEY=value`, `export`, quotes, a trailing comment). A value that needs a shell (`$`, backquotes, backslashes, `~`, `;`, `|`...) exits `2`, as does a key that appears after such a line: the shell may read the lines that follow differently. `set` rewrites a value in a form they read. Without a value, `set` reads it from standard input, or has you type it unseen, so a secret stays out of your shell history.',
            ],
            list: [],
            code: '',
          },
          {
            title: 'Extra mounts, in detail',
            paras: [
              'A destination is used as written, with no `~`: the VM home is `/home/<you>.guest` (Lima 2.1 and later, `.linux` before). A source that does not exist is skipped with a warning. `rw` works for directories only. A destination named `ro` or `rw` needs an explicit mode after it, and a destination cannot contain `:`.',
              'A single file is hardlinked into `~/.agent-vm/file-mounts/<vm>/` and bind-mounted in the VM, without its directory. Across filesystems it is copied instead, and host edits wait for the next start.',
              'A missing mount point in the project is created without following symlinks, which needs `perl`.',
            ],
            list: [],
            code: '# ~/.agent-vm/volumes: your Claude instructions and skills,\n# not the whole ~/.claude, which holds your login on Linux\n~/.claude/CLAUDE.md:/home/you.guest/.claude/CLAUDE.md\n~/.claude/skills:/home/you.guest/.claude/skills',
          },
          {
            title: 'Setup and runtime scripts',
            paras: [
              '`~/.agent-vm/setup.sh` runs once, in the template, at the end of `setup`, as the VM user with sudo. `~/.agent-vm/runtime.sh` runs in the VM on every command that enters one, then the project’s `.agent-vm.runtime.sh`: both must be safe to run again. [`runtime.example.sh`](https://github.com/sylvinus/agent-vm/blob/main/runtime.example.sh) covers git identity, `gh auth setup-git`, skills, MCP servers and a status line. Keep private keys out: the agent can read whatever they set up.',
              '`setup.sh` runs under zsh. A runtime script runs under the shell its shebang names (bash or sh, zsh otherwise). Both are fed on standard input: `$0` is the shell, and a command in it that reads standard input reads the rest of the script, so give it `</dev/null`.',
              '`AGENT_VM_PROJECT_RUNTIME` moves the project’s script, relative to the project or absolute, `..` resolved as `cd` does. Inside the project, the VM reads it; outside, the host. mise picks up `.ruby-version`, `.python-version`, `.node-version` and `.tool-versions`.',
            ],
            list: [],
            code: '# .agent-vm.runtime.sh\nmise install\nnpm install\ndocker compose up -d',
          },
        ],
      },
      {
        title: 'Operations and scripts',
        topics: [
          {
            title: 'Resources, ports, doctor',
            paras: [
              'CPU and memory are clamped to half the host per VM, with a notice. `AGENT_VM_HOST_SHARE` changes the divisor (`1` for the whole host); when the host capacity cannot be read, nothing is clamped.',
              'A port set with `--ssh-port` stays until `--reset` or `rm`. One another Lima VM is set to is refused; one used by anything else makes the start fail. The VM must run for SSH to connect.',
              '`doctor` prints no secret, so its output can go into an issue as is. It exits `1` when a check fails.',
            ],
            list: [],
            code: '',
          },
          {
            title: 'For integrators',
            paras: [
              '`AGENT_VM_STATE_DIR` moves `~/.agent-vm`, for a test, a CI job or a second install, without moving `HOME` (which would move Lima’s VMs too). Read it back from `info` (`state_dir=`) rather than from `$HOME`.',
              '`base_exists=1` means the template is usable, not only listed by Lima. `agent-vm.sh` can be sourced under `set -u` and `pipefail`, not `set -e`.',
              'A start asks its questions on the terminal, and only when stderr is one too: a tool that captures stderr gets the answer "no", so the start stops. `security_questions=` in `info` says beforehand what the start of a VM that is not running would stop on (`lima`, `lima-unknown`, `hooks`, `git-config`, `bare-repo`, or `none`), and `git_protected=` whether `.git` would be read-only. Pass `--unsafe-disable-security-prompts` to go on anyway, once the user has agreed.',
            ],
            list: [],
            code: '',
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
            title: '--readonly and .git, in detail',
            paras: [
              '`--readonly` covers every share, `rw` volumes included, with a notice naming them: a writable volume containing the project would be a second way in. Whether the host enforces it is decided from what Lima reports for the VM, never by asking the guest. agent-vm records the mounts it gave each VM, so one left with a writable share is changed; a stopped VM gets the mode before it boots.',
              'Every `.git` is read-only at any depth, whatever the case of the name. `git status`, `diff` and `log` work in the VM; `commit` does not. Every `.hg` is too, for Mercurial’s hooks.',
              'When git’s `core.hooksPath` puts the hooks in the project (husky sets `.husky/_`), the first folder of that path, from the top of its repository, is read-only as well, by its name and at any depth like `.git`, so the agent cannot change the hooks git runs on your commits. A name that does not start with a dot (`tools` for `tools/hooks`) would lock every folder of that name in the project, so the start asks first; yes is the default. Hooks at the top of a repository cannot be protected that way, so the start stops on them, as on the other risks above. The repository holding the project and those up to two levels below it are checked on every start: `doctor` says whether the VM has the names.',
              'A Lima whose answer agent-vm cannot read (a failing `limactl validate`, an unknown wording) stops the start with an error rather than being taken for one without `readonlyNames`, which would drop the protection of your VMs; `--readonly`, `--unsafe-writable-git` and `--scratch` still start. The `AGENT_VM_UNSAFE_*` variables must be exactly `1`, and are read from your shell, never from a file of the project. A tool that loads environment variables from the project on `cd` (mise’s `[env]`, for one) can set them, though: see [mise](#shell-commands-hooks) below. With a Lima that lacks `readonlyNames`, a VM goes back to Lima’s default mount type at its next start, since `reverse-sshfs` without it is the weaker one. Back to Homebrew’s Lima: `brew uninstall lima-sylvinus && brew link lima`.',
            ],
            list: [],
            code: '# the Lima build, without Homebrew (needs Go and make)\ngit clone --depth 1 -b v2.3.0-sylvinus.2 https://github.com/sylvinus/lima\ncd lima && make native && sudo make install',
          },
        ],
      },
      {
        title: 'What else on your machine reads the project',
        topics: [
          {
            title: 'The rule',
            paras: [
              'The agent writes the project folder, so anything on your machine that reads it and acts on what it finds can run what the agent wrote. agent-vm closes what nearly every machine has and what runs without you doing anything: git, through `.git`, `.hg`, hooks folders and git config (see [Protecting .git](#git)). It cannot know your other tools, and cannot lock the files they read without stopping the agent from working: it has to be able to write `.vscode/`, `docker-compose.yml` or `mise.toml`.',
              'So on your machine, open the project in your editor and use git in it; run everything else in the VM, with `agent-vm run`. The lists below are examples, sorted by what sets them off, not a complete inventory: check your own setup against them.',
            ],
            list: [
              'Nothing at all: what runs when you `cd` into the folder, when your prompt redraws, when your editor opens it or a file manager shows it. The most dangerous kind, since you never decide.',
              'Something you do anyway: `git commit` runs hooks whose commands sit in the working tree, `docker compose up` mounts whatever the compose file names, your home directory included.',
              'Running project code: `npm test`, `make`, a build. That is the agent’s code by definition, so it belongs in the VM.',
            ],
            code: '',
          },
          {
            title: 'Keeping your checkout out of reach',
            paras: [
              'To take the question off the table, do not give agent-vm the checkout you work in. Clone the project a second time, run agent-vm there, and bring its work into your own checkout with `git fetch` once you have read the diff. Your editor, prompt and habits stay in a folder the VM cannot write, and nothing of yours opens the agent’s folder by reflex. Fetching reads objects and does not check them out, so the agent’s files reach your working tree only when you merge. It does run git in the clone’s `.git`, so this holds with a Lima that keeps `.git` read-only: without one, the VM can write that `.git` too, and git’s own documentation advises against fetching, as yourself, from a `.git` someone else could write.',
            ],
            list: [],
            code: '# once; --no-local copies the objects instead of hardlinking them\ngit clone --no-local ~/work/app ~/agent/app\n# the agent works there\ncd ~/agent/app && agent-vm claude\n# back in your checkout, when it is done\ncd ~/work/app\ngit fetch ~/agent/app HEAD:agent/review\ngit diff ...agent/review     # read it all, .vscode/ and package.json included\ngit merge agent/review',
          },
          {
            title: 'Editors and agents',
            paras: [
              'Anything that runs in the project on your machine can run code the agent wrote. A changed tracked file shows in `git diff`, a new one as untracked; one in an ignored path (`node_modules`, `.venv`, `target/`) shows nowhere.',
            ],
            list: [
              'VS Code: open agent-vm projects in Restricted Mode (“No, I don’t trust the authors”), and do not trust a parent folder, which trusts everything below it. A trusted workspace runs tasks and extensions that execute project code: `eslint.config.js`, `vite.config.ts`, `build.rs` through rust-analyzer, the Python interpreter the settings name.',
              'JetBrains IDEs: “Preview in Safe Mode”. A trusted project runs its Gradle or Maven scripts on import.',
              'Neovim asks before running a project’s `.nvim.lua` or `.exrc` (`exrc`, off by default), and again when it changes; Vim does not ask, so leave `exrc` off. Emacs asks before applying risky `.dir-locals.el` values.',
              'Agents on your machine read project config that runs commands: `.claude/settings.json` hooks, `.mcp.json`, `.cursor/`. Review those before running one there, and treat `CLAUDE.md` and `AGENTS.md` as the VM’s writing.',
            ],
            code: '',
          },
          {
            title: 'Shell, commands, hooks',
            paras: [],
            list: [
              'direnv only loads an `.envrc` you allowed, and a change revokes it.',
              'mise trusts a config by its path: the agent can change a trusted `mise.toml`, and your shell runs its hooks and sets its env on the next `cd`, agent-vm’s own variables included. `mise settings set paranoid true` ties trust to the content.',
              'Mercurial runs hooks from `.hg/hgrc` in a repository you own, which files written through the share are. With a Lima that keeps `.git` read-only, every `.hg` is read-only too.',
              '`npm run`, `make`, `./gradlew`, `pytest` (`conftest.py`), `node_modules/.bin`, an activated `.venv`: each runs files the agent can write. Run them in the VM, with `agent-vm run`.',
              '`docker compose up` on your machine does what the compose file says, and a service can mount any folder of yours, `/` included, into a container running as root. Docker runs in the VM: use it there.',
              'Commit hooks: lefthook (`lefthook.yml`) and pre-commit (`.pre-commit-config.yaml`) keep their commands in the working tree, so `git commit` on your machine runs what the agent wrote there. Read them in the diff, or commit with `--no-verify`. With a Lima that keeps `.git` read-only, the `.husky/` folder of husky is read-only too, since `core.hooksPath` points into it (see [Protecting .git](#git)), but the commands its hooks call (`npx lint-staged`, `npm test`) run project files.',
            ],
            code: '',
          },
          {
            title: 'File managers',
            paras: [],
            list: [
              'macOS: files written through the share carry no quarantine flag, so Gatekeeper does not check an `.app`, `.command` or `.pkg` the agent left there. Do not open them from Finder.',
              'Windows: Explorer contacts the server named in a `.library-ms`, `.searchConnector-ms`, `.url`, `.lnk` or `desktop.ini` when it shows the folder, sending your NTLM hash ([CVE-2025-24054](https://research.checkpoint.com/2025/cve-2025-24054-ntlm-exploit-in-the-wild/), exploited in 2025). Keep Windows updated and outbound SMB blocked.',
              'Linux: KDE’s Dolphin ran commands from a `.desktop` or `.directory` file in a folder it only displayed (CVE-2019-14744, fixed in KDE Frameworks 5.61).',
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
              'Clipboard: OSC 52 lets a program set your clipboard, and in some terminals read it. Allow writes only if you need them, never reads, and check what you paste into a host shell.',
              'Replies typed for you: some sequences make the terminal type an answer. During a session it goes to the VM, but one sent just before exit lands in your host shell. Answers that carried a command were real bugs: iTerm2 [CVE-2024-38396](https://www.sentinelone.com/vulnerability-database/cve-2024-38396/) (fixed in 3.5.2), xterm before it. Keep your terminal updated.',
              'Features that act on your machine: iTerm2 file transfer and triggers, kitty remote control (off by default: keep it off), links whose text differs from their target.',
              'Spoofing: the VM can print a fake host prompt after a fake exit. Check where you are before typing a secret.',
            ],
            code: '',
          },
          {
            title: 'Network and ports',
            paras: [
              'The VM reaches the internet and every service on your machine’s loopback, at `192.168.5.2`: a dev database, another project’s VM through its forwarded ports. Lima forwards every port a VM listens on to your `127.0.0.1`, unless it is taken: a VM that listens first on 5432 receives the connections, and passwords, meant for your local Postgres. Blocking this is [on the roadmap](#roadmap).',
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
      'The wizard’s default install and `--preinstall=default` produce the same set: everything below except the rows marked no.',
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
      'The suite runs against a stub `limactl` in a throwaway `HOME`, with git reading its config from there only. No VM is created, started or deleted, your real `~/.agent-vm` and git config are untouched, and nothing is downloaded. It covers VM naming, resource comparison, staleness, the `info`, `version` and `name` surface, the `--preinstall` parser, the MCP config writer, and the project mount mode that `--readonly` rides on. `./test-e2e.sh` is the other half: it builds a real VM with `--preinstall=none` and checks what a stub cannot, starting with whether root in the guest can lift `--readonly`, and, with a Lima that has `readonlyNames`, whether it can write `.git`, and that a `--scratch` VM sees nothing of the host and is gone afterwards. It runs in its own `LIMA_HOME`, so your own VMs are never touched. The unit tests are `tests/NN-*.sh`, run in order in one shell after `tests/helpers.sh`, so a file can use what an earlier one set up; a new area gets its own file.',
    testsCode: './test.sh        # fast, no VM\n./test-e2e.sh    # real VM, needs Lima',
    shellsTitle: 'Test the shells that matter',
    shellsBody:
      'macOS still ships bash 3.2, which is stricter about empty array expansion under `set -u` than modern bash. A change that passes on bash 5 can still break on a stock Mac. The `bash:3.2` image has no git, so the tests that need it skip there: add it with `apk`.',
    shellsCode: 'docker run --rm -v "$PWD:/w" -w /w bash:3.2 ./test.sh\ndocker run --rm -v "$PWD:/w" -w /w bash:3.2 sh -c \'apk add -q git && git config --global safe.directory "*" && ./test.sh\'',
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
