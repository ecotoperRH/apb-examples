---
source-path: nginx-oss-apb
---

Now I have a complete picture of the role. Let me compile the full migration plan.

---

# Migration Plan: nginx-oss-apb

**TLDR**: `nginx-oss-apb` is an **Ansible Playbook Bundle (APB)** — a legacy OpenShift Service Catalog packaging format — that provisions and deprovisions a single NGINX OSS instance (with optional load balancing) on an OpenShift cluster. It uses heavily deprecated modules (`openshift_v1_deployment_config`, `k8s_v1_service`, `openshift_v1_route`, bare `shell: oc create configmap`, and `template` without FQCN or `mode:`), relies on the now-defunct `ansible.kubernetes-modules` role, and is structured as a Docker image rather than a standard Ansible role or collection. The migration must replace all OpenShift/Kubernetes legacy modules with `kubernetes.core` equivalents, convert APB-specific packaging to a standard Ansible role/collection, modernize all syntax, and introduce proper argument specs and execution environment metadata.

---

## Service Type and Configuration

**Service Type**: Web Server / Kubernetes-Native Application Deployment (OpenShift)

**Key Operations**:
- **Provision**: Creates an OpenShift `DeploymentConfig` running `docker.io/alessfg/openshift-nginx`, a Kubernetes `Service` (port 80 → 8080), an OpenShift `Route` (external HTTP access), renders an NGINX `default.conf` from a Jinja2 template, and creates a `ConfigMap` from that rendered file via a raw `oc` shell command
- **Deprovision**: Deletes the `Route`, `Service`, and `DeploymentConfig` in reverse order
- **NGINX configuration**: Supports optional upstream load balancing with configurable algorithm (`round_robin`, `least_conn`, `ip_hash`, `hash`) and a comma-separated server list; falls back to static file serving when load balancing is disabled
- **Parameters exposed**: `lb` (boolean), `server` (string, CSV), `lb_method` (enum)

---

## File Structure

**IMPORTANT: All paths are relative to the repository root `nginx-oss-apb/`.**

**Playbook Files:**
```
playbooks/provision.yml
playbooks/deprovision.yml
```

**Task Files:**
```
roles/provision-nginx-oss-apb/tasks/main.yml
roles/deprovision-nginx-oss-apb/tasks/main.yml
```

**Handler Files:**
```
(none — no handlers directory exists in either role)
```

**Variable Files:**
```
(none — no defaults/main.yml or vars/main.yml in either role)
```

**Meta:**
```
(none — no meta/main.yml in either role)
```

**Templates:**
```
roles/provision-nginx-oss-apb/templates/default.conf.j2
```

**APB Metadata / Container Files:**
```
apb.yml
Dockerfile
```

**Static Files:**
```
(none)
```

---

## Module Explanation

The role performs operations in this order:

### 1. Playbook Entry Point — Provision (`playbooks/provision.yml`)
- Runs on `localhost` with `connection: local` and `gather_facts: false`
- Loads the legacy `ansible.kubernetes-modules` role (with `install_python_requirements: no`) to inject deprecated OpenShift/k8s Python libraries
- Then runs `provision-nginx-oss-apb` role with `playbook_debug: false`
- **Legacy pattern**: Dependency on `ansible.kubernetes-modules` — this entire role is obsolete; `kubernetes.core` collection ships its own Python client requirements
- **Modern equivalent**: Remove `ansible.kubernetes-modules` dependency entirely; declare `kubernetes.core` in `collections/requirements.yml`; use `ansible.builtin.include_role` or direct collection usage

### 2. Provision Role — `roles/provision-nginx-oss-apb/tasks/main.yml`

#### Task 1 — Create DeploymentConfig
- **Module used**: `openshift_v1_deployment_config` (from the defunct `ansible.kubernetes-modules` role)
- **What it does**: Creates an OpenShift `DeploymentConfig` named `nginx-oss-apb` in `{{ namespace }}` with 1 replica, mounts a `ConfigMap` volume at `/etc/nginx/conf.d`, and uses image `docker.io/alessfg/openshift-nginx`
- **Legacy pattern**: `openshift_v1_deployment_config` is a tombstoned module from the `ansible.kubernetes-modules` role (pre-Operator SDK era); it does not exist in any current collection
- **Modern equivalent**: `kubernetes.core.k8s` with `kind: DeploymentConfig` and `apiVersion: apps.openshift.io/v1` (for OpenShift), or migrate to `kind: Deployment` / `apiVersion: apps/v1` for vanilla Kubernetes portability
- **Parameter drift**: The legacy module used flattened snake_case parameters (e.g., `spec_template_metadata_labels`, `restart_policy` at top level). `kubernetes.core.k8s` uses a full native Kubernetes manifest under the `definition:` key — **all parameters must be restructured into a proper YAML manifest**

#### Task 2 — Create Service
- **Module used**: `k8s_v1_service` (from `ansible.kubernetes-modules`, tombstoned)
- **What it does**: Creates a Kubernetes `Service` named `nginx-oss-apb` mapping port 80 to container port 8080
- **Legacy pattern**: `k8s_v1_service` is tombstoned; flattened parameter style
- **Modern equivalent**: `kubernetes.core.k8s` with `kind: Service`, `apiVersion: v1`, full `definition:` manifest
- **Parameter drift**: `ports[].target_port` was an integer in the legacy module; in `kubernetes.core.k8s` it must be specified as a string (`"8080"`) or integer under `spec.ports[].targetPort`

#### Task 3 — Create Route
- **Module used**: `openshift_v1_route` (tombstoned)
- **What it does**: Creates an OpenShift `Route` exposing the service externally via `spec_port_target_port: web`
- **Legacy pattern**: `openshift_v1_route` is tombstoned; `spec_port_target_port` is a flattened parameter
- **Modern equivalent**: `kubernetes.core.k8s` with `kind: Route`, `apiVersion: route.openshift.io/v1`, full `definition:` manifest

#### Task 4 — Render NGINX Config Template
- **Module used**: `template` (short name, no FQCN)
- **What it does**: Renders `default.conf.j2` to `/tmp/default.conf` on the controller host
- **Legacy patterns**:
  - Short module name `template` → must be `ansible.builtin.template`
  - Missing `mode:` parameter on the task
  - Destination is `/tmp/default.conf` — a controller-local temp path, which is fragile
- **Modern equivalent**: `ansible.builtin.template` with `mode: '0644'`; consider using `ansible.builtin.tempfile` + `ansible.builtin.template` for a managed temp path, or use `kubernetes.core.k8s` with an inline `ConfigMap` manifest to eliminate the temp file entirely

#### Task 5 — Create ConfigMap via Shell
- **Module used**: `shell` (short name, no FQCN)
- **What it does**: Runs `oc create configmap nginx-conf --from-file=nginx-conf=/tmp/default.conf` — a raw CLI call
- **Legacy patterns**:
  - Short module name `shell` → `ansible.builtin.shell`
  - Missing `changed_when:` — task will always report `changed` (idempotency violation)
  - `oc create` is not idempotent — will fail on re-run if the ConfigMap already exists
  - Depends on `oc` CLI being present on the controller
- **Modern equivalent**: Replace entirely with `kubernetes.core.k8s` using an inline `ConfigMap` manifest with `data:` populated via the `lookup('ansible.builtin.template', ...)` or `ansible.builtin.slurp` pattern, eliminating both the temp file and the shell call

### 3. Deprovision Role — `roles/deprovision-nginx-oss-apb/tasks/main.yml`

#### Task 1 — Delete Route
- **Module used**: `openshift_v1_route` with `state: absent`
- **Modern equivalent**: `kubernetes.core.k8s` with `state: absent`, `kind: Route`, `apiVersion: route.openshift.io/v1`

#### Task 2 — Delete Service
- **Module used**: `k8s_v1_service` with `state: absent`
- **Modern equivalent**: `kubernetes.core.k8s` with `state: absent`, `kind: Service`, `apiVersion: v1`

#### Task 3 — Delete DeploymentConfig
- **Module used**: `openshift_v1_deployment_config` with `state: absent`
- **Modern equivalent**: `kubernetes.core.k8s` with `state: absent`, `kind: DeploymentConfig`, `apiVersion: apps.openshift.io/v1`

### 4. Playbook Entry Point — Deprovision (`playbooks/deprovision.yml`)
- Mirror of `provision.yml` — same `ansible.kubernetes-modules` dependency, same modernization applies

---

## Modernization Mapping

| Legacy Pattern | Modern Equivalent | Files Affected | Notes |
|---|---|---|---|
| `openshift_v1_deployment_config:` | `kubernetes.core.k8s:` with `kind: DeploymentConfig` | `roles/provision-nginx-oss-apb/tasks/main.yml`, `roles/deprovision-nginx-oss-apb/tasks/main.yml` | **Tombstoned module** — full parameter restructure into `definition:` manifest required; `spec_template_metadata_labels` → `spec.template.metadata.labels`; `restart_policy` → `spec.template.spec.restartPolicy` |
| `k8s_v1_service:` | `kubernetes.core.k8s:` with `kind: Service` | `roles/provision-nginx-oss-apb/tasks/main.yml`, `roles/deprovision-nginx-oss-apb/tasks/main.yml` | **Tombstoned module** — `ports[].target_port` (int) → `spec.ports[].targetPort` (int or string) |
| `openshift_v1_route:` | `kubernetes.core.k8s:` with `kind: Route` | `roles/provision-nginx-oss-apb/tasks/main.yml`, `roles/deprovision-nginx-oss-apb/tasks/main.yml` | **Tombstoned module** — `spec_port_target_port` → `spec.port.targetPort` inside `definition:` |
| `template:` | `ansible.builtin.template:` | `roles/provision-nginx-oss-apb/tasks/main.yml` | FQCN required |
| `template:` missing `mode:` | Add `mode: '0644'` | `roles/provision-nginx-oss-apb/tasks/main.yml` | File permission best practice |
| `shell: oc create configmap ...` | `kubernetes.core.k8s:` with inline `ConfigMap` definition | `roles/provision-nginx-oss-apb/tasks/main.yml` | **Idempotency violation** — `oc create` fails on re-run; missing `changed_when:`; replace with native k8s module using `lookup('ansible.builtin.template', ...)` to inline config data |
| `shell:` (short name) | `ansible.builtin.shell:` | `roles/provision-nginx-oss-apb/tasks/main.yml` | FQCN (if shell task is retained as interim) |
| `shell:` missing `changed_when:` | Add `changed_when: true` or replace with idempotent module | `roles/provision-nginx-oss-apb/tasks/main.yml` | Idempotency |
| `role: ansible.kubernetes-modules` | Remove entirely | `playbooks/provision.yml`, `playbooks/deprovision.yml` | Obsolete role; `kubernetes.core` collection replaces all functionality |
| `install_python_requirements: no` | Remove (role removed) | `playbooks/provision.yml`, `playbooks/deprovision.yml` | Obsolete parameter |
| `playbook_debug: false` | Remove or convert to `vars:` block | `playbooks/provision.yml`, `playbooks/deprovision.yml` | Unused/legacy APB debug flag |
| APB `Dockerfile` + `apb.yml` | `execution-environment.yml` + `bindep.txt` | `Dockerfile`, `apb.yml` | APB packaging format is EOL; replace with Ansible Execution Environment (EE) |
| `apb.yml` parameters section | `meta/argument_specs.yml` | `apb.yml` | APB parameter schema → Ansible role argument spec |
| Bare `{{ namespace }}` variable (no default) | Define in `defaults/main.yml` with `argument_specs.yml` validation | Both task files | Variable has no default and no spec — must be required in argument spec |
| `{% if lb %}` bare Jinja2 boolean test | `{% if lb | bool %}` | `roles/provision-nginx-oss-apb/templates/default.conf.j2` | Jinja2 native type safety — `lb` arrives as a string `"false"` from APB/survey inputs |
| `{% set list = server.split(', ') %}` | `{% set server_list = server.split(', ') %}` | `roles/provision-nginx-oss-apb/templates/default.conf.j2` | `list` is a reserved Jinja2/Python built-in name; rename variable |
| `{{ ' $request_uri' if lb_method == 'hash' }}` | Retain but add whitespace guard | `roles/provision-nginx-oss-apb/templates/default.conf.j2` | Functionally correct but fragile — add `lb_method \| default('round_robin')` guard |
| `gather_facts: false` | Retain (correct for k8s plays) | `playbooks/provision.yml`, `playbooks/deprovision.yml` | No change needed |
| `connection: local` | Retain or use `delegate_to: localhost` pattern | `playbooks/provision.yml`, `playbooks/deprovision.yml` | Correct for k8s API interactions |
| `community.kubernetes.*` (if transitively used) | `kubernetes.core.*` | Any transitive dependency | `community.kubernetes` collection was renamed to `kubernetes.core` |

---

## Dependencies

**Collection dependencies** (for `collections/requirements.yml`):
```yaml
collections:
  - name: kubernetes.core
    version: ">=2.4.0"
  - name: ansible.builtin
    # ships with ansible-core, no explicit pin needed
```

> **Note**: The legacy `ansible.kubernetes-modules` Galaxy role and its transitive dependency on the `openshift` Python package must be replaced by the `kubernetes` Python package (≥ 12.0) and optionally `openshift` (≥ 0.13) for OpenShift-specific resource types. These belong in `bindep.txt` / `execution-environment.yml`.

**Role dependencies**: 
- `ansible.kubernetes-modules` — **REMOVE** (EOL, replaced by `kubernetes.core` collection)

**External packages / Python requirements**:
- `kubernetes >= 12.0.0` (pip) — required by `kubernetes.core`
- `openshift >= 0.13.1` (pip) — required for OpenShift-specific API resources (`Route`, `DeploymentConfig`)
- `PyYAML >= 3.11` (pip)
- `oc` CLI — **REMOVE dependency** (currently required by the `shell: oc create configmap` task; eliminated by migrating to `kubernetes.core.k8s`)

**Services managed**:
- No OS-level services managed (all operations are Kubernetes API calls)
- Kubernetes/OpenShift resources lifecycle-managed: `DeploymentConfig`, `Service`, `Route`, `ConfigMap`

---

## Template Modernization

### `roles/provision-nginx-oss-apb/templates/default.conf.j2`

1. **Bare boolean test `{% if lb %}`**: When `lb` is passed as a string (e.g., from an Ansible survey or APB parameter), `"false"` is truthy in Jinja2. Change to:
   ```jinja2
   {% if lb | bool %}
   ```

2. **Reserved variable name `list`**: `{% set list = server.split(', ') %}` shadows the Python/Jinja2 built-in `list`. Rename to:
   ```jinja2
   {% set server_list = server.split(', ') %}
   {% for ip in server_list %}
   ```

3. **Missing default guards**: `server` and `lb_method` are referenced without defaults. Add guards:
   ```jinja2
   {% set server_list = (server | default('')) .split(', ') %}
   ```
   and:
   ```jinja2
   {% if lb_method | default('round_robin') != 'round_robin' %}
       {{ lb_method | default('round_robin') }}{{ ' $request_uri' if lb_method == 'hash' }};
   ```

4. **No deprecated Jinja2 tests found** (`is undefined` etc.) — template is otherwise clean.

5. **ConfigMap inline approach** (recommended): Rather than writing to `/tmp/default.conf` and shelling out to `oc create configmap`, the modernized role should use:
   ```yaml
   - name: Create NGINX ConfigMap
     kubernetes.core.k8s:
       state: present
       definition:
         apiVersion: v1
         kind: ConfigMap
         metadata:
           name: nginx-conf
           namespace: "{{ namespace }}"
         data:
           nginx-conf: "{{ lookup('ansible.builtin.template', 'default.conf.j2') }}"
   ```
   This eliminates both the `ansible.builtin.template` task writing to `/tmp` and the `ansible.builtin.shell` task entirely.

---

## Argument Specification

The following variables (currently defined only in `apb.yml`) must be migrated to `meta/argument_specs.yml` for both roles:

| Variable | Type | Default | Required | Description |
|---|---|---|---|---|
| `namespace` | `str` | _(none)_ | **yes** | OpenShift/Kubernetes namespace to deploy into |
| `lb` | `bool` | `false` | no | Enable upstream load balancing in NGINX config |
| `server` | `str` | `""` | no (required when `lb: true`) | Comma-separated list of upstream server IPs with port 8080 |
| `lb_method` | `str` | `"round_robin"` | no | Load balancing algorithm: `round_robin`, `least_conn`, `ip_hash`, `hash` |

**Proposed `meta/argument_specs.yml`** (for `provision-nginx-oss-apb`):
```yaml
argument_specs:
  main:
    short_description: Provision NGINX OSS on OpenShift
    description:
      - Deploys a single NGINX OSS instance to an OpenShift cluster via DeploymentConfig,
        Service, Route, and ConfigMap resources.
    options:
      namespace:
        type: str
        required: true
        description: OpenShift namespace to deploy resources into.
      lb:
        type: bool
        required: false
        default: false
        description: Enable NGINX upstream load balancing.
      server:
        type: str
        required: false
        default: ""
        description: >
          Comma-separated list of upstream backend servers (with port 8080).
          Required when lb is true.
      lb_method:
        type: str
        required: false
        default: round_robin
        choices:
          - round_robin
          - least_conn
          - ip_hash
          - hash
        description: NGINX load balancing algorithm.
```

---

## Execution Environment Modernization

The legacy `Dockerfile` (based on `ansibleplaybookbundle/apb-base`) must be replaced with a modern Ansible Execution Environment definition.

**`execution-environment.yml`**:
```yaml
version: 1
build_arg_defaults:
  EE_BASE_IMAGE: 'quay.io/ansible/ansible-runner:latest'

ansible_config: 'ansible.cfg'

dependencies:
  galaxy: collections/requirements.yml
  python: requirements.txt
  system: bindep.txt
```

**`requirements.txt`** (Python dependencies):
```
kubernetes>=12.0.0
openshift>=0.13.1
PyYAML>=3.11
```

**`bindep.txt`** (system-level dependencies):
```
python3-devel [platform:rpm]
gcc [platform:rpm]
```

**`collections/requirements.yml`**:
```yaml
collections:
  - name: kubernetes.core
    version: ">=2.4.0"
```

---

## Checks for the Migration

**Files to verify** (all files in the modernized role, relative to repo root):
```
playbooks/provision.yml
playbooks/deprovision.yml
roles/provision-nginx-oss-apb/tasks/main.yml
roles/provision-nginx-oss-apb/templates/default.conf.j2
roles/provision-nginx-oss-apb/meta/argument_specs.yml
roles/provision-nginx-oss-apb/defaults/main.yml
roles/deprovision-nginx-oss-apb/tasks/main.yml
roles/deprovision-nginx-oss-apb/meta/argument_specs.yml
collections/requirements.yml
execution-environment.yml
requirements.txt
bindep.txt
```

**Services to check**:
- OpenShift `DeploymentConfig` `nginx-oss-apb` in target namespace — verify `AVAILABLE` replicas = 1
- Kubernetes `Service` `nginx-oss-apb` — verify `ClusterIP` assigned and port 80→8080 mapping
- OpenShift `Route` `nginx-oss-apb` — verify `HOST/PORT` is populated and reachable
- Kubernetes `ConfigMap` `nginx-conf` — verify `nginx-conf` key contains valid rendered NGINX config

**Templates to validate**:
- `roles/provision-nginx-oss-apb/templates/default.conf.j2` — validate rendered output for both `lb: false` and `lb: true` scenarios; confirm `lb | bool` filter is applied; confirm `server_list` variable rename; confirm `lb_method` default guard

---

## Pre-flight Checks

```bash
# 1. Verify kubernetes.core collection is installed
ansible-galaxy collection list | grep kubernetes.core

# 2. Verify Python kubernetes client is available in the EE / venv
python3 -c "import kubernetes; print(kubernetes.__version__)"

# 3. Verify OpenShift Python client (for Route/DeploymentConfig resources)
python3 -c "import openshift; print(openshift.__version__)"

# 4. Verify cluster connectivity and namespace exists
kubectl get namespace "${NAMESPACE}" || oc get project "${NAMESPACE}"

# 5. Dry-run the provision playbook (check mode)
ansible-playbook playbooks/provision.yml \
  -e namespace=test-nginx \
  -e lb=false \
  --check --diff

# 6. Dry-run with load balancing enabled
ansible-playbook playbooks/provision.yml \
  -e namespace=test-nginx \
  -e lb=true \
  -e server="10.0.0.1:8080, 10.0.0.2:8080" \
  -e lb_method=least_conn \
  --check --diff

# 7. Validate ConfigMap content after provision
kubectl get configmap nginx-conf -n "${NAMESPACE}" \
  -o jsonpath='{.data.nginx-conf}'

# 8. Validate NGINX pod is running
kubectl get pods -n "${NAMESPACE}" -l service=nginx-oss-apb

# 9. Validate Route is accessible
curl -I "$(kubectl get route nginx-oss-apb -n ${NAMESPACE} \
  -o jsonpath='{.spec.host}')"

# 10. Idempotency check — re-run provision, expect zero changes
ansible-playbook playbooks/provision.yml \
  -e namespace=test-nginx \
  -e lb=false

# 11. Dry-run deprovision
ansible-playbook playbooks/deprovision.yml \
  -e namespace=test-nginx \
  --check --diff

# 12. Verify template renders correctly for all lb_method values
for method in round_robin least_conn ip_hash hash; do
  ansible -m ansible.builtin.template \
    -a "src=roles/provision-nginx-oss-apb/templates/default.conf.j2 dest=/tmp/test-${method}.conf" \
    -e "lb=true server='10.0.0.1:8080' lb_method=${method}" \
    localhost
done
```

---

## Summary of Critical Breaking Changes

| Priority | Issue | Impact | Action |
|---|---|---|---|
| 🔴 **Critical** | `openshift_v1_deployment_config`, `k8s_v1_service`, `openshift_v1_route` are tombstoned | Role completely non-functional on any modern Ansible | Replace all three with `kubernetes.core.k8s` + full manifest `definition:` blocks |
| 🔴 **Critical** | `ansible.kubernetes-modules` role is EOL/removed | Playbook fails at role load | Remove from both playbooks; add `kubernetes.core` to `collections/requirements.yml` |
| 🔴 **Critical** | `shell: oc create configmap` is not idempotent | Re-runs fail with "already exists" error | Replace with `kubernetes.core.k8s` ConfigMap definition using `lookup('ansible.builtin.template', ...)` |
| 🟠 **High** | All module parameter structures must be rebuilt | `kubernetes.core.k8s` uses `definition:` manifest, not flattened snake_case params | Full task rewrites required for all 5 provision tasks and 3 deprovision tasks |
| 🟠 **High** | APB packaging (`Dockerfile`, `apb.yml`) is EOL | Cannot be deployed via modern Ansible Automation Platform | Replace with EE (`execution-environment.yml`) and `meta/argument_specs.yml` |
| 🟡 **Medium** | `{% if lb %}` bare boolean in template | String `"false"` is truthy — load balancing always enabled when `lb` is a string | Add `\| bool` filter |
| 🟡 **Medium** | `{% set list = ... %}` shadows built-in | Potential Jinja2 rendering errors in strict environments | Rename to `server_list` |
| 🟢 **Low** | Missing FQCN on `template:` | Lint warnings, future deprecation | Change to `ansible.builtin.template:` |
| 🟢 **Low** | Missing `mode:` on template task | File permission lint warning | Add `mode: '0644'` |
| 🟢 **Low** | No `defaults/main.yml` or `meta/argument_specs.yml` | No variable documentation or validation | Create both files |