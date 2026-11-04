# Octopus — déploiement d'une application de vote multi-tier avec Ansible

Ce dépôt contient le code Ansible qui déploie, **sans aucun conteneur**, une
application de vote répartie sur 5 machines Debian 13 :

```
                 ┌──────────┐        ┌────────┐        ┌────────────┐
  navigateur ──▶ │  poll    │ ─────▶ │ redis  │ ─────▶ │   worker   │
   (vote)        │ (Flask)  │        │(file de│        │   (Java)   │
                 │ port 80  │        │ votes) │        └─────┬──────┘
                 └──────────┘        └────────┘              │
                                                              ▼
                 ┌──────────┐                          ┌────────────┐
  navigateur ──▶ │  result  │ ◀────────────────────────│ postgresql │
   (résultats)   │ (Node.js)│         lecture          │  (table    │
                 │ port 80  │                          │   votes)   │
                 └──────────┘                          └────────────┘
```

| Rôle Ansible | Hôte (groupe inventaire) | Rôle dans l'application |
|---|---|---|
| `base`       | tous           | paquets de base (vim, curl, acl…) communs à toutes les machines |
| `redis`      | `redis-1`      | file d'attente des votes |
| `postgresql` | `postgresql-1` | base de données (table `votes`, utilisateur `paul`) |
| `poll`       | `poll-1`       | site web de vote (Flask + gunicorn, port 80) |
| `worker`     | `worker-1`     | consommateur Java : lit Redis, écrit en base |
| `result`     | `result-1`     | site web de résultats en direct (Node.js, port 80) |

Toutes les applications sont packagées telles quelles (`poll.tar`, `worker.tar`,
`result.tar` — **utilisées sans aucune modification**, comme demandé par le
sujet) et tournent en tant que **services systemd** (`enabled` + `started`,
donc démarrage automatique au boot, redémarrage automatique en cas de crash).
La configuration applicative suit le **12-factor** : chaque service lit ses
paramètres depuis un fichier d'environnement dédié (`/etc/<service>.env`,
généré par un template Jinja2) référencé par `EnvironmentFile=` dans son unit
systemd.

## Structure du dépôt

```
.
├── playbook.yml            # 6 plays : base, redis, postgresql, poll, worker, result
├── ansible.cfg             # inventaire par défaut = "production", roles_path, etc.
├── requirements.yml        # collections Galaxy nécessaires (namespace community.*)
├── group_vars/all.yml      # variables partagées + secret postgres (chiffré au vault)
├── production.example      # modèle d'inventaire (à copier en "production")
├── production              # inventaire réel — LOCAL, jamais versionné (.gitignore)
├── poll.tar / worker.tar / result.tar   # archives des applications, fournies telles quelles
├── setup-incus.sh          # script optionnel : provisionne 5 conteneurs Incus pour tester en local
└── roles/
    ├── base/tasks/
    ├── redis/{tasks,handlers,files}/
    ├── postgresql/{tasks,handlers,files}/      # listen.conf, pg_hba.conf, schema.sql
    ├── poll/{tasks,handlers,files,templates}/  # poll.service, poll.env.j2
    ├── worker/{tasks,handlers,files,templates}/
    └── result/{tasks,handlers,files,templates}/
```

## Pré-requis sur la machine de contrôle

- Python 3 + un environnement virtuel
- `ansible` (le projet a été testé avec ansible-core fourni par le paquet `ansible`)
- Les collections **community** listées dans `requirements.yml` (seul
  namespace Galaxy autorisé par le sujet — aucune collection tierce, aucun rôle
  Galaxy)
- Une paire de clés SSH (le projet utilise `~/.ssh/id_ed25519` /
  `id_ed25519.pub`, comme déclaré dans `production.example`)

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install ansible
ansible-galaxy collection install -r requirements.yml
```

## 1. Préparer les 5 machines cibles

Le sujet demande 5 machines Debian 13 dédiées à un seul rôle chacune
(`redis-1`, `postgresql-1`, `poll-1`, `worker-1`, `result-1`), accessibles en
SSH par clé avec un utilisateur `debian` qui peut `sudo` sans mot de passe (le
playbook s'exécute entièrement avec `become: true`).

### Option A — machines réelles / VM cloud

Sur chaque machine Debian 13 fraîchement installée :

1. Installer `openssh-server`, `sudo` et `python3` (Ansible a besoin d'un
   interpréteur Python sur la cible).
2. Créer l'utilisateur `debian`, l'ajouter au groupe `sudo` et autoriser le
   `sudo` sans mot de passe (`/etc/sudoers.d/debian` :
   `debian ALL=(ALL) NOPASSWD:ALL`, mode `440`).
3. Déposer la clé publique SSH dans `~/debian/.ssh/authorized_keys`
   (répertoire `.ssh` en `0700`, fichier en `0600`, appartenant à `debian`).
4. Démarrer et activer SSH : `systemctl enable --now ssh`.

### Option B — banc de test local avec Incus/LXD (utilisé pour valider ce dépôt)

Le script `setup-incus.sh` crée 5 conteneurs Debian 13
(`redis-1`, `postgresql-1`, `poll-1`, `result-1`, `worker-1`) à partir de
l'image `images:debian/13` et tente de les configurer via cloud-init.

> **Constat important pendant les tests** : sur la version d'Incus utilisée,
> le `user-data` cloud-init n'est **pas appliqué** par les conteneurs créés
> (`cloud-init status` reste `disabled`/inactif, l'utilisateur `debian` n'est
> jamais créé, SSH ne démarre jamais → `ansible -m ping` échoue avec
> *"Connection refused on port 22"*). Le bootstrap a donc dû être fait
> **manuellement**, conteneur par conteneur, via `incus exec <conteneur> -- ...` :
>
> ```bash
> # à répéter pour chacun des 5 conteneurs
> incus exec <conteneur> -- apt-get update
> incus exec <conteneur> -- apt-get install -y openssh-server sudo python3
> incus exec <conteneur> -- useradd -m -s /bin/bash debian
> incus exec <conteneur> -- bash -c \
>   'echo "debian ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/debian && chmod 440 /etc/sudoers.d/debian'
> incus exec <conteneur> -- mkdir -p /home/debian/.ssh
> incus file push ~/.ssh/id_ed25519.pub <conteneur>/home/debian/.ssh/authorized_keys
> incus exec <conteneur> -- bash -c \
>   'chown -R debian:debian /home/debian/.ssh && chmod 700 /home/debian/.ssh && chmod 600 /home/debian/.ssh/authorized_keys'
> incus exec <conteneur> -- systemctl enable --now ssh
> ```
>
> Ce détour ne change rien au playbook lui-même : une fois SSH/`debian`/`sudo`
> en place, les machines sont indiscernables de vraies VM Debian 13 du point
> de vue d'Ansible. **Aucun conteneur ne fait partie du déploiement** — Incus
> sert uniquement de banc d'essai local, ce qui respecte l'interdiction du
> sujet sur Docker/Podman/conteneurisation dans le déploiement lui-même.

## 2. Configurer l'inventaire

Copier le modèle et y mettre les adresses réelles des 5 machines :

```bash
cp production.example production
$EDITOR production
```

`production` reste **strictement local** : il est listé dans `.gitignore` et
ne doit jamais être commité (il contient les IP réelles de l'infrastructure).

## 3. Préparer le vault Ansible

Le mot de passe de l'utilisateur de base de données `paul` est stocké chiffré
dans `group_vars/all.yml` (`postgres_password: !vault | ...`) — **aucun mot de
passe n'apparaît en clair dans le dépôt**. Pour lancer le playbook, Ansible a
besoin du mot de passe du vault (fourni dans le sujet du projet) :

```bash
echo "<mot de passe du vault fourni dans le sujet>" > /tmp/.vault_pass
chmod 600 /tmp/.vault_pass
export ANSIBLE_VAULT_PASSWORD_FILE=/tmp/.vault_pass
```

Pour vérifier que le secret se déchiffre correctement :

```bash
ansible-vault view group_vars/all.yml
```

## 4. Vérifications avant déploiement (optionnel mais recommandé)

```bash
# Connectivité SSH vers les 5 machines
ansible -i production all -m ping

# Syntaxe du playbook
ansible-playbook playbook.yml --syntax-check -i production

# Lint (style et bonnes pratiques Ansible)
ansible-lint
```

## 5. Lancer le déploiement

```bash
ansible-playbook -i production playbook.yml
```

Le playbook exécute, dans l'ordre, 6 plays : `base` (sur toutes les machines),
puis `redis`, `postgresql`, `poll`, `worker`, `result` — chacun ciblant
uniquement le groupe d'inventaire correspondant.

> **Point d'attention — suite PGDG** : le rôle `postgresql` ajoute le dépôt
> APT officiel PostgreSQL (PGDG) avec, par défaut,
> `postgresql_pgdg_suite: "{{ ansible_distribution_release }}-pgdg"`
> (donc `trixie-pgdg` sur Debian 13). Si PGDG n'a pas encore publié de suite
> pour `trixie` au moment du déploiement, l'installation du paquet
> `postgresql-16` échoue avec une erreur de dépôt introuvable. Dans ce cas,
> forcer la suite précédente dans `group_vars/all.yml` :
> ```yaml
> postgresql_pgdg_suite: "bookworm-pgdg"
> ```

À la fin de l'exécution, le récapitulatif (`PLAY RECAP`) doit afficher
`failed=0 unreachable=0` pour les 5 hôtes.

## 6. Vérifier l'idempotence

Le sujet exige qu'une seconde exécution ne change plus rien sur des machines
déjà déployées. Relancer simplement le playbook :

```bash
ansible-playbook -i production playbook.yml
```

Le `PLAY RECAP` final doit afficher **`changed=0`** pour les 5 hôtes.

## 7. Tester le flux de bout en bout

```bash
# Voter (poll-1, port 80) — remplacer par l'IP réelle de poll-1
curl http://<IP de poll-1>/

# Consulter les résultats en direct (result-1, port 80)
curl http://<IP de result-1>/

# Vérifier que le vote est bien arrivé en base (sur postgresql-1)
ansible postgresql -i production -b -m ansible.builtin.command \
  -a 'sudo -u postgres psql -d paul -c "SELECT * FROM votes;"'
```

Le flux complet est : navigateur → `poll` (Flask, écrit dans Redis) → `worker`
(Java, lit Redis et écrit en PostgreSQL) → `result` (Node.js, lit PostgreSQL
et affiche les résultats). Une ligne apparaît dans la table `votes` après
chaque vote, et la page de résultats se met à jour en conséquence.

## Sécurité et gestion des secrets

- **Aucun mot de passe en clair** n'est présent dans le dépôt : le seul secret
  applicatif (mot de passe de l'utilisateur PostgreSQL `paul`) est chiffré
  avec `ansible-vault` dans `group_vars/all.yml` et n'est déchiffré qu'en
  mémoire, au moment de l'exécution, via `ANSIBLE_VAULT_PASSWORD_FILE`.
- Les fichiers d'environnement contenant ce secret en clair sur les machines
  cibles (`/etc/worker.env`, `/etc/result.env`) sont déployés en mode `0600`
  (lecture/écriture root uniquement).
- L'inventaire `production` (qui contient les adresses IP réelles de
  l'infrastructure) est local et ignoré par Git (`.gitignore`).
- Aucune collection Galaxy en dehors du namespace **community** n'est
  utilisée (`community.general`, `community.postgresql`), conformément à
  l'autorisation du sujet.

## Dépannage — problèmes réellement rencontrés pendant les tests

Cette section documente les vrais blocages rencontrés en testant ce dépôt sur
un banc de 5 conteneurs Incus (Debian 13), et la façon dont ils ont été
résolus — pour gagner du temps si vous les rencontrez aussi.

### `ansible -m ping` → "Connection refused on port 22"

**Cause** : sur les conteneurs de test, cloud-init n'exécute pas le
`user-data` (SSH n'est jamais activé, l'utilisateur `debian` n'existe pas).
**Solution** : configurer SSH/l'utilisateur/le sudo manuellement (voir
[Option B](#option-b--banc-de-test-local-avec-incuslxd-utilisé-pour-valider-ce-dépôt)
ci-dessus).

### Le rôle `postgresql` échoue : *"python3-debian is not installed, and install_python_debian is False"*

**Cause** : le module `deb822_repository` (utilisé pour ajouter le dépôt PGDG)
nécessite la bibliothèque Python `python3-debian` côté cible ; sur les
versions récentes d'ansible-core, l'option `install_python_debian` qui
l'installait automatiquement est désactivée par défaut.
**Solution** : `python3-debian` a été ajouté à la liste de paquets installés
en pré-requis dans `roles/postgresql/tasks/main.yml`, à côté de
`python3-psycopg2` (déjà nécessaire aux modules `community.postgresql.*`).

### Le rôle `poll` échoue : *"Failed to import the required Python library (packaging) on poll-1's Python ..."*

**Cause** : le module `ansible.builtin.pip` a besoin de la bibliothèque
`packaging` côté cible pour comparer des versions de paquets.
**Solution** : `python3-packaging` a été ajouté à la tâche d'installation des
outils Python (`roles/poll/tasks/main.yml`), aux côtés de `python3` et
`python3-venv`.

### Idempotence non respectée : `changed=1` sur "Create the application directory" pour `worker`/`result` au second run

**Cause** : les archives `poll.tar`/`worker.tar`/`result.tar` (utilisées
telles quelles, sans modification, comme l'exige le sujet) contiennent une
entrée de répertoire racine avec le mode `0775`. Lorsque la tâche `file`
positionnant le mode `0755` s'exécutait *avant* `unarchive`, l'extraction
réécrasait ensuite le mode du répertoire avec celui de l'archive (`0775`),
ce qui rendait l'exécution suivante non idempotente (le module `file`
détectait alors une différence et la corrigeait — d'où `changed=1`).
**Solution** : inverser l'ordre des deux tâches dans les rôles `poll`,
`worker` et `result` — `unarchive` (gardée par `creates:` pour ne s'exécuter
qu'une fois) **puis** `file` pour fixer définitivement le mode `0755`. Ainsi
l'état déclaré l'emporte toujours, quel que soit le mode contenu dans
l'archive. Validé par 3 exécutions consécutives du playbook complet :
`changed=0` sur les 5 hôtes dès la deuxième exécution.

### Une commande groupée (`ansible-lint` + syntax-check + grep) lancée en arrière-plan reste bloquée

**Cause probable** : enchaînement de plusieurs commandes (`source` +
export + outils) dans un script de fond — l'activation du venv ou un des
outils ne rendait pas la main proprement.
**Solution** : exécuter chaque vérification séparément, au premier plan
(`ansible-lint`, puis `--syntax-check`, puis le grep), comme détaillé à
l'étape [4](#4-vérifications-avant-déploiement-optionnel-mais-recommandé).
