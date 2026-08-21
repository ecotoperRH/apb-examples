---
source-path: etherpad-apb
---

I now have all the information needed to write a comprehensive migration plan. Let me compile the full analysis.

---

# Migration Plan: etherpad-apb

**TLDR**: `etherpad-apb` is an Ansible Playbook Bundle (APB) — a containerized Ansible role designed to deploy Etherpad Lite (a collaborative note-taking web application) alongside a MariaDB database onto an OpenShift cluster. It uses heavily deprecated APB-era modules (`k8s_v1_persistent_volume_claim`, `k8s_v1_service`, `openshift_v1_route`, `openshift_v1_deployment_config`) that no longer exist in any supported collection. The entire APB packaging model (the `Dockerfile`, `apb.yml`, and `ansibleplaybookbundle/apb-base` image) is obsolete. Migration requires replacing all APB/OpenShift v1 modules with `kubernetes.core` and `redhat.openshift` equivalents, restructuring the project as a standard Ansible role or collection, and modernizing all syntactical patterns (booleans, FQCN, fact access).

---

## Service Type and Configuration

**Service Type**: Cloud-Native Application Deployment (Kubernetes / OpenShift)

**Key Operations**:
- Creates a `PersistentVolumeClaim` (`mariadb-storage`, 1Gi) for MariaDB data
- Creates a `PersistentVolumeClaim` (`mariadb-logs`, 1Gi) for MariaDB logs
- Creates a Kubernetes `Service` for MariaDB (port 3306)
- Creates a Kubernetes `Service` for Etherpad (port 9001)
- Creates an OpenShift `Route` to expose the Etherpad service externally
- Creates an OpenShift `DeploymentConfig` for MariaDB (`docker.io/mariadb:latest`) with environment-variable-based credentials and PVC volume mounts
- Creates an OpenShift `DeploymentConfig` for Etherpad (`docker.io/tvelocity/etherpad-lite:latest`) with environment-variable-based DB connection settings
- All resources are namespace-scoped and state-driven (`present`/`absent`)

---

## File Structure

**IMPORTANT: All paths are relative to the repository root `etherpad-apb/`.**

**Playbook Files:**
```
playbooks/provision.yaml
```

**Task Files:**
```
roles/provision-etherpad-apb/tasks/main.yml
```

**Variable Files:**
```
roles/provision-etherpad-apb/defaults/main.yml
```

**Meta / Documentation:**
```
roles/provision-etherpad-apb/README
```

**APB Packaging (Legacy — to be replaced):**
```
apb.yml
Dockerfile
```

---

## Module Explanation

The role performs operations in this order:

### 1. **Playbook Entry Point** (`playbooks/provision.yaml`)
- Runs on `localhost` with `connection: local` and `gather_facts: false`
- Loads the legacy `ansible.kubernetes-modules` role (the APB-era shim that provided `k8s_v1_*` and `openshift_v1_*` modules) — **this role is tombstoned and must be removed**
- Loads `provision-etherpad-apb` with `playbook_debug: false`
- **Legacy pattern**: Dependency on `ansible.kubernetes-modules` (APB-era, no longer maintained or installable)
- **Modern equivalent**: Use `kubernetes.core` and `redhat.openshift` collections directly; no shim role needed

### 2. **MariaDB Storage PVC** (`roles/provision-etherpad-apb/tasks/main.yml`, task 1)
- Module: `k8s_v1_persistent_volume_claim` — **tombstoned APB module**
- Creates PVC `mariadb-storage` in `{{ namespace }}` with `ReadWriteOnce`, 1Gi
- Has a **duplicate `state:` key** (both `state: present` and `state: "{{ state }}"` — the second overrides the first, which is a latent bug)
- **Modern equivalent**: `kubernetes.core.k8s` with a full Kubernetes manifest dict

### 3. **MariaDB Logs PVC** (`roles/provision-etherpad-apb/tasks/main.yml`, task 2)
- Module: `k8s_v1_persistent_volume_claim` — **tombstoned APB module**
- Creates PVC `mariadb-logs` in `{{ namespace }}` with `ReadWriteOnce`, 1Gi
- Same duplicate `state:` key bug as task 1
- **Modern equivalent**: `kubernetes.core.k8s` with a full Kubernetes manifest dict

### 4. **MariaDB Service** (`roles/provision-etherpad-apb/tasks/main.yml`, task 3)
- Module: `k8s_v1_service` — **tombstoned APB module**
- Creates a ClusterIP Service `mariadb` on port 3306, selecting pods with labels `app: etherpad-apb, service: mariadb`
- **Modern equivalent**: `kubernetes.core.k8s` with a `v1/Service` manifest

### 5. **Etherpad Service** (`roles/provision-etherpad-apb/tasks/main.yml`, task 4)
- Module: `k8s_v1_service` — **tombstoned APB module**
- Creates a ClusterIP Service `etherpad` on port 9001, selecting pods with labels `app: etherpad-apb, service: etherpad`
- **Modern equivalent**: `kubernetes.core.k8s` with a `v1/Service` manifest

### 6. **Etherpad Route** (`roles/provision-etherpad-apb/tasks/main.yml`, task 5)
- Module: `openshift_v1_route` — **tombstoned APB/OpenShift module**
- Creates an OpenShift `Route` named `etherpad` pointing to the `etherpad` service on `port-9001`
- Uses flattened parameter style (`spec_port_target_port`, `to_name`) — **parameter drift**: modern module uses nested manifest YAML
- **Modern equivalent**: `redhat.openshift.k8s` or `kubernetes.core.k8s` with a `route.openshift.io/v1/Route` manifest

### 7. **MariaDB DeploymentConfig** (`roles/provision-etherpad-apb/tasks/main.yml`, task 6)
- Module: `openshift_v1_deployment_config` — **tombstoned APB/OpenShift module**
- Deploys MariaDB with 1 replica, environment variables for credentials, and two PVC volume mounts
- Uses flattened parameter style (`spec_template_metadata_labels`, `dns_policy`, etc.) — **parameter drift**: modern module uses nested manifest YAML
- Image: `docker.io/mariadb:latest` (pinning to `latest` is a risk — should be versioned)
- **Modern equivalent**: `kubernetes.core.k8s` with a `apps.openshift.io/v1/DeploymentConfig` manifest (or migrate to a standard `apps/v1/Deployment`)

### 8. **Etherpad DeploymentConfig** (`roles/provision-etherpad-apb/tasks/main.yml`, task 7)
- Module: `openshift_v1_deployment_config` — **tombstoned APB/OpenShift module**
- Deploys Etherpad with 1 replica, environment variables for DB connection and admin credentials
- Has `state: present` hardcoded inline **and** `state: "{{ state }}"` at the bottom — same duplicate key bug
- Image: `docker.io/tvelocity/etherpad-lite:latest` (unmaintained image — should be replaced with a maintained alternative)
- **Modern equivalent**: `kubernetes.core.k8s` with a `apps.openshift.io/v1/DeploymentConfig` manifest (or migrate to `apps/v1/Deployment`)

### 9. **Defaults** (`roles/provision-etherpad-apb/defaults/main.yml`)
- `playbook_debug: no` — **legacy boolean** (`no` → `false`)
- All sensitive values default to `'admin'` — **security risk**, should use `ansible-vault` or require explicit values
- `namespace` resolved via `lookup('env', 'NAMESPACE')` — APB-era pattern; in modern roles this should be a required variable with no default or use `vars_prompt`/inventory

---

## Modernization Mapping

| Legacy Pattern | Modern Equivalent | Files Affected | Notes |
|---|---|---|---|
| `k8s_v1_persistent_volume_claim:` | `kubernetes.core.k8s:` with `v1/PersistentVolumeClaim` manifest | `tasks/main.yml` | Tombstoned APB module; full parameter drift — all params become nested manifest YAML |
| `k8s_v1_service:` | `kubernetes.core.k8s:` with `v1/Service` manifest | `tasks/main.yml` | Tombstoned APB module; full parameter drift |
| `openshift_v1_route:` | `kubernetes.core.k8s:` with `route.openshift.io/v1/Route` manifest | `tasks/main.yml` | Tombstoned APB module; `spec_port_target_port` → `spec.port.targetPort`, `to_name` → `spec.to.name` |
| `openshift_v1_deployment_config:` | `kubernetes.core.k8s:` with `apps.openshift.io/v1/DeploymentConfig` manifest | `tasks/main.yml` | Tombstoned APB module; all flattened params (`spec_template_metadata_labels`, `dns_policy`, etc.) → nested manifest YAML |
| `role: ansible.kubernetes-modules` | Remove entirely | `playbooks/provision.yaml` | APB shim role — tombstoned; `kubernetes.core` collection replaces it |
| `install_python_requirements: no` | Remove (role removed) | `playbooks/provision.yaml` | APB-era parameter |
| `playbook_debug: false` (role param) | Standard `vars:` or remove | `playbooks/provision.yaml` | APB-era convention |
| `playbook_debug: no` | `playbook_debug: false` | `defaults/main.yml` | Legacy boolean `no` → `false` |
| Duplicate `state:` key in tasks | Remove `state: present` inline; keep only `state: "{{ state }}"` | `tasks/main.yml` | Tasks 1, 2, 7 have duplicate YAML keys — second value silently wins; this is a latent bug |
| Flattened module parameters (`spec_port_target_port`, `spec_template_metadata_labels`, `dns_policy`, etc.) | Nested Kubernetes manifest YAML under `definition:` | `tasks/main.yml` | Full parameter drift for all APB-era OpenShift modules |
| `image: docker.io/mariadb:latest` | `image: docker.io/mariadb:11` (or pinned version) | `tasks/main.yml` | `latest` tag is non-idempotent and a security risk |
| `image: docker.io/tvelocity/etherpad-lite:latest` | `image: docker.io/nicholaswilde/etherpad:latest` or maintained alternative | `tasks/main.yml` | `tvelocity/etherpad-lite` is unmaintained; evaluate replacement |
| `namespace: "{{ lookup('env','NAMESPACE') }}"` | Explicit required variable or `vars_prompt` | `defaults/main.yml` | APB-era env-var injection pattern; not portable outside APB runtime |
| `mariadb_root_password: "{{ lookup('env','MYSQL_ROOT_PASSWORD') \| default('admin', true) }}"` | Use `ansible-vault` encrypted var or `vars_prompt` with `no_log: true` | `defaults/main.yml` | Plaintext default passwords are a security risk |
| `Dockerfile` + `apb.yml` + `ansibleplaybookbundle/apb-base` | `execution-environment.yml` + `bindep.txt` + `collections/requirements.yml` | `Dockerfile`, `apb.yml` | Entire APB packaging model is obsolete; replace with Ansible Execution Environment (EE) |
| Missing `meta/main.yml` | Add `meta/main.yml` with `galaxy_info` and `dependencies` | (missing) | Required for Ansible Galaxy / AAP |
| Missing `meta/argument_specs.yml` | Add `meta/argument_specs.yml` | (missing) | Role input validation |
| Missing FQCN on all modules | Add FQCN prefix to all modules | `tasks/main.yml` | e.g., `kubernetes.core.k8s:` |

---

## Dependencies

**Collection dependencies** (for `collections/requirements.yml`):
```yaml
collections:
  - name: kubernetes.core
    version: ">=3.0.0"
  - name: redhat.openshift
    version: ">=2.3.0"
  - name: ansible.utils
    version: ">=2.0.0"
```

**Role dependencies**: 
- `ansible.kubernetes-modules` — **REMOVE**; this is the tombstoned APB shim. All functionality is now in `kubernetes.core`.

**External packages** (Python, for EE / `bindep.txt`):
- `kubernetes` (PyPI) — required by `kubernetes.core`
- `openshift` (PyPI) — required by `redhat.openshift`
- `PyYAML`

**Container images referenced**:
- `docker.io/mariadb:latest` — MariaDB database
- `docker.io/tvelocity/etherpad-lite:latest` — Etherpad Lite (unmaintained; evaluate replacement)

**Services managed** (Kubernetes/OpenShift resources):
- `PersistentVolumeClaim/mariadb-storage` (1Gi, RWO)
- `PersistentVolumeClaim/mariadb-logs` (1Gi, RWO)
- `Service/mariadb` (port 3306)
- `Service/etherpad` (port 9001)
- `Route/etherpad` (OpenShift route → port 9001)
- `DeploymentConfig/mariadb` (1 replica)
- `DeploymentConfig/etherpad` (1 replica)

---

## Template Modernization

There are **no Jinja2 `.j2` template files** in this role. All Kubernetes manifests are expressed inline as module parameters (APB-era flattened style). During modernization, these inline parameters must be converted to full Kubernetes manifest YAML under the `definition:` key of `kubernetes.core.k8s`.

**Example conversion for the MariaDB PVC (task 1)**:

*Legacy (APB style):*
```yaml
- name: mariadb storage volume claim
  k8s_v1_persistent_volume_claim:
    name: mariadb-storage
    namespace: '{{ namespace }}'
    state: present          # BUG: duplicate key
    access_modes:
      - ReadWriteOnce
    resources_requests:
      storage: 1Gi
    state: "{{ state }}"   # this one wins
```

*Modern (`kubernetes.core.k8s`):*
```yaml
- name: mariadb storage volume claim
  kubernetes.core.k8s:
    state: "{{ state }}"
    definition:
      apiVersion: v1
      kind: PersistentVolumeClaim
      metadata:
        name: mariadb-storage
        namespace: "{{ namespace }}"
      spec:
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 1Gi
```

**Example conversion for the OpenShift Route (task 5)**:

*Legacy (APB style):*
```yaml
- name: create etherpad route
  openshift_v1_route:
    name: etherpad
    namespace: '{{ namespace }}'
    spec_port_target_port: port-9001
    labels:
      app: etherpad
      service: etherpad
    to_name: etherpad
    state: "{{ state }}"
```

*Modern (`kubernetes.core.k8s`):*
```yaml
- name: create etherpad route
  kubernetes.core.k8s:
    state: "{{ state }}"
    definition:
      apiVersion: route.openshift.io/v1
      kind: Route
      metadata:
        name: etherpad
        namespace: "{{ namespace }}"
        labels:
          app: etherpad
          service: etherpad
      spec:
        to:
          kind: Service
          name: etherpad
        port:
          targetPort: port-9001
```

---

## Argument Specification

The following variables should be documented in `meta/argument_specs.yml`:

| Variable | Type | Default | Required | Description |
|---|---|---|---|---|
| `namespace` | `str` | `etherpad-apb` (env lookup) | Yes | Kubernetes/OpenShift namespace to deploy into |
| `state` | `str` | `present` | No | Desired state of all resources (`present` or `absent`) |
| `mariadb_name` | `str` | `etherpad` | Yes | MariaDB database name |
| `mariadb_user` | `str` | `etherpad` | Yes | MariaDB application user |
| `mariadb_password` | `str` | `admin` | Yes | MariaDB application user password (**must be vaulted**) |
| `mariadb_root_password` | `str` | `admin` | Yes | MariaDB root password (**must be vaulted**) |
| `etherpad_admin_user` | `str` | `etherpad` | No | Etherpad admin username |
| `etherpad_admin_password` | `str` | `admin` | No | Etherpad admin password (**must be vaulted**) |
| `etherpad_db_host` | `str` | `mariadb` | No | Hostname of the MariaDB service (defaults to in-cluster service name) |
| `playbook_debug` | `bool` | `false` | No | Enable debug output (APB-era flag; consider removing) |

**Recommended `meta/argument_specs.yml` entry:**
```yaml
argument_specs:
  main:
    short_description: Deploy Etherpad Lite and MariaDB to OpenShift
    options:
      namespace:
        type: str
        required: true
        description: OpenShift/Kubernetes namespace for all resources
      state:
        type: str
        required: false
        default: present
        choices: [present, absent]
        description: Desired state of all Kubernetes resources
      mariadb_name:
        type: str
        required: true
        description: MariaDB database name
      mariadb_user:
        type: str
        required: true
        description: MariaDB application user
      mariadb_password:
        type: str
        required: true
        no_log: true
        description: MariaDB application user password
      mariadb_root_password:
        type: str
        required: true
        no_log: true
        description: MariaDB root password
      etherpad_admin_user:
        type: str
        required: false
        default: etherpad
        description: Etherpad admin username
      etherpad_admin_password:
        type: str
        required: false
        no_log: true
        description: Etherpad admin password
      etherpad_db_host:
        type: str
        required: false
        default: mariadb
        description: Hostname of the MariaDB service
```

---

## New Files to Create

The following files must be **created from scratch** as part of the modernization (none exist in the legacy role):

```
roles/provision-etherpad-apb/meta/main.yml
roles/provision-etherpad-apb/meta/argument_specs.yml
collections/requirements.yml
execution-environment.yml
bindep.txt
```

The `Dockerfile` and `apb.yml` should be **retired** (or archived) and replaced by `execution-environment.yml`.

---

## Checks for the Migration

**Files to verify** (all paths relative to `etherpad-apb/`):

```
playbooks/provision.yaml                                  (modified)
roles/provision-etherpad-apb/tasks/main.yml               (fully rewritten)
roles/provision-etherpad-apb/defaults/main.yml            (boolean fix, security review)
roles/provision-etherpad-apb/meta/main.yml                (new)
roles/provision-etherpad-apb/meta/argument_specs.yml      (new)
collections/requirements.yml                              (new)
execution-environment.yml                                 (new, replaces Dockerfile+apb.yml)
bindep.txt                                                (new)
```

**Services to check** (Kubernetes/OpenShift resources after provisioning):
- `oc get pvc -n <namespace>` → `mariadb-storage` and `mariadb-logs` should be `Bound`
- `oc get svc -n <namespace>` → `mariadb` (3306) and `etherpad` (9001) should exist
- `oc get route -n <namespace>` → `etherpad` route should have a hostname assigned
- `oc get dc -n <namespace>` → `mariadb` and `etherpad` DeploymentConfigs should show `1/1` ready replicas (or use `oc get deployment` if migrated to standard Deployments)
- `oc get pods -n <namespace>` → all pods should be in `Running` state

**Templates to validate**: N/A (no `.j2` files; all manifests are inline YAML)

---

## Pre-flight Checks

```bash
# 1. Verify target collection versions are available
ansible-galaxy collection install kubernetes.core redhat.openshift ansible.utils
ansible-galaxy collection list | grep -E 'kubernetes.core|redhat.openshift'

# 2. Verify Python dependencies for the kubernetes.core collection
pip show kubernetes openshift PyYAML

# 3. Verify OpenShift cluster connectivity
oc whoami
oc cluster-info

# 4. Verify the target namespace exists (or will be created)
oc get namespace <namespace>

# 5. Verify StorageClass supports ReadWriteOnce PVCs
oc get storageclass

# 6. Dry-run the modernized playbook (check mode)
ansible-playbook playbooks/provision.yaml --check -e namespace=etherpad-test -e state=present

# 7. Validate no duplicate YAML keys remain in tasks/main.yml
python3 -c "import yaml; yaml.safe_load(open('roles/provision-etherpad-apb/tasks/main.yml'))"

# 8. Confirm tombstoned modules are no longer referenced
grep -rn 'k8s_v1_\|openshift_v1_\|ansible\.kubernetes-modules' roles/ playbooks/

# 9. Confirm no plaintext passwords in defaults
grep -n 'password' roles/provision-etherpad-apb/defaults/main.yml
# All password defaults should be empty string '' or use vault references

# 10. After provisioning, verify Etherpad is reachable
ROUTE=$(oc get route etherpad -n <namespace> -o jsonpath='{.spec.host}')
curl -s -o /dev/null -w "%{http_code}" http://${ROUTE}/
# Expected: 200
```

---

## Summary of Critical Issues (Priority Order)

| Priority | Issue | Impact |
|---|---|---|
| 🔴 CRITICAL | All 7 task modules are tombstoned APB modules (`k8s_v1_*`, `openshift_v1_*`) | Role is completely non-functional on any modern Ansible/OpenShift version |
| 🔴 CRITICAL | Dependency on `ansible.kubernetes-modules` role (tombstoned APB shim) | Playbook will fail at role-loading stage |
| 🔴 CRITICAL | Duplicate `state:` YAML keys in 3 tasks | Silent data loss — first `state: present` is silently discarded; behavior is undefined |
| 🟠 HIGH | Full parameter drift on all modules | All flattened APB params must be rewritten as nested Kubernetes manifest YAML |
| 🟠 HIGH | Plaintext default passwords (`admin`) for all credentials | Security vulnerability — must use vault or require explicit values |
| 🟡 MEDIUM | APB packaging model (`Dockerfile`, `apb.yml`) is obsolete | Must be replaced with Execution Environment (`execution-environment.yml`) |
| 🟡 MEDIUM | `image: ...:latest` tags for both containers | Non-idempotent, security risk — pin to specific versions |
| 🟡 MEDIUM | `tvelocity/etherpad-lite` image is unmaintained | Evaluate replacement with a maintained Etherpad image |
| 🟢 LOW | `playbook_debug: no` legacy boolean | Cosmetic — change to `false` |
| 🟢 LOW | Missing `meta/main.yml`, `meta/argument_specs.yml` | Role validation and Galaxy publishing will fail |
| 🟢 LOW | Env-var-based namespace/credential injection (`lookup('env',...)`) | APB-era pattern; replace with standard Ansible variable passing |