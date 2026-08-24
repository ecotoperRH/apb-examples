---
source-path: hastebin-apb
---

Now I have a complete picture of the role. Let me write the full migration plan.

---

# Migration Plan: hastebin-apb

**TLDR**: `hastebin-apb` is a legacy **Ansible Playbook Bundle (APB)** that provisions and deprovisions the [Hastebin](https://github.com/toptal/haste-server) paste-bin web application onto an OpenShift cluster. It uses the now-defunct APB framework (`ansibleplaybookbundle/apb-base` Docker image, `apb.yml` spec file, `ansible.kubernetes-modules` and `ansibleplaybookbundle.asb-modules` roles) together with tombstoned OpenShift/Kubernetes modules (`openshift_v1_deployment_config`, `k8s_v1_service`, `openshift_v1_route`) from the old `ansible.kubernetes-modules` collection. The entire APB packaging layer must be replaced with a standard Ansible role/collection structure, all tombstoned modules must be migrated to `kubernetes.core` equivalents, bare Jinja2 variables in the template must be wrapped, and a proper `meta/argument_specs.yml` must be generated.

---

## Service Type and Configuration

**Service Type**: Application Deployment / Container Orchestration (OpenShift / Kubernetes)

**Key Operations**:
- Render a Hastebin JSON configuration file from a Jinja2 template (`config.js.j2`)
- Create an OpenShift/Kubernetes ConfigMap from the rendered file using a raw `oc` shell command
- Create an OpenShift DeploymentConfig with two containers: `hastebin` (port 7777) and `memcached` (port 11211), backed by the ConfigMap volume
- Create a Kubernetes Service exposing port 80 → 7777
- Create an OpenShift Route exposing the service externally
- Deprovision (delete) all of the above resources (currently commented-out stub tasks)

---

## File Structure

**IMPORTANT: All paths are relative to the repository root `hastebin-apb/`.**

**Top-level / APB packaging files:**
```
Dockerfile
apb.yml
```

**Playbook files:**
```
playbooks/provision.yml
playbooks/deprovision.yml
```

**Provision role – Tasks:**
```
roles/provision-hastebin-apb/tasks/main.yml
```

**Provision role – Templates:**
```
roles/provision-hastebin-apb/templates/config.js.j2
```

**Deprovision role – Tasks:**
```
roles/deprovision-hastebin-apb/tasks/main.yml
```

---

## Module Explanation

The role performs operations in this order:

### 1. **Provision playbook entry point** (`playbooks/provision.yml`)
- Sets `hosts: localhost`, `gather_facts: false`, `connection: local` — these are fine and should be kept.
- Loads three roles in order:
  1. `ansible.kubernetes-modules` with `install_python_requirements: no` — **tombstoned**; this entire role must be removed. Its modules are now in `kubernetes.core`.
  2. `ansibleplaybookbundle.asb-modules` — **tombstoned APB framework role**; must be removed entirely.
  3. `provision-hastebin-apb` with `playbook_debug: false` — the actual application role; keep and modernize.
- Ansible module mapping: role-level dependency `ansible.kubernetes-modules` → `kubernetes.core` collection (installed via `collections/requirements.yml`); `ansibleplaybookbundle.asb-modules` → **remove** (no modern equivalent needed).

### 2. **Deprovision playbook entry point** (`playbooks/deprovision.yml`)
- Mirrors `provision.yml` structure; same tombstoned role dependencies apply.
- Loads `deprovision-hastebin-apb` role.

### 3. **Provision role tasks** (`roles/provision-hastebin-apb/tasks/main.yml`)

#### Step 1 – Render config template
```yaml
- name: Create hastebin config from template
  template:
    src: config.js.j2
    dest: /tmp/config.js
```
- Uses short module name `template` → must become `ansible.builtin.template`.
- Missing `mode:` parameter → add `mode: '0644'`.
- Writing to `/tmp/config.js` on the controller is a workaround for the subsequent `shell` command; in the modern role this intermediate file can be eliminated entirely (see Step 2).

#### Step 2 – Create ConfigMap via raw shell
```yaml
- name: Create hastebin configmap
  shell: oc create configmap haste-config --from-file=haste-config=/tmp/config.js
```
- Uses short module name `shell` → must become `ansible.builtin.shell`.
- **No `changed_when:`** — idempotency violation; the command will always report `changed`.
- **No `creates:` or idempotency guard** — running twice will fail with "already exists".
- **Tombstoned pattern**: raw `oc` CLI call should be replaced with `kubernetes.core.k8s` using a `ConfigMap` manifest, making the intermediate `/tmp/config.js` file and the `ansible.builtin.template` write step unnecessary.
- Modern equivalent:
  ```yaml
  - name: Create hastebin configmap
    kubernetes.core.k8s:
      state: present
      definition:
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: haste-config
          namespace: "{{ namespace }}"
        data:
          config.js: "{{ lookup('ansible.builtin.template', 'config.js.j2') }}"
  ```

#### Step 3 – Create DeploymentConfig
```yaml
- name: create deployment config
  openshift_v1_deployment_config:
    name: hastebin
    namespace: '{{ namespace }}'
    ...
```
- **Tombstoned module**: `openshift_v1_deployment_config` was part of `ansible.kubernetes-modules` (deprecated ~2018, removed). No direct 1:1 replacement exists in `kubernetes.core` because OpenShift `DeploymentConfig` is an OpenShift-specific resource.
- **Migration path**: Replace with `kubernetes.core.k8s` using a full `DeploymentConfig` manifest (or migrate to a standard Kubernetes `Deployment` if OpenShift 4.x+ is the target, since `DeploymentConfig` is deprecated in OCP 4.14+).
- **Parameter drift**: The legacy module used flattened parameters (`spec_template_metadata_labels`, `containers`, `volumes` at top level). The modern `kubernetes.core.k8s` requires a full Kubernetes API object under `definition:`.
- Boolean `False` in `apb.yml` (`bindable: False`) → `false`.

#### Step 4 – Create Service
```yaml
- name: create hastebin service
  k8s_v1_service:
    name: hastebin
    namespace: '{{ namespace }}'
    ...
```
- **Tombstoned module**: `k8s_v1_service` → `kubernetes.core.k8s` with `kind: Service` manifest.
- **Parameter drift**: Flattened `labels`, `selector`, `ports` parameters → must be expressed as a full `Service` manifest under `definition:`.

#### Step 5 – Create Route
```yaml
- name: create hastebin route
  openshift_v1_route:
    name: hastebin
    namespace: '{{ namespace }}'
    ...
```
- **Tombstoned module**: `openshift_v1_route` → `kubernetes.core.k8s` with `kind: Route` manifest (OpenShift CRD).
- **Parameter drift**: `to_name` and `spec_port_target_port` are legacy flattened parameters → must be expressed as a full `Route` manifest.

### 4. **Deprovision role tasks** (`roles/deprovision-hastebin-apb/tasks/main.yml`)
- The entire file body is **commented out** — no active tasks exist.
- The commented tasks use the same tombstoned modules (`openshift_v1_route`, `k8s_v1_service`, `openshift_v1_deployment_config`) with `state: absent`.
- **Migration**: Uncomment and rewrite all three tasks using `kubernetes.core.k8s` with `state: absent`.

### 5. **Jinja2 template** (`roles/provision-hastebin-apb/templates/config.js.j2`)
- Contains bare (unbraced) Jinja2 variable interpolations: `{{ hastebin_port }}`, `{{ key_length }}`, `{{ max_length }}` — these are actually correctly double-braced in the file, but the values are rendered directly into a JSON file without quoting, which is correct for integer types.
- `recompressStaticAssets: true` — this is a JSON boolean, not Ansible YAML, so it is fine as-is.
- No deprecated Jinja2 tests found.
- Template is otherwise clean; no changes needed beyond ensuring variables are defined.

### 6. **APB spec file** (`apb.yml`)
- **Tombstoned**: The entire APB framework (`apb.yml`, `Dockerfile` based on `apb-base`) is obsolete. The OpenShift Ansible Broker (OAB) was removed in OpenShift 4.
- **Migration**: Replace with standard Ansible role `defaults/main.yml` (for parameters), `meta/main.yml`, and `meta/argument_specs.yml`. The `apb.yml` parameters map directly to role variables.

### 7. **Dockerfile**
- **Tombstoned**: Based on `ansibleplaybookbundle/apb-base` which no longer exists/is maintained.
- **Migration**: Replace with an Ansible Execution Environment (EE) definition (`execution-environment.yml` + `bindep.txt`) for use with `ansible-builder`, or simply remove if the role is consumed as a standard collection role.

---

## Modernization Mapping

| Legacy Pattern | Modern Equivalent | Files Affected | Notes |
|---|---|---|---|
| `ansible.kubernetes-modules` role dependency | `kubernetes.core` collection via `collections/requirements.yml` | `playbooks/provision.yml`, `playbooks/deprovision.yml` | Entire role removed; collection installed instead |
| `ansibleplaybookbundle.asb-modules` role dependency | **Remove entirely** | `playbooks/provision.yml`, `playbooks/deprovision.yml` | APB framework is EOL; no modern equivalent |
| `openshift_v1_deployment_config:` | `kubernetes.core.k8s:` with `kind: DeploymentConfig` or `kind: Deployment` manifest | `roles/provision-hastebin-apb/tasks/main.yml` | **Tombstoned module + parameter drift**: all flattened params → full manifest under `definition:` |
| `k8s_v1_service:` | `kubernetes.core.k8s:` with `kind: Service` manifest | `roles/provision-hastebin-apb/tasks/main.yml` | **Tombstoned module + parameter drift**: `labels`, `selector`, `ports` → full manifest |
| `openshift_v1_route:` | `kubernetes.core.k8s:` with `kind: Route` manifest | `roles/provision-hastebin-apb/tasks/main.yml`, `roles/deprovision-hastebin-apb/tasks/main.yml` | **Tombstoned module + parameter drift**: `to_name`, `spec_port_target_port` → full manifest |
| `template:` (short name) | `ansible.builtin.template:` | `roles/provision-hastebin-apb/tasks/main.yml` | FQCN required |
| `shell:` (short name) | Replaced by `kubernetes.core.k8s:` ConfigMap | `roles/provision-hastebin-apb/tasks/main.yml` | Raw `oc` CLI call eliminated; no `changed_when:` was present |
| `shell: oc create configmap ...` (no `changed_when:`) | `kubernetes.core.k8s:` with `state: present` (idempotent) | `roles/provision-hastebin-apb/tasks/main.yml` | Idempotency violation fixed by switching to declarative module |
| `template` task writing to `/tmp/config.js` | Inline `lookup('ansible.builtin.template', ...)` inside `kubernetes.core.k8s` definition | `roles/provision-hastebin-apb/tasks/main.yml` | Eliminates temp file on controller |
| Missing `mode:` on `template:` task | `mode: '0644'` | `roles/provision-hastebin-apb/tasks/main.yml` | File permission best practice (if temp file approach is kept) |
| Commented-out deprovision tasks | Uncommented `kubernetes.core.k8s:` tasks with `state: absent` | `roles/deprovision-hastebin-apb/tasks/main.yml` | All three resources must be actively deprovisioned |
| `apb.yml` APB spec | `defaults/main.yml` + `meta/argument_specs.yml` | New files | APB framework replaced by standard role variables |
| `Dockerfile` (apb-base) | `execution-environment.yml` + `bindep.txt` | New files | EE replaces APB container packaging |
| `bindable: False` in `apb.yml` | N/A (APB concept removed) | `apb.yml` | No equivalent needed |
| `playbook_debug: false` role variable | Standard role variable in `defaults/main.yml` | `playbooks/provision.yml`, `playbooks/deprovision.yml` | Keep as optional debug flag |
| `'{{ namespace }}'` (single-quoted Jinja2) | `"{{ namespace }}"` (double-quoted) | All task files | YAML best practice for Jinja2 strings |
| `community.kubernetes.*` / `ansible.kubernetes-modules` | `kubernetes.core.*` | All task files | Collection was renamed from `community.kubernetes` to `kubernetes.core` |

---

## Dependencies

**Collection dependencies** (for `collections/requirements.yml`):
```yaml
collections:
  - name: kubernetes.core
    version: ">=2.4.0"
  - name: ansible.builtin
    # ships with ansible-core, no install needed
```

> **Note**: If OpenShift-specific resources (`Route`, `DeploymentConfig`) are retained, the `kubernetes.core.k8s` module handles them generically via the OpenShift API server — no separate OpenShift collection is strictly required, but `redhat.openshift` (formerly `community.okd`) provides convenience modules and should be considered:
```yaml
  - name: redhat.openshift
    version: ">=2.3.0"
```

**Role dependencies** (from `meta/main.yml` — to be created):
- None (all former role dependencies replaced by collection installs)

**External packages / system dependencies**:
- `openshift` Python library (`kubernetes` pip package ≥ 12.0) — required by `kubernetes.core.k8s`
- `python3-openshift` or `pip install kubernetes openshift` on the execution host

**Services managed**:
- OpenShift/Kubernetes resources (not OS services):
  - `ConfigMap/haste-config` (namespace: `{{ namespace }}`)
  - `DeploymentConfig/hastebin` or `Deployment/hastebin` (namespace: `{{ namespace }}`)
  - `Service/hastebin` (namespace: `{{ namespace }}`)
  - `Route/hastebin` (namespace: `{{ namespace }}`)
- Container images pulled at deploy time:
  - `docker.io/dymurray/hastebin:latest`
  - `docker.io/modularitycontainers/memcached:latest`

---

## Template Modernization

**`roles/provision-hastebin-apb/templates/config.js.j2`**:

| Issue | Detail | Action |
|---|---|---|
| Bare integer interpolation | `{{ hastebin_port }}`, `{{ key_length }}`, `{{ max_length }}` are rendered directly into JSON without type guards | Add `\| int` filter to enforce integer type: `{{ hastebin_port \| int }}` |
| No default values in template | If variables are undefined, template rendering fails with an unhelpful error | Add Jinja2 defaults: `{{ hastebin_port \| default(7777) \| int }}` |
| `recompressStaticAssets: true` | JSON boolean — correct as-is, not an Ansible YAML boolean | No change needed |
| Storage host hardcoded to `0.0.0.0` | Memcached sidecar is in the same pod; should use `localhost` or a variable | Change to `"localhost"` or `{{ memcached_host \| default('localhost') }}` |

**Modernized template excerpt**:
```json
{
  "host": "0.0.0.0",
  "port": {{ hastebin_port | default(7777) | int }},
  "keyLength": {{ key_length | default(10) | int }},
  "maxLength": {{ max_length | default(400000) | int }},
  ...
  "storage": {
    "type": "memcached",
    "host": "localhost",
    "port": 11211
  }
}
```

---

## Argument Specification

The following variables should be declared in `meta/argument_specs.yml` (new file to create):

| Variable | Type | Default | Required | Source | Description |
|---|---|---|---|---|---|
| `namespace` | `str` | — | **yes** | runtime | Kubernetes/OpenShift namespace to deploy into |
| `hastebin_port` | `int` | `7777` | no | `apb.yml` plan parameter | Container port Hastebin listens on |
| `max_length` | `int` | `400000` | no | `apb.yml` plan parameter | Maximum length of a Hastebin paste entry |
| `key_length` | `int` | `10` | no | `apb.yml` plan parameter | Length of the generated Hastebin key |
| `playbook_debug` | `bool` | `false` | no | playbook role var | Enable debug output during playbook execution |
| `hastebin_image` | `str` | `docker.io/dymurray/hastebin:latest` | no | new | Hastebin container image (parameterize hardcoded value) |
| `memcached_image` | `str` | `docker.io/modularitycontainers/memcached:latest` | no | new | Memcached container image (parameterize hardcoded value) |
| `hastebin_replicas` | `int` | `1` | no | new | Number of Hastebin pod replicas |

**`meta/argument_specs.yml`** skeleton:
```yaml
argument_specs:
  main:
    short_description: Provision Hastebin on OpenShift/Kubernetes
    description:
      - Deploys the Hastebin paste-bin application with a Memcached backend
        onto an OpenShift or Kubernetes cluster.
    options:
      namespace:
        type: str
        required: true
        description: Target Kubernetes/OpenShift namespace
      hastebin_port:
        type: int
        default: 7777
        description: Port Hastebin listens on inside the container
      max_length:
        type: int
        default: 400000
        description: Maximum character length of a paste entry
      key_length:
        type: int
        default: 10
        description: Length of the randomly generated paste key
      hastebin_image:
        type: str
        default: "docker.io/dymurray/hastebin:latest"
        description: Hastebin container image reference
      memcached_image:
        type: str
        default: "docker.io/modularitycontainers/memcached:latest"
        description: Memcached container image reference
      hastebin_replicas:
        type: int
        default: 1
        description: Number of Hastebin pod replicas
```

---

## Checks for the Migration

**Files to create/modify in the modern role**:

```
collections/requirements.yml                          # NEW – kubernetes.core + redhat.openshift
execution-environment.yml                             # NEW – replaces Dockerfile/apb-base
bindep.txt                                            # NEW – system package deps for EE
playbooks/provision.yml                               # MODIFY – remove APB role deps
playbooks/deprovision.yml                             # MODIFY – remove APB role deps
roles/provision-hastebin-apb/tasks/main.yml           # MODIFY – all tombstoned modules replaced
roles/provision-hastebin-apb/templates/config.js.j2   # MODIFY – add | int filters + defaults
roles/provision-hastebin-apb/defaults/main.yml        # NEW – role variable defaults
roles/provision-hastebin-apb/meta/main.yml            # NEW – role metadata
roles/provision-hastebin-apb/meta/argument_specs.yml  # NEW – argument validation
roles/deprovision-hastebin-apb/tasks/main.yml         # MODIFY – uncomment + rewrite tasks
roles/deprovision-hastebin-apb/meta/main.yml          # NEW – role metadata
```

**Files to delete** (APB framework artifacts):
```
Dockerfile        # Replaced by execution-environment.yml
apb.yml           # Replaced by defaults/main.yml + argument_specs.yml
```

**Services / Kubernetes resources to check**:
- `ConfigMap` `haste-config` in target namespace
- `DeploymentConfig` (OCP ≤ 4.13) or `Deployment` (OCP ≥ 4.14 / vanilla k8s) `hastebin`
- `Service` `hastebin`
- `Route` `hastebin` (OpenShift only)

**Templates to validate**:
- `roles/provision-hastebin-apb/templates/config.js.j2` — verify JSON is valid after variable substitution; add `| int` filters

---

## Pre-flight Checks

```bash
# 1. Verify kubernetes.core collection is installed
ansible-galaxy collection list | grep kubernetes.core
# Expected: kubernetes.core  2.x.x

# 2. Verify Python kubernetes library is available
python3 -c "import kubernetes; print(kubernetes.__version__)"
# Expected: 12.x or higher

# 3. Verify cluster connectivity
kubectl cluster-info
# or
oc status

# 4. Verify target namespace exists
kubectl get namespace "${NAMESPACE}"
# or
oc project "${NAMESPACE}"

# 5. Dry-run the provision playbook (check mode)
ansible-playbook playbooks/provision.yml \
  -e namespace=hastebin-test \
  --check --diff

# 6. Validate rendered config template
ansible -m ansible.builtin.template \
  -a "src=roles/provision-hastebin-apb/templates/config.js.j2 dest=/tmp/config-test.js" \
  -e "hastebin_port=7777 key_length=10 max_length=400000" \
  localhost
python3 -m json.tool /tmp/config-test.js   # Must parse without errors

# 7. After provision – verify all resources are Running
kubectl -n "${NAMESPACE}" get deploymentconfig,service,route,configmap -l app=hastebin
kubectl -n "${NAMESPACE}" rollout status dc/hastebin

# 8. After provision – verify Hastebin is reachable
ROUTE=$(oc -n "${NAMESPACE}" get route hastebin -o jsonpath='{.spec.host}')
curl -sf "http://${ROUTE}/" | grep -i hastebin

# 9. Dry-run the deprovision playbook
ansible-playbook playbooks/deprovision.yml \
  -e namespace=hastebin-test \
  --check --diff

# 10. After deprovision – verify all resources are gone
kubectl -n "${NAMESPACE}" get deploymentconfig,service,route,configmap -l app=hastebin
# Expected: No resources found
```

---

## Summary of Critical Migration Risks

| Risk | Severity | Mitigation |
|---|---|---|
| `openshift_v1_deployment_config` / `k8s_v1_service` / `openshift_v1_route` are tombstoned — no drop-in replacement | **HIGH** | Rewrite as full Kubernetes manifest objects under `kubernetes.core.k8s` `definition:` block; significant parameter restructuring required |
| `DeploymentConfig` is deprecated in OpenShift 4.14+ | **MEDIUM** | Migrate to standard `Deployment` if targeting OCP 4.14+; use `DeploymentConfig` only for OCP ≤ 4.13 |
| `shell: oc create configmap` is not idempotent | **HIGH** | Replace with `kubernetes.core.k8s` ConfigMap manifest (idempotent by design) |
| Deprovision role has zero active tasks (all commented out) | **HIGH** | Uncomment and rewrite all three deprovision tasks before the role is production-ready |
| Hardcoded container images (`latest` tag) | **MEDIUM** | Parameterize via `hastebin_image` / `memcached_image` variables with pinned digest tags |
| APB framework (`apb-base`, OAB) is EOL since OpenShift 4.x | **HIGH** | Remove all APB packaging; migrate to standard Ansible role + EE |