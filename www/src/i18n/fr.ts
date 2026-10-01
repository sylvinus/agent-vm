// Version française. Typée contre `en.ts` : une clé manquante ou renommée
// casse le build au lieu de retomber silencieusement sur l'anglais.
//
// Ce n'est pas une traduction mot à mot de `en.ts` : c'est le même propos,
// écrit en français. Les commandes shell, elles, sont identiques partout.
//
// Même règle de style qu'en anglais : on dit ce que fait l'outil. Pas de
// slogan, pas d'absolu que le code ne tient pas (« impossible à quitter »,
// « plus rien ne sort »), pas de phrase dont le seul rôle est de sonner bien.

import type { Dictionary } from './en';

export const fr: Dictionary = {
  meta: {
    lang: 'fr',
    label: 'Français',
    title: 'agent-vm | une VM Linux jetable par projet pour les agents de code IA',
    description:
      'agent-vm donne à chaque projet sa propre VM Linux et y lance l\'agent de code sans demande de confirmation. Tes clés SSH, tes sessions de navigateur et le reste de ton disque restent hors de sa portée. Basé sur Lima, sous licence MIT.',
    skipToContent: 'Aller au contenu',
  },

  nav: {
    sections: {
      install: 'Installation',
      usage: 'Utilisation',
      reference: 'Référence',
      architecture: 'Architecture',
      security: 'Sécurité',
      contribute: 'Contribuer',
      credits: 'Crédits',
    },
    github: 'GitHub',
    menu: 'Menu',
    language: 'Langue',
  },

  hero: {
    title: 'Donne aux agents une machine qu\'ils peuvent casser.',
    titleAccent: 'Garde la tienne.',
    lede:
      'Un agent de code a besoin de droits étendus pour être utile : il installe des dépendances, lance des builds, démarre des serveurs. agent-vm donne à chaque projet sa propre VM Linux, et c\'est là que l\'agent travaille. Il n\'y voit ni tes clés SSH, ni tes sessions de navigateur, ni le reste de ton disque.',
    installLabel: 'Pour commencer',
    ctaPrimary: 'Installer',
    ctaSecondary: 'Comment ça marche',
    meta: 'Licence MIT · macOS, Linux, Windows (expérimental) · basé sur Lima',
    terminalCaption:
      'Seul le dossier du projet est monté. Une VM par dossier, créée au premier lancement puis réutilisée.',
    points: [
      {
        title: 'Lima, seule dépendance côté hôte',
        body: 'Ni Node, ni npm, ni Docker Desktop sur ta machine : la chaîne d\'outils vit dans la VM. Sous Linux, Lima a aussi besoin de QEMU et d\'un accès à KVM.',
      },
      {
        title: 'Un noyau séparé, pas un simple namespace',
        body: 'Sous Linux, sortir d\'un conteneur, c\'est atterrir sur l\'hôte. Sortir d\'une VM, c\'est d\'abord devoir franchir l\'hyperviseur.',
      },
      {
        title: 'Les ports sont redirigés automatiquement',
        body: 'Un serveur de dev lancé dans la VM répond sur localhost, au même port. C\'est Lima qui s\'en charge : aucune option, aucune configuration.',
      },
      {
        title: 'Cinq agents, une commande',
        body: 'OpenCode, Claude Code, Codex CLI et Mistral Vibe, chacun lancé avec son option d\'approbation automatique. Pi, en option, ne demande jamais rien.',
      },
    ],
  },

  threat: {
    eyebrow: 'Pourquoi ce projet',
    title: 'Pourquoi ne pas lancer l\'agent directement sur ta machine ?',
    lede:
      'Chaque agent propose une option qui désactive les demandes de confirmation, et beaucoup s\'en servent ainsi. Quand ça se passe dans ton répertoire personnel, trois choses peuvent mal tourner.',
    reasons: [
      {
        title: 'Installer une dépendance, c\'est exécuter du code',
        body: 'Chaque `npm install` exécute des scripts d\'installation tiers avant que quiconque les ait lus. En 2025, le ver Shai-Hulud s\'est propagé ainsi dans des milliers de paquets npm : il récupérait jetons npm, PAT GitHub, clés SSH et identifiants cloud, puis s\'en servait pour publier des versions infectées d\'autres paquets. Ces installations n\'avaient rien d\'anormal en apparence.',
      },
      {
        title: 'On finit par tout valider',
        body: 'L\'autre option, c\'est de valider chaque commande à la main. Au bout de quelques dizaines de demandes, on répond par réflexe, et celle qui comptait reçoit le même oui que les autres. C\'est pour ça que l\'option qui désactive tout existe, et qu\'on s\'en sert.',
      },
      {
        title: 'L\'agent lui-même n\'est pas fiable',
        body: 'Pas besoin d\'un paquet compromis. Un agent lit des issues, des pages web, des README, et tout ce qu\'il lit peut essayer de lui donner des ordres. Il fait aussi des erreurs toutes bêtes : le mauvais chemin, un `git checkout .` sur du travail pas encore commité.',
      },
    ],
    closing:
      'Une VM limite ce qu\'une erreur ou un agent compromis peut atteindre : ton code source et ce que tu as mis dans [son fichier d\'env](#share-secrets-across-vms), mais ni tes clés SSH, ni tes identifiants git, ni tes sessions de navigateur. [`--readonly`](#tighten-the-session) restreint encore, et c\'est l\'hôte qui l\'applique : root dans l\'invité ne peut pas le lever. Le projet partagé est protégé lui aussi : avec un Lima qui a `sshfs.readonlyNames`, chaque `.git` y est en lecture seule pour la VM, donc l\'agent ne peut pas déposer dans `.git` un hook ou une config que git lancerait ensuite sur ton hôte (voir [Protéger .git](#git) plus bas). Reste le réseau : l\'agent peut envoyer des données n\'importe où, et Lima expose le loopback de l\'hôte en `192.168.5.2`, donc une base de données de dev qui écoute sur localhost est joignable depuis la VM.',
  },

  install: {
    eyebrow: 'Installation',
    title: 'Installer, construire une image de base, lancer un agent.',
    lede:
      'agent-vm, ce sont quelques scripts shell, sans démon.',
    prerequisitesTitle: 'Prérequis',
    prerequisites: [
      { name: 'macOS, Linux ou Windows', note: 'Windows est expérimental : Git Bash, QEMU et Lima pour Windows requis.', href: '' },
      {
        name: 'Lima',
        note: 'agent-vm setup propose de l\'installer avec Homebrew, dans une version qui garde les `.git` en lecture seule, en attendant son intégration en amont. Sous Linux, il faut aussi QEMU et KVM. Sous Windows, QEMU (winget) et la fonctionnalité Windows Hypervisor Platform ; setup propose le téléchargement de Lima.',
        href: 'https://lima-vm.io/docs/installation/',
      },
      {
        name: 'Un abonnement ou une clé API pour ton agent',
        note: 'L\'authentification se fait dans la VM, VM par VM.',
        href: '',
      },
    ],
    methodsTitle: 'Installer la commande',
    methodsBody: 'Au choix. Chacune met `agent-vm` dans ton `PATH`, sans root.',
    methodsLabel: 'Méthode d\'installation',
    methods: [
      {
        id: 'curl',
        label: 'curl',
        code: 'curl -fsSL https://www.agent-vm.org/install.sh | sh',
        note: 'Télécharge la dernière version publiée sur GitHub, la vérifie avec le `SHA256SUMS` de la version, la décompresse dans `~/.local/share/agent-vm` et place un lien `agent-vm` dans `~/.local/bin`. Propose ensuite de lancer l\'étape 2 dans la foulée. Relance-le pour mettre à jour. `sh -s -- --version X.Y.Z` installe une version donnée, `sh -s -- --git` un clone de `main`.',
      },
      {
        id: 'brew',
        label: 'Homebrew',
        code: 'brew install sylvinus/tap/agent-vm',
        note: 'macOS, ou Linux avec Homebrew. `brew upgrade agent-vm` le met à jour.',
      },
      {
        id: 'git',
        label: 'git',
        code: 'git clone https://github.com/sylvinus/agent-vm.git\ncd agent-vm && ./agent-vm.sh install',
        note: '`install` place un lien symbolique `agent-vm` dans ton `PATH` : un `git pull` dans le clone suffit ensuite pour mettre à jour. Il propose aussi de lancer l\'étape 2 dans la foulée.',
      },
      {
        id: 'windows',
        label: 'Windows',
        code: '# dans Git Bash (expérimental)\nwinget install SoftwareFreedom.QEMU\ncurl -fsSL https://www.agent-vm.org/install.sh | sh',
        note: 'Expérimental. À lancer dans Git Bash : c\'est l\'installeur curl, et `agent-vm setup` propose ensuite une version de Lima pour Windows. Prends-la : avec le Lima d\'origine, les partages passent par `reverse-sshfs`, qui ne cantonne pas la VM à ses partages, et root dans la VM peut atteindre tes clés SSH et le reste de ton disque (un démarrage le dit, et demande). Les VM ont aussi besoin de l\'hyperviseur de Windows, la fonctionnalité Windows Hypervisor Platform. Elle est désactivée par défaut et seul un administrateur peut l\'activer, une fois (Fonctionnalités de Windows, ou `DISM /Online /Enable-Feature /FeatureName:HypervisorPlatform /All`, puis un redémarrage). Sur un portable géré, c\'est une demande à faire au service informatique. Sans elle, les VM ne démarrent pas.',
      },
    ],
    steps: [
      {
        title: 'Construire l\'image de base',
        body: 'À faire une seule fois. Sans Lima, propose d\'abord de l\'installer, dans la version qui garde les `.git` en lecture seule pour les VM. L\'assistant propose ensuite une sélection par défaut : il suffit d\'appuyer sur Entrée pour l\'accepter. Après lui, un Lima qui ne sait pas garder les `.git` en lecture seule reçoit la même proposition. Crée enfin une VM Debian 13, y installe la chaîne d\'outils et les agents, puis l\'arrête et la garde comme image de base.',
        code: 'agent-vm setup',
      },
      {
        title: 'Lancer un agent dans ton projet',
        body: 'Clone l\'image en une VM dédiée à ce dossier, y monte le répertoire de travail et lance l\'agent, sans demande de confirmation. Avant le démarrage de la VM, agent-vm peut s\'arrêter sur une question de sécurité, par exemple un réglage git qu\'il propose de faire : voir [Protéger .git](#git).',
        code: 'cd ton-projet\nagent-vm opencode     # ou : agent-vm claude',
      },
    ],
    preinstallTitle: 'Choisir ce qui entre dans l\'image',
    preinstallBody:
      'En minuscules, séparés par des virgules. `default` installe tout sauf Ruby, Rust, Go, Pi et le MCP Playwright, `all` installe tout, `none` rien. `codex` et `pi` entraînent `node`, tout comme `mcp-chrome` quand `chromium` et un agent sont choisis, parce que ces installations passent par `npm` et `npx`. Les deux serveurs MCP sont ignorés sans `node` et `chromium`. Sans terminal, l\'assistant est sauté et la sélection par défaut est installée. `setup` accepte aussi `--disk`, `--memory` et `--cpus` pour l\'image elle-même.',
    preinstallNames:
      'python · node · ruby · rust · golang · docker · chromium · gh · claude · opencode · codex · vibe · pi · mcp-chrome · mcp-playwright',
    preinstallCode:
      'agent-vm setup                                       # assistant interactif\nagent-vm setup --preinstall=default                  # sans question\nagent-vm setup --preinstall=default,rust             # avec Rust en plus\nagent-vm setup --preinstall=python,docker,claude     # Claude seul, minimal\nagent-vm setup --preinstall=node,chromium,opencode   # sans MCP\nagent-vm setup --disk 50 --memory 16 --cpus 8        # pour les gros projets',
    setupHeaders: ['Option', 'Rôle', 'Défaut'],
    setup: [
      ['--disk GB', 'Taille du disque de l\'image de base.', '10'],
      ['--memory GB', 'Mémoire de l\'image de base.', '3'],
      ['--cpus N', 'Nombre de CPU de l\'image de base.', '1'],
      ['--preinstall=LIST', 'N\'installe que cette liste, séparée par des virgules. Saute l\'assistant.', 'assistant'],
    ],
    updateTitle: 'Mise à jour',
    updateBody:
      'Installé avec curl : relance l\'installeur. Avec Homebrew : `brew upgrade agent-vm`. Depuis un clone : `git pull`, rien à réinstaller. `agent-vm uninstall` retire le lien que posent les installations curl et git. Depuis la 0.1.0, lance `agent-vm setup` une fois : une VM issue d\'une base construite par la 0.1.0 redémarre une fois de plus à son prochain lancement pour installer `sshfs`, nécessaire pour garder `.git` en lecture seule, et `--reset` lui donne la nouvelle base. Cette migration sera retirée dans une prochaine version.',
  },


  usage: {
    eyebrow: 'Utilisation',
    title: 'Les commandes du quotidien.',
    lede:
      'Chaque VM est rattachée à un dossier, sauf celles de `--scratch`. Relance une commande d\'agent dans le même dossier et tu retrouves la même machine, avec ses paquets, ses conteneurs et ses identifiants.',
    cards: [
      {
        title: 'Lancer un agent',
        body: 'Les arguments supplémentaires sont transmis tels quels à l\'agent : tout ce que sa CLI accepte fonctionne ici.',
        code: 'agent-vm opencode                        # OpenCode\nagent-vm claude                          # Claude Code\nagent-vm codex                           # Codex CLI\nagent-vm vibe                            # Mistral Vibe\n\nagent-vm claude -p "corrige les erreurs de lint"\nagent-vm opencode run "mets à jour le changelog"',
      },
      {
        title: 'Accéder au serveur de dev',
        body: 'Lima redirige vers l\'hôte les ports ouverts dans la VM. Démarre un serveur depuis l\'agent ou depuis un shell : il répond sur localhost au même port, dans ton navigateur. L\'inverse est vrai aussi : tout port sur lequel l\'agent écoute dans la VM apparaît sur ton propre localhost. Considère ces ports comme les siens.',
        code: 'agent-vm run npm run dev   # puis ouvre localhost:5173\nagent-vm shell             # pareil pour docker compose up',
      },
      {
        title: 'Entrer dans la VM',
        body: 'Un shell pour aller voir ce qui s\'y passe, ou une commande isolée quand tu sais déjà ce que tu veux.',
        code: 'agent-vm shell                    # zsh dans la VM\nagent-vm run npm install          # commande unique\nagent-vm run --tty opencode       # un PTY pour les TUI\nagent-vm sh -c "ls -la | grep config"',
      },
      {
        title: 'Brancher un IDE en SSH',
        body: 'VS Code Remote-SSH, JetBrains Gateway ou un agent graphique peuvent garder leur fenêtre sur l\'hôte et faire tourner le reste dans la VM. Lima écrit une config SSH par VM avec le port du démarrage en cours, sous l\'alias que `agent-vm info` affiche comme `ssh_host`. Mets les lignes ci-dessous en haut de `~/.ssh/config`, au-dessus de tout `Host *` : ssh garde la première valeur qu\'il trouve, et un `ForwardAgent yes` à cet endroit donnerait à la VM toutes les clés de ton agent SSH, tout comme le `remote.SSH.enableAgentForwarding` de VS Code sans ces lignes. Pour un outil qui enregistre le port plutôt que l\'alias, `--ssh-port` le fixe (`0` revient à un nouveau port à chaque démarrage).',
        code: '# en haut de ~/.ssh/config\nInclude ~/.lima/*/ssh.config\nHost lima-agent-vm-*\n  ForwardAgent no\n  ForwardX11 no\n\nagent-vm info | grep ^ssh_host   # l\'alias à utiliser\nagent-vm --ssh-port 2222 shell   # un port fixe',
      },
      {
        title: 'Gérer le parc',
        body: 'Dans `list`, la VM du dossier courant est marquée d\'un `>`. Si un dossier a été renommé, seul `list` permet de retrouver sa VM.',
        code: 'agent-vm list          # toutes les VM, la courante marquée, base de chacune\nagent-vm stop          # arrête, garde le disque\nagent-vm rm            # arrête et supprime\nagent-vm destroy-all   # toutes les VM, image de base comprise\nagent-vm doctor        # ce qui ne va pas, et quoi lancer',
      },
      {
        title: 'Restreindre la session',
        body: 'Pratique pour une relecture ou un audit, où l\'agent n\'a rien à écrire. `--readonly` passe tous les partages de l\'hôte en lecture seule : le projet et les entrées de [`~/.agent-vm/volumes`](#customisation-files), y compris celles en `rw`, puisqu\'un volume accessible en écriture qui contient le projet serait un second accès. La restriction s\'applique aux partages Lima : c\'est l\'hôte qui refuse les écritures (l\'hyperviseur, ou le serveur SFTP de Lima sur les partages qui protègent `.git`), et root dans la VM ne peut pas la lever. Là où Lima ne l\'appliquerait que dans l\'invité, agent-vm refuse l\'option : `reverse-sshfs` sans `readonlyNames`, et virtiofs sous QEMU. Une VM en marche dans l\'autre mode est redémarrée, après confirmation (non par défaut) : refusé, ou sans terminal, la commande échoue, dans un sens comme dans l\'autre, pour qu\'une VM en lecture seule d\'une autre session ne repasse pas en écriture sous elle. Le disque de la VM, `$HOME` et `/tmp` restent accessibles en écriture, donc l\'agent peut toujours installer des paquets et écrire ses caches. Toute écriture dans le projet échoue en revanche, y compris `node_modules`, le dossier d\'état de l\'agent et ce qu\'y écrirait un script de runtime, puisque le mode est appliqué avant leur exécution. `--scratch` va plus loin : une nouvelle VM où rien de ce qui est à toi n\'est monté, que l\'agent remplit depuis le réseau (un `git clone` avec un jeton tiré d\'`agent-vm env`), supprimée à la fin de la commande ; sur un terminal, elle demande d\'abord, et un non ouvre un shell dans la VM. Son travail sort par le même chemin, en push ou en pull request. Les connexions n\'y survivent pas : les agents ont besoin de leur jeton dans `agent-vm env`, `ANTHROPIC_API_KEY`, ou `CLAUDE_CODE_OAUTH_TOKEN` obtenu par `claude setup-token`.',
        code: 'agent-vm --readonly shell     # rien n\'est modifiable sur l\'hôte\nagent-vm --scratch claude     # rien de toi n\'est monté, supprimée à la sortie\nagent-vm --rm run npm test    # détruit la VM à la sortie',
      },
      {
        title: 'Redimensionner à la volée',
        body: 'Une nouvelle VM reprend ceux de l\'image de base : 10 Go de disque, 3 Go de mémoire, 1 CPU, sauf si `setup` en a reçu d\'autres. Passe une option avec une autre valeur et la VM est arrêtée, reconfigurée puis redémarrée ; une VM en marche demande d\'abord (non par défaut), et refusé, ou sans terminal, elle garde ses réglages. Le disque peut grandir, jamais rétrécir. CPU et mémoire sont plafonnés à la moitié de l\'hôte, mais VM par VM, pas au total : les VM persistent, et plusieurs VM allumées en même temps s\'additionnent. `agent-vm list` montre ce qui tourne, `rm` et `destroy-all` libèrent la place.',
        code: 'agent-vm --disk 50 opencode\nagent-vm --memory 16 --cpus 8 shell\nagent-vm --reset claude   # re-cloner depuis l\'image',
      },
      {
        title: 'Partager des secrets entre VM',
        body: 'De simples lignes `CLÉ=valeur` dans `~/.agent-vm/env`, poussées dans chaque VM à chaque lancement et chargées dans ses shells. Passe par les sous-commandes plutôt que d\'éditer le fichier à la main : il est sourcé par un shell, donc une seule apostrophe mal échappée casse tous les secrets du fichier, pas seulement cette ligne.',
        code: 'agent-vm env set GH_TOKEN   # colle-le : ni affiché, ni dans l\'historique\nagent-vm env list           # les noms, jamais les valeurs\nagent-vm env has ANTHROPIC_API_KEY\n\n# limité à ce projet\nagent-vm project-env set SOME_PATH ./config',
      },
      {
        title: 'Interroger depuis un script',
        body: 'Si tu pilotes agent-vm depuis un autre outil, passe par ces commandes plutôt que de parser la sortie destinée aux humains ou de lire `~/.agent-vm` : le nommage des VM, le nom de l\'image et les fichiers d\'état sont des détails d\'implémentation, amenés à changer. `version --min` renvoie `0` si le moteur est assez récent, `1` avec un message s\'il est trop ancien, et `2` si l\'appel lui-même est mal formé : une faute de frappe dans la version demandée ne passe donc pas pour un « moteur trop ancien ». Attention : un moteur antérieur à `--min` ignore l\'option et renvoie `0`. Dans `info`, les booléens valent `1` ou `0`, et ce qui ne peut pas être déterminé vaut `unknown`. Ces quatre commandes fonctionnent sans Lima. Sans terminal, un démarrage s\'arrête là où il poserait une question de sécurité : `security_questions` dans `info` les liste à l\'avance, `--unsafe-disable-security-prompts` les accepte, et `--readonly` les évite. Un redémarrage qu\'il demanderait échoue aussi : `--readonly` sur une VM en marche accessible en écriture, ou l\'inverse, et un redimensionnement d\'une VM en marche n\'est pas appliqué.',
        code: 'agent-vm version --min 0.2.0 || exit 1  # silencieux si OK\nagent-vm name [dir]    # nom de la VM d\'un dossier\nagent-vm info [dir]    # une paire clé=valeur par ligne\nagent-vm help          # l\'aide intégrée\n\n# clés de info : version, template, state_dir,\n# project_env, dir, vm_name, base_exists,\n# vm_exists, vm_running, vm_stale,\n# ssh_host, ssh_config, git_protected,\n# security_questions',
      },
    ],
    customTitle: 'Fichiers de personnalisation',
    customLede:
      'Six fichiers facultatifs, aucun n\'est nécessaire pour démarrer. Ceux propres à l\'utilisateur sont dans `~/.agent-vm/`, ceux propres à un projet dans le projet lui-même.',
    customTable: {
      headers: ['Fichier', 'Portée', 'Quand'],
      rows: [
        ['~/.agent-vm/env', 'Toutes les VM', 'Copié à chaque lancement'],
        ['~/.agent-vm/volumes', 'Toutes les VM, ou les projets qu\'une entrée désigne', 'Monté à la création de la VM'],
        ['~/.agent-vm/setup.sh', 'Image de base', 'Une fois, pendant agent-vm setup'],
        ['~/.agent-vm/runtime.sh', 'Toutes les VM', 'À chaque commande qui entre dans une VM, en premier'],
        ['.agent-vm.runtime.sh', 'Un seul projet', 'À chaque commande qui entre dans sa VM, après le global'],
        ['.agent-vm.env', 'Un seul projet', 'Copié après l\'env partagé, et prioritaire sur lui'],
      ],
    },
    volumesTitle: 'Montages en plus : ~/.agent-vm/volumes',
    volumesBody:
      'Une ligne `source[:destination][:mode][:projet]` par montage, `~` développé à gauche, `#` pour les commentaires. Le mode est `ro` (par défaut) ou `rw`, et `rw` ne marche que pour les dossiers. Sans destination, le chemin est monté au même endroit dans la VM. Une destination relative est dans le projet, par-dessus ce que le projet a à cet endroit. Le quatrième champ, après un mode explicite, limite l\'entrée aux projets qu\'il désigne, `*` couvrant n\'importe quoi. Une entrée qui ne se lit pas ainsi est ignorée avec un avertissement, jamais montée partout.',
    volumesCode:
      '# ~/.agent-vm/volumes\n~/.gitconfig    # même chemin, lecture seule\n~/.cache/shared:/home/you.guest/.cache/shared:rw\n\n# seulement dans ~/work/webapp, comme son .claude, en lecture seule\n~/.claude-vm/webapp:.claude:ro:~/work/webapp\n\n# tous les projets sous ~/work\n~/.cache/pip:/home/you.guest/.cache/pip:rw:~/work/*\n\n# même chemin, un seul projet\n~/datasets::ro:~/work/ml',
    volumesNote:
      'Gardé de ton côté et pas dans le projet, exprès : l\'agent peut écrire dans le projet, et une liste de montages rangée là lui permettrait de monter n\'importe quel dossier de l\'hôte dans sa propre VM. Pour la même raison, une destination relative qui sort du projet avec `..` ou passe par un lien symbolique du projet est ignorée. agent-vm crée le point de montage manquant dans le projet sur ta machine : un `.claude` vide y apparaît donc aussi. Les changements valent pour les nouvelles VM : `--reset` les réapplique.',
    gitTitle: 'Laisser l\'agent commiter',
    gitBody:
      'git lit son identité dans l\'environnement : le fichier d\'env partagé suffit, sans aucun `git config` dans la VM. Les quatre variables sont nécessaires, car git exige un committer et pas seulement un auteur.',
    gitCode:
      '# ~/.agent-vm/env\nGIT_AUTHOR_NAME=Ton Nom\nGIT_AUTHOR_EMAIL=12345+toi@users.noreply.github.com\nGIT_COMMITTER_NAME=Ton Nom\nGIT_COMMITTER_EMAIL=12345+toi@users.noreply.github.com',
    gitNote:
      'Ces variables passent avant `git config`, dans tous les dépôts de la VM : pour une identité par dépôt, règle plutôt `user.name` et `user.email` depuis un script de runtime. `gh` lit `GH_TOKEN` de lui-même, donc `gh pr create` fonctionne sans rien d\'autre. Un `git push` en HTTPS a besoin, lui, d\'un credential helper : une ligne `gh auth setup-git` dans ton [script de runtime](#customisation-files).',
    gitHumanTitle: 'Cela dit, garde la main sur les commits',
    gitHumanBody:
      'Que l\'agent puisse commiter ne veut pas dire qu\'il doit le faire. Un commit signifie que tu as lu le diff : laisse l\'agent écrire le code, relis-le et commite toi-même. Avec un Lima qui [garde les `.git` en lecture seule](#git), c\'est même le seul moyen : l\'agent ne peut pas commiter dans le projet partagé, sauf si tu désactives la protection, ce qui lui donne un moyen de lancer des commandes sur ton hôte.',
    gitGuardTitle: 'Protéger .git',
    gitGuardBody:
      'Git, sur ta machine, exécute ce que désignent le `.git/config` et les hooks d\'un dépôt : `core.fsmonitor` à chaque `git status`, les hooks au commit. Ton éditeur et ton prompt de shell lancent `git status` d\'eux-mêmes : une VM capable d\'écrire dans `.git` pourrait donc lancer des commandes sur ton hôte en quelques secondes, sans que rien n\'apparaisse dans `git diff`. Avec un Lima qui a `sshfs.readonlyNames`, chaque `.git` des partages est en lecture seule pour la VM, à toute profondeur, et c\'est le serveur SFTP de Lima, sur l\'hôte, qui l\'impose : l\'agent lit l\'historique mais ne peut pas commiter. Ce n\'est pas encore intégré en amont ([lima-vm/lima#5529](https://github.com/lima-vm/lima/issues/5529)) : `agent-vm setup` propose une version qui l\'a. Les partages passent alors en `reverse-sshfs`, plus lent sur beaucoup de fichiers (voir [Node.js](#node)).',
    gitGuardCode:
      'brew unlink lima; brew install sylvinus/tap/lima-sylvinus\nagent-vm doctor                          # où tu en es\nagent-vm --unsafe-writable-git claude    # commiter quand même\n# sans Homebrew : compiler github.com/sylvinus/lima\n# Windows (Git Bash) : setup propose ce téléchargement ; à la main (AMD64) :\nbase=https://github.com/sylvinus/lima/releases/download/v2.3.0-sylvinus.2\ncurl -fsSLO "$base/lima-2.3.0-sylvinus.2-Windows-AMD64.zip" \\\n     -fsSLO "$base/lima-additional-guestagents-2.3.0-sylvinus.2-Windows-AMD64.zip"\nsha256sum -c <<\'EOF\'   # les sommes fixées par agent-vm\n053f3479b397628b79fe46b0268a50a7f1fc51073691d7d8bce78c9be2ae2787  lima-2.3.0-sylvinus.2-Windows-AMD64.zip\na0828aa4518e21c9519d341be9f32adf07cbeb74a3f8beadaa2f350c45b5933b  lima-additional-guestagents-2.3.0-sylvinus.2-Windows-AMD64.zip\nEOF\nfor z in lima-*-Windows-AMD64.zip; do unzip -q -o "$z" -d ~/.local/share/lima-sylvinus; done\nexport PATH="$HOME/.local/share/lima-sylvinus/bin:$PATH"   # et dans ~/.bash_profile',
    gitGuardNote:
      'Chaque `.hg` est aussi en lecture seule, de même que le dossier vers lequel pointe chaque `core.hooksPath` du projet (`.husky` pour husky). Une VM en marche reçoit les nouvelles protections à son prochain démarrage, qu\'agent-vm propose. Le nom `.git` n\'est pas la seule entrée pour autant. Un dossier que la VM remplit des fichiers internes de git (`HEAD`, `objects/`, `refs/`, un `config`) est un dépôt pour git sous n\'importe quel nom, et git lance les commandes que désigne son `config`, comme son pager dès que tu tapes `git log` dans ce dossier : `git config --global safe.bareRepository explicit` fait ignorer ces dossiers par git. Un fichier de config inclus depuis le projet, ou un réglage dont la commande est un fichier du projet, ouvre la même porte. Avant de démarrer une VM aux partages modifiables, agent-vm s\'arrête sur chacun de ceux qu\'il trouve, et sur un Lima sans `readonlyNames`, pour demander s\'il faut continuer : Entrée, ou l\'absence de terminal, annule. Il propose de régler `safe.bareRepository` pour toi. `doctor` les liste, et `info` les nomme pour les scripts. `--unsafe-writable-git`, ou `AGENT_VM_UNSAFE_WRITABLE_GIT=1` dans ton shell, désactive la protection pour que l\'agent puisse commiter, et rouvre ce chemin vers ton hôte : un avertissement le rappelle à chaque lancement.',
    gitGuardEditor:
      'Ton éditeur est une porte du même genre. L\'agent peut écrire un `.vscode/tasks.json`, des réglages d\'espace de travail, un `eslint.config.js` ou un `build.rs`, que VS Code et ses extensions peuvent exécuter. Quand VS Code te le demande, laisse le projet non approuvé (mode restreint), et n\'approuve pas un dossier parent : cela approuve tout ce qu\'il contient. Les IDE JetBrains proposent le même choix (Safe Mode). La suite est dans [Sécurité](#what-else-on-your-machine-reads-the-project).',
    nodeTitle: 'Node.js : node_modules dans la VM',
    nodeBody:
      'Des centaines de milliers de fichiers sont lents à travers le partage, et les paquets natifs diffèrent de toute façon entre macOS et Linux. Monte un dossier du disque de la VM par-dessus `node_modules` depuis le [script de runtime](#customisation-files) du projet, lancé à chaque commande :',
    nodeCode:
      '#!/bin/bash\n# .agent-vm.runtime.sh\nset -e\nmkdir -p "$HOME/node_modules" node_modules\nmountpoint -q node_modules ||\n  sudo mount --bind "$HOME/node_modules" node_modules',
    nodeNote: 'L\'hôte voit un `node_modules` vide, ou garde le sien : installe aussi de ce côté si ton éditeur a besoin des paquets. `--reset` et `rm` suppriment la copie de la VM. Dans un workspace, le `node_modules` de la racine contient presque tout (npm remonte les paquets, pnpm garde son store dans `node_modules/.pnpm`) ; répète le montage pour un paquet qui a un gros `node_modules` à lui. Un serveur de dev dans la VM peut avoir besoin du polling pour voir les modifications faites sur l\'hôte (Vite : `server.watch.usePolling`).',
    refTitle: 'Toutes les commandes',
    refNote: 'Appelle la commande au lieu de sourcer le fichier : une fonction shell n\'est pas héritée par les processus fils, donc un outil qui lance un shell ne la voit pas.',
    commandGroups: [
      {
        title: 'Lancer un agent',
        rows: [
          ['opencode [args]', 'Lance OpenCode avec `--auto`.'],
          ['claude [args]', 'Lance Claude Code avec `--dangerously-skip-permissions`.'],
          ['codex [args]', 'Lance Codex CLI avec `--dangerously-bypass-approvals-and-sandbox`.'],
          ['vibe [args]', 'Lance Mistral Vibe avec `--agent auto-approve`.'],
          ['pi [args]', 'Lance Pi, qui ne demande aucune permission. En option à l\'installation.'],
        ],
      },
      {
        title: 'Entrer dans la VM',
        rows: [
          ['shell, sh', 'Ouvre un shell zsh dans la VM. `-c "…"` exécute une commande unique via un shell de connexion.'],
          ['run <cmd> [args]', 'Exécute une commande sans shell. `--tty` alloue un PTY pour les TUI.'],
        ],
      },
      {
        title: 'Gérer le parc',
        rows: [
          ['list, status', 'Liste toutes les VM agent-vm, celle du dossier courant marquée d\'un `>`, avec la version d’agent-vm qui a construit la base dont chacune est clonée, et sa date.'],
          ['stop [vm-name]', 'Arrête la VM de ce dossier, ou celle dont tu donnes le nom. Le disque est conservé.'],
          ['rm [vm-name]', 'Arrête et supprime. Un nom issu de `list` permet de viser une VM dont le dossier a disparu.'],
          ['destroy-all', 'Arrête et supprime toutes les VM agent-vm, image de base comprise. `setup` la reconstruit.'],
          ['doctor', 'Vérifie l\'hôte, Lima, l\'image de base et ce dossier, et dit quoi lancer. Ne modifie rien.'],
        ],
      },
      {
        title: 'Installer et configurer',
        rows: [
          ['install', 'Met `agent-vm` dans ton `PATH`, depuis le clone : `./agent-vm.sh install`. L\'installeur curl le lance pour toi.'],
          ['uninstall', 'Retire ce lien. Les VM et `~/.agent-vm` restent.'],
          ['setup', 'Crée l\'image de base. Une seule fois.'],
          ['env <sub>', '`set`, `get`, `has`, `unset`, `list` sur les secrets partagés par toutes les VM.'],
          ['project-env <sub>', 'Mêmes sous-commandes, limitées à ce projet. Prime sur le fichier partagé.'],
          ['help', 'Affiche l\'aide intégrée.'],
        ],
      },
      {
        title: 'Interroger, depuis un script',
        rows: [
          ['version', 'Affiche la version. `--min X.Y.Z` la vérifie au lieu de l\'afficher.'],
          ['info [dir]', 'État lisible par un programme, une paire `clé=valeur` par ligne.'],
          ['name [dir]', 'Affiche le nom de VM d\'un dossier. Par défaut, le dossier courant.'],
        ],
      },
    ],
    optionsTitle: 'Options de VM',
    optionsNote: 'Pour `claude`, `opencode`, `codex`, `vibe`, `pi`, `shell` et `run`, à placer avant la commande ou juste après son nom. Tout ce qui suit appartient à la commande : dans `agent-vm run docker run --rm x`, `--rm` est l\'option de docker.',
    optionsHeaders: ['Option', 'Rôle', 'Défaut'],
    options: [
      ['--disk GB', 'Taille du disque. Peut grandir, jamais rétrécir.', 'celle de l\'image (10)'],
      ['--memory GB', 'Mémoire de la VM. Plafonnée à la moitié de l\'hôte, par VM.', 'celle de l\'image (3)'],
      ['--cpus N', 'Nombre de CPU. Plafonné à la moitié de l\'hôte, par VM.', 'celui de l\'image (1)'],
      ['--ssh-port N', 'Port fixe sur l\'hôte pour le SSH de la VM, pour les outils qui l\'enregistrent. `0` revient à un nouveau port à chaque démarrage. Redémarre une VM en marche, après confirmation.', 'un nouveau par démarrage'],
      ['--reset', 'Détruit la VM et la re-clone depuis l\'image de base.', 'inactif'],
      ['--readonly', 'Tous les partages de l\'hôte en lecture seule (projet et volumes), côté hôte. Redémarre une VM en marche, après confirmation.', 'inactif'],
      ['--unsafe-writable-git', 'Laisse chaque `.git` modifiable pour que l\'agent puisse commiter, avec un avertissement. Voir [Protéger .git](#git).', 'inactif'],
      ['--unsafe-disable-security-prompts', 'Continue là où un démarrage s\'arrêterait pour poser une question de sécurité (voir [Protéger .git](#git)), sans proposer de modifier ta config git. Les avertissements restent affichés. Pour les scripts sans terminal ; `AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1` dans ton shell fait de même.', 'inactif'],
      ['--rm', 'Détruit la VM dès que la commande se termine.', 'inactif'],
      ['--scratch', 'Une nouvelle VM où rien de ce qui est à toi n\'est monté, ni le projet ni les volumes, supprimée à la fin de la commande, Ctrl-C compris. Sur un terminal, la suppression est d\'abord demandée (oui par défaut) : non ouvre un shell dans la VM, et en sortir repose la question. Le fichier d\'env et le script de runtime du projet restent dehors ; `~/.agent-vm/env` et `runtime.sh` y entrent. La VM du dossier n\'est pas touchée, et plusieurs peuvent tourner en même temps. Une exécution tuée net laisse sa VM derrière elle : la prochaine exécution de `--scratch` la supprime, et `doctor` la signale d\'ici là. Voir [Restreindre la session](#tighten-the-session).', 'inactif'],
    ],
  },



  reference: {
    eyebrow: 'Référence',
    title: 'Les détails.',
    lede: 'Ce que les cartes ci-dessus laissent de côté : les options de l\'installeur, ce que fait setup, les fichiers de configuration et les variables pour les scripts.',
    groups: [
      {
        title: 'Installation et setup',
        topics: [
          {
            title: 'Options de l\'installeur',
            paras: [
              'Les options se placent après `sh -s --` : `--version X.Y.Z`, `--git` pour un clone de `main`, `--dir DIR` pour un autre emplacement que `~/.local/share/agent-vm` (ou `$XDG_DATA_HOME/agent-vm`). Pour lire l\'installeur d\'abord, télécharge-le, puis lance-le avec `sh`.',
              'Il se termine par `agent-vm install`, qui place un lien `agent-vm` dans `~/.local/bin` (`AGENT_VM_BIN_DIR` le change), ou un petit lanceur là où Git Bash ne crée pas de liens. La commande marche depuis n\'importe quel shell, fish compris : la ligne `source .../agent-vm.sh` que les versions précédentes ajoutaient à ton rc de shell ne sert plus, et `install` le signale quand il la trouve. `./install.sh` reste, pour l\'instant, comme raccourci.',
            ],
            list: [],
            code: 'curl -fsSL https://www.agent-vm.org/install.sh | sh -s -- --dir ~/tools/agent-vm\ncurl -fsSLO https://www.agent-vm.org/install.sh && sh install.sh',
          },
          {
            title: 'Ce que fait setup',
            paras: [
              'L\'assistant propose d\'abord la sélection par défaut ; réponds `n` pour être interrogé composant par composant. La création de la VM (le premier lancement télécharge une image Debian) et l\'installation des paquets n\'affichent que leurs 10 dernières lignes, sur place ; la sortie complète va dans `~/.agent-vm/setup.log`.',
              'Les noms `mcp-*` branchent un serveur MCP dans chaque agent installé, sauf Pi, qui n\'a pas de support MCP. Laisse-les de côté pour ne pas toucher à la config MCP des agents, quand les serveurs MCP se gèrent projet par projet. `mcp-playwright` n\'entraîne pas `node` : ajoute-le aussi.',
              'Relancer `setup` reconstruit l\'image de base, pas les VM existantes : agent-vm prévient quand une VM vient d\'une image plus ancienne, et `--reset` la reclone. Un `setup` interrompu laisse une image inutilisable, que `info` signale par `base_exists=0` : relance `setup`.',
            ],
            list: [],
            code: '',
          },
          {
            title: 'Windows, WSL et chemins',
            paras: [
              'Sous Windows, `setup` installe la version de Lima dans `~/.local/share/lima-sylvinus` (`AGENT_VM_LIMA_DIR` la déplace) et cherche QEMU dans `/c/Program Files/qemu` quand il n\'est pas dans le `PATH` (`AGENT_VM_QEMU_DIR` indique un autre dossier).',
              'Sous WSL2, KVM demande la virtualisation imbriquée, que l\'hôte Windows doit laisser passer ; WSL1 ne peut pas faire tourner de VM. `setup` et `doctor` disent dans quel cas tu es.',
              'Lima ne sait pas monter un chemin qui contient un espace, et agent-vm le refuse, comme un chemin avec un guillemet, une barre oblique inverse ou un caractère de contrôle. Les chemins d\'iCloud Drive contiennent des espaces : passe par un lien symbolique.',
            ],
            list: [],
            code: 'ln -s ~/Library/Mobile\\ Documents/com~apple~CloudDocs/Dev ~/Dev\ncd ~/Dev/ton-projet && agent-vm claude',
          },
        ],
      },
      {
        title: 'Agents',
        topics: [
          {
            title: 'Comment chaque agent est lancé',
            paras: [
              'Claude Code reçoit aussi le mode sans confirmation par des réglages gérés (`/etc/claude-code/managed-settings.json`) : il perd l\'option de ligne de commande quand il se relance lui-même ([#72479](https://github.com/anthropics/claude-code/issues/72479)). Le `--auto` d\'OpenCode accepte toute demande qui n\'est pas explicitement refusée. Pour Pi, setup règle `defaultProjectTrust: "always"`, pour que les extensions et skills du `.pi/` d\'un projet se chargent.',
              'Connecte-toi dans la VM (`claude login`, `gh auth login`) : la connexion reste dans cette VM. Monter tes identifiants de l\'hôte à la place donnerait ta connexion principale à tout ce qui tourne dans la VM.',
              'Lima transmet `COLORTERM` à la VM. Un terminal en couleurs 24 bits qui ne le définit pas (Terminal.app sous macOS 26, parfois) a besoin de `export COLORTERM=truecolor`.',
            ],
            list: [],
            code: '',
          },
          {
            title: 'Serveurs MCP',
            paras: [
              'Playwright MCP tourne avec `--executable-path /usr/bin/chromium` et `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` : il ne télécharge aucun navigateur à lui. Pour un autre moteur, modifie son entrée (retire `--executable-path`, ajoute `--browser firefox`) et lance `npx playwright install firefox` dans la VM.',
              'Pour ajouter un serveur à Claude Code, ajoute-le à `mcpServers` dans `~/.claude.json`, depuis `~/.agent-vm/setup.sh` ou dans une VM.',
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
            title: 'Les fichiers d\'environnement',
            paras: [
              'Des lignes `CLÉ=valeur`, `#` pour les commentaires, poussées dans la VM à chaque commande : une modification n\'a pas besoin de `--reset`. agent-vm ne connaît aucun des noms : `gh` lit `GH_TOKEN`, Claude Code `ANTHROPIC_API_KEY` quand il n\'est pas connecté, Codex `OPENAI_API_KEY`, Vibe `MISTRAL_API_KEY`.',
              'Tout ce qui tourne dans la VM peut les lire, l\'agent et ses dépendances compris, et les envoyer ailleurs. Mets-y des jetons dédiés, au périmètre étroit, que tu peux révoquer.',
              'Le fichier du projet, `.agent-vm.env` (`AGENT_VM_PROJECT_ENV` le déplace, relatif au projet ou absolu), est poussé après le fichier partagé et l\'emporte. Il est dans un dépôt, donc pas de secret dedans : `project-env set` affiche la ligne qui l\'ignore dans git, ou le `git rm --cached` quand il est déjà suivi. La VM peut en faire un lien symbolique : c\'est donc elle qui le lit à chaque démarrage, et `project-env` refuse un lien, vérifié avec `perl` pour que la VM ne puisse pas le devancer.',
              '`get` et `has` lisent le fichier, jamais l\'environnement, et ne l\'exécutent jamais. Ils acceptent ce qu\'écrit `set` et les lignes dotenv simples (`CLÉ=valeur`, `export`, guillemets, commentaire en fin de ligne). Une valeur qui demande un shell (`$`, accents graves, barres obliques inverses, `~`, `;`, `|`...) sort avec le code `2`, comme une clé qui apparaît après une telle ligne : le shell peut lire les lignes suivantes autrement. `set` réécrit une valeur sous une forme qu\'ils lisent. Sans valeur, `set` la lit sur l\'entrée standard, ou te la fait taper sans l\'afficher : un secret reste ainsi hors de l\'historique de ton shell.',
            ],
            list: [],
            code: '',
          },
          {
            title: 'Montages supplémentaires, en détail',
            paras: [
              'Une destination est prise telle quelle, sans `~` : le dossier personnel dans la VM est `/home/<toi>.guest` (Lima 2.1 et suivants, `.linux` avant). Une source qui n\'existe pas est ignorée, avec un avertissement. `rw` ne marche que pour les dossiers. Une destination nommée `ro` ou `rw` demande un mode explicite après elle, et une destination ne peut pas contenir `:`.',
              'Un fichier seul est lié en dur dans `~/.agent-vm/file-mounts/<vm>/` puis monté dans la VM, sans son dossier. D\'un système de fichiers à l\'autre, il est copié à la place, et les modifications de l\'hôte attendent le démarrage suivant.',
              'Un point de montage manquant dans le projet est créé sans suivre de lien symbolique, ce qui demande `perl`.',
            ],
            list: [],
            code: '# ~/.agent-vm/volumes : tes instructions et skills Claude,\n# pas tout ~/.claude, qui contient ta connexion sous Linux\n~/.claude/CLAUDE.md:/home/toi.guest/.claude/CLAUDE.md\n~/.claude/skills:/home/toi.guest/.claude/skills',
          },
          {
            title: 'Scripts de setup et de runtime',
            paras: [
              '`~/.agent-vm/setup.sh` tourne une fois, dans l\'image de base, à la fin de `setup`, en tant qu\'utilisateur de la VM avec sudo. `~/.agent-vm/runtime.sh` tourne dans la VM à chaque commande qui y entre, puis le `.agent-vm.runtime.sh` du projet : les deux doivent pouvoir être relancés. [`runtime.example.sh`](https://github.com/sylvinus/agent-vm/blob/main/runtime.example.sh) couvre l\'identité git, `gh auth setup-git`, les skills, les serveurs MCP et une ligne d\'état. Pas de clé privée dedans : l\'agent peut lire tout ce qu\'ils mettent en place.',
              '`setup.sh` tourne sous zsh. Un script de runtime tourne sous le shell que nomme sa première ligne (bash ou sh, zsh sinon). Les deux sont lus sur l\'entrée standard : `$0` est le shell, et une commande du script qui lit l\'entrée standard lit la suite du script ; donne-lui `</dev/null`.',
              '`AGENT_VM_PROJECT_RUNTIME` déplace le script du projet, relatif au projet ou absolu, `..` résolu comme le fait `cd`. Dans le projet, c\'est la VM qui le lit ; en dehors, l\'hôte. mise reprend `.ruby-version`, `.python-version`, `.node-version` et `.tool-versions`.',
            ],
            list: [],
            code: '# .agent-vm.runtime.sh\nmise install\nnpm install\ndocker compose up -d',
          },
        ],
      },
      {
        title: 'Exploitation et scripts',
        topics: [
          {
            title: 'Ressources, ports, doctor',
            paras: [
              'Processeurs et mémoire sont plafonnés à la moitié de l\'hôte par VM, avec un avertissement. `AGENT_VM_HOST_SHARE` change le diviseur (`1` pour tout l\'hôte) ; quand la capacité de l\'hôte ne peut pas être lue, rien n\'est plafonné.',
              'Un port fixé avec `--ssh-port` reste jusqu\'à `--reset` ou `rm`. Un port déjà fixé pour une autre VM Lima est refusé ; un port pris par autre chose fait échouer le démarrage. La VM doit tourner pour que SSH se connecte.',
              '`doctor` n\'affiche aucun secret : sa sortie peut aller telle quelle dans une issue. Il sort avec le code `1` quand une vérification échoue.',
            ],
            list: [],
            code: '',
          },
          {
            title: 'Pour les intégrateurs',
            paras: [
              '`AGENT_VM_STATE_DIR` déplace `~/.agent-vm`, pour un test, un job de CI ou une seconde installation, sans déplacer `HOME` (qui déplacerait aussi les VM de Lima). Relis-le dans `info` (`state_dir=`) plutôt que depuis `$HOME`.',
              '`base_exists=1` veut dire que l\'image de base est utilisable, pas seulement listée par Lima. `agent-vm.sh` peut être sourcé sous `set -u` et `pipefail`, pas sous `set -e`.',
              'Un démarrage pose ses questions sur le terminal, et seulement quand la sortie d\'erreur en est un aussi : un outil qui capture cette sortie reçoit la réponse « non », et le démarrage s\'arrête. `security_questions=` dans `info` dit à l\'avance sur quoi s\'arrêterait le démarrage d\'une VM qui ne tourne pas (`lima`, `lima-unknown`, `hooks`, `git-config`, `bare-repo`, ou `none`), et `git_protected=` si `.git` serait en lecture seule. Passe `--unsafe-disable-security-prompts` pour continuer malgré tout, une fois que l\'utilisateur a donné son accord.',
            ],
            list: [],
            code: '',
          },
        ],
      },
    ],
  },

  security: {
    eyebrow: 'Sécurité',
    title: 'Ce qui traverse la frontière.',
    lede: 'La VM ne peut pas sortir de ses partages. Reste ce qui les traverse : le dossier du projet, que l\'agent écrit et que ta machine lit, le terminal et le réseau.',
    groups: [
      {
        title: 'Ce que fait agent-vm',
        topics: [
          {
            title: 'Dossiers et fichiers refusés',
            paras: [
              'agent-vm ne partage ni ton dossier personnel, ni `/`, ni son propre dossier, ni `~/.agent-vm`, ni le dossier de Lima, ni un dossier qui en contient un : `cd ~ && agent-vm shell` donnerait à la VM tes fichiers de configuration et tes clés SSH.',
              'Il ne lit jamais un fichier du projet par son chemin, puisque la VM peut en faire un lien vers n\'importe lequel de tes fichiers. Ses propres appels à git dans un projet refusent un dépôt nu et ne lancent ni `core.fsmonitor` ni pager.',
            ],
            list: [],
            code: '',
          },
          {
            title: '--readonly et .git, en détail',
            paras: [
              '`--readonly` couvre tous les partages, volumes `rw` compris, avec un avertissement qui les nomme : un volume accessible en écriture contenant le projet serait une seconde entrée. L\'hôte l\'impose-t-il ? agent-vm le déduit de ce que Lima rapporte sur la VM, jamais en interrogeant l\'invité. Il garde la trace des montages donnés à chaque VM, si bien qu\'une VM qui a encore un partage en écriture est modifiée ; une VM arrêtée reçoit le mode avant de démarrer.',
              'Chaque `.git` est en lecture seule à toute profondeur, quelle que soit la casse du nom. `git status`, `diff` et `log` marchent dans la VM ; `commit`, non. Chaque `.hg` l\'est aussi, pour les hooks de Mercurial.',
              'Quand le `core.hooksPath` de git place les hooks dans le projet (husky règle `.husky/_`), le premier dossier de ce chemin, depuis la racine de son dépôt, est lui aussi en lecture seule, par son nom et à toute profondeur comme `.git` : l\'agent ne peut pas changer les hooks que git lance à tes commits. Un nom qui ne commence pas par un point (`tools` pour `tools/hooks`) verrouillerait tous les dossiers de ce nom dans le projet : le démarrage demande donc d\'abord, oui par défaut. Des hooks à la racine d\'un dépôt ne peuvent pas être protégés ainsi : le démarrage s\'arrête donc dessus, comme sur les autres risques plus haut. Sont examinés le dépôt qui contient le projet et ceux jusqu\'à deux niveaux en dessous, à chaque démarrage : `doctor` dit si la VM a ces noms.',
              'Un Lima dont agent-vm ne sait pas lire la réponse (un `limactl validate` qui échoue, une formulation inconnue) arrête le démarrage sur une erreur, plutôt que d\'être pris pour un Lima sans `readonlyNames`, ce qui retirerait la protection de tes VM ; `--readonly`, `--unsafe-writable-git` et `--scratch` démarrent quand même. Les variables `AGENT_VM_UNSAFE_*` doivent valoir exactement `1`, et sont lues dans ton shell, jamais dans un fichier du projet. Un outil qui charge des variables d\'environnement depuis le projet au `cd` (le `[env]` de mise, par exemple) peut toutefois les définir : voir [mise](#shell-commands-hooks) plus bas. Avec un Lima sans `readonlyNames`, une VM revient au type de montage par défaut de Lima à son démarrage suivant, car `reverse-sshfs` sans cette option est le moins sûr des deux. Revenir au Lima de Homebrew : `brew uninstall lima-sylvinus && brew link lima`.',
            ],
            list: [],
            code: '# la version de Lima, sans Homebrew (Go et make nécessaires)\ngit clone --depth 1 -b v2.3.0-sylvinus.2 https://github.com/sylvinus/lima\ncd lima && make native && sudo make install',
          },
        ],
      },
      {
        title: 'Ce qui, sur ta machine, lit aussi le projet',
        topics: [
          {
            title: 'La règle',
            paras: [
              'L\'agent écrit dans le dossier du projet : tout ce qui, sur ta machine, le lit et agit selon ce qu\'il y trouve peut exécuter ce que l\'agent a écrit. agent-vm ferme ce que presque toutes les machines ont et qui se lance sans que tu fasses rien : git, par `.git`, `.hg`, les dossiers de hooks et la config git (voir [Protéger .git](#git)). Il ne peut pas connaître tes autres outils, ni verrouiller les fichiers qu\'ils lisent sans empêcher l\'agent de travailler : il doit pouvoir écrire `.vscode/`, `docker-compose.yml` ou `mise.toml`.',
              'Donc, sur ta machine, ouvre le projet dans ton éditeur et utilise git dedans ; lance tout le reste dans la VM, avec `agent-vm run`. Les listes qui suivent sont des exemples, classés selon ce qui les déclenche, pas un inventaire complet : compare-les à ta propre installation.',
            ],
            list: [
              'Rien du tout : ce qui se lance quand tu fais `cd` dans le dossier, quand ton prompt se redessine, quand ton éditeur l\'ouvre ou qu\'un gestionnaire de fichiers l\'affiche. Le cas le plus dangereux, puisque tu ne décides jamais rien.',
              'Un geste que tu fais de toute façon : `git commit` lance des hooks dont les commandes sont dans l\'arborescence, `docker compose up` monte ce que nomme le fichier compose, ton dossier personnel compris.',
              'Lancer du code du projet : `npm test`, `make`, un build. C\'est par définition le code de l\'agent : sa place est dans la VM.',
            ],
            code: '',
          },
          {
            title: 'Garder ton dépôt hors d\'atteinte',
            paras: [
              'Pour ne plus avoir à te poser la question, ne donne pas à agent-vm le dépôt dans lequel tu travailles. Clone le projet une seconde fois, lance agent-vm dans ce clone, et rapatrie son travail dans ton dépôt avec `git fetch` une fois le diff relu. Ton éditeur, ton prompt et tes habitudes restent dans un dossier que la VM ne peut pas écrire, et rien de ce que tu utilises n\'ouvre le dossier de l\'agent par réflexe. `git fetch` lit des objets sans les extraire : les fichiers de l\'agent n\'arrivent dans ton arborescence qu\'au moment où tu fusionnes. Il fait tout de même tourner git dans le `.git` du clone : cela tient donc avec un Lima qui garde les `.git` en lecture seule. Sans lui, la VM peut aussi écrire ce `.git`, et la documentation de git déconseille de récupérer, sous ton propre compte, depuis un `.git` que quelqu\'un d\'autre peut écrire.',
            ],
            list: [],
            code: '# une fois ; --no-local copie les objets au lieu de les lier en dur\ngit clone --no-local ~/work/app ~/agent/app\n# l\'agent travaille là\ncd ~/agent/app && agent-vm claude\n# de retour dans ton dépôt, une fois qu\'il a fini\ncd ~/work/app\ngit fetch ~/agent/app HEAD:agent/review\ngit diff ...agent/review     # relis tout, .vscode/ et package.json compris\ngit merge agent/review',
          },
          {
            title: 'Éditeurs et agents',
            paras: [
              'Tout ce qui tourne dans le projet sur ta machine peut exécuter du code écrit par l\'agent. Un fichier suivi modifié apparaît dans `git diff`, un nouveau comme non suivi ; un fichier dans un chemin ignoré (`node_modules`, `.venv`, `target/`) n\'apparaît nulle part.',
            ],
            list: [
              'VS Code : ouvre les projets agent-vm en mode restreint (« Non, je ne fais pas confiance aux auteurs »), et n\'approuve pas un dossier parent, ce qui approuve tout ce qu\'il contient. Un espace de travail approuvé lance des tâches et des extensions qui exécutent du code du projet : `eslint.config.js`, `vite.config.ts`, `build.rs` via rust-analyzer, l\'interpréteur Python que nomment les réglages.',
              'IDE JetBrains : « Preview in Safe Mode ». Un projet approuvé lance ses scripts Gradle ou Maven à l\'import.',
              'Neovim demande avant de lancer le `.nvim.lua` ou le `.exrc` d\'un projet (`exrc`, désactivé par défaut), et de nouveau quand il change ; Vim ne demande pas, laisse donc `exrc` désactivé. Emacs demande avant d\'appliquer des valeurs risquées d\'un `.dir-locals.el`.',
              'Les agents sur ta machine lisent une configuration de projet qui lance des commandes : hooks de `.claude/settings.json`, `.mcp.json`, `.cursor/`. Relis-les avant d\'en lancer un là, et considère `CLAUDE.md` et `AGENTS.md` comme écrits par la VM.',
            ],
            code: '',
          },
          {
            title: 'Shell, commandes, hooks',
            paras: [],
            list: [
              'direnv ne charge qu\'un `.envrc` que tu as autorisé, et une modification retire l\'autorisation.',
              'mise fait confiance à une configuration selon son chemin : l\'agent peut modifier un `mise.toml` approuvé, et ton shell lance ses hooks et définit son environnement au `cd` suivant, variables d\'agent-vm comprises. `mise settings set paranoid true` lie la confiance au contenu.',
              'Mercurial lance les hooks du `.hg/hgrc` d\'un dépôt qui t\'appartient, ce qui est le cas des fichiers écrits à travers le partage. Avec un Lima qui garde les `.git` en lecture seule, chaque `.hg` l\'est aussi.',
              '`npm run`, `make`, `./gradlew`, `pytest` (`conftest.py`), `node_modules/.bin`, un `.venv` activé : chacun lance des fichiers que l\'agent peut écrire. Lance-les dans la VM, avec `agent-vm run`.',
              '`docker compose up` sur ta machine fait ce que dit le fichier compose, et un service peut monter n\'importe lequel de tes dossiers, `/` compris, dans un conteneur qui tourne en root. Docker tourne dans la VM : sers-t\'en là.',
              'Hooks de commit : lefthook (`lefthook.yml`) et pre-commit (`.pre-commit-config.yaml`) gardent leurs commandes dans l\'arborescence de travail, donc `git commit` sur ta machine lance ce que l\'agent y a écrit. Relis-les dans le diff, ou commite avec `--no-verify`. Avec un Lima qui garde les `.git` en lecture seule, le dossier `.husky/` de husky l\'est aussi, puisque `core.hooksPath` pointe dedans (voir [Protéger .git](#git)), mais les commandes que ses hooks appellent (`npx lint-staged`, `npm test`) lancent des fichiers du projet.',
            ],
            code: '',
          },
          {
            title: 'Gestionnaires de fichiers',
            paras: [],
            list: [
              'macOS : les fichiers écrits à travers le partage ne portent pas l\'attribut de quarantaine, donc Gatekeeper ne vérifie pas un `.app`, `.command` ou `.pkg` que l\'agent y a laissé. Ne les ouvre pas depuis le Finder.',
              'Windows : l\'Explorateur contacte le serveur nommé dans un `.library-ms`, `.searchConnector-ms`, `.url`, `.lnk` ou `desktop.ini` quand il affiche le dossier, et lui envoie ton empreinte NTLM ([CVE-2025-24054](https://research.checkpoint.com/2025/cve-2025-24054-ntlm-exploit-in-the-wild/), exploitée en 2025). Garde Windows à jour et le SMB sortant bloqué.',
              'Linux : Dolphin, sous KDE, lançait des commandes depuis un `.desktop` ou un `.directory` d\'un dossier qu\'il ne faisait qu\'afficher (CVE-2019-14744, corrigée dans KDE Frameworks 5.61).',
            ],
            code: '',
          },
        ],
      },
      {
        title: 'Terminal et réseau',
        topics: [
          {
            title: 'Séquences d\'échappement du terminal',
            paras: [
              'Ce qu\'affiche la VM arrive tel quel dans ton terminal, et les terminaux réagissent aux séquences d\'échappement. agent-vm ne peut pas les filtrer sans casser les interfaces plein écran des agents.',
            ],
            list: [
              'Presse-papiers : OSC 52 permet à un programme d\'écrire dans ton presse-papiers, et, dans certains terminaux, de le lire. N\'autorise l\'écriture que si tu en as besoin, jamais la lecture, et regarde ce que tu colles dans un shell de l\'hôte.',
              'Réponses tapées à ta place : certaines séquences font taper une réponse au terminal. Pendant une session, elle part vers la VM, mais une séquence envoyée juste avant la sortie atterrit dans ton shell. Des réponses porteuses d\'une commande ont été de vrais bugs : iTerm2 [CVE-2024-38396](https://www.sentinelone.com/vulnerability-database/cve-2024-38396/) (corrigée en 3.5.2), xterm avant lui. Garde ton terminal à jour.',
              'Fonctions qui agissent sur ta machine : transfert de fichiers et triggers d\'iTerm2, contrôle à distance de kitty (désactivé par défaut : laisse-le ainsi), liens dont le texte diffère de la cible.',
              'Usurpation : la VM peut afficher un faux prompt de l\'hôte après une fausse sortie. Vérifie où tu es avant de taper un secret.',
            ],
            code: '',
          },
          {
            title: 'Réseau et ports',
            paras: [
              'La VM atteint Internet et tous les services de la boucle locale de ta machine, à `192.168.5.2` : une base de données de dev, la VM d\'un autre projet par ses ports redirigés. Lima redirige chaque port qu\'écoute une VM vers ton `127.0.0.1`, s\'il est libre : une VM qui écoute la première sur 5432 reçoit les connexions, et les mots de passe, destinés à ton Postgres local. Le bloquer est [sur la feuille de route](#roadmap).',
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
    title: 'Une image de base, puis un clone par dossier.',
    lede:
      'L\'installation des outils ne se paie qu\'une fois, au setup. Chaque projet n\'est ensuite qu\'un clone d\'une VM qui contient déjà toute la chaîne d\'outils.',
    steps: [
      {
        n: '01',
        title: 'setup construit l\'image',
        body: 'Lima crée une VM Debian 13. `agent-vm.setup.sh` y installe les outils de dev, Docker, Chromium et les agents, puis la VM est arrêtée et conservée comme image de base.',
      },
      {
        n: '02',
        title: 'Le premier lancement la clone',
        body: 'Lancer un agent dans un dossier clone l\'image en une VM persistante rattachée à ce chemin, y monte le répertoire de travail et exécute les [scripts de runtime](#customisation-files) : celui de l\'utilisateur d\'abord, celui du projet ensuite.',
      },
      {
        n: '03',
        title: 'L\'agent travaille sans surveillance',
        body: 'Il est lancé avec son option d\'approbation automatique. Lima redirige vers l\'hôte les ports qu\'il ouvre dans la VM : un serveur de dev reste joignable depuis ton navigateur, comme d\'habitude.',
      },
      {
        n: '04',
        title: 'La VM survit à la session',
        body: 'Elle reste là après la sortie de l\'agent. Toute commande lancée ensuite dans le même dossier la réutilise, avec ses conteneurs et ses identifiants, jusqu\'à `rm` ou `--rm`.',
      },
    ],
    diagram: {
      hostTitle: 'Ta machine',
      hostItems: ['Clés SSH', 'Jetons d\'API', 'Sessions de navigateur', 'Config git', 'Tout le reste'],
      hostNote: 'Seul Lima est installé',
      boundaryLabel: 'Frontière de l\'hyperviseur',
      vmTitle: 'La VM',
      vmItems: ['L\'agent', 'node, python, docker, ...', 'Chromium headless, ...', 'Ports redirigés vers l\'hôte'],
      vmNote: 'Noyau séparé',
      sharedLabel: 'Partagé',
      sharedTitle: '~/work/ton-projet',
      sharedBody:
        'Le dossier de ton projet, monté dans la VM au même chemin. Ton éditeur et l\'agent travaillent sur les mêmes fichiers, il n\'y a donc rien à recopier. Lecture-écriture par défaut, lecture seule avec `--readonly`. Tout ce qui traverse d\'autre, c\'est toi qui l\'as choisi : le fichier d\'env, et les montages ajoutés dans `~/.agent-vm/volumes`.',
    },
    isolationNote:
      'Chaque VM s\'authentifie de son côté : le `claude login` se fait dedans. Les identifiants survivent aux redémarrages de cette VM et ne sont partagés ni avec l\'hôte ni avec les autres VM. Le réseau, lui, est partagé : voir [Réseau et ports](#network-and-ports).',
    contentsTitle: 'Ce qu\'il y a dans la VM',
    contentsLede:
      'La sélection par défaut de l\'assistant et `--preinstall=default` donnent le même résultat : tout ce qui suit, sauf les lignes marquées non.',
    contentsHeaders: ['Catégorie', 'Paquets', 'Nom', 'Par défaut'],
    contents: [
      ['Base', 'git, curl, wget, jq, zsh, ca-certificates, sshfs, build-essential, pkgconf, patch, unzip, zip, ripgrep, fd-find, htop', 'toujours', 'oui'],
      ['Bibliothèques de compilation', 'libssl-dev, libreadline-dev, zlib1g-dev, libyaml-dev, libffi-dev', 'toujours', 'oui'],
      ['Gestionnaire de versions', 'mise', 'toujours', 'oui'],
      ['Python', 'python3, pip, venv', 'python', 'oui'],
      ['Node.js', 'Node.js 24 LTS via NodeSource', 'node', 'oui'],
      ['Ruby', 'ruby-full', 'ruby', 'non'],
      ['Rust', 'rustup, toolchain stable', 'rust', 'non'],
      ['Go', 'golang-go', 'golang', 'non'],
      ['CLI GitHub', 'gh', 'gh', 'oui'],
      ['Navigateur', 'Chromium headless, xvfb', 'chromium', 'oui'],
      ['Conteneurs', 'Docker Engine, Docker Compose', 'docker', 'oui'],
      ['Agents IA', 'Claude Code, OpenCode, Codex CLI, Mistral Vibe', 'claude, opencode, codex, vibe', 'oui'],
      ['Agents IA', 'Pi', 'pi', 'non'],
      ['MCP', 'Chrome DevTools MCP, câblé dans chaque agent installé sauf Pi (pas de support MCP)', 'mcp-chrome', 'oui'],
      ['MCP', 'Playwright MCP, réutilisant le même Chromium', 'mcp-playwright', 'non'],
    ],
    contentsNote:
      'Ce n\'est que ce que l\'image contient au départ, pour que le premier lancement ne passe pas son temps à télécharger des outils. L\'agent est root dans la VM et a accès au réseau : il installe lui-même ce qui lui manque, avec `apt install`, `pip`, `cargo` ou un runtime absent de la liste.',
    dockerTitle: 'Pourquoi pas Docker',
    dockerLede:
      'Sous Linux, les conteneurs partagent le noyau de l\'hôte : une dépendance compromise qui trouve une faille dans le noyau se retrouve sur ta machine. Sous macOS, Docker Desktop fait déjà tourner une VM, ce qui réduit l\'écart, mais c\'est une seule VM partagée par tous tes conteneurs, pas une par projet. Une VM a son propre noyau, et root dans la VM a encore l\'hyperviseur entre lui et ton poste. Les différences pratiques comptent autant que celle-ci.',
    dockerHeaders: ['', 'Sans isolation', 'Docker / devcontainer', 'agent-vm'],
    docker: [
      ['L\'agent peut tout exécuter', 'Oui', 'Oui', 'Oui'],
      ['Fichiers de l\'hôte accessibles', 'Tous', 'Ce que tu montes', 'Le dossier du projet'],
      [
        'Identifiants git, agent SSH',
        'Les tiens',
        'Aucun avec Docker seul, transmis par les devcontainers de VS Code',
        'Rien, sauf ce que tu mets dans ~/.agent-vm/env',
      ],
      ['Réseau sortant', 'Ouvert', 'Ouvert par défaut', 'Ouvert (voir [la feuille de route](#roadmap))'],
      ['Partage le noyau de l\'hôte', 'Oui', 'Sous Linux ; sous macOS, celui de la VM Docker Desktop', 'Non'],
      [
        'Pour atteindre l\'hôte, il faut',
        'Rien',
        'Une faille du noyau, plus une faille de l\'hyperviseur sous macOS',
        'Une faille de l\'hyperviseur',
      ],
      ['Docker à l\'intérieur', 'Oui', 'Exige DinD ou un montage de socket', 'Oui, nativement'],
      ['Navigateur headless', 'Sur l\'hôte', 'À prévoir dans ton image', 'Chromium, inclus'],
      [
        'Définition de l\'environnement',
        'Aucune, ta machine',
        'Un devcontainer.json versionné avec le projet',
        'Une image de base unique, la même pour tous tes projets',
      ],
    ],
    dockerNote:
      'Docker tourne nativement dans la VM, sans Docker-in-Docker, Chromium headless fonctionne d\'emblée, et Lima redirige les ports tout seul. Sur un Mac, ça remplace Docker Desktop.',
  },

  roadmap: {
    title: 'Ce qui manque.',
    items: [
      {
        status: 'Attend Lima',
        title: 'Bloquer le réseau sortant',
        body: '`--offline` a existé, puis a été retiré : il posait des règles iptables dans la VM, où l\'agent est root et pouvait les supprimer. Bloquer côté hôte demande un réglage que Lima ne propose pas. QEMU a déjà l\'option (`-netdev user,restrict=on`) ; avec `vz`, le réseau en mode utilisateur est la pile gvisor de Lima, c\'est donc là qu\'il faudrait l\'ajouter. Le même blocage couperait aussi l\'accès au loopback de l\'hôte, que l\'invité joint aujourd\'hui en `192.168.5.2`.',
      },
      {
        status: 'Demande un M3',
        title: 'Faire tourner une VM dans la VM',
        body: 'Une option `--allow-nested-vm`, pour tester de l\'outillage de virtualisation depuis la VM. Lima gère la virtualisation imbriquée, mais elle est désactivée par défaut et ne peut pas être activée sans condition : sur une puce antérieure à l\'Apple M3, `limactl start` échoue purement et simplement, et plus aucune VM ne démarrerait. L\'option devrait donc d\'abord vérifier ce que l\'hôte sait faire. Personne ici n\'a de M3 pour la tester. Elle donnerait aussi à l\'agent un accès à une interface d\'hyperviseur.',
      },
      {
        status: 'Conçu, pas construit',
        title: 'Faire tourner les VM sur une autre machine',
        body: 'Une seule installation sur ton portable, qui pilote des VM sur une machine que tu loues. Tu refermes le portable, l\'agent continue. Questions ouvertes : désigner une VM par son nom plutôt que par le dossier courant, et décider qui se charge de supprimer un espace de travail.',
      },
    ],
  },

  contribute: {
    eyebrow: 'Contribuer',
    title: 'Les contributions sont bienvenues.',
    lede:
      'agent-vm est une petite base de code Bash lisible, avec une suite de tests qui ne crée aucune VM et n\'a pas besoin du réseau. Rapports de bugs, corrections du moteur, prise en charge de nouveaux agents : tout est bienvenu.',
    testsTitle: 'Lancer les tests',
    testsBody:
      'La suite tourne avec un `limactl` factice, dans un `HOME` jetable, où git lit aussi sa config. Aucune VM n\'est créée, démarrée ou supprimée, ton vrai `~/.agent-vm` et ta config git ne sont pas touchés, et rien n\'est téléchargé. Elle couvre le nommage des VM, la comparaison des ressources, la détection des VM obsolètes, les commandes `info`, `version` et `name`, l\'analyse de `--preinstall`, l\'écriture de la config MCP, et le mode de montage du projet sur lequel repose `--readonly`. `./test-e2e.sh` complète le tableau : il construit une vraie VM avec `--preinstall=none` et vérifie ce qu\'un `limactl` factice ne peut pas vérifier, à commencer par la capacité de root dans l\'invité à lever `--readonly` et, avec un Lima qui a `readonlyNames`, à écrire dans `.git`, et le fait qu\'une VM `--scratch` ne voie rien de l\'hôte et disparaisse ensuite. Il tourne dans son propre `LIMA_HOME` : tes VM ne sont jamais touchées. Les tests unitaires sont les `tests/NN-*.sh`, lancés dans l\'ordre dans un même shell après `tests/helpers.sh`, si bien qu\'un fichier peut s\'appuyer sur un précédent ; un nouveau sujet a son propre fichier.',
    testsCode: './test.sh        # rapide, sans VM\n./test-e2e.sh    # vraie VM, nécessite Lima',
    shellsTitle: 'Tester avec les shells qui comptent',
    shellsBody:
      'macOS fournit encore bash 3.2, plus strict qu\'un bash récent sur l\'expansion d\'un tableau vide sous `set -u`. Un changement qui passe sous bash 5 peut très bien casser sur un Mac tel qu\'il sort du carton. L\'image `bash:3.2` n\'a pas git, donc les tests qui en ont besoin y sont sautés : ajoute-le avec `apk`.',
    shellsCode: 'docker run --rm -v "$PWD:/w" -w /w bash:3.2 ./test.sh\ndocker run --rm -v "$PWD:/w" -w /w bash:3.2 sh -c \'apk add -q git && git config --global safe.directory "*" && ./test.sh\'',
    structureTitle: 'Où se trouve quoi',
    structureHeaders: ['Fichier', 'Ce que c\'est'],
    structure: [
      ['agent-vm.sh', 'La commande : réglages, chargement de lib/, démarrage d\'une VM, les commandes. À poser sur ton PATH.'],
      ['lib/', 'Le reste de la commande, un fichier par sujet : montages, protection de .git, env, doctor, setup…'],
      ['agent-vm.setup.sh', 'Installation des paquets, exécutée dans la VM de base pendant le setup.'],
      ['install.sh', 'Ancien installeur, désormais un raccourci vers ./agent-vm.sh install.'],
      ['test.sh', 'Suite de tests. limactl factice, aucune VM, aucun réseau. Lance tests/, dans l\'ordre.'],
      ['test-e2e.sh', 'Suite de bout en bout. Construit une vraie VM dans un LIMA_HOME jetable.'],
      ['runtime.example.sh', 'Modèle commenté pour ~/.agent-vm/runtime.sh.'],
      ['CHANGELOG.md', 'Ce qui change à chaque version.'],
      ['release.sh', 'Vérifie, tague et publie une version. --dry-run d\'abord.'],
      ['www/', 'Ce site. Astro, statique, déployé sur GitHub Pages.'],
      ['www/public/install.sh', 'L\'installeur curl, servi à /install.sh.'],
    ],
    guidelinesTitle: 'Avant d\'ouvrir une PR',
    guidelines: [
      'Reste compatible avec bash 3.2, et lance `./test.sh` sous `bash:3.2` en plus de ton propre shell.',
      'Tout le code doit pouvoir être relancé : vérifie l\'état avant d\'agir plutôt que de supposer une machine vierge.',
      'Tout nouveau comportement a son test dans `tests/` (un nouveau domaine a son propre `NN-*.sh`). Le `limactl` factice rend ça peu coûteux.',
      'Les commandes destinées aux intégrateurs (`info`, `env`, `version`) sont des contrats. Ajouter des clés, oui ; en changer le sens, non.',
      'Aucun secret, jeton ou chemin personnel dans un commit, une fixture de test ou une issue.',
    ],
    issuesLabel: 'Ouvrir une issue',
    issuesHref: 'https://github.com/sylvinus/agent-vm/issues',
    prLabel: 'Parcourir les pull requests',
    prHref: 'https://github.com/sylvinus/agent-vm/pulls',
    repoLabel: 'Lire le code',
    repoHref: 'https://github.com/sylvinus/agent-vm',
  },

  credits: {
    eyebrow: 'Crédits',
    title: 'Construit sur le travail des autres.',
    lede:
      'agent-vm n\'est qu\'une fine couche au-dessus de logiciels écrits par d\'autres. L\'essentiel de ce qui le fait fonctionner figure dans cette liste.',
    groups: [
      {
        title: 'La machine',
        items: [
          { name: 'Lima', note: 'Des VM Linux sur macOS, Linux et Windows. La seule dépendance hôte, avec QEMU sous Windows.', href: 'https://lima-vm.io/' },
          { name: 'Debian', note: 'La distribution invitée. Debian 13.', href: 'https://www.debian.org/' },
          { name: 'mise', note: 'Gestionnaire de versions de runtimes dans la VM.', href: 'https://mise.jdx.dev/' },
        ],
      },
      {
        title: 'Les agents',
        items: [
          { name: 'Claude Code', note: 'Anthropic.', href: 'https://claude.ai/code' },
          { name: 'OpenCode', note: 'Agent terminal open source.', href: 'https://github.com/anomalyco/opencode' },
          { name: 'Codex CLI', note: 'OpenAI.', href: 'https://github.com/openai/codex' },
          { name: 'Mistral Vibe', note: 'Mistral AI.', href: 'https://docs.mistral.ai/vibe/code/cli/install-setup' },
          { name: 'Pi', note: 'Harnais open source minimaliste. En option.', href: 'https://pi.dev' },
        ],
      },
      {
        title: 'Accès navigateur',
        items: [
          {
            name: 'Chrome DevTools MCP',
            note: 'Câblé par défaut dans chaque agent installé.',
            href: 'https://github.com/ChromeDevTools/chrome-devtools-mcp',
          },
          {
            name: 'Playwright MCP',
            note: 'En option, pointé sur le même Chromium.',
            href: 'https://github.com/microsoft/playwright-mcp',
          },
        ],
      },
    ],
    authorTitle: 'Mainteneur',
    authorBody: 'Construit et maintenu par Sylvain Zimmer.',
    authorHref: 'https://github.com/sylvinus',
    authorName: 'sylvinus',
    licenseTitle: 'Licence',
    licenseBody: 'MIT : utilisation, copie, modification et redistribution libres, à condition de conserver la mention de copyright et la licence. Sans garantie.',
    licenseHref: 'https://github.com/sylvinus/agent-vm/blob/main/LICENSE',
  },

  footer: {
    tagline: 'Une VM Linux jetable par projet pour les agents de code IA.',
    license: 'MIT',
    backToTop: 'Haut de page',
  },

  ui: {
    copy: 'Copier',
    copied: 'Copié',
    copyFailed: 'Échec de la copie',
    copyLabel: 'Copier le code dans le presse-papiers',
    anchorLabel: 'Lien vers cette section (le copie)',
    linkCopied: 'Lien copié',
  },
};
