---
source-path: apb-base
---

I now have a complete picture of the `apb-base` module. Let me write the comprehensive migration plan.

---

# Migration Plan: apb-base

**TLDR**: `apb-base` is a legacy **Ansible Playbook Bundle (APB) container base image** project — not a traditional Ansible role. It packages a set of shell scripts and Ansible configuration files into a CentOS 7 Docker image that acts as the runtime foundation for APBs (OpenShift Service Broker automation units). The project has no Ansible task files, handlers, variables, or templates; its entire content is static files (shell scripts + `ansible.cfg` + `hosts`) deployed into a container image via `Dockerfile` `COPY` instructions and an RPM spec file. Modernization requires migrating from the deprecated APB/OpenShift Service Broker ecosystem to **Ansible Automation Platform (AAP) / Execution Environments (EEs)**, replacing the CentOS 7 base with a supported UBI image, replacing `origin-clients`/`oc` with `kubectl`/`oc` from a supported source, replacing Python 2 dependencies with Python 3, and converting the shell-script-driven container entrypoint pattern into a proper EE-compatible structure.

---

## Service Type and Configuration

**Service Type**: Container Base Image / Ansible Execution Environment Bootstrap (APB Runtime)

**Key Operations**:
- Provides a CentOS 7 container image that serves as the base for all Ansible Playbook Bundles
- Installs Ansible, OpenShift origin clients (`oc`), `python-openshift`, `ansible-kubernetes-modules`, and `ansible-asb-modules` via `yum`
- Deploys a static `ansible.cfg` configuring `roles_path = /etc/ansible/roles:/opt/ansible/roles`
- Deploys a static `hosts` file with `localhost ansible_connection=local`
- Deploys six shell scripts to `/usr/bin/` that form the APB runtime lifecycle:
  - **`entrypoint.sh`** — Container entrypoint; handles S2I detection, dynamic `/etc/passwd` entry, `oc login`, secret injection via `--extra-vars`, playbook dispatch by action name, bind-creds lifecycle, and test-result lifecycle
  - **`oc-login.sh`** — Authenticates to OpenShift using either a token env var or the in-cluster service account
  - **`bind-init`** — Keeps the container alive (polling loop, 5-minute timeout) until the broker collects bind credentials
  - **`broker-bind-creds`** — Reads and emits bind credentials from `/var/tmp/bind-creds`; exits `2` if not available
  - **`test-retrieval-init`** — Keeps the container alive until test results are collected by the user
  - **`test-retrieval`** — Reads and emits test results from `/var/tmp/test-result`; exits `2` if not available
- Packaged as an RPM (`apb-base-scripts`) via `apb-base-scripts.spec` for installation into the image
- Three Dockerfile variants: `latest` (COPR stable), `nightly` (COPR nightly), `canary` (builds Ansible from `devel` branch source)

---

## File Structure

**IMPORTANT: All paths are relative to the role/project root (`apb-base/`).**

**Static Files (deployed into container image):**
```
files/etc/ansible/ansible.cfg
files/etc/ansible/hosts
files/usr/bin/bind-init
files/usr/bin/broker-bind-creds
files/usr/bin/entrypoint.sh
files/usr/bin/oc-login.sh
files/usr/bin/test-retrieval
files/usr/bin/test-retrieval-init
```

**Build / Packaging Files (project root — not Ansible role files):**
```
Dockerfile-latest
Dockerfile-nightly
Dockerfile-canary
Makefile
apb-base-scripts.spec
```

**Task Files:** _(none — this project has no Ansible task files)_

**Handler Files:** _(none)_

**Variable Files:** _(none)_

**Meta:** _(none — no `meta/main.yml`)_

**Templates:** _(none — no `.j2` templates)_

---

## Module Explanation

This project is **not a conventional Ansible role**. It contains no `tasks/`, `handlers/`, `defaults/`, `vars/`, `meta/`, or `templates/` directories. The "role" is the container image itself — Ansible is a *consumer* inside the image, not the tool that builds it. The migration analysis therefore focuses on the content of the static files and the container build pipeline.

### 1. `files/etc/ansible/ansible.cfg`

**Purpose**: Configures the Ansible runtime inside the container.

**Current content**:
```ini
[defaults]
roles_path = /etc/ansible/roles:/opt/ansible/roles
```

**Legacy issues**:
- No `collections_paths` directive — collections were not a concept when this was written.
- No `interpreter_python` directive — defaults to Python 2 auto-detection on CentOS 7.
- No `host_key_checking = False` (relied on `localhost` only, but not explicit).
- Missing `stdout_callback` for structured output useful in EE/AAP contexts.

**Modern equivalent**:
```ini
[defaults]
roles_path        = /etc/ansible/roles:/opt/ansible/roles
collections_paths = /usr/share/ansible/collections:/opt/ansible/collections
interpreter_python = auto_silent
host_key_checking = False
stdout_callback   = yaml
```

---

### 2. `files/etc/ansible/hosts`

**Purpose**: Static inventory declaring `localhost` with a local connection.

**Current content**:
```
localhost ansible_connection=local
```

**Legacy issues**:
- Bare inventory file with no group structure.
- No `ansible_python_interpreter` set — will default to Python 2 on CentOS 7.

**Modern equivalent**:
```ini
[local]
localhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3
```

---

### 3. `files/usr/bin/entrypoint.sh`

**Purpose**: Container entrypoint — the central orchestration script for APB lifecycle.

**Legacy issues and modernization needs**:

| Issue | Location in script | Modern Equivalent |
|---|---|---|
| `set -x` at top level leaks secrets to logs | Line 3 | Use `set -x` only in non-sensitive sections; already partially mitigated with `set +x` before secret handling |
| `oc-login.sh` called unconditionally | After passwd fixup | Replace with `kubectl`-based auth or AAP credential injection |
| Secret injection via `--extra-vars @/tmp/secrets` flat file | Secret loop section | Use AAP Credential Types / Vault / EE secret mounts instead |
| `ls $SECRETS_DIR` result used as a string and as a path test simultaneously | `mounted_secrets=$(ls ...)` | Separate existence check from listing; use `[[ -d "$SECRETS_DIR" ]]` |
| `[[ ! -e "$mounted_secrets" ]]` tests the *string content* of `ls` output as a path, not the directory | Logic inversion bug | Fix: `if [[ -n "$mounted_secrets" ]]` |
| `ANSIBLE_ROLES_PATH` set inline on `ansible-playbook` command | Both playbook dispatch lines | Move to `ansible.cfg` or EE image build |
| `ansible-playbook` called without `--inventory` | Both dispatch lines | Add `-i /etc/ansible/hosts` explicitly |
| Bash `for r in $(seq 1 $RETRIES)` pattern delegated to `bind-init` | (see bind-init) | See bind-init notes |
| S2I workaround comment references a 2015 GitHub issue | Comment block | Remove or update comment; s2i is deprecated |
| No `#!/usr/bin/env bash` portability shebang | Line 1 | Use `#!/usr/bin/env bash` or ensure `/bin/bash` path is correct in UBI |
| `rm -f /tmp/secrets` without checking if file was created | Cleanup section | Guard with `[[ -f /tmp/secrets ]]` |

---

### 4. `files/usr/bin/oc-login.sh`

**Purpose**: Authenticates the container to an OpenShift/Kubernetes cluster.

**Legacy issues**:

| Issue | Modern Equivalent |
|---|---|
| Uses `oc login` with `--insecure-skip-tls-verify=true` unconditionally when token is present | Use proper CA bundle; pass `--certificate-authority` when available |
| `OPENSHIFT_TARGET` / `OPENSHIFT_TOKEN` env vars are OpenShift-Service-Broker-specific conventions | Replace with standard `KUBECONFIG` injection or AAP machine credentials |
| Hardcoded fallback to `https://kubernetes.default` | Acceptable for in-cluster, but should be configurable |
| `[[ ! -z "${VAR}" ]]` anti-pattern | Use `[[ -n "${VAR}" ]]` |
| `oc` binary from `origin-clients` (CentOS 7 / OpenShift 3.x) | Use `oc` from `openshift-clients` RPM on UBI 8/9, or use `kubectl` |
| No error handling on `oc login` failure | Add `|| { echo "Login failed"; exit 1; }` |

---

### 5. `files/usr/bin/bind-init`

**Purpose**: Keeps the APB container alive while the broker collects bind credentials.

**Legacy issues**:

| Issue | Modern Equivalent |
|---|---|
| `for r in $(seq 1 $RETRIES)` — spawns a subshell for `seq` | Use `for ((r=1; r<=RETRIES; r++))` bash arithmetic loop |
| Logic is inverted: loops *while file exists*, exits when file is *gone* — comment says "waiting for broker to gather" but the broker removes the file via `broker-bind-creds` | Logic is correct but comment is misleading; clarify |
| No signal handling — container cannot be gracefully terminated during wait | Add `trap 'exit 0' SIGTERM SIGINT` |
| Hardcoded 5-minute timeout (150 × 2s) | Make `RETRIES` and `SLEEP_INTERVAL` configurable via env vars |
| APB/Service Broker pattern is deprecated | Replace with AAP workflow / EE credential output patterns |

---

### 6. `files/usr/bin/broker-bind-creds`

**Purpose**: Emits bind credentials to stdout for the broker to collect.

**Legacy issues**:

| Issue | Modern Equivalent |
|---|---|
| Reads from hardcoded `/var/tmp/bind-creds` | Make path configurable via `CREDS` env var (already done in `entrypoint.sh` but not here) |
| `rm $CREDS` after `cat` — destructive, no backup | Acceptable for ephemeral container use, but document clearly |
| Exit code `2` for "not available" — broker-specific convention | Document exit code contract; in AAP context replace with proper output artifacts |
| No error handling if `cat` fails | Add `|| exit 1` |

---

### 7. `files/usr/bin/test-retrieval`

**Purpose**: Emits test results to stdout for collection.

**Legacy issues**:

| Issue | Modern Equivalent |
|---|---|
| `rm $CREDS` inside `test-retrieval` — removes bind-creds file, not test-result file (possible copy-paste bug) | Should be `rm $TEST_RESULT` only; `rm $CREDS` here is likely a bug |
| Hardcoded `/var/tmp/test-result` path | Make configurable via env var |
| Same exit code `2` convention as `broker-bind-creds` | Document consistently |

---

### 8. `files/usr/bin/test-retrieval-init`

**Purpose**: Keeps the container alive while the user collects test results.

**Legacy issues**:

| Issue | Modern Equivalent |
|---|---|
| Typo in output: `"Waiting for the user to gather the test resutls..."` | Fix: `"results"` |
| Same `for r in $(seq ...)` anti-pattern as `bind-init` | Use bash arithmetic loop |
| Error message says `"bind-init timed out"` — copy-paste error from `bind-init` | Fix: `"test-retrieval-init timed out..."` |
| No signal handling | Add `trap 'exit 0' SIGTERM SIGINT` |

---

### 9. `Dockerfile-latest` / `Dockerfile-nightly` / `Dockerfile-canary`

**Purpose**: Build the container image.

**Legacy issues**:

| Issue | Modern Equivalent |
|---|---|
| `FROM centos:7` — CentOS 7 EOL June 2024 | `FROM registry.access.redhat.com/ubi9/ubi:latest` or `ubi8` |
| `MAINTAINER` instruction deprecated | Use `LABEL maintainer=` |
| `yum` package manager | `dnf` on UBI 8/9 |
| `python-openshift` (Python 2) | `python3-openshift` or `kubernetes` Python package |
| `ansible-kubernetes-modules` role (legacy, pre-collections) | `kubernetes.core` collection |
| `ansible-asb-modules` (Ansible Service Broker modules, archived) | Replaced by AAP / EE patterns |
| `origin-clients` / `centos-release-openshift-origin` (OpenShift 3.x) | `openshift-clients` from OpenShift 4.x mirror or UBI |
| `apb-base-scripts` RPM from COPR | Inline `COPY` of modernized scripts |
| `Dockerfile-canary` builds Ansible from `devel` git branch | Use `pip install ansible-core` with pinned version |
| `Dockerfile-canary` clones `openshift-restclient-python` | Use `pip install openshift` (Python 3) |
| `chmod -R g=u` pattern | Retain — required for OpenShift arbitrary UID support |
| No `USER` instruction | Add `USER ${USER_UID}` before `ENTRYPOINT` |
| `ENTRYPOINT ["entrypoint.sh"]` — relies on `/usr/bin` being in PATH | Use `ENTRYPOINT ["/usr/bin/entrypoint.sh"]` (absolute path) |

---

## Modernization Mapping

| Legacy Pattern | Modern Equivalent | Files Affected | Notes |
|---|---|---|---|
| `FROM centos:7` | `FROM registry.access.redhat.com/ubi9/ubi:latest` | Dockerfile-latest, Dockerfile-nightly, Dockerfile-canary | CentOS 7 EOL; UBI 9 is RHEL-based, supported |
| `MAINTAINER` Dockerfile instruction | `LABEL maintainer="..."` | All Dockerfiles | `MAINTAINER` deprecated since Docker 1.13 |
| `yum -y install` | `dnf -y install` | All Dockerfiles | `yum` is a symlink to `dnf` on UBI 8/9 but `dnf` is canonical |
| `python-openshift` (Python 2) | `python3-openshift` or `pip3 install openshift` | Dockerfile-latest, Dockerfile-nightly | Python 2 EOL January 2020 |
| `ansible-kubernetes-modules` role | `kubernetes.core` Ansible collection | Dockerfile-canary, ansible.cfg | Legacy role replaced by certified collection |
| `ansible-asb-modules` | Deprecated / no direct replacement | All Dockerfiles | APB/ASB ecosystem archived; use AAP EE patterns |
| `origin-clients` / `centos-release-openshift-origin` | `openshift-clients` (OCP 4.x) | All Dockerfiles | OpenShift 3.x packages; OCP 3 EOL |
| `apb-base-scripts` RPM (COPR) | Direct `COPY` of scripts into image | Dockerfile-latest, Dockerfile-nightly | COPR repo may be unavailable; embed scripts directly |
| `ansible_python_interpreter` (implicit Python 2) | `interpreter_python = auto_silent` in `ansible.cfg` | files/etc/ansible/ansible.cfg | Explicit Python 3 selection |
| Missing `collections_paths` in `ansible.cfg` | Add `collections_paths = /usr/share/ansible/collections:/opt/ansible/collections` | files/etc/ansible/ansible.cfg | Required for collection-based modules |
| Bare `hosts` inventory (no group, no python interpreter) | Add `[local]` group + `ansible_python_interpreter=/usr/bin/python3` | files/etc/ansible/hosts | Python 3 explicit selection |
| `[[ ! -z "${VAR}" ]]` | `[[ -n "${VAR}" ]]` | files/usr/bin/oc-login.sh | Idiomatic bash; `! -z` is double-negative |
| `oc login --insecure-skip-tls-verify=true` | Use CA bundle or AAP credential injection | files/usr/bin/oc-login.sh | TLS verification should not be skipped in production |
| `for r in $(seq 1 $RETRIES)` | `for ((r=1; r<=RETRIES; r++))` | files/usr/bin/bind-init, files/usr/bin/test-retrieval-init | Avoids subshell; pure bash arithmetic |
| No `trap` for SIGTERM/SIGINT in polling loops | `trap 'exit 0' SIGTERM SIGINT` | files/usr/bin/bind-init, files/usr/bin/test-retrieval-init | Graceful container shutdown |
| `rm $CREDS` inside `test-retrieval` (wrong file) | `rm $TEST_RESULT` only | files/usr/bin/test-retrieval | Bug: removes bind-creds instead of test-result |
| Typo `"test resutls"` | `"test results"` | files/usr/bin/test-retrieval-init | Cosmetic fix |
| `"bind-init timed out"` in `test-retrieval-init` | `"test-retrieval-init timed out"` | files/usr/bin/test-retrieval-init | Copy-paste error from bind-init |
| `ENTRYPOINT ["entrypoint.sh"]` (relative) | `ENTRYPOINT ["/usr/bin/entrypoint.sh"]` | All Dockerfiles | Absolute path is safer; avoids PATH dependency |
| No `USER` instruction in Dockerfile | `USER ${USER_UID}` before `ENTRYPOINT` | All Dockerfiles | Security best practice; OpenShift requires non-root |
| Secret injection via `--extra-vars @/tmp/secrets` flat file | AAP Credential Types / Vault / EE secret mounts | files/usr/bin/entrypoint.sh | Flat file secrets are a security risk |
| `[[ ! -e "$mounted_secrets" ]]` (tests string as path) | `[[ -n "$mounted_secrets" ]]` | files/usr/bin/entrypoint.sh | Logic bug: `! -e` on a string of filenames is always true |
| `ansible-playbook` without `-i` inventory flag | `ansible-playbook -i /etc/ansible/hosts` | files/usr/bin/entrypoint.sh | Explicit inventory is best practice |
| `git clone` Ansible from `devel` in Dockerfile-canary | `pip install ansible-core==<pinned>` | Dockerfile-canary | Building from `devel` is non-reproducible |
| No `execution-environment.yml` | Create `execution-environment.yml` | New file | Required for AAP EE builds |
| No `collections/requirements.yml` | Create `collections/requirements.yml` | New file | Declare `kubernetes.core`, `community.okd` |
| No `bindep.txt` | Create `bindep.txt` | New file | Declare system package dependencies for EE |

---

## Dependencies

**Collection dependencies** (for `collections/requirements.yml`):
```yaml
collections:
  - name: kubernetes.core
    version: ">=2.4.0"
  - name: community.okd
    version: ">=2.3.0"
  - name: ansible.builtin
    # included with ansible-core, no separate install needed
```

**Role dependencies**: None declared (no `meta/main.yml` exists)

**External packages** (installed by the Dockerfiles):
- `epel-release` (CentOS 7) → not needed on UBI 9
- `centos-release-openshift-origin` (OpenShift 3.x) → **deprecated**; replace with OpenShift 4.x client RPM
- `origin-clients` → **deprecated**; replace with `openshift-clients` from OCP 4.x
- `python-openshift` (Python 2) → replace with `python3-openshift` or `pip3 install openshift`
- `ansible` (from COPR) → replace with `ansible-core` from `pip` or UBI AppStream
- `ansible-kubernetes-modules` (legacy role) → replace with `kubernetes.core` collection
- `ansible-asb-modules` (archived) → **no direct replacement**; APB ecosystem is deprecated
- `apb-base-scripts` (COPR RPM) → embed scripts directly via `COPY`

**Services managed**: None (this is a container base image, not a system service role)

**Cluster/platform dependencies**:
- OpenShift / Kubernetes cluster (consumed at runtime by `oc-login.sh` and playbooks)
- Ansible Service Broker (deprecated) → replace with AAP / EE workflow

---

## Template Modernization

No `.j2` Jinja2 templates exist in this project. All configuration is delivered as static files.

If the project is modernized to use an Ansible role that *generates* the `ansible.cfg` or `hosts` file dynamically (recommended for flexibility), the following templates should be created:

- **`templates/ansible.cfg.j2`**: Parameterize `roles_path`, `collections_paths`, `interpreter_python`, `stdout_callback`
- **`templates/hosts.j2`**: Parameterize `ansible_python_interpreter`, optionally add cluster host entries

---

## Argument Specification

Since this project has no `meta/argument_specs.yml` and no Ansible role variables, the following variables should be formally declared if the project is converted to a proper Ansible role or EE build role:

| Variable | Type | Default | Description |
|---|---|---|---|
| `apb_user_name` | `str` | `apb` | Username for the APB/EE container user |
| `apb_user_uid` | `int` | `1001` | UID for the container user |
| `apb_base_dir` | `str` | `/opt/apb` | Home/base directory for the APB user |
| `apb_roles_path` | `str` | `/etc/ansible/roles:/opt/ansible/roles` | Ansible roles path inside the container |
| `apb_collections_path` | `str` | `/usr/share/ansible/collections:/opt/ansible/collections` | Ansible collections path inside the container |
| `apb_secrets_dir` | `str` | `/etc/apb-secrets` | Directory where broker mounts secrets |
| `apb_bind_creds_path` | `str` | `/var/tmp/bind-creds` | Path for bind credentials file |
| `apb_test_result_path` | `str` | `/var/tmp/test-result` | Path for test result file |
| `apb_bind_retries` | `int` | `150` | Number of polling retries in bind-init / test-retrieval-init |
| `apb_bind_sleep` | `int` | `2` | Sleep interval (seconds) between retries |
| `openshift_target` | `str` | `https://kubernetes.default` | OpenShift API endpoint |
| `openshift_token` | `str` | `""` | OpenShift authentication token (sensitive) |

---

## New Files to Create for Full Modernization

### `execution-environment.yml`
```yaml
version: 3
build_arg_defaults:
  ANSIBLE_GALAXY_CLI_COLLECTION_OPTS: '--pre'

base_image:
  name: registry.access.redhat.com/ubi9/ubi:latest

dependencies:
  galaxy: collections/requirements.yml
  python: requirements.txt
  system: bindep.txt

additional_build_steps:
  prepend_galaxy:
    - RUN dnf -y install openshift-clients python3-openshift && dnf clean all
  append_final:
    - COPY files/etc/ansible/ansible.cfg /etc/ansible/ansible.cfg
    - COPY files/etc/ansible/hosts /etc/ansible/hosts
    - COPY files/usr/bin/ /usr/bin/
    - RUN chmod 755 /usr/bin/bind-init /usr/bin/broker-bind-creds \
            /usr/bin/entrypoint.sh /usr/bin/oc-login.sh \
            /usr/bin/test-retrieval /usr/bin/test-retrieval-init
    - USER 1001
    - ENTRYPOINT ["/usr/bin/entrypoint.sh"]
```

### `collections/requirements.yml`
```yaml
collections:
  - name: kubernetes.core
    version: ">=2.4.0"
  - name: community.okd
    version: ">=2.3.0"
```

### `bindep.txt`
```
openshift-clients [platform:rpm]
python3-openshift  [platform:rpm]
git                [platform:rpm]
```

### `requirements.txt`
```
ansible-core>=2.15
openshift>=0.13.2
kubernetes>=26.1.0
```

---

## Checks for the Migration

**Files to verify** (all paths relative to project root):
```
files/etc/ansible/ansible.cfg
files/etc/ansible/hosts
files/usr/bin/bind-init
files/usr/bin/broker-bind-creds
files/usr/bin/entrypoint.sh
files/usr/bin/oc-login.sh
files/usr/bin/test-retrieval
files/usr/bin/test-retrieval-init
Dockerfile-latest
Dockerfile-nightly
Dockerfile-canary
collections/requirements.yml        ← NEW
execution-environment.yml           ← NEW
bindep.txt                          ← NEW
requirements.txt                    ← NEW
```

**Services to check**: None (container image, no systemd services)

**Templates to validate**: None (no `.j2` files)

**Cluster resources to validate at runtime**:
- OpenShift/Kubernetes API reachable from container
- Service account token mounted at `/var/run/secrets/kubernetes.io/serviceaccount/token`
- `oc` binary available at `/usr/bin/oc` inside the built image
- `/opt/apb/actions/` directory exists and contains playbooks in the derived image

---

## Pre-flight Checks

### Container Build Validation
```bash
# Build the modernized image
docker build -t apb-base:modern -f Dockerfile-latest .

# Verify all scripts are present and executable
docker run --rm apb-base:modern ls -la /usr/bin/{bind-init,broker-bind-creds,entrypoint.sh,oc-login.sh,test-retrieval,test-retrieval-init}

# Verify ansible.cfg is correct
docker run --rm apb-base:modern cat /etc/ansible/ansible.cfg

# Verify hosts inventory
docker run --rm apb-base:modern cat /etc/ansible/hosts

# Verify Ansible version and Python 3
docker run --rm apb-base:modern ansible --version

# Verify oc client is available
docker run --rm apb-base:modern oc version --client

# Verify container runs as non-root (UID 1001)
docker run --rm apb-base:modern id

# Verify kubernetes.core collection is installed
docker run --rm apb-base:modern ansible-galaxy collection list | grep kubernetes.core

# Verify community.okd collection is installed
docker run --rm apb-base:modern ansible-galaxy collection list | grep community.okd

# Verify Python 3 openshift library
docker run --rm apb-base:modern python3 -c "import openshift; print(openshift.__version__)"
```

### Script Logic Validation
```bash
# Test bind-init timeout behavior (should exit 1 after retries)
docker run --rm apb-base:modern bash -c "RETRIES=2 bind-init; echo exit:$?"

# Test broker-bind-creds with no creds file (should exit 2)
docker run --rm apb-base:modern bash -c "broker-bind-creds; echo exit:$?"

# Test broker-bind-creds with a creds file (should exit 0 and print content)
docker run --rm apb-base:modern bash -c "echo 'user: test' > /var/tmp/bind-creds && broker-bind-creds; echo exit:$?"

# Test test-retrieval with no result file (should exit 2)
docker run --rm apb-base:modern bash -c "test-retrieval; echo exit:$?"

# Test entrypoint S2I bypass
docker run --rm apb-base:modern entrypoint.sh s2i/assemble; echo "exit: $?"

# Test oc-login.sh with token env vars
docker run --rm -e OPENSHIFT_TARGET=https://api.example.com -e OPENSHIFT_TOKEN=testtoken \
  apb-base:modern bash -c "bash -x /usr/bin/oc-login.sh 2>&1 | head -5"
```

### EE Build Validation (if using `ansible-builder`)
```bash
# Build EE using ansible-builder
ansible-builder build -t apb-base-ee:latest -f execution-environment.yml -v 3

# Verify EE introspection
ansible-navigator images --eei apb-base-ee:latest
```

### Ansible Syntax Check (for derived APB playbooks)
```bash
# Inside a derived APB image, verify playbook syntax
docker run --rm -v /path/to/apb/actions:/opt/apb/actions apb-base:modern \
  ansible-playbook --syntax-check /opt/apb/actions/provision.yml
```

---

## Summary of Critical Issues

| Severity | Issue | File | Action |
|---|---|---|---|
| 🔴 **Critical** | CentOS 7 EOL base image | All Dockerfiles | Migrate to UBI 8/9 |
| 🔴 **Critical** | Python 2 dependencies (`python-openshift`) | All Dockerfiles | Replace with Python 3 equivalents |
| 🔴 **Critical** | OpenShift 3.x client (`origin-clients`) | All Dockerfiles | Replace with OCP 4.x `openshift-clients` |
| 🔴 **Critical** | `ansible-asb-modules` / APB ecosystem archived | All Dockerfiles | Migrate to AAP EE patterns |
| 🔴 **Critical** | `rm $CREDS` bug in `test-retrieval` | files/usr/bin/test-retrieval | Fix: should be `rm $TEST_RESULT` |
| 🟠 **High** | `[[ ! -e "$mounted_secrets" ]]` logic bug | files/usr/bin/entrypoint.sh | Fix: use `[[ -n "$mounted_secrets" ]]` |
| 🟠 **High** | `--insecure-skip-tls-verify=true` in oc-login | files/usr/bin/oc-login.sh | Use proper CA bundle |
| 🟠 **High** | Secrets written to `/tmp/secrets` flat file | files/usr/bin/entrypoint.sh | Use AAP Vault / EE secret mounts |
| 🟠 **High** | No `collections_paths` in `ansible.cfg` | files/etc/ansible/ansible.cfg | Add collections path |
| 🟡 **Medium** | No signal handling in polling loops | bind-init, test-retrieval-init | Add `trap` for SIGTERM/SIGINT |
| 🟡 **Medium** | `for r in $(seq ...)` subshell pattern | bind-init, test-retrieval-init | Use bash arithmetic loop |
| 🟡 **Medium** | `[[ ! -z ]]` anti-pattern | files/usr/bin/oc-login.sh | Use `[[ -n ]]` |
| 🟡 **Medium** | `"bind-init timed out"` in test-retrieval-init | files/usr/bin