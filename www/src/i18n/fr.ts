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
      'agent-vm donne à chaque projet sa propre VM Linux et y lance l\'agent de code sans demande de confirmation. Tes clés SSH, tes sessions de navigateur, le reste de ton disque et ton réseau local restent hors de sa portée. Un seul binaire, Lima intégré, sous licence MIT.',
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
      'agent-vm lance les agents de code IA avec toutes les permissions, dans une VM Linux par projet. Ils n\'y atteignent ni tes clés SSH, ni tes sessions de navigateur, ni le reste de ton disque, ni ton réseau local.',
    installLabel: 'Pour commencer',
    ctaPrimary: 'Installer',
    ctaSecondary: 'Comment ça marche',
    meta: 'Licence MIT · macOS, Linux, Windows (expérimental) · Lima intégré',
    terminalCaption:
      'Seul le dossier du projet est monté.',
    points: [
      {
        title: 'Un seul binaire, [Lima](https://lima-vm.io/) intégré',
        body: 'Ni Lima à installer, ni Node, ni npm, ni Docker Desktop sur ta machine : la chaîne d\'outils vit dans la VM. Sous Linux, les VM ont besoin de QEMU et d\'un accès à KVM.',
      },
      {
        title: 'Un noyau séparé, pas un simple namespace',
        body: 'Sous Linux, sortir d\'un conteneur, c\'est atterrir sur l\'hôte. Sortir d\'une VM, c\'est d\'abord devoir franchir l\'hyperviseur.',
      },
      {
        title: 'Les ports sont redirigés automatiquement',
        body: 'Un serveur de dev lancé dans la VM répond sur localhost, au même port, avec une notification, sans option ni configuration. Un port déjà pris par un de tes programmes lui est laissé.',
      },
      {
        title: 'Tout est prêt, et root pour le reste',
        body: 'La VM de base contient les outils de dev, Docker, Chromium headless et les agents, choisis dans un assistant de setup. L\'agent est root dans sa VM : il installe lui-même ce qui lui manque.',
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
        body: 'npm a lancé les scripts d\'installation de chaque paquet par défaut jusqu\'à npm 12 (juillet 2026), pip lance toujours le build d\'un paquet source, Cargo son `build.rs`, et tes tests exécutent ensuite tout ce qui a été installé. En 2025, le ver Shai-Hulud s\'est propagé ainsi dans des milliers de paquets npm : il récupérait jetons npm, PAT GitHub, clés SSH et identifiants cloud, puis s\'en servait pour se republier.',
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
      'Une VM limite ce qu\'une erreur ou un agent compromis peut atteindre au projet, à Internet et à ce que tu lui confies, comme [son fichier d\'env](#share-secrets-across-vms). Ta machine et ton réseau local restent hors d\'atteinte : voir [Sécurité](#security).',
  },

  install: {
    eyebrow: 'Installation',
    title: 'Installer, construire une image de base, lancer un agent.',
    lede:
      'agent-vm, c\'est un seul binaire, Lima intégré, sans démon : chaque VM en marche est servie par un processus agent-vm à elle.',
    prerequisitesTitle: 'Prérequis',
    prerequisites: [
      { name: 'macOS, Linux ou Windows', note: 'Windows est expérimental : pas encore essayé sur une machine Windows.', href: '' },
      {
        name: 'QEMU, sous Linux et Windows',
        note: 'macOS n\'a besoin de rien d\'autre. Sous Linux, KVM aussi : `agent-vm setup` dit ce qui manque et comment l\'installer. Sous Windows, QEMU 7.2 ou plus récent et la fonctionnalité Windows Hypervisor Platform.',
        href: '',
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
        note: 'Télécharge depuis GitHub la dernière version publiée, compilée pour ta machine, la vérifie avec le `SHA256SUMS` de la version, la décompresse dans `~/.local/share/agent-vm` et place un lien `agent-vm` dans `~/.local/bin`. Propose ensuite de lancer l\'étape 2 dans la foulée. Relance-le pour mettre à jour. `sh -s -- --version X.Y.Z` installe une version donnée, `sh -s -- --git` un clone de `main`.',
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
        note: 'Le compile, avec Go (et sous macOS les outils en ligne de commande de Xcode), puis `install` place un lien symbolique `agent-vm` dans ton `PATH`. Après un `git pull`, relance `./agent-vm.sh install` pour recompiler. Il propose aussi de lancer l\'étape 2 dans la foulée.',
      },
      {
        id: 'windows',
        label: 'Windows',
        code: '# dans Git Bash (expérimental)\nwinget install SoftwareFreedom.QEMU\ncurl -fsSL https://www.agent-vm.org/install.sh | sh',
        note: 'Expérimental : pas encore essayé sur une machine Windows. Sans Git Bash, télécharge `agent-vm-X.Y.Z-windows-amd64.tar.gz` (ou `-arm64`) depuis les versions publiées sur GitHub, décompresse-le avec `tar -xzf`, et lance `agent-vm.exe install` dans PowerShell. Les VM ont aussi besoin de la fonctionnalité Windows Hypervisor Platform, qu\'un administrateur active une fois : voir [Windows et WSL](#windows-and-wsl).',
      },
    ],
    steps: [
      {
        title: 'Construire l\'image de base',
        body: 'À faire une seule fois. Un assistant choisit ce qui entre dans l\'image : Entrée prend la sélection par défaut (voir [Ce qu\'il y a dans la VM](#what-is-in-the-vm)). Crée avec elle une VM Debian 13, puis la garde, arrêtée, comme image de base.',
        code: 'agent-vm setup',
      },
      {
        title: 'Lancer un agent dans ton projet',
        body: 'Clone l\'image en une VM dédiée à ce dossier, y monte le dossier et lance l\'agent, sans demande de confirmation. Un démarrage peut d\'abord s\'arrêter sur une question de sécurité : voir [Protéger .git](#git).',
        code: 'cd ton-projet\nagent-vm opencode     # ou : agent-vm claude',
      },
    ],
  },


  usage: {
    eyebrow: 'Utilisation',
    title: 'Les commandes du quotidien.',
    lede:
      'À lancer depuis le dossier de ton projet. La [Référence](#reference) liste chaque commande, option et fichier.',
    cards: [
      {
        title: 'Lancer un agent',
        body: 'Les arguments supplémentaires sont transmis tels quels à l\'agent : tout ce que sa CLI accepte fonctionne ici.',
        code: 'agent-vm opencode                        # OpenCode\nagent-vm claude                          # Claude Code\nagent-vm codex                           # Codex CLI\nagent-vm vibe                            # Mistral Vibe\n\nagent-vm claude -p "corrige les erreurs de lint"\nagent-vm opencode run "mets à jour le changelog"',
      },
      {
        title: 'Accéder au serveur de dev',
        body: 'Chaque port ouvert dans la VM est redirigé vers le même port de ton localhost : un serveur de dev s\'ouvre dans ton navigateur comme d\'habitude, et une notification le signale. Un port sur lequel écoute déjà un de tes programmes n\'est pas pris : la notification le dit aussi. Considère les ports redirigés comme ceux de l\'agent.',
        code: 'agent-vm run npm run dev         # puis ouvre localhost:5173\nagent-vm run docker compose up',
      },
      {
        title: 'Entrer dans la VM',
        body: 'Un shell pour aller voir ce qui s\'y passe, ou une commande isolée quand tu sais déjà ce que tu veux.',
        code: 'agent-vm shell                    # zsh dans la VM\nagent-vm run npm install          # commande unique\nagent-vm run --tty opencode       # un PTY pour les TUI\nagent-vm sh -c "ls -la | grep config"\nagent-vm code                     # VS Code dans le navigateur, si installé',
      },
      {
        title: 'Gérer le parc',
        body: 'Dans `list`, la VM du dossier courant est marquée d\'un `>`. Si un dossier a été renommé, seul `list` permet de retrouver sa VM.',
        code: 'agent-vm list          # chaque VM, la courante marquée\nagent-vm stop          # arrête, garde le disque\nagent-vm rm            # arrête et supprime\nagent-vm destroy-all   # tout, image de base comprise\nagent-vm doctor        # ce qui ne va pas, et quoi lancer',
      },
      {
        title: 'Restreindre la session',
        body: '`--readonly` passe tous les partages de l\'hôte en lecture seule, volumes `rw` compris, et c\'est l\'hôte qui l\'impose : root dans la VM ne peut pas le lever. Les paquets s\'installent toujours sur le disque de la VM, mais rien n\'arrive dans le projet. `--scratch` ne monte rien de ce qui est à toi : l\'agent clone le code avec un jeton tiré d\'`agent-vm env`, pousse son travail, et la VM est supprimée à la sortie.',
        code: 'agent-vm --readonly shell   # rien de modifiable sur l\'hôte\nagent-vm --scratch claude   # rien de monté, supprimée après\nagent-vm --rm run npm test  # détruit la VM à la sortie',
      },
      {
        title: 'Redimensionner à la volée',
        body: 'Une nouvelle VM reprend les 10 Go de disque, 3 Go de mémoire (4 avec code-server choisi dans l\'assistant) et 1 CPU de l\'image. Passe une autre valeur et la VM est reconfigurée, après confirmation si elle tourne. Le disque ne fait que grandir. CPU et mémoire sont plafonnés à la moitié de l\'hôte, par VM.',
        code: 'agent-vm --disk 50 opencode\nagent-vm --memory 16 --cpus 8 shell\nagent-vm --reset claude   # re-cloner depuis l\'image',
      },
      {
        title: 'Partager des secrets entre VM',
        body: 'Des lignes `CLÉ=valeur` dans `~/.agent-vm/env`, poussées dans chaque VM à chaque commande. Tout ce qui tourne dans la VM peut les lire : mets-y des jetons étroits et révocables. Passe par `env set` : une seule apostrophe mal placée casse tout le fichier.',
        code: 'agent-vm env set GH_TOKEN   # masqué, hors historique\nagent-vm env list           # les noms, jamais les valeurs\nagent-vm env has ANTHROPIC_API_KEY\n\n# limité à ce projet\nagent-vm project-env set SOME_PATH ./config',
      },
      {
        title: 'Éditer avec les outils de la VM',
        body: 'Pour les serveurs de langage, les linters, le débogueur et les paquets de la VM, fais tourner l\'éditeur dans la VM : `agent-vm code` sert VS Code (code-server) dans un onglet du navigateur, seule partie sur ta machine. Il s\'installe avec `code-server` ou un nom `code-*` ([Ce qu\'il y a dans la VM](#what-is-in-the-vm)). L\'onglet peut toujours ouvrir des liens, et chaque VM peut y envoyer ton navigateur, d\'où un mot de passe et un nom d\'hôte par VM ([Réseau et ports](#network-and-ports)). N\'y branche pas plutôt un éditeur de bureau en SSH ([SSH depuis ta machine](#ssh-from-your-machine)).',
        code: 'agent-vm setup --preinstall=default,code-claude   # une fois\nagent-vm code   # affiche l\'adresse et le mot de passe\n                # Ctrl-C arrête l\'éditeur',
      },
    ],
    gitTitle: 'Laisser l\'agent commiter',
    gitBody:
      'git lit son identité dans l\'environnement : le fichier d\'env partagé suffit, sans aucun `git config` dans la VM. Les quatre variables sont nécessaires, car git exige un committer et pas seulement un auteur.',
    gitCode:
      '# ~/.agent-vm/env\nGIT_AUTHOR_NAME=Ton Nom\nGIT_AUTHOR_EMAIL=12345+toi@users.noreply.github.com\nGIT_COMMITTER_NAME=Ton Nom\nGIT_COMMITTER_EMAIL=12345+toi@users.noreply.github.com',
    gitNote:
      'Ces variables passent avant `git config`, dans tous les dépôts de la VM : pour une identité par dépôt, règle plutôt `user.name` et `user.email` depuis un script de runtime. `gh` lit `GH_TOKEN` de lui-même, donc `gh pr create` fonctionne sans rien d\'autre. Un `git push` en HTTPS a besoin, lui, d\'un credential helper : une ligne `gh auth setup-git` dans ton [script de runtime](#customisation-files).',
    gitHumanTitle: 'Cela dit, garde la main sur les commits',
    gitHumanBody:
      'Que l\'agent puisse commiter ne veut pas dire qu\'il doit le faire. Un commit signifie que tu as lu le diff : laisse l\'agent écrire le code, relis-le et commite toi-même. Avec `.git` [protégé](#git), c\'est même le seul moyen.',
  },

  reference: {
    eyebrow: 'Référence',
    title: 'Chaque commande, option et fichier.',
    lede: 'Ce que les sections précédentes laissent de côté : toutes les commandes, les fichiers et variables de configuration, et ce sur quoi un script peut compter.',
    commandGroups: [
      {
        title: 'Lancer un agent',
        rows: [
          ['opencode [args]', 'Lance OpenCode avec `--auto`.'],
          ['claude [args]', 'Lance Claude Code avec `--dangerously-skip-permissions`.'],
          ['codex [args]', 'Lance Codex CLI avec `--dangerously-bypass-approvals-and-sandbox`.'],
          ['vibe [args]', 'Lance Mistral Vibe avec `--agent auto-approve`.'],
          ['pi [args]', 'Lance Pi, qui ne demande aucune permission.'],
        ],
      },
      {
        title: 'Entrer dans la VM',
        rows: [
          ['shell, sh', 'Ouvre un shell zsh dans la VM. `-c "…"` exécute une commande unique via un shell de connexion.'],
          ['run <cmd> [args]', 'Exécute une commande sans shell. `--tty` alloue un PTY pour les TUI.'],
          ['code', 'Sert VS Code (code-server) depuis la VM à `http://<nom-de-vm>.localhost:<port>/`, jusqu\'à Ctrl-C, à ouvrir dans ton navigateur. Son mot de passe est créé dans la VM à la première utilisation, puis affiché avec l\'adresse. Demande `code-server` ou un nom `code-*` au setup ([Ce qu\'il y a dans la VM](#what-is-in-the-vm)).'],
        ],
      },
      {
        title: 'Gérer le parc',
        rows: [
          ['list, status', 'Liste toutes les VM agent-vm, celle du dossier courant marquée d\'un `>`, avec la version d’agent-vm qui a construit la base dont chacune est clonée, et sa date.'],
          ['stop [vm-name]', 'Arrête la VM de ce dossier, ou celle dont tu donnes le nom. Le disque est conservé.'],
          ['rm [vm-name]', 'Arrête et supprime. Un nom issu de `list` permet de viser une VM dont le dossier a disparu.'],
          ['destroy-all', 'Arrête et supprime toutes les VM agent-vm, image de base comprise. `setup` la reconstruit.'],
          ['doctor', 'Vérifie l\'hôte, l\'image de base, tes fichiers de réglages et ce dossier, et dit quoi lancer. Ne modifie rien.'],
        ],
      },
      {
        title: 'Installer et configurer',
        rows: [
          ['install', 'Met `agent-vm` dans ton `PATH` : un lien vers le binaire qui le lance, dans `~/.local/bin`. L\'installeur curl le lance pour toi.'],
          ['uninstall', 'Retire ce lien. Les VM et `~/.agent-vm` restent.'],
          ['setup', 'Construit l\'image de base. `--preinstall=LIST` saute l\'assistant ([Ce qu\'il y a dans la VM](#what-is-in-the-vm)) ; `--disk`, `--memory` et `--cpus` la dimensionnent.'],
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
    optionsNote: 'Pour `claude`, `opencode`, `codex`, `vibe`, `pi`, `shell`, `run` et `code`, à placer avant la commande ou juste après son nom. Tout ce qui suit appartient à la commande : dans `agent-vm run docker run --rm x`, `--rm` est l\'option de docker.',
    optionsHeaders: ['Option', 'Rôle', 'Défaut'],
    options: [
      ['--disk GB', 'Taille du disque. Peut grandir, jamais rétrécir.', 'celle de l\'image (10)'],
      ['--memory GB', 'Mémoire de la VM. Plafonnée à la moitié de l\'hôte, par VM.', 'celle de l\'image (3, ou 4 avec code-server choisi dans l\'assistant)'],
      ['--cpus N', 'Nombre de CPU. Plafonné à la moitié de l\'hôte, par VM.', 'celui de l\'image (1)'],
      ['--ssh-port N', 'Port fixe sur l\'hôte pour le SSH de la VM, pour les outils qui l\'enregistrent. `0` revient à un nouveau port à chaque démarrage. Redémarre une VM en marche, après confirmation.', 'un nouveau par démarrage'],
      ['--reset', 'Détruit la VM et la re-clone depuis l\'image de base.', 'inactif'],
      ['--readonly', 'Tous les partages de l\'hôte en lecture seule, projet et volumes. Redémarre une VM en marche, après confirmation.', 'inactif'],
      ['--unsafe-writable-git', 'Laisse chaque `.git` modifiable pour que l\'agent puisse commiter, avec un avertissement. Voir [Protéger .git](#git).', 'inactif'],
      ['--unsafe-disable-security-prompts', 'Continue là où un démarrage s\'arrêterait sur une question de sécurité (voir [Protéger .git](#git)). Les avertissements restent affichés. Équivaut à `AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1`.', 'inactif'],
      ['--rm', 'Détruit la VM dès que la commande se termine.', 'inactif'],
      ['--scratch', 'Une nouvelle VM où rien de ce qui est à toi n\'est monté, supprimée à la fin de la commande (après confirmation sur un terminal). `~/.agent-vm/env` et `runtime.sh` y entrent, les fichiers du projet non. Plusieurs peuvent tourner en même temps.', 'inactif'],
    ],
    envTitle: 'Variables d\'environnement',
    envNote: 'Lues dans ton shell, jamais dans un fichier du projet.',
    envHeaders: ['Variable', 'Rôle', 'Défaut'],
    env: [
      ['AGENT_VM_STATE_DIR', 'Déplace `~/.agent-vm`, VM comprises, pour des tests, la CI ou une seconde installation, sans déplacer `HOME`.', '~/.agent-vm'],
      ['AGENT_VM_LIMA_HOME', 'Où vivent les VM. Pas le dossier de ton propre Lima : agent-vm garde ses VM à part.', '~/.agent-vm/lima'],
      ['AGENT_VM_PROJECT_ENV', 'Le fichier d\'env du projet, relatif au projet ou absolu.', '.agent-vm.env'],
      ['AGENT_VM_PROJECT_RUNTIME', 'Le script de runtime du projet, relatif au projet ou absolu. Hors du projet, c\'est l\'hôte qui le lit.', '.agent-vm.runtime.sh'],
      ['AGENT_VM_HOST_SHARE', 'CPU et mémoire par VM sont plafonnés à ceux de l\'hôte divisés par ce nombre. `1` : tout l\'hôte.', '2'],
      ['AGENT_VM_BIN_DIR', 'Où `install` place le lien `agent-vm`.', '~/.local/bin'],
      ['AGENT_VM_SSHFS_CACHE', '`1` : sshfs met aussi en cache les partages modifiables, plus rapide sur beaucoup de fichiers (`git status`, `find`) ; la VM peut alors voir un fichier tel qu\'il était jusqu\'à 20 secondes avant, et le réécrire ainsi. S\'applique au prochain démarrage d\'une VM.', 'non définie'],
      ['AGENT_VM_NOTIFY', '`0` : pas de notification quand un port est redirigé, ou laissé à un de tes programmes.', 'non définie'],
      ['AGENT_VM_GUARDED_WRITES', '`deny` : refuse sans demander les écritures de la VM dans les [fichiers surveillés](#guarded-files), pour une machine sans personne devant l\'écran.', 'non définie'],
      ['AGENT_VM_UNSAFE_OPEN_NETWORK', '`1` : pas d\'[isolation réseau](#network-and-ports) : les VM atteignent ta machine et tes réseaux locaux. S\'applique au prochain démarrage d\'une VM.', 'non définie'],
      ['AGENT_VM_UNSAFE_WRITABLE_GIT', '`1` : équivaut à `--unsafe-writable-git`.', 'non définie'],
      ['AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS', '`1` : équivaut à `--unsafe-disable-security-prompts`.', 'non définie'],
    ],
    customTitle: 'Fichiers de personnalisation',
    customLede:
      'Huit fichiers facultatifs, aucun n\'est nécessaire pour démarrer. Ceux propres à l\'utilisateur sont dans `~/.agent-vm/`, ceux propres à un projet dans le projet lui-même.',
    customTable: {
      headers: ['Fichier', 'Portée', 'Quand'],
      rows: [
        ['~/.agent-vm/env', 'Toutes les VM', 'Copié à chaque lancement'],
        ['~/.agent-vm/volumes', 'Toutes les VM, ou les projets qu\'une entrée désigne', 'Monté à la création de la VM'],
        ['~/.agent-vm/network', 'Toutes les VM : ce qu\'elles peuvent atteindre ([Réseau et ports](#network-and-ports))', 'Lu au démarrage d\'une VM'],
        ['~/.agent-vm/guarded', 'Toutes les VM : les fichiers sur lesquels demander ([Fichiers surveillés](#guarded-files))', 'Lu au démarrage d\'une VM'],
        ['~/.agent-vm/setup.sh', 'Image de base', 'Une fois, pendant agent-vm setup'],
        ['~/.agent-vm/runtime.sh', 'Toutes les VM', 'À chaque commande qui entre dans une VM, en premier'],
        ['.agent-vm.runtime.sh', 'Un seul projet', 'À chaque commande qui entre dans sa VM, après le global'],
        ['.agent-vm.env', 'Un seul projet', 'Copié après l\'env partagé, et prioritaire sur lui'],
      ],
    },
    volumesTitle: 'Montages en plus : ~/.agent-vm/volumes',
    volumesBody:
      'Une ligne `source[:destination][:mode][:projet]` par montage, `~` développé à gauche, `#` pour les commentaires. Le mode est `ro` (par défaut) ou `rw`, et `rw` ne marche que pour les dossiers. Sans destination, le chemin est monté au même endroit dans la VM ; une destination relative est dans le projet. Le quatrième champ limite l\'entrée aux projets qu\'il désigne, `*` couvrant n\'importe quoi.',
    volumesCode:
      '# ~/.agent-vm/volumes\n~/.gitconfig    # même chemin, lecture seule\n~/.cache/shared:/home/you.guest/.cache/shared:rw\n\n# seulement dans ~/work/webapp, en .claude, lecture seule\n~/.claude-vm/webapp:.claude:ro:~/work/webapp\n\n# tous les projets sous ~/work\n~/.cache/pip:/home/you.guest/.cache/pip:rw:~/work/*\n\n# même chemin, un seul projet\n~/datasets::ro:~/work/ml',
    volumesNote:
      'La liste reste de ton côté, pas dans le projet : l\'agent écrit dans le projet, et pourrait sinon monter n\'importe quel dossier de l\'hôte dans sa VM. Une destination relative qui sort du projet, par `..` ou un lien symbolique, est ignorée. Les changements valent pour les nouvelles VM : `--reset` les réapplique.',
    nodeTitle: 'Node.js : node_modules dans la VM',
    nodeBody:
      'Des centaines de milliers de fichiers sont lents à travers le partage, et les paquets natifs diffèrent de toute façon entre macOS et Linux. Monte un dossier du disque de la VM par-dessus `node_modules` depuis le [script de runtime](#customisation-files) du projet, lancé à chaque commande :',
    nodeCode:
      '#!/bin/bash\n# .agent-vm.runtime.sh\nset -e\nmkdir -p "$HOME/node_modules" node_modules\nmountpoint -q node_modules ||\n  sudo mount --bind "$HOME/node_modules" node_modules',
    nodeNote: 'L\'hôte voit un `node_modules` vide, ou garde le sien : installe aussi de ce côté si ton éditeur a besoin des paquets. Dans un workspace, répète le montage pour un paquet qui a un gros `node_modules` à lui. Un serveur de dev dans la VM peut avoir besoin du polling pour voir les modifications faites sur l\'hôte (Vite : `server.watch.usePolling`).',
    scriptsTitle: 'Depuis un script',
    scriptsParas: [
      'Passe par ces commandes plutôt que de parser la sortie destinée aux humains ou de lire `~/.agent-vm` : les noms de VM et les fichiers d\'état sont des détails d\'implémentation. Aucune ne démarre de VM.',
      '`version --min` renvoie `0` si la version suffit, `1` si elle est plus ancienne, `2` pour un appel mal formé ; un moteur antérieur à `--min` l\'ignore et renvoie `0`. Dans `info`, les booléens valent `1` ou `0`, `unknown` quand c\'est indéterminable, et `base_exists=1` veut dire que l\'image est utilisable.',
      'Un démarrage ne pose ses questions que si la sortie d\'erreur est un terminal : sinon, il s\'arrête là. `security_questions` dans `info` les nomme à l\'avance (`hooks`, `git-config`, `bare-repo` ou `none`), et `--unsafe-disable-security-prompts` les accepte une fois l\'accord de l\'utilisateur obtenu.',
    ],
    scriptsCode:
      'agent-vm version --min 0.2.0 || exit 1  # silencieux si OK\nagent-vm name [dir]    # nom de la VM d\'un dossier\nagent-vm info [dir]    # une paire clé=valeur par ligne\n\n# clés de info : version, template, state_dir,\n# project_env, dir, vm_name, base_exists,\n# vm_exists, vm_running, vm_stale,\n# ssh_host, ssh_config, git_protected,\n# security_questions',
    groups: [
      {
        title: 'Installation et mise à jour',
        topics: [
          {
            title: 'Options de l\'installeur',
            paras: [
              'Les options se placent après `sh -s --` : `--version X.Y.Z`, `--git` pour un clone de `main`, `--dir DIR` au lieu de `~/.local/share/agent-vm`. Pour lire l\'installeur d\'abord, télécharge-le, puis lance-le avec `sh`.',
            ],
            list: [],
            code: 'curl -fsSL https://www.agent-vm.org/install.sh |\n  sh -s -- --dir ~/tools/agent-vm\n\n# le lire d\'abord\ncurl -fsSLO https://www.agent-vm.org/install.sh\nsh install.sh',
          },
          {
            title: 'Mettre à jour',
            paras: [
              'Relance l\'installeur curl, `brew upgrade agent-vm`, ou `git pull && ./agent-vm.sh install` dans un clone. `agent-vm uninstall` retire le lien ; les VM et `~/.agent-vm` restent.',
              'Relancer `setup` reconstruit l\'image de base, pas les VM qui en sont clonées : agent-vm les signale, et `--reset` en reclone une. Son journal complet est dans `~/.agent-vm/setup.log`.',
            ],
            list: [],
            code: '',
          },
          {
            title: 'Depuis la 0.2',
            paras: [
              'Lima est intégré : le Lima de Homebrew, ou la version de Lima installée par la 0.2, peut partir, sauf si tu t\'en sers pour tes propres VM. agent-vm garde ses VM dans `~/.agent-vm/lima`, à l\'écart des tiennes, et les nomme sans le préfixe `agent-vm-` : `ton-projet-1a2b3c4d`, et `base` pour l\'image.',
              'La première commande qui a besoin des VM propose de déplacer celles de la 0.2 depuis `~/.lima` (ou `$LIMA_HOME`), en arrêtant d\'abord celles qui tournent : elles gardent leurs disques, partages et réglages. Si tu refuses, agent-vm redemande la fois suivante ; sans terminal pour demander, il les déplace. `doctor` et `info` se contentent de regarder, et disent s\'il en reste à déplacer.',
              'Pour mettre à jour, relance l\'installeur curl, ou `git pull && ./agent-vm.sh install` dans un clone (Go nécessaire) : le lien de ton `PATH` mène alors au binaire. D\'ici là, le lien de la 0.2 vers `agent-vm.sh` continue de marcher (dans un clone, après un `git pull`, il compile d\'abord agent-vm), tout comme une ligne de ton fichier rc qui le source, dont `install` signale qu\'elle peut partir. Une VM issue d\'une base construite par la 0.1.0 ne démarre plus : lance `agent-vm setup`, puis `--reset`.',
            ],
            list: [],
            code: '',
          },
          {
            title: 'Windows et WSL',
            paras: [
              'Sous Windows, agent-vm tourne nativement, depuis PowerShell ou Git Bash, avec QEMU ; c\'est expérimental, pas encore essayé sur une machine Windows. Tes dossiers y sont `C:/Users/toi/projet`, et `/c/Users/toi/projet` dans la VM, comme avec la 0.2. Le fichier des volumes accepte `C:/x` ou `C:\\x`, et le `/c/x` de la 0.2.',
              'Les VM ont besoin de la fonctionnalité Windows Hypervisor Platform. Elle est désactivée par défaut et seul un administrateur peut l\'activer, une fois, dans les Fonctionnalités de Windows ou avec la commande ci-dessous, puis un redémarrage. Sur un portable géré, c\'est une demande au service informatique. Un démarrage qui échoue faute d\'elle le dit.',
              'WSL2, c\'est Linux pour agent-vm, et ses VM ont besoin de KVM, que WSL2 n\'a qu\'avec la virtualisation imbriquée transmise par l\'hôte Windows. WSL1 ne peut pas faire tourner de VM.',
            ],
            list: [],
            code: '# dans PowerShell en administrateur, puis redémarrer\nDISM /Online /Enable-Feature `\n  /FeatureName:HypervisorPlatform /All',
          },
          {
            title: 'Chemins',
            paras: [
              'Les chemins avec un espace, un guillemet, une barre oblique inverse, un caractère de contrôle, `{{` (Lima le lit comme un modèle) ou des octets qui ne sont pas de l\'UTF-8 sont refusés. Les chemins d\'iCloud Drive contiennent des espaces : passe par un lien symbolique. Un nom de dossier trop long pour les chemins de sockets de Lima est raccourci dans le nom de la VM, qui garde l\'empreinte du chemin complet.',
            ],
            list: [],
            code: 'ln -s ~/Library/Mobile\\ Documents/com~apple~CloudDocs/Dev \\\n  ~/Dev\ncd ~/Dev/ton-projet && agent-vm claude',
          },
          {
            title: 'Ports et doctor',
            paras: [
              'Un port fixé avec `--ssh-port` reste jusqu\'à `--reset` ou `rm`. `doctor` n\'affiche aucun secret : sa sortie peut aller telle quelle dans une issue.',
            ],
            list: [],
            code: '',
          },
        ],
      },
      {
        title: 'Agents et configuration',
        topics: [
          {
            title: 'Comment chaque agent est lancé',
            paras: [
              'Claude Code reçoit aussi le mode sans confirmation par des réglages gérés, car il perd l\'option quand il se relance lui-même ([#72479](https://github.com/anthropics/claude-code/issues/72479)). Pour Pi, setup règle `defaultProjectTrust: "always"`.',
              'Connecte-toi dans la VM (`claude login`, `gh auth login`) : la connexion reste dans cette VM. Monter tes identifiants de l\'hôte les donnerait à tout ce qui y tourne.',
              'Un terminal en couleurs 24 bits qui ne définit pas `COLORTERM` (Terminal.app sous macOS 26) a besoin de `export COLORTERM=truecolor`.',
            ],
            list: [],
            code: '',
          },
          {
            title: 'Serveurs MCP',
            paras: [
              'Playwright MCP utilise le Chromium de la VM et ne télécharge aucun navigateur. Pour un autre moteur, modifie son entrée (retire `--executable-path`, ajoute `--browser firefox`) et lance `npx playwright install firefox`. Ajoute tes propres serveurs à `mcpServers` dans `~/.claude.json`, depuis `~/.agent-vm/setup.sh` ou dans une VM.',
            ],
            list: [],
            code: '{\n  "mcpServers": {\n    "postgres": {\n      "command": "npx",\n      "args": [\n        "-y",\n        "@modelcontextprotocol/server-postgres",\n        "postgresql://localhost:5432/mydb"\n      ]\n    }\n  }\n}',
          },
          {
            title: 'Les fichiers d\'environnement',
            paras: [
              'agent-vm ne connaît aucun des noms : `gh` lit `GH_TOKEN`, Claude Code `ANTHROPIC_API_KEY`, Codex `OPENAI_API_KEY`, Vibe `MISTRAL_API_KEY`. Une modification n\'a pas besoin de `--reset`.',
              'Le `.agent-vm.env` du projet est poussé après le fichier partagé et l\'emporte. Il est dans un dépôt, donc pas de secret dedans : `project-env set` affiche la ligne qui l\'ignore dans git.',
              '`get` et `has` lisent le fichier sans l\'exécuter, et sortent avec le code `2` sur une valeur qui demande un shell. `set` sans valeur te la fait taper sans l\'afficher, hors de l\'historique de ton shell.',
            ],
            list: [],
            code: '',
          },
          {
            title: 'Montages supplémentaires, en détail',
            paras: [
              'Une destination est prise telle quelle, sans `~` : le dossier personnel dans la VM est `/home/<toi>.guest` (`.linux` avant Lima 2.1). Une source absente est ignorée, avec un avertissement.',
              'Un fichier seul est lié en dur dans `~/.agent-vm/file-mounts/<vm>/` puis monté. D\'un système de fichiers à l\'autre, il est copié, et les modifications de l\'hôte attendent le démarrage suivant.',
            ],
            list: [],
            code: '# ~/.agent-vm/volumes : tes instructions et skills Claude,\n# pas tout ~/.claude, qui contient ta connexion sous Linux\n~/.claude/CLAUDE.md:/home/toi.guest/.claude/CLAUDE.md\n~/.claude/skills:/home/toi.guest/.claude/skills',
          },
          {
            title: 'Scripts de setup et de runtime',
            paras: [
              '`~/.agent-vm/setup.sh` tourne une fois dans l\'image, à la fin de `setup`, sous zsh avec sudo. `~/.agent-vm/runtime.sh`, puis le `.agent-vm.runtime.sh` du projet, tournent à chaque commande qui entre dans la VM : les deux doivent pouvoir être relancés. [`runtime.example.sh`](https://github.com/sylvinus/agent-vm/blob/main/runtime.example.sh) couvre l\'identité git, `gh auth setup-git`, les skills et les serveurs MCP.',
              'Ils sont lus sur l\'entrée standard : donne `</dev/null` à une commande qui la lit. Pas de clé privée dedans, l\'agent peut lire ce qu\'ils mettent en place.',
            ],
            list: [],
            code: '# .agent-vm.runtime.sh\nmise install\nnpm install\ndocker compose up -d',
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
        id: 'git',
        title: 'Protéger .git',
        topics: [
          {
            title: 'Pourquoi .git',
            paras: [
              'Git, sur ta machine, exécute ce que désignent le `.git/config` et les hooks d\'un dépôt : `core.fsmonitor` à chaque `git status`, les hooks au commit. Ton éditeur et ton prompt lancent `git status` d\'eux-mêmes : une VM capable d\'écrire dans `.git` pourrait lancer des commandes sur ton hôte en quelques secondes, sans que rien n\'apparaisse dans `git diff`.',
              'Chaque `.git` et `.hg` des partages est en lecture seule pour la VM, à toute profondeur, et c\'est le serveur SFTP intégré à agent-vm, sur ta machine, qui l\'impose (le `sshfs.readonlyNames` de Lima, pas encore intégré en amont : [lima-vm/lima#5529](https://github.com/lima-vm/lima/issues/5529)). L\'agent lit l\'historique mais ne peut pas commiter. Les partages sont en `reverse-sshfs`, plus lent sur beaucoup de fichiers (voir [Node.js](#node)), et sans le cache de sshfs sur ceux qui sont modifiables, pour que la VM ne réécrive jamais un fichier tel qu\'il était avant que tu le changes : `AGENT_VM_SSHFS_CACHE=1` échange cela contre de la vitesse.',
            ],
            list: [],
            code: 'agent-vm doctor    # où tu en es\n\n# laisser l\'agent commiter quand même\nagent-vm --unsafe-writable-git claude',
          },
          {
            title: 'Au-delà du nom .git',
            paras: [
              'Le dossier vers lequel pointe un `core.hooksPath` dans un partage (`.husky` pour husky) est aussi en lecture seule, comme un lien sur le chemin qui y mène, et de même pour les dépôts de tes volumes modifiables. Un dossier qui contient les fichiers internes de git (`HEAD`, `objects/`, `refs/`, un `config`) est un dépôt sous n\'importe quel nom : régler `safe.bareRepository` à `explicit` dans ta config git globale le fait ignorer par git, et celui d\'un volume modifiable est en lecture seule par son nom. Une config incluse depuis un partage, une commande ou un hook que git y lance, ou des hooks à la racine d\'un partage, ouvrent la même porte.',
              'Avant de démarrer une VM aux partages modifiables, agent-vm s\'arrête sur chacun de ceux qu\'il trouve, pour demander : Entrée, ou l\'absence de terminal, annule. `doctor` les liste. `--unsafe-writable-git` (ou `AGENT_VM_UNSAFE_WRITABLE_GIT=1` dans ton shell, jamais lu depuis le projet) laisse l\'agent commiter et rouvre ce chemin vers ton hôte, avec un avertissement à chaque lancement.',
            ],
            list: [],
            code: '',
          },
          {
            title: 'Lima, intégré',
            paras: [
              'agent-vm compile Lima, son serveur SFTP (sshocker et pkg/sftp) et sa pile réseau (gvisor-tap-vsock) depuis leurs sources amont, avec des [correctifs](https://github.com/sylvinus/agent-vm/blob/main/patches/README.md) assez petits pour être proposés en amont : les noms en lecture seule, des corrections du serveur SFTP (un ajout en fin de fichier qui faisait tomber la VM, des écritures appliquées dans le désordre), l\'isolation réseau, la vérification des ports. Chaque VM en marche est servie par un processus agent-vm, qui est l\'agent hôte de Lima.',
              'Chaque partage est servi par le serveur SFTP intégré, cantonné à son dossier : agent-vm ne démarre aucune VM dont la config dit autre chose, quoi qui l\'ait réglée. Un `default.yaml` ou `override.yaml` dans `~/.agent-vm/lima/_config` s\'ajouterait à la config de chaque VM : agent-vm ne démarre aucune VM tant qu\'il y en a un.',
            ],
            list: [],
            code: '',
          },
        ],
      },
      {
        title: 'Ce que fait agent-vm',
        topics: [
          {
            title: 'Dossiers et fichiers refusés',
            paras: [
              'agent-vm ne partage ni ton dossier personnel, ni `/`, ni son propre dossier, ni `~/.agent-vm`, ni le dossier de ton propre Lima (`~/.lima`), ni un dossier qui en contient un : `cd ~ && agent-vm shell` donnerait à la VM tes fichiers de configuration et tes clés SSH.',
              'Il ne lit jamais un fichier du projet par son chemin, puisque la VM peut en faire un lien vers n\'importe lequel de tes fichiers. Ses propres appels à git dans un projet refusent un dépôt nu et ne lancent ni `core.fsmonitor` ni pager.',
            ],
            list: [],
            code: '',
          },
          {
            title: '--readonly, en détail',
            paras: [
              '`--readonly` couvre tous les partages, volumes `rw` compris : un volume accessible en écriture contenant le projet serait une seconde entrée. Le serveur SFTP intégré l\'impose sur ta machine, et agent-vm vérifie la config de chaque VM avant son démarrage, jamais sur la parole de l\'invité.',
              'Une VM en marche dans l\'autre mode est redémarrée, après confirmation. Refusé, ou sans terminal, la commande échoue : la VM en lecture seule d\'une autre session ne repasse jamais en écriture sous elle.',
            ],
            list: [],
            code: '',
          },
        ],
      },
      {
        title: 'Ce qui, sur ta machine, lit aussi le projet',
        topics: [
          {
            title: 'La règle',
            paras: [
              'Tout ce qui, sur ta machine, lit le projet et agit selon ce qu\'il y trouve peut exécuter ce que l\'agent a écrit. agent-vm ferme les portes de git (voir [Protéger .git](#git)), mais ne peut pas verrouiller les fichiers que lisent tes autres outils sans empêcher l\'agent de travailler.',
              'Donc, sur ta machine, ouvre le projet dans ton éditeur et utilise git dedans ; lance tout le reste dans la VM, avec `agent-vm run`. Les listes qui suivent sont des exemples, pas un inventaire.',
            ],
            list: [
              'Rien du tout : ce qui se lance quand tu fais `cd` dans le dossier, quand ton prompt se redessine, quand ton éditeur l\'ouvre. Le cas le plus dangereux.',
              'Un geste que tu fais de toute façon : `git commit` lance des hooks rangés dans l\'arborescence, `docker compose up` monte ce que nomme le fichier compose.',
              'Lancer du code du projet : `npm test`, `make`, un build. C\'est le code de l\'agent : lance-le dans la VM.',
            ],
            code: '',
          },
          {
            title: 'Fichiers surveillés',
            paras: [
              'Pour le premier cas, agent-vm surveille les fichiers que ta machine exécute d\'elle-même : quand la VM en écrit, crée, renomme ou supprime un, à n\'importe quelle profondeur des partages, une fenêtre te demande d\'abord. Un oui vaut jusqu\'à l\'arrêt de la VM ; un non, une minute, après quoi une nouvelle tentative redemande. Là où aucune fenêtre ne peut s\'afficher (pas de session graphique), l\'écriture est refusée et une notification le dit ; une fenêtre restée sans réponse deux minutes la refuse aussi. `AGENT_VM_GUARDED_WRITES=deny` les refuse toutes sans demander.',
              'Surveillés par défaut : `.envrc` (direnv), `.vscode/tasks.json`, `.vscode/settings.json` et `.vscode/launch.json` (VS Code), `.pre-commit-config.yaml` (pre-commit), `lefthook.yml` et `.lefthook.yml` (lefthook), `mise.toml` et `.mise.toml` (mise). Les fichiers que l\'agent modifie couramment, comme un `Makefile` ou un `package.json`, ne le sont pas : ajoute-les dans `~/.agent-vm/guarded`, un chemin par ligne, lu au démarrage d\'une VM. `!chemin` retire un fichier par défaut.',
            ],
            list: [],
            code: '# ~/.agent-vm/guarded\nMakefile               # demander avant que la VM change un Makefile\n.github/workflows/ci.yml\n!.vscode/settings.json # plus demandé',
          },
          {
            title: 'Garder ton dépôt hors d\'atteinte',
            paras: [
              'Ne donne pas à agent-vm le dépôt dans lequel tu travailles. Clone le projet une seconde fois, lance agent-vm dans ce clone, et rapatrie son travail avec `git fetch` une fois le diff relu. `git fetch` n\'extrait aucun fichier : ceux de l\'agent n\'arrivent dans ton arborescence qu\'à la fusion. Cela suppose que le `.git` du clone reste en lecture seule pour la VM, ce qui est le cas sauf avec `--unsafe-writable-git` : sinon, la VM peut l\'écrire, et git le lit ensuite.',
            ],
            list: [],
            code: '# une fois ; --no-local copie, sans liens en dur\ngit clone --no-local ~/work/app ~/agent/app\n# l\'agent travaille là\ncd ~/agent/app && agent-vm claude\n# de retour dans ton dépôt, une fois qu\'il a fini\ncd ~/work/app\ngit fetch ~/agent/app HEAD:agent/review\ngit diff ...agent/review   # relis tout\ngit merge agent/review',
          },
          {
            title: 'Éditeurs et agents',
            paras: [
              'Un fichier suivi modifié apparaît dans `git diff`, un nouveau comme non suivi ; un fichier dans un chemin ignoré (`node_modules`, `.venv`, `target/`) n\'apparaît nulle part.',
            ],
            list: [
              'VS Code : ouvre les projets agent-vm en mode restreint, et n\'approuve pas un dossier parent. Un espace de travail approuvé exécute du code du projet par ses tâches et extensions : `eslint.config.js`, `vite.config.ts`, `build.rs`.',
              'IDE JetBrains : « Preview in Safe Mode ». Un projet approuvé lance ses scripts Gradle ou Maven à l\'import.',
              'Vim : laisse `exrc` désactivé. Neovim et Emacs demandent avant d\'exécuter la config d\'un projet.',
              'Les agents sur ta machine lancent des commandes depuis les hooks de `.claude/settings.json`, `.mcp.json` ou `.cursor/` : relis-les, et considère `CLAUDE.md` et `AGENTS.md` comme écrits par la VM.',
            ],
            code: '',
          },
          {
            title: 'SSH depuis ta machine',
            paras: [
              'Ne branche pas VS Code Remote-SSH ou open-remote-ssh sur une VM d\'agent. Ils font tourner un serveur dans la VM, que contrôle root dans la VM, et l\'éditeur sur ta machine lui fait confiance. La page de Remote-SSH chez Microsoft le dit : « a compromised remote could use the VS Code Remote connection to execute code on your local machine », et c\'est voulu. Des articles publics le montrent ouvrant un terminal sur l\'hôte et y lançant des commandes. Cela supprime la frontière que pose agent-vm, ce qui est pire qu\'ouvrir le projet en mode restreint. JetBrains Gateway ne se dit pas plus sûr : sa page sur le modèle de sécurité dit que ce que charge le backend arrive sur ta machine sans rien demander, que le backend y ouvre des liens (après confirmation) et décide de la version du client qu\'elle télécharge. Pour les serveurs de langage et un débogueur avec les paquets de la VM, utilise [`agent-vm code`](#edit-with-the-vm-s-tools).',
              'Pour des scripts, `scp` ou `rsync`, `agent-vm info` affiche l\'alias SSH comme `ssh_host`. Mets ces lignes en haut de `~/.ssh/config` : un `ForwardAgent yes` trouvé avant elles donnerait tes clés SSH à la VM. `lima-*` couvre aussi les VM de ton propre Lima, si tu en as un. `--ssh-port` fixe le port pour les outils qui l\'enregistrent.',
            ],
            list: [],
            code: '# en haut de ~/.ssh/config\nInclude ~/.agent-vm/lima/*/ssh.config\nHost lima-*\n  ForwardAgent no\n  ForwardX11 no\n\nagent-vm info | grep ^ssh_host   # l\'alias à utiliser\nagent-vm --ssh-port 2222 shell   # un port fixe',
          },
          {
            title: 'Shell, commandes, hooks',
            paras: [],
            list: [
              'direnv ne charge qu\'un `.envrc` que tu as autorisé, et une modification retire l\'autorisation ; agent-vm demande aussi avant que la VM en écrive un ([Fichiers surveillés](#guarded-files)).',
              'mise fait confiance à une config selon son chemin : une VM autorisée à modifier un `mise.toml` approuvé fait lancer ses hooks à ton shell, et définir son environnement, au `cd` suivant, variables `AGENT_VM_UNSAFE_*` d\'agent-vm comprises. agent-vm demande avant cette écriture ; `mise settings set paranoid true` lie aussi la confiance au contenu. Une config sous un autre nom (`mise.local.toml`, `.mise/config.toml`) n\'est surveillée qu\'une fois que tu l\'ajoutes.',
              '`npm run`, `make`, `./gradlew`, `pytest`, `node_modules/.bin`, un `.venv` activé : chacun lance des fichiers que l\'agent peut écrire. Lance-les dans la VM.',
              '`docker compose up` sur ta machine peut monter n\'importe lequel de tes dossiers dans un conteneur root. Docker tourne dans la VM : sers-t\'en là.',
              'lefthook et pre-commit gardent leurs commandes dans l\'arborescence : agent-vm demande avant que la VM change leur config, mais pas les scripts qu\'elle nomme. Les hooks de husky appellent des scripts du projet. Relis-les dans le diff, ou commite avec `--no-verify`.',
            ],
            code: '',
          },
          {
            title: 'Gestionnaires de fichiers',
            paras: [],
            list: [
              'macOS : les fichiers écrits à travers le partage ne portent pas l\'attribut de quarantaine, donc Gatekeeper ne vérifie pas un `.app`, `.command` ou `.pkg` laissé là. Ne les ouvre pas depuis le Finder.',
              'Windows : l\'Explorateur contacte le serveur nommé dans un `.library-ms`, `.url`, `.lnk` ou `desktop.ini` qu\'il affiche, et lui envoie ton empreinte NTLM ([CVE-2025-24054](https://research.checkpoint.com/2025/cve-2025-24054-ntlm-exploit-in-the-wild/)). Garde Windows à jour et le SMB sortant bloqué.',
              'Linux : Dolphin, sous KDE, lançait des commandes depuis un `.desktop` d\'un dossier qu\'il ne faisait qu\'afficher (CVE-2019-14744, corrigée dans KDE Frameworks 5.61).',
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
              'Presse-papiers : OSC 52 permet à un programme d\'écrire dans ton presse-papiers, et, dans certains terminaux, de le lire. N\'autorise jamais la lecture, et regarde ce que tu colles dans un shell de l\'hôte.',
              'Réponses tapées à ta place : une séquence envoyée juste avant la sortie peut faire taper le terminal dans ton shell. Certaines ont été de vrais bugs (iTerm2 [CVE-2024-38396](https://www.sentinelone.com/vulnerability-database/cve-2024-38396/)) : garde ton terminal à jour.',
              'Fonctions qui agissent sur ta machine : transfert de fichiers et triggers d\'iTerm2, contrôle à distance de kitty (laisse-le désactivé), liens dont le texte diffère de la cible.',
              'Usurpation : la VM peut afficher un faux prompt de l\'hôte après une fausse sortie. Vérifie où tu es avant de taper un secret.',
            ],
            code: '',
          },
          {
            title: 'Réseau et ports',
            paras: [
              'Une VM atteint Internet, pas ta machine : sa boucle locale (où sont redirigés les ports des autres VM), ses propres adresses et tes réseaux locaux (plages privées, link-local et CGNAT) sont refusés, sur ta machine, par la pile réseau qu\'agent-vm fait tourner pour chaque VM. Root dans la VM ne peut pas le lever.',
              'Il n\'y a pas de `~/.agent-vm/network` par défaut, et il n\'en faut pas : sans lui, les VM atteignent tout Internet et rien de ta machine ni de tes réseaux locaux. Écris-en un pour ouvrir des passages, lu au démarrage d\'une VM, une ligne chacun : `allow` une adresse (`192.168.1.20`), une adresse et un port (`192.168.1.20:5432`, `[fd00::5]:80`), un réseau (`10.8.0.0/16`), ou un service de la boucle locale de ta machine, `localhost:PORT` (`localhost` seul ouvre tous les ports), que la VM atteint à `192.168.5.2`. Une ligne `allow` vaut pour TCP et UDP.',
              'Les lignes `domain` restreignent Internet lui-même : ces domaines et leurs sous-domaines (`domain github.com` couvre `api.github.com` ; `*.github.com` revient au même) deviennent les seuls noms que les VM résolvent, et une adresse n\'est joignable qu\'une fois donnée par le DNS d\'agent-vm pour l\'un d\'eux. Les lignes `allow` s\'appliquent toujours. Une ligne illisible arrête le démarrage, en la nommant ; `doctor` vérifie le fichier. `AGENT_VM_UNSAFE_OPEN_NETWORK=1` dans ton shell désactive l\'isolation.',
              'Chaque port qu\'écoute une VM est redirigé vers ton `127.0.0.1`, et une notification le signale. Un port sur lequel écoute un de tes programmes lui est laissé, avec une notification aussi : sous macOS, une VM qui écouterait la première sur 5432 recevrait sinon les connexions, et les mots de passe, destinés à ton Postgres local. Sur un port libre, ce que tu y envoies va à la VM : regarde la notification.',
              'Aucune VM n\'atteint plus l\'éditeur d\'une autre, mais `agent-vm code` donne toujours à chacune son propre mot de passe, créé dans cette VM, et son propre nom d\'hôte, `<nom-de-vm>.localhost`. Une VM peut servir une page sur un port redirigé et envoyer ton navigateur au nom d\'hôte d\'une autre VM sur ce port ; les navigateurs rangent les cookies par nom d\'hôte et non par port, donc le navigateur lui remet le cookie de cet éditeur. La VM ne peut pas s\'en servir contre l\'éditeur lui-même, puisque ta boucle locale lui est refusée, mais arrête `agent-vm code` (Ctrl-C) quand tu ne t\'en sers pas. Chrome et Firefox résolvent `*.localhost` eux-mêmes ; Safari peut ne pas le faire, et `127.0.0.1` dans une fenêtre privée réservée à l\'éditeur fait alors la même chose.',
            ],
            list: [],
            code: '# ~/.agent-vm/network\nallow localhost:11434       # Ollama sur cette machine, à 192.168.5.2:11434\nallow 192.168.1.20:5432     # une base de données du réseau local\nallow 10.8.0.0/16           # un VPN\n\n# seulement ceux-là sur Internet, sous-domaines compris\ndomain github.com\ndomain npmjs.org',
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
        body: 'agent-vm crée une VM Debian 13 avec le Lima qu\'il intègre. `agent-vm.setup.sh` y installe les outils de dev, Docker, Chromium et les agents, puis la VM est arrêtée et conservée comme image de base.',
      },
      {
        n: '02',
        title: 'Le premier lancement la clone',
        body: 'Lancer un agent dans un dossier clone l\'image en une VM persistante rattachée à ce chemin, y monte le répertoire de travail et exécute les [scripts de runtime](#customisation-files) : celui de l\'utilisateur d\'abord, celui du projet ensuite.',
      },
      {
        n: '03',
        title: 'L\'agent travaille sans surveillance',
        body: 'Il est lancé avec son option d\'approbation automatique. Il atteint Internet, pas ta machine. Les ports qu\'il ouvre dans la VM sont redirigés vers la tienne : un serveur de dev reste joignable depuis ton navigateur, comme d\'habitude.',
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
      hostNote: 'Seul agent-vm est installé',
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
      'Chaque VM s\'authentifie de son côté : le `claude login` se fait dedans. Les identifiants survivent aux redémarrages de cette VM et ne sont partagés ni avec l\'hôte ni avec les autres VM. Chaque VM a aussi sa propre pile réseau, qui atteint Internet et pas ta machine : voir [Réseau et ports](#network-and-ports).',
    contentsTitle: 'Ce qu\'il y a dans la VM',
    contentsLede:
      'L\'assistant de setup propose la sélection par défaut : tout ce qui suit, sauf les lignes marquées non. Réponds `n` pour choisir élément par élément. `--preinstall` prend les noms à la place, séparés par des virgules, plus `default`, `all` ou `none`, et saute l\'assistant, comme un setup sans terminal.',
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
      ['Éditeur', 'code-server (VS Code dans le navigateur, pour `agent-vm code`), thème sombre, GitHub Copilot désactivé, sans télémétrie', 'code-server', 'non'],
      ['Éditeur', 'L\'extension Claude Code, Codex ou Mistral Vibe, chacune démarrant sans demande de permission, avec code-server', 'code-claude, code-codex, code-vibe', 'non'],
    ],
    contentsCode:
      'agent-vm setup --preinstall=default                  # sans question\nagent-vm setup --preinstall=default,rust             # avec Rust en plus\nagent-vm setup --preinstall=python,docker,claude     # Claude seul, minimal\nagent-vm setup --preinstall=default,code-claude      # avec l\'éditeur\nagent-vm setup --disk 50 --memory 16 --cpus 8        # une image plus grosse',
    contentsNote:
      '`codex` et `pi` entraînent `node`, tout comme `mcp-chrome` avec `chromium` et un agent. Les deux serveurs MCP sont ignorés sans `node` et `chromium`. Chaque extension de l\'éditeur apporte sa propre copie de son agent (200 à 600 Mo) : l\'assistant demande s\'il faut garder aussi celle en ligne de commande. Sans elle, `agent-vm claude` dit qu\'il n\'est pas installé. Ce n\'est que ce que l\'image contient au départ : l\'agent est root dans la VM et atteint Internet, il installe lui-même ce qui lui manque.',
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
      ['Réseau sortant', 'Ouvert', 'Ouvert par défaut', 'Internet, pas ta machine ni ton réseau local ([Réseau et ports](#network-and-ports))'],
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
      'Docker tourne nativement dans la VM, sans Docker-in-Docker, et Chromium headless fonctionne d\'emblée. Sur un Mac, ça remplace Docker Desktop.',
  },

  roadmap: {
    title: 'Ce qui manque.',
    items: [
      {
        status: 'Construit, pas encore essayé',
        title: 'Windows, nativement',
        body: 'agent-vm tourne désormais sous Windows sans Git Bash, ses chemins pris en `C:/...` et vus par la VM en `/c/...`, comme avec la 0.2, et ses tests tournent sur tous les systèmes. Rien n\'a encore tourné sur une machine Windows : le setup, les partages, l\'isolation réseau, la vérification des ports. On cherche quelqu\'un pour l\'essayer, en x86_64 ou arm64, et une fenêtre de confirmation pour les fichiers surveillés.',
      },
      {
        status: 'Idée',
        title: 'Relire ce que l\'agent écrit',
        body: 'Chaque écriture de la VM passe par le serveur SFTP d\'agent-vm. Il pourrait les garder de côté et te laisser relire le diff, puis en appliquer tout ou partie au vrai dossier. Un premier pas : la liste de chaque chemin que la VM a écrit pendant une session.',
      },
      {
        status: 'Demande un M3',
        title: 'Faire tourner une VM dans la VM',
        body: 'Une option `--allow-nested-vm`, pour tester de l\'outillage de virtualisation depuis la VM. Lima gère la virtualisation imbriquée, mais elle est désactivée par défaut et ne peut pas être activée sans condition : sur une puce antérieure à l\'Apple M3, Lima échoue purement et simplement à démarrer la VM, et plus aucune VM ne démarrerait. L\'option devrait donc d\'abord vérifier ce que l\'hôte sait faire. Personne ici n\'a de M3 pour la tester. Elle donnerait aussi à l\'agent un accès à une interface d\'hyperviseur.',
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
      'agent-vm est un programme Go qui intègre Lima, compilé depuis ses sources amont avec de petits correctifs, et une suite de tests qui ne crée aucune VM et n\'a pas besoin du réseau. Rapports de bugs, corrections, prise en charge de nouveaux agents : tout est bienvenu.',
    testsTitle: 'Lancer les tests',
    testsBody:
      'Deux suites. Aucune ne touche à tes VM, à ton `~/.agent-vm` ni à ta config git.',
    testsList: [
      '`make test-go` tourne avec un faux gestionnaire de VM dans des dossiers jetables : aucune VM, aucun réseau. Là où la version bash de la 0.2 sert de comparaison, ses résultats ont été enregistrés dans `testdata/bashref`.',
      'Les tests de bout en bout démarrent de vraies VM dans leur propre dossier Lima : la suite des VM vérifie ce qu\'un faux ne peut pas (root dans l\'invité ne peut écrire ni dans `.git` ni dans un fichier surveillé, ni atteindre la boucle locale de cette machine) ; celle de la CLI lance `setup` puis une commande dans un projet.',
      '`make fuzz` lance chaque fuzzer, `FUZZTIME` chacun : la comparaison des noms du serveur SFTP et les requêtes d\'un client hostile, l\'analyse git, les lecteurs d\'env et de volumes, les chemins et les noms.',
    ],
    testsCode: 'make test-go                                       # rapide, sans VM\ngo test -tags e2e ./internal/vm/ ./internal/cli/   # vraies VM\nmake fuzz FUZZTIME=5m',
    shellsTitle: 'Corriger Lima, son serveur SFTP et son réseau',
    shellsBody:
      '`third_party/` contient Lima, sshocker, pkg/sftp et gvisor-tap-vsock : chacun est le commit amont de `third_party/SOURCES` plus les correctifs de `patches/`, chacun assez petit pour être proposé en amont. Ne modifie jamais `third_party/` à la main : change un correctif, puis reconstruis-le. La CI vérifie qu\'il n\'y a rien d\'autre.',
    shellsCode: 'scripts/third-party-sync sshocker   # reconstruit depuis SOURCES et les correctifs\nmake check-third-party              # ce que vérifie la CI\nmake test-third-party               # leurs propres tests, corrigés',
    structureTitle: 'Où se trouve quoi',
    structureHeaders: ['Fichier', 'Ce que c\'est'],
    structure: [
      ['cmd/agent-vm/', 'Le point d\'entrée de la commande.'],
      ['internal/cli/', 'Les commandes, le démarrage et ses vérifications, setup, doctor.'],
      ['internal/vm/', 'Les VM, via le Lima intégré.'],
      ['internal/limaembed/', 'L\'agent hôte de Lima, lancé comme `agent-vm hostagent`, et les fichiers dont il a besoin.'],
      ['internal/mounts/, internal/gitguard/', 'Les partages, et la protection de .git.'],
      ['internal/netguard/, internal/guard/', 'L\'isolation réseau, et les fichiers surveillés.'],
      ['third_party/, patches/', 'Lima, son serveur SFTP et sa pile réseau, en amont plus les correctifs.'],
      ['agent-vm.setup.sh', 'Installation des paquets, exécutée dans la VM de base pendant le setup.'],
      ['agent-vm.sh', 'Lance agent-vm : le binaire à côté de lui dans une version publiée, celui que construit make dans un clone. Les liens et lignes de fichier rc laissés par la 0.2 mènent ici.'],
      ['runtime.example.sh', 'Modèle commenté pour ~/.agent-vm/runtime.sh.'],
      ['CHANGELOG.md', 'Ce qui change à chaque version.'],
      ['release.sh', 'Vérifie, tague et publie une version, une archive par plateforme. --dry-run d\'abord.'],
      ['www/', 'Ce site. Astro, statique, déployé sur GitHub Pages.'],
      ['www/public/install.sh', 'L\'installeur curl, servi à /install.sh.'],
    ],
    guidelinesTitle: 'Avant d\'ouvrir une PR',
    guidelines: [
      'Tout le code doit pouvoir être relancé : vérifie l\'état avant d\'agir plutôt que de supposer une machine vierge.',
      'Tout nouveau comportement a son test, vérifié en échec sans le changement. Le faux gestionnaire (`vmtest.Fake`) rend ça peu coûteux.',
      'Un changement de Lima, sshocker, pkg/sftp ou gvisor-tap-vsock est un correctif dans `patches/`, assez petit pour être proposé en amont.',
      'Les commandes destinées aux intégrateurs (`info`, `env`, `version`) sont des contrats. Ajouter des clés, oui ; en changer le sens, non.',
      'Aucun secret, jeton ou chemin personnel dans un commit, une fixture de test ou une issue.',
    ],
    issuesLabel: 'Ouvrir une issue',
    issuesHref: 'https://github.com/sylvinus/agent-vm/issues',
    prLabel: 'Parcourir les pull requests',
    prHref: 'https://github.com/sylvinus/agent-vm/pulls',
    repoLabel: 'Lire le code',
    repoHref: 'https://github.com/sylvinus/agent-vm',
    chatLabel: 'Discuter sur Matrix',
    chatHref: 'https://matrix.to/#/#agent-vm:matrix.org',
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
          { name: 'Lima', note: 'Des VM Linux sur macOS et Linux, intégré à agent-vm.', href: 'https://lima-vm.io/' },
          { name: 'sshocker et pkg/sftp', note: 'Le serveur SFTP qui sert les partages et garde .git en lecture seule.', href: 'https://github.com/lima-vm/sshocker' },
          { name: 'gvisor-tap-vsock', note: 'La pile réseau de chaque VM, où s\'applique l\'isolation.', href: 'https://github.com/containers/gvisor-tap-vsock' },
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
          { name: 'Pi', note: 'Harnais open source minimaliste.', href: 'https://pi.dev' },
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
            note: 'Pointé sur le même Chromium.',
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
