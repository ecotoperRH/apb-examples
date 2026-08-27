---
source-path: nginx-oss-apb
---

Now I have a complete picture of the role. Let me write the full migration plan.

---

# Migration Plan: nginx-oss-apb

**TLDR**: `nginx-oss-apb` is an **Ansible Playbook Bundle (APB)** — a now-deprecated packaging format that ran Ansible inside a Docker container to provision/deprovision NGINX OSS on an OpenShift cluster. It uses tombstoned APB-era modules (`openshift_v1_deployment_config`, `k8s_v1_service`, `openshift_v1_route`, `ansible.kubernetes-modules` role) and a raw `shell: oc create configmap` call. The migration replaces the entire APB scaffolding with a modern Ansible role/collection structure, swaps all legacy OpenShift/Kubernetes modules for `kubernetes.core.k8s`, eliminates the raw `shell` call with a proper `kubernetes.core.k8s` ConfigMap task, adds FQCN throughout, and introduces `meta/argument_specs.yml`, `execution-environment.yml`, and `collections/requirements.yml`.

---

## Service Type and Configuration

**Service Type**: Web Server / Reverse Proxy — OpenShift/Kubernetes Deployment (NGINX OSS)

**Key Operations**:
- **Provision role**:
  - Renders an NGINX `default.conf` from a Jinja2 template (supports optional upstream load-balancing with `round_robin`, `least_conn`, `ip_hash`, `hash` methods)
  - Creates a Kubernetes ConfigMap (`nginx-conf`) from the rendered config file
  - Creates an OpenShift `DeploymentConfig` running `docker.io/alessfg/openshift-nginx` on port 8080, mounting the ConfigMap as `/etc/nginx/conf.d`
  - Creates a Kubernetes `Service` (port 80 → 8080)
  - Creates an OpenShift `Route` to expose the service externally
- **Deprovision role**:
  - Deletes the OpenShift `Route`
  - Deletes the Kubernetes `Service`
  - Deletes the OpenShift `DeploymentConfig`

**Parameters (from `apb.yml`)**:
| Name | Type | Default | Description |
|---|---|---|---|
| `namespace` | string | _(required)_ | Target OpenShift/Kubernetes namespace |
| `lb` | boolean | `false` | Enable upstream load balancing |
| `server` | string | _(empty)_ | Comma-separated list of upstream servers (with port 8080) |
| `lb_method` | enum | `round_robin` | LB algorithm: `round_robin`, `least_conn`, `ip_hash`, `hash` |

---

## File Structure

**IMPORTANT: Relative paths from the role root (`nginx-oss-apb/`).**

**Top-level / APB scaffolding files:**
```
Dockerfile
apb.yml
playbooks/provision.yml
playbooks/deprovision.yml
```

**Provision role:**
```
roles/provision-nginx-oss-apb/tasks/main.yml
roles/provision-nginx-oss-apb/templates/default.conf.j2
```

**Deprovision role:**
```
roles/deprovision-nginx-oss-apb/tasks/main.yml
```

**No handlers, defaults, vars, or meta files exist in either role.**

---

## Module Explanation

The project is structured as two independent roles invoked by two playbooks. Execution order follows provision → deprovision lifecycle.

### 1. **Provision playbook** (`playbooks/provision.yml`)

- Runs on `localhost` with `connection: local` and `gather_facts: false`
- Loads the legacy `ansible.kubernetes-modules` role first (with `install_python_requirements: no`) — this role shipped Python Kubernetes/OpenShift client libraries inside the APB container; it is **tombstoned** and must be removed
- Then runs `provision-nginx-oss-apb`
- **Legacy pattern**: `role: ansible.kubernetes-modules` — this entire dependency disappears; the modern `kubernetes.core` collection handles its own Python requirements via `execution-environment.yml`

### 2. **Deprovision playbook** (`playbooks/deprovision.yml`)

- Mirror of provision playbook; loads `ansible.kubernetes-modules` then `deprovision-nginx-oss-apb`
- Same tombstoned dependency must be removed

### 3. **Provision tasks** (`roles/provision-nginx-oss-apb/tasks/main.yml`)

**Task 1 — Create DeploymentConfig**
- Module: `openshift_v1_deployment_config` — **tombstoned APB-era module**
- Creates an OpenShift `DeploymentConfig` (kind `DeploymentConfig`, apiVersion `apps.openshift.io/v1`)
- Parameters use flat underscore-namespaced keys (e.g., `spec_template_metadata_labels`) — APB module convention, not standard `kubernetes.core.k8s` resource manifest format
- Modern equivalent: `kubernetes.core.k8s` with an inline resource manifest using standard Kubernetes YAML structure
- Note: `DeploymentConfig` is itself deprecated in OpenShift 4.14+ in favour of `apps/v1 Deployment`; the migration plan should offer both options

**Task 2 — Create Service**
- Module: `k8s_v1_service` — **tombstoned APB-era module** (not the same as `community.kubernetes.k8s` or `kubernetes.core.k8s`)
- Creates a `v1/Service` with selector and port mapping
- Modern equivalent: `kubernetes.core.k8s` with inline `v1/Service` manifest

**Task 3 — Create Route**
- Module: `openshift_v1_route` — **tombstoned APB-era module**
- Creates an OpenShift `route.openshift.io/v1/Route`
- Modern equivalent: `kubernetes.core.k8s` with inline `route.openshift.io/v1/Route` manifest

**Task 4 — Render NGINX config template**
- Module: `template` — short name, needs FQCN → `ansible.builtin.template`
- Renders `default.conf.j2` to `/tmp/default.conf` on the controller
- Missing `mode:` parameter
- Modern equivalent: `ansible.builtin.template` with `mode: '0644'`

**Task 5 — Create ConfigMap via shell**
- Module: `shell` — **anti-pattern**: raw `oc` CLI call: `oc create configmap nginx-conf --from-file=nginx-conf=/tmp/default.conf`
- Problems: not idempotent (fails if ConfigMap already exists), missing `changed_when:`, requires `oc` binary on the controller, bypasses Ansible's state management
- Modern equivalent: `kubernetes.core.k8s` with a `v1/ConfigMap` manifest, reading the rendered template content with `ansible.builtin.slurp` or using `lookup('ansible.builtin.file', ...)` inline — **fully idempotent**

**Ansible module mapping (provision)**:
| Legacy | Modern FQCN | Notes |
|---|---|---|
| `openshift_v1_deployment_config` | `kubernetes.core.k8s` | Full manifest required; parameter structure changes completely |
| `k8s_v1_service` | `kubernetes.core.k8s` | Full manifest required |
| `openshift_v1_route` | `kubernetes.core.k8s` | Full manifest required |
| `template` | `ansible.builtin.template` | Add `mode:` |
| `shell: oc create configmap` | `kubernetes.core.k8s` | Idempotent ConfigMap creation |

### 4. **Deprovision tasks** (`roles/deprovision-nginx-oss-apb/tasks/main.yml`)

**Task 1 — Delete Route**
- Module: `openshift_v1_route` with `state: absent` — tombstoned
- Modern equivalent: `kubernetes.core.k8s` with `state: absent` and Route manifest

**Task 2 — Delete Service**
- Module: `k8s_v1_service` with `state: absent` — tombstoned
- Modern equivalent: `kubernetes.core.k8s` with `state: absent` and Service manifest

**Task 3 — Delete DeploymentConfig**
- Module: `openshift_v1_deployment_config` with `state: absent` — tombstoned
- Modern equivalent: `kubernetes.core.k8s` with `state: absent` and DeploymentConfig/Deployment manifest

**Ansible module mapping (deprovision)**:
| Legacy | Modern FQCN | Notes |
|---|---|---|
| `openshift_v1_route` | `kubernetes.core.k8s` | `state: absent` |
| `k8s_v1_service` | `kubernetes.core.k8s` | `state: absent` |
| `openshift_v1_deployment_config` | `kubernetes.core.k8s` | `state: absent` |

### 5. **Template** (`roles/provision-nginx-oss-apb/templates/default.conf.j2`)

- Uses `{% if lb %}` — tests the `lb` variable as a bare boolean; safe in Jinja2 but should be guarded with `| bool` since the APB passes it as a string `"false"` from the service catalog
- Uses `{% set list = server.split(', ') %}` — Python string method, valid in Jinja2 but fragile; modern equivalent uses `| split(', ')` Jinja2 filter (Ansible 2.11+) or `server.split(', ')` remains acceptable
- Uses `{{ lb_method }}` and `{{ ' $request_uri' if lb_method == 'hash' }}` — bare variable, needs `{{ lb_method | default('round_robin') }}` guard
- No deprecated Jinja2 tests present
- No `is undefined` patterns

---

## Modernization Mapping

| Legacy Pattern | Modern Equivalent | Files Affected | Notes |
|---|---|---|---|
| `openshift_v1_deployment_config:` | `kubernetes.core.k8s:` with full manifest | `roles/provision-nginx-oss-apb/tasks/main.yml`, `roles/deprovision-nginx-oss-apb/tasks/main.yml` | **Tombstoned module** — complete parameter structure change; flat `spec_*` keys → nested YAML manifest |
| `k8s_v1_service:` | `kubernetes.core.k8s:` with full manifest | `roles/provision-nginx-oss-apb/tasks/main.yml`, `roles/deprovision-nginx-oss-apb/tasks/main.yml` | **Tombstoned module** — APB-era, not `community.kubernetes` |
| `openshift_v1_route:` | `kubernetes.core.k8s:` with full manifest | `roles/provision-nginx-oss-apb/tasks/main.yml`, `roles/deprovision-nginx-oss-apb/tasks/main.yml` | **Tombstoned module** |
| `shell: oc create configmap ...` | `kubernetes.core.k8s:` with `v1/ConfigMap` manifest | `roles/provision-nginx-oss-apb/tasks/main.yml` | Not idempotent; missing `changed_when:`; requires `oc` binary; replace entirely |
| `template:` | `ansible.builtin.template:` | `roles/provision-nginx-oss-apb/tasks/main.yml` | FQCN + add `mode: '0644'` |
| Missing `mode:` on `template` task | `mode: '0644'` | `roles/provision-nginx-oss-apb/tasks/main.yml` | File permissions best practice |
| `role: ansible.kubernetes-modules` | _(remove entirely)_ | `playbooks/provision.yml`, `playbooks/deprovision.yml` | Tombstoned APB helper role; `kubernetes.core` collection is self-contained |
| `install_python_requirements: no` | _(remove with role)_ | `playbooks/provision.yml`, `playbooks/deprovision.yml` | APB-era parameter |
| `playbook_debug: false` | _(remove or replace with `debuglevel`)_ | `playbooks/provision.yml`, `playbooks/deprovision.yml` | APB-era role variable |
| `gather_facts: false` | Keep as `gather_facts: false` | `playbooks/provision.yml`, `playbooks/deprovision.yml` | Correct for k8s-only plays; no change needed |
| `{% if lb %}` bare boolean test | `{% if lb \| bool %}` | `roles/provision-nginx-oss-apb/templates/default.conf.j2` | APB passes booleans as strings from service catalog |
| `{{ lb_method }}` bare variable | `{{ lb_method \| default('round_robin') }}` | `roles/provision-nginx-oss-apb/templates/default.conf.j2` | Guard against undefined |
| `server.split(', ')` Python method | `server.split(', ')` or `server \| split(', ')` | `roles/provision-nginx-oss-apb/templates/default.conf.j2` | `.split()` works in Jinja2; `\| split` filter preferred in Ansible ≥ 2.11 |
| APB `Dockerfile` + `apb.yml` | `execution-environment.yml` + `bindep.txt` | New files | APB container replaced by Ansible Execution Environment (EE) |
| No `meta/argument_specs.yml` | Add `meta/argument_specs.yml` | New file | Role input validation |
| No `collections/requirements.yml` | Add `collections/requirements.yml` | New file | Declare `kubernetes.core` dependency |
| No `meta/main.yml` in either role | Add `meta/main.yml` | New files | Role metadata, platform, min Ansible version |
| `spec_template_metadata_labels:` flat key | `spec.template.metadata.labels:` nested in manifest | `roles/provision-nginx-oss-apb/tasks/main.yml` | **Parameter drift** — APB modules used underscore-flattened keys; `kubernetes.core.k8s` uses standard nested Kubernetes YAML |
| `spec_port_target_port: web` flat key | `spec.port.targetPort: web` nested in Route manifest | `roles/provision-nginx-oss-apb/tasks/main.yml` | **Parameter drift** — same flattening issue |
| `to_name: nginx-oss-apb` APB key | `spec.to.name: nginx-oss-apb` in Route manifest | `roles/provision-nginx-oss-apb/tasks/main.yml` | **Parameter drift** |
| `containers:` at top level of DC task | Nested under `spec.template.spec.containers:` | `roles/provision-nginx-oss-apb/tasks/main.yml` | **Parameter drift** — APB modules accepted flattened container specs |
| `restart_policy: Always` at top level | `spec.template.spec.restartPolicy: Always` | `roles/provision-nginx-oss-apb/tasks/main.yml` | **Parameter drift** |
| `volumes:` at top level of DC task | `spec.template.spec.volumes:` | `roles/provision-nginx-oss-apb/tasks/main.yml` | **Parameter drift** |

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

> **Note**: `community.kubernetes` was the predecessor to `kubernetes.core`. If any intermediate migration used `community.kubernetes.*` modules, those must also be migrated to `kubernetes.core.*` — they are not the same as the tombstoned APB modules here, but the rename is a known migration step.

**Role dependencies**: 
- `ansible.kubernetes-modules` — **remove entirely** (tombstoned APB helper role)

**External packages / binaries**:
- `oc` (OpenShift CLI) — currently required by the `shell: oc create configmap` task; **eliminated** after migration to `kubernetes.core.k8s`
- Python `kubernetes` library (`pip install kubernetes`) — required by `kubernetes.core`; declared in `bindep.txt` / EE definition

**Services managed**:
- No OS-level services managed (this is a Kubernetes/OpenShift deployment role)
- Kubernetes resources managed: `DeploymentConfig` (or `Deployment`), `Service`, `Route`, `ConfigMap`

**Container image used**:
- `docker.io/alessfg/openshift-nginx` — runs NGINX on port 8080 (non-root OpenShift-compatible image)

---

## Template Modernization

**`roles/provision-nginx-oss-apb/templates/default.conf.j2`**:

1. **Bare boolean test** — `{% if lb %}` must become `{% if lb | bool %}` because the APB service catalog (and any modern role invocation passing variables as strings) will pass `lb` as the string `"false"` rather than the Python boolean `False`. Without `| bool`, the string `"false"` is truthy in Jinja2.

2. **Bare variable without default** — `{{ lb_method }}` and the conditional `{{ ' $request_uri' if lb_method == 'hash' }}` should use `{{ lb_method | default('round_robin') }}` to prevent `Undefined` errors when `lb_method` is not passed.

3. **String split method** — `{% set list = server.split(', ') %}` is valid Jinja2 but the variable name `list` shadows the Python built-in. Rename to `{% set server_list = server.split(', ') %}` and update the loop to `{% for ip in server_list %}`. Alternatively use the Ansible `split` filter: `{% set server_list = server | split(', ') %}` (requires Ansible ≥ 2.11 / `ansible-core` ≥ 2.11).

4. **No `mode:` on the `template` task** — the rendered `/tmp/default.conf` file has no explicit permissions set. Add `mode: '0644'` to the `ansible.builtin.template` task.

**Modernized template snippet**:
```jinja2
{% if lb | bool %}
upstream upstr {
{% if lb_method | default('round_robin') != 'round_robin' %}
    {{ lb_method | default('round_robin') }}{{ ' $request_uri' if lb_method | default('round_robin') == 'hash' }};
{% endif %}
{% set server_list = server | split(', ') %}
{% for ip in server_list %}
    server {{ ip }};
{% endfor %}
}
{% endif %}
```

---

## Argument Specification

New file: `roles/provision-nginx-oss-apb/meta/argument_specs.yml`

```yaml
argument_specs:
  main:
    short_description: Provision NGINX OSS on OpenShift/Kubernetes
    description:
      - Deploys NGINX OSS as a DeploymentConfig (or Deployment), Service, Route,
        and ConfigMap on an OpenShift or Kubernetes cluster.
    options:
      namespace:
        type: str
        required: true
        description: Target Kubernetes/OpenShift namespace for all resources.
      lb:
        type: bool
        required: false
        default: false
        description: Enable upstream load balancing in the NGINX configuration.
      server:
        type: str
        required: false
        default: ""
        description: >
          Comma-separated list of upstream backend servers including port 8080
          (e.g. "10.0.0.1:8080, 10.0.0.2:8080"). Required when lb is true.
      lb_method:
        type: str
        required: false
        default: round_robin
        description: >
          NGINX load balancing algorithm. One of: round_robin, least_conn,
          ip_hash, hash.
        choices:
          - round_robin
          - least_conn
          - ip_hash
          - hash
```

New file: `roles/deprovision-nginx-oss-apb/meta/argument_specs.yml`

```yaml
argument_specs:
  main:
    short_description: Deprovision NGINX OSS from OpenShift/Kubernetes
    description:
      - Removes the NGINX OSS Route, Service, and DeploymentConfig/Deployment
        from the target namespace.
    options:
      namespace:
        type: str
        required: true
        description: Target Kubernetes/OpenShift namespace from which to remove resources.
```

---

## New Files to Create

### `collections/requirements.yml`
```yaml
---
collections:
  - name: kubernetes.core
    version: ">=2.4.0"
```

### `execution-environment.yml` (replaces `Dockerfile` / APB base image)
```yaml
---
version: 1
build_arg_defaults:
  EE_BASE_IMAGE: 'quay.io/ansible/ansible-runner:latest'

dependencies:
  galaxy: collections/requirements.yml
  python: requirements.txt
  system: bindep.txt

additional_build_steps:
  prepend:
    - RUN pip3 install --upgrade pip
```

### `requirements.txt`
```
kubernetes>=24.2.0
openshift>=0.13.2
```

### `bindep.txt`
```
python3-devel [platform:rpm]
gcc [platform:rpm]
```

### `roles/provision-nginx-oss-apb/meta/main.yml`
```yaml
---
galaxy_info:
  role_name: provision_nginx_oss
  author: NGINX Inc
  description: Provision NGINX OSS on OpenShift/Kubernetes
  license: BSD-2-Clause
  min_ansible_version: "2.14"
  platforms:
    - name: all
dependencies: []
```

### `roles/deprovision-nginx-oss-apb/meta/main.yml`
```yaml
---
galaxy_info:
  role_name: deprovision_nginx_oss
  author: NGINX Inc
  description: Deprovision NGINX OSS from OpenShift/Kubernetes
  license: BSD-2-Clause
  min_ansible_version: "2.14"
  platforms:
    - name: all
dependencies: []
```

---

## Modernized Task Examples

### Provision tasks — modernized `roles/provision-nginx-oss-apb/tasks/main.yml`

```yaml
---
- name: Render NGINX default.conf from template
  ansible.builtin.template:
    src: default.conf.j2
    dest: /tmp/default.conf
    mode: '0644'

- name: Create NGINX ConfigMap
  kubernetes.core.k8s:
    state: present
    definition:
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: nginx-conf
        namespace: "{{ namespace }}"
        labels:
          app: "{{ namespace }}"
          service: nginx-oss-apb
      data:
        nginx-conf: "{{ lookup('ansible.builtin.file', '/tmp/default.conf') }}"

- name: Create NGINX OSS Deployment
  kubernetes.core.k8s:
    state: present
    definition:
      apiVersion: apps/v1          # Use apps.openshift.io/v1 DeploymentConfig if OCP < 4.14
      kind: Deployment
      metadata:
        name: nginx-oss-apb
        namespace: "{{ namespace }}"
        labels:
          app: "{{ namespace }}"
          service: nginx-oss-apb
      spec:
        replicas: 1
        selector:
          matchLabels:
            app: "{{ namespace }}"
            service: nginx-oss-apb
        template:
          metadata:
            labels:
              app: "{{ namespace }}"
              service: nginx-oss-apb
          spec:
            restartPolicy: Always
            containers:
              - name: nginx-oss-apb
                image: docker.io/alessfg/openshift-nginx
                ports:
                  - containerPort: 8080
                    protocol: TCP
                volumeMounts:
                  - mountPath: /etc/nginx/conf.d
                    name: configuration
            volumes:
              - name: configuration
                configMap:
                  name: nginx-conf
                  items:
                    - key: nginx-conf
                      path: default.conf

- name: Create NGINX OSS Service
  kubernetes.core.k8s:
    state: present
    definition:
      apiVersion: v1
      kind: Service
      metadata:
        name: nginx-oss-apb
        namespace: "{{ namespace }}"
        labels:
          app: "{{ namespace }}"
          service: nginx-oss-apb
      spec:
        selector:
          app: "{{ namespace }}"
        ports:
          - name: web
            port: 80
            targetPort: 8080

- name: Create NGINX OSS Route
  kubernetes.core.k8s:
    state: present
    definition:
      apiVersion: route.openshift.io/v1
      kind: Route
      metadata:
        name: nginx-oss-apb
        namespace: "{{ namespace }}"
        labels:
          app: "{{ namespace }}"
          service: nginx-oss-apb
      spec:
        to:
          kind: Service
          name: nginx-oss-apb
        port:
          targetPort: web
```

### Deprovision tasks — modernized `roles/deprovision-nginx-oss-apb/tasks/main.yml`

```yaml
---
- name: Delete NGINX OSS Route
  kubernetes.core.k8s:
    state: absent
    definition:
      apiVersion: route.openshift.io/v1
      kind: Route
      metadata:
        name: nginx-oss-apb
        namespace: "{{ namespace }}"

- name: Delete NGINX OSS Service
  kubernetes.core.k8s:
    state: absent
    definition:
      apiVersion: v1
      kind: Service
      metadata:
        name: nginx-oss-apb
        namespace: "{{ namespace }}"

- name: Delete NGINX OSS Deployment
  kubernetes.core.k8s:
    state: absent
    definition:
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: nginx-oss-apb
        namespace: "{{ namespace }}"

- name: Delete NGINX ConfigMap
  kubernetes.core.k8s:
    state: absent
    definition:
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: nginx-conf
        namespace: "{{ namespace }}"
```

---

## Checks for the Migration

**Files to verify** (all files in the modernized role):
```
apb.yml                                                  # Retire / replace with role README
Dockerfile                                               # Retire / replace with execution-environment.yml
execution-environment.yml                                # NEW
requirements.txt                                         # NEW
bindep.txt                                               # NEW
collections/requirements.yml                             # NEW
playbooks/provision.yml                                  # Modified: remove ansible.kubernetes-modules role
playbooks/deprovision.yml                                # Modified: remove ansible.kubernetes-modules role
roles/provision-nginx-oss-apb/tasks/main.yml             # Modified: all 5 tasks rewritten
roles/provision-nginx-oss-apb/templates/default.conf.j2  # Modified: | bool, | default(), rename list var
roles/provision-nginx-oss-apb/meta/main.yml              # NEW
roles/provision-nginx-oss-apb/meta/argument_specs.yml    # NEW
roles/deprovision-nginx-oss-apb/tasks/main.yml           # Modified: all 3 tasks rewritten + ConfigMap deletion added
roles/deprovision-nginx-oss-apb/meta/main.yml            # NEW
roles/deprovision-nginx-oss-apb/meta/argument_specs.yml  # NEW
```

**Services / Kubernetes resources to check**:
- `Deployment` (or `DeploymentConfig`) `nginx-oss-apb` in target namespace
- `Service` `nginx-oss-apb` in target namespace
- `Route` `nginx-oss-apb` in target namespace
- `ConfigMap` `nginx-conf` in target namespace

**Templates to validate**:
- `roles/provision-nginx-oss-apb/templates/default.conf.j2` — test with `lb: false`, `lb: true` + each `lb_method` value, and `lb: true` with `server` as a comma-separated string

---

## Pre-flight Checks

```bash
# 1. Verify kubernetes.core collection is installed
ansible-galaxy collection list | grep kubernetes.core

# 2. Verify Python kubernetes library is available in the execution environment
python3 -c "import kubernetes; print(kubernetes.__version__)"

# 3. Verify cluster connectivity (kubeconfig must be configured)
kubectl cluster-info
# or for OpenShift:
oc whoami

# 4. Verify target namespace exists
kubectl get namespace <namespace>

# 5. Dry-run the provision playbook (check mode)
ansible-playbook playbooks/provision.yml \
  -e namespace=test-nginx \
  -e lb=false \
  --check --diff

# 6. Dry-run with load balancing enabled
ansible-playbook playbooks/provision.yml \
  -e namespace=test-nginx \
  -e lb=true \
  -e "server=10.0.0.1:8080, 10.0.0.2:8080" \
  -e lb_method=least_conn \
  --check --diff

# 7. Verify rendered ConfigMap content after provision
kubectl get configmap nginx-conf -n <namespace> -o jsonpath='{.data.nginx-conf}'

# 8. Verify NGINX pod is running
kubectl get pods -n <namespace> -l service=nginx-oss-apb

# 9. Verify Route is accessible (OpenShift)
oc get route nginx-oss-apb -n <namespace>

# 10. Dry-run the deprovision playbook
ansible-playbook playbooks/deprovision.yml \
  -e namespace=test-nginx \
  --check --diff

# 11. Validate template rendering independently
ansible -m ansible.builtin.template \
  -a "src=roles/provision-nginx-oss-apb/templates/default.conf.j2 dest=/tmp/test-default.conf" \
  -e lb=true \
  -e "server=10.0.0.1:8080" \
  -e lb_method=hash \
  localhost

# 12. Lint the modernized role
ansible-lint roles/provision-nginx-oss-apb/
ansible-lint roles/deprovision-nginx-oss-apb/
```