---
source-path: nginx-oss-apb
---

Now I have a complete picture of the role. Let me produce the detailed migration specification.

---

# Migration Plan: nginx-oss-apb

**TLDR**: `nginx-oss-apb` is an **Ansible Playbook Bundle (APB)** — a now-deprecated packaging format that ran Ansible inside a Docker container to provision/deprovision NGINX OSS on an OpenShift cluster. It uses tombstoned APB-era modules (`openshift_v1_deployment_config`, `k8s_v1_service`, `openshift_v1_route`, `ansible.kubernetes-modules` role) and a raw `shell: oc create configmap …` call. The migration replaces the entire APB scaffolding with a modern Ansible role/collection structure, swaps all legacy OpenShift/Kubernetes modules for `kubernetes.core.k8s`, eliminates the raw `shell` call with a proper `kubernetes.core.k8s` ConfigMap task, adds FQCN throughout, and introduces `meta/argument_specs.yml`, `execution-environment.yml`, and `collections/requirements.yml`.

---

## Service Type and Configuration

**Service Type**: Kubernetes / OpenShift Workload Provisioner (Web Server — NGINX OSS)

**Key Operations**:
- Render an NGINX `default.conf` from a Jinja2 template (supports optional upstream load-balancing with `round_robin`, `least_conn`, `ip_hash`, or `hash` algorithms)
- Create a Kubernetes ConfigMap (`nginx-conf`) from the rendered config file
- Create an OpenShift `DeploymentConfig` running `docker.io/alessfg/openshift-nginx` on port 8080, mounting the ConfigMap as `/etc/nginx/conf.d`
- Create a Kubernetes `Service` (port 80 → 8080)
- Create an OpenShift `Route` to expose the service externally
- Deprovision: delete the Route, Service, and DeploymentConfig in reverse order

---

## File Structure

**IMPORTANT: All paths are relative to the repository root `nginx-oss-apb/`.**

**Playbooks:**
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
(none — no defaults/ or vars/ directories exist; all variables are injected by the APB runtime via apb.yml)
```

**Meta:**
```
(none — no meta/main.yml exists in either role)
apb.yml   ← APB-specific manifest; replaces meta/main.yml in the modern role
```

**Templates:**
```
roles/provision-nginx-oss-apb/templates/default.conf.j2
```

**Static Files / Project Root:**
```
Dockerfile
README.md
apb.yml
```

---

## Module Explanation

The role performs operations in this order:

### 1. Provision Playbook (`playbooks/provision.yml`)

- Runs on `localhost` with `connection: local` and `gather_facts: false`.
- Loads the legacy `ansible.kubernetes-modules` role first (with `install_python_requirements: no`), which provided the now-tombstoned `openshift_v1_*` and `k8s_v1_*` Python-backed modules.
- Then runs `provision-nginx-oss-apb`.
- **Legacy pattern**: Dependency on `ansible.kubernetes-modules` role → **must be removed**; replaced by the `kubernetes.core` collection.
- **Legacy pattern**: `playbook_debug: false` is an APB-specific role variable with no modern equivalent; drop it.

### 2. `roles/provision-nginx-oss-apb/tasks/main.yml`

**Task 1 — Create DeploymentConfig**
- Module: `openshift_v1_deployment_config` (tombstoned APB-era module from `ansible.kubernetes-modules`)
- Creates an OpenShift `DeploymentConfig` with 1 replica, mounts a ConfigMap volume at `/etc/nginx/conf.d`.
- **Modern equivalent**: `kubernetes.core.k8s` with `definition:` block containing a full `DeploymentConfig` manifest (apiVersion: `apps.openshift.io/v1`, kind: `DeploymentConfig`). Note significant **parameter drift**: the legacy module used flattened snake_case parameters (e.g., `spec_template_metadata_labels`, `restart_policy`, `containers` at top level); the modern module requires a full Kubernetes-style YAML manifest under `definition:`.

**Task 2 — Create Service**
- Module: `k8s_v1_service` (tombstoned APB-era module)
- Creates a `v1/Service` mapping port 80 to container port 8080.
- **Modern equivalent**: `kubernetes.core.k8s` with `definition:` containing `apiVersion: v1`, `kind: Service`.
- **Parameter drift**: `target_port` was a flat parameter; must be expressed as `spec.ports[].targetPort` in the manifest.

**Task 3 — Create Route**
- Module: `openshift_v1_route` (tombstoned APB-era module)
- Creates an OpenShift `Route` pointing to the service.
- **Modern equivalent**: `kubernetes.core.k8s` with `definition:` containing `apiVersion: route.openshift.io/v1`, `kind: Route`.
- **Parameter drift**: `spec_port_target_port` and `to_name` were flat parameters; must be expressed as `spec.port.targetPort` and `spec.to.name` in the manifest.

**Task 4 — Create NGINX config from template**
- Module: `template` (bare short name, no FQCN)
- Renders `default.conf.j2` to `/tmp/default.conf` on the controller node.
- **Missing `mode:`** — no file permission set.
- **Modern equivalent**: `ansible.builtin.template` with `mode: '0644'`.
- In the fully modernized version this intermediate file step can be eliminated entirely — the rendered content can be passed inline to `kubernetes.core.k8s` as the ConfigMap `data:` value using the `lookup('ansible.builtin.template', ...)` filter.

**Task 5 — Create ConfigMap**
- Module: `shell` (bare short name) running `oc create configmap nginx-conf --from-file=nginx-conf=/tmp/default.conf`
- **Critical issues**:
  - Uses raw `shell:` with no `changed_when:` → always reports `changed`, breaks idempotency.
  - Depends on `oc` CLI being present on the controller.
  - Will fail on re-run if the ConfigMap already exists.
- **Modern equivalent**: `kubernetes.core.k8s` with `definition:` containing `apiVersion: v1`, `kind: ConfigMap`, and `data.nginx-conf: "{{ lookup('ansible.builtin.template', 'default.conf.j2') }}"`. This is fully idempotent and requires no `oc` CLI.

### 3. `roles/deprovision-nginx-oss-apb/tasks/main.yml`

**Task 1 — Delete Route**
- Module: `openshift_v1_route` with `state: absent`
- **Modern equivalent**: `kubernetes.core.k8s` with `state: absent`, `api_version: route.openshift.io/v1`, `kind: Route`.

**Task 2 — Delete Service**
- Module: `k8s_v1_service` with `state: absent`
- **Modern equivalent**: `kubernetes.core.k8s` with `state: absent`, `api_version: v1`, `kind: Service`.

**Task 3 — Delete DeploymentConfig**
- Module: `openshift_v1_deployment_config` with `state: absent`
- **Modern equivalent**: `kubernetes.core.k8s` with `state: absent`, `api_version: apps.openshift.io/v1`, `kind: DeploymentConfig`.

### 4. Template (`roles/provision-nginx-oss-apb/templates/default.conf.j2`)

- Uses `{% if lb %}` / `{% if lb_method != 'round_robin' %}` conditionals and a `{% set list = server.split(', ') %}` / `{% for ip in list %}` loop.
- **Issue**: `lb` is used as a bare boolean in a Jinja2 `{% if %}` block — this is fine in templates but the variable must be passed as a proper boolean (not a string `"false"`).
- **Issue**: `{{ lb_method }}` and `{{ ip }}` are bare variable references — acceptable in `.j2` templates (not Ansible YAML), so no quoting change needed here.
- **Issue**: `{{ ' $request_uri' if lb_method == 'hash' }}` — valid Jinja2 inline conditional, no change needed.
- **Improvement**: The `server.split(', ')` approach is fragile (depends on exact spacing). In the modern role, `server` should be documented as accepting either a list or a comma-separated string, with a `| split(',') | map('trim') | list` filter applied defensively.

### 5. `apb.yml` (APB Manifest → replaces with `meta/argument_specs.yml`)

- Defines three user-facing parameters: `lb` (boolean, default `false`), `server` (string), `lb_method` (enum).
- In the modern role this becomes `meta/argument_specs.yml` and optionally a `defaults/main.yml`.

---

## Modernization Mapping

| Legacy Pattern | Modern Equivalent | Files Affected | Notes |
|---|---|---|---|
| `openshift_v1_deployment_config:` | `kubernetes.core.k8s:` with full manifest | `roles/provision-nginx-oss-apb/tasks/main.yml`, `roles/deprovision-nginx-oss-apb/tasks/main.yml` | Tombstoned module; massive parameter drift — flat params → nested YAML manifest |
| `k8s_v1_service:` | `kubernetes.core.k8s:` with full manifest | `roles/provision-nginx-oss-apb/tasks/main.yml`, `roles/deprovision-nginx-oss-apb/tasks/main.yml` | Tombstoned module; `target_port` → `spec.ports[].targetPort` |
| `openshift_v1_route:` | `kubernetes.core.k8s:` with full manifest | `roles/provision-nginx-oss-apb/tasks/main.yml`, `roles/deprovision-nginx-oss-apb/tasks/main.yml` | Tombstoned module; `spec_port_target_port` → `spec.port.targetPort`; `to_name` → `spec.to.name` |
| `template:` (bare) | `ansible.builtin.template:` | `roles/provision-nginx-oss-apb/tasks/main.yml` | FQCN required |
| `shell:` (bare) | `kubernetes.core.k8s:` (ConfigMap with inline template lookup) | `roles/provision-nginx-oss-apb/tasks/main.yml` | Eliminates `oc` CLI dependency; makes task idempotent |
| `shell: oc create configmap …` (no `changed_when:`) | `kubernetes.core.k8s:` (idempotent) | `roles/provision-nginx-oss-apb/tasks/main.yml` | Idempotency fix; removes CLI dependency |
| `template:` task writing to `/tmp/default.conf` | Inline `lookup('ansible.builtin.template', 'default.conf.j2')` in ConfigMap `data:` | `roles/provision-nginx-oss-apb/tasks/main.yml` | Eliminates ephemeral temp file; no `mode:` needed |
| `template:` missing `mode:` | `mode: '0644'` | `roles/provision-nginx-oss-apb/tasks/main.yml` | File permission hygiene (if temp-file approach is retained) |
| `role: ansible.kubernetes-modules` | Remove entirely | `playbooks/provision.yml`, `playbooks/deprovision.yml` | Replaced by `kubernetes.core` collection |
| `playbook_debug: false` (APB role var) | Remove | `playbooks/provision.yml`, `playbooks/deprovision.yml` | APB-specific, no modern equivalent |
| APB `Dockerfile` + `apb.yml` | `execution-environment.yml` + `meta/argument_specs.yml` | `Dockerfile`, `apb.yml` | APB packaging → Ansible Execution Environment |
| `spec_template_metadata_labels:` (flat param) | `spec.template.metadata.labels:` in manifest `definition:` | `roles/provision-nginx-oss-apb/tasks/main.yml` | Parameter drift for `kubernetes.core.k8s` |
| `restart_policy: Always` (flat param) | `spec.template.spec.restartPolicy: Always` in manifest | `roles/provision-nginx-oss-apb/tasks/main.yml` | Parameter drift |
| `containers:` at task top level | `spec.template.spec.containers:` in manifest | `roles/provision-nginx-oss-apb/tasks/main.yml` | Parameter drift |
| `volumes:` at task top level | `spec.template.spec.volumes:` in manifest | `roles/provision-nginx-oss-apb/tasks/main.yml` | Parameter drift |
| `spec_port_target_port:` (flat param) | `spec.port.targetPort:` in Route manifest | `roles/provision-nginx-oss-apb/tasks/main.yml`, `roles/deprovision-nginx-oss-apb/tasks/main.yml` | Parameter drift |
| `to_name:` (flat param) | `spec.to.name:` in Route manifest | `roles/provision-nginx-oss-apb/tasks/main.yml` | Parameter drift |
| `server.split(', ')` in template | `server \| split(',') \| map('trim') \| list` (or pre-process in task) | `roles/provision-nginx-oss-apb/templates/default.conf.j2` | Defensive whitespace handling |
| No `meta/main.yml` | Create `meta/main.yml` with collection dependencies | (new file) | Role metadata required |
| No `meta/argument_specs.yml` | Create from `apb.yml` parameters | (new file) | Role input validation |
| No `defaults/main.yml` | Create with `lb`, `server`, `lb_method` defaults | (new file) | Variable defaults |
| No `collections/requirements.yml` | Create with `kubernetes.core` | (new file) | Collection dependency declaration |
| No `execution-environment.yml` | Create EE definition | (new file) | Replaces APB `Dockerfile` |

---

## Dependencies

**Collection dependencies** (for `collections/requirements.yml`):
```yaml
collections:
  - name: kubernetes.core
    version: ">=2.4.0"
  - name: ansible.utils
    version: ">=2.10.0"
```

> **Note**: `community.kubernetes` is the legacy name for `kubernetes.core`. All `community.kubernetes.*` references must be migrated to `kubernetes.core.*`.

**Role dependencies**: The legacy `ansible.kubernetes-modules` role dependency must be **removed entirely**. It is superseded by the `kubernetes.core` collection.

**External packages / binaries**:
- `oc` CLI (OpenShift client) — currently required by the `shell: oc create configmap …` task. **Must be eliminated** by replacing with `kubernetes.core.k8s`. If `oc` is still needed for other operations, add it to `bindep.txt`.
- Python packages required by `kubernetes.core`: `kubernetes`, `openshift`, `PyYAML` (add to EE `requirements.txt`).

**Services managed**:
- No OS-level services are managed (this is a Kubernetes/OpenShift workload provisioner).
- Kubernetes/OpenShift resources managed: `DeploymentConfig` (apps.openshift.io/v1), `Service` (v1), `Route` (route.openshift.io/v1), `ConfigMap` (v1).

**Container image used**: `docker.io/alessfg/openshift-nginx` (runs NGINX on port 8080 for OpenShift non-root compatibility).

---

## Template Modernization

**`roles/provision-nginx-oss-apb/templates/default.conf.j2`**:

1. **`lb` boolean handling**: The template uses `{% if lb %}` directly. When `lb` is passed as the string `"false"` (which APB runtimes sometimes do), this evaluates as truthy. In the modern role, ensure `lb` is always a native boolean. In the task that passes the template, use `lb | bool` if there is any risk of string injection:
   ```jinja2
   {% if lb | bool %}
   ```

2. **`server.split(', ')` fragility**: The current split assumes exactly one space after each comma. Replace with a more robust approach:
   ```jinja2
   {% set server_list = server.split(',') | map('trim') | list %}
   {% for ip in server_list %}
       server {{ ip }};
   {% endfor %}
   ```
   And remove the `{% set list = server.split(', ') %}` line (also avoids shadowing the Python built-in `list`; rename to `server_list`).

3. **Variable name `list`**: `{% set list = … %}` shadows the Jinja2 built-in `list` filter. Rename to `server_list` or `upstream_servers`.

4. **No deprecated Jinja2 tests found** — `is undefined` / `is not defined` patterns are not present.

5. **No Python 2-specific string operations** beyond the `split()` call addressed above.

---

## Argument Specification

The following variables (sourced from `apb.yml`) should be declared in `meta/argument_specs.yml`:

| Variable | Type | Default | Required | Description |
|---|---|---|---|---|
| `namespace` | `str` | _(none)_ | **yes** | Target OpenShift/Kubernetes namespace for all resources |
| `lb` | `bool` | `false` | no | Enable upstream load balancing in NGINX config |
| `server` | `str` | `""` | no (required when `lb: true`) | Comma-separated list of upstream server IPs with port 8080 |
| `lb_method` | `str` | `round_robin` | no | Load balancing algorithm: `round_robin`, `least_conn`, `ip_hash`, or `hash` |

**`meta/argument_specs.yml` skeleton**:
```yaml
argument_specs:
  main:
    short_description: Provision NGINX OSS on OpenShift/Kubernetes
    description:
      - Deploys a single NGINX OSS instance as an OpenShift DeploymentConfig
        with optional upstream load balancing.
    options:
      namespace:
        type: str
        required: true
        description: Target OpenShift/Kubernetes namespace.
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
          Comma-separated list of upstream backend servers (IP:8080).
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
        description: NGINX upstream load balancing algorithm.
```

---

## New Files to Create

The following files do not exist in the legacy role and must be created as part of modernization:

```
collections/requirements.yml
execution-environment.yml
bindep.txt
roles/provision-nginx-oss-apb/defaults/main.yml
roles/provision-nginx-oss-apb/meta/main.yml
roles/provision-nginx-oss-apb/meta/argument_specs.yml
roles/deprovision-nginx-oss-apb/meta/main.yml
```

**`roles/provision-nginx-oss-apb/defaults/main.yml`** (example):
```yaml
lb: false
server: ""
lb_method: round_robin
```

**`execution-environment.yml`** (replaces `Dockerfile`):
```yaml
version: 1
build_arg_defaults:
  EE_BASE_IMAGE: 'quay.io/ansible/ansible-runner:latest'
dependencies:
  galaxy: collections/requirements.yml
  python: requirements.txt
  system: bindep.txt
```

**`bindep.txt`**:
```
# No system packages required when using kubernetes.core (oc CLI no longer needed)
```

**`collections/requirements.yml`**:
```yaml
collections:
  - name: kubernetes.core
    version: ">=2.4.0"
  - name: ansible.utils
    version: ">=2.10.0"
```

---

## Checks for the Migration

**Files to verify** (all files in the modernized role):
```
playbooks/provision.yml
playbooks/deprovision.yml
roles/provision-nginx-oss-apb/tasks/main.yml
roles/provision-nginx-oss-apb/templates/default.conf.j2
roles/provision-nginx-oss-apb/defaults/main.yml
roles/provision-nginx-oss-apb/meta/main.yml
roles/provision-nginx-oss-apb/meta/argument_specs.yml
roles/deprovision-nginx-oss-apb/tasks/main.yml
roles/deprovision-nginx-oss-apb/meta/main.yml
collections/requirements.yml
execution-environment.yml
bindep.txt
```

**Services to check**:
- OpenShift `DeploymentConfig` `nginx-oss-apb` in target namespace
- Kubernetes `Service` `nginx-oss-apb` in target namespace
- OpenShift `Route` `nginx-oss-apb` in target namespace
- Kubernetes `ConfigMap` `nginx-conf` in target namespace

**Templates to validate**:
- `roles/provision-nginx-oss-apb/templates/default.conf.j2` — validate rendered output for both `lb: false` and `lb: true` with each `lb_method` value

---

## Pre-flight Checks

```bash
# 1. Verify kubernetes.core collection is installed
ansible-galaxy collection list | grep kubernetes.core

# 2. Verify Python kubernetes client is available in the EE / venv
python -c "import kubernetes; print(kubernetes.__version__)"
python -c "import openshift; print(openshift.__version__)"

# 3. Verify OpenShift cluster connectivity and namespace exists
oc whoami
oc get namespace "${NAMESPACE}"

# 4. Dry-run the provision playbook (check mode)
ansible-playbook playbooks/provision.yml \
  -e namespace=test-nginx \
  -e lb=false \
  --check --diff

# 5. Dry-run with load balancing enabled
ansible-playbook playbooks/provision.yml \
  -e namespace=test-nginx \
  -e lb=true \
  -e "server=10.0.0.1:8080, 10.0.0.2:8080" \
  -e lb_method=least_conn \
  --check --diff

# 6. Validate rendered NGINX config template locally
ansible -m ansible.builtin.template \
  -a "src=roles/provision-nginx-oss-apb/templates/default.conf.j2 dest=/tmp/test-default.conf" \
  -e lb=true \
  -e "server=10.0.0.1:8080, 10.0.0.2:8080" \
  -e lb_method=hash \
  localhost

# 7. After provision: verify all resources are Running
oc get deploymentconfig nginx-oss-apb -n "${NAMESPACE}"
oc get service nginx-oss-apb -n "${NAMESPACE}"
oc get route nginx-oss-apb -n "${NAMESPACE}"
oc get configmap nginx-conf -n "${NAMESPACE}"

# 8. Verify NGINX pod is Running and config is mounted correctly
oc get pods -l service=nginx-oss-apb -n "${NAMESPACE}"
oc exec -n "${NAMESPACE}" \
  $(oc get pod -l service=nginx-oss-apb -n "${NAMESPACE}" -o name | head -1) \
  -- cat /etc/nginx/conf.d/default.conf

# 9. Idempotency check — re-run provision, expect zero changes
ansible-playbook playbooks/provision.yml \
  -e namespace=test-nginx \
  -e lb=false

# 10. Dry-run deprovision
ansible-playbook playbooks/deprovision.yml \
  -e namespace=test-nginx \
  --check --diff

# 11. Lint the modernized role
ansible-lint playbooks/provision.yml
ansible-lint playbooks/deprovision.yml
```

---

## Summary of Critical Breaking Changes

| Priority | Issue | Impact | Fix |
|---|---|---|---|
| 🔴 CRITICAL | `openshift_v1_deployment_config`, `k8s_v1_service`, `openshift_v1_route` are tombstoned | Role will not run at all on modern Ansible | Replace with `kubernetes.core.k8s` + full manifest definitions |
| 🔴 CRITICAL | `ansible.kubernetes-modules` role no longer exists | Playbook fails at role load | Remove from playbooks; install `kubernetes.core` collection |
| 🔴 CRITICAL | `shell: oc create configmap …` — not idempotent, requires `oc` CLI | Fails on re-run; breaks in EE without `oc` | Replace with `kubernetes.core.k8s` ConfigMap task using `lookup('ansible.builtin.template', …)` |
| 🟠 HIGH | Massive parameter drift on all three legacy modules | All task parameters must be rewritten as full Kubernetes manifests | Rewrite each task with `definition:` block |
| 🟡 MEDIUM | `template:` missing `mode:` | Lint warning; potential permission issue | Add `mode: '0644'` (or eliminate temp file entirely) |
| 🟡 MEDIUM | All modules use bare short names (no FQCN) | Ansible-lint failures; namespace ambiguity | Add `ansible.builtin.` prefix to `template:` and `shell:` |
| 🟡 MEDIUM | `server.split(', ')` fragile split in template | Breaks if user inputs `10.0.0.1:8080,10.0.0.2:8080` (no space) | Use `split(',') \| map('trim') \| list` |
| 🟢 LOW | No `meta/argument_specs.yml` | No role input validation | Create from `apb.yml` parameters |
| 🟢 LOW | `Dockerfile` / `apb.yml` APB packaging | APB format is deprecated | Replace with `execution-environment.yml` |
| 🟢 LOW | `{% set list = … %}` shadows Jinja2 built-in | Potential filter shadowing | Rename to `server_list` |