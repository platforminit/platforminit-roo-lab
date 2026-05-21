# PlatformInit / DevOps Homelab 2 – Teljes projektleírás CH01–CH15

**Dátum:** 2026-05-20
**Projekt:** PlatformInit Platform / DevOps Homelab 2
**Repo:** `platforminit/platforminit-platform`
**Célkörnyezet:** Hetzner Cloud VPS, Ubuntu, single-node k3s, GitOps, Authentik SSO, operator-központú observability
**Fő domain:** `sysadminhomelab.hu`
**Jelenlegi ismert dev host:** `platforminit-dev-01`
**Alapelv:** friss VPS → determinisztikusan újraépíthető, validált, production-ready single-node platform.

---

## 1. Vezetői összefoglaló

A PlatformInit célja egy olyan automatizált platform-alap létrehozása, amely egy friss VPS-ből viszonylag rövid, kontrollált folyamatban használható, biztonságos, monitorozott és GitOps-alapon üzemeltethető kis production platformot épít.

A projekt nem egyszerű homelabként kezelendő, hanem egy fokozatosan termékesíthető platformindító rendszerként:

- **CH01–CH02:** host életciklus, baseline, hardening, drift, file integrity;
- **CH03–CH04:** single-node Kubernetes és alap platformszolgáltatások;
- **CH04.5–CH04.6:** identity foundation és Argo CD SSO;
- **CH05:** operations monitoring / observability;
- **CH06–CH09:** security, onboarding, promotion, backup, DR, reliability;
- **CH10–CH15:** productizáció, governance, AIOps, IDP és customer-facing PlatformInit.

A projekt jelenlegi iránya szerint a platform nem HA/multi-node rendszer. A cél egy **resource-conscious, single-node, deterministic rebuild** modell. A rollback nem klasszikus in-place rollback, hanem:

> destroy → recreate → bootstrap → baseline → k3s → Argo CD sync → validáció

A hosszabb távú cél az, hogy a PlatformInit egy ismételhető, ügyfél- vagy projektkörnyezetre is adaptálható platform-alap legyen.

---

## 2. Alapelvek és architektúra

### 2.1 Fő tervezési elvek

| Elv | Jelentés |
|---|---|
| Determinisztikus rebuild | A rendszer újraépíthető legyen Gitből, workflow-kból és deklarált állapotból. |
| GitOps-first | Kubernetes workloadot hosszú távon Argo CD kezeljen, ne kézi `kubectl apply`. |
| Minimal operational noise | Ne legyen túl sok dashboard, túl sok fals alert vagy értelmezhetetlen metrika. |
| Operator-first UX | A monitoring mondja meg: mi romlott el, hol, mennyire sürgős, mit kell nézni. |
| Version pinning | k3s, chartok, image-ek és fő komponensek ne `latest` alapúak legyenek. |
| Single-node first | Nincs HA és nincs cluster scaling a jelenlegi scope-ban. |
| Rebuild over repair | Hosszú távon a tiszta újraépítés előnyben van az ad-hoc javítással szemben. |
| Secrets separation | GitHub secrets / environments / project-scoped tokenek, nem hardcoded secret. |
| Chapter boundaries | CH01–CH15 elkülönülő rétegek, hogy ne keveredjen a host, cluster, identity, monitoring és product scope. |

### 2.2 Fő technológiák

| Terület | Technológia | Szerep |
|---|---|---|
| Cloud provider | Hetzner Cloud | VPS, volume, projektalapú infrastruktúra |
| OS | Ubuntu 24.04 LTS | host operációs rendszer |
| Provisioning | Terraform + GitHub Actions | host és volume létrehozás / rebuild |
| Automation | GitHub Actions | fejezetenkénti workflow orchestration |
| Kubernetes | k3s | single-node Kubernetes |
| GitOps | Argo CD | deklaratív cluster/app kezelés |
| Ingress | Traefik | HTTP/HTTPS ingress |
| TLS | cert-manager + Let's Encrypt | automatikus cert kezelés |
| DNS | Cloudflare DNS-01 | wildcard / ACME DNS challenge |
| Identity | Authentik | SSO, OIDC, forwardAuth |
| Monitoring | Checkmk Community | operator-központú host/service monitoring |
| Logging / optional | Loki / OpenObserve / Vector irányok | későbbi log aggregation és keresés |
| Repo workflow | VS Code + WSL + GitHub | fejlesztés, branch, review, commit |
| AI workflow | DeepSeek Coder + OpenAI Reviewer + OWASP review | batch-alapú agentic fejlesztési workflow |

### 2.3 Környezetek és projekt-routing

A tervezett modell szerint ne egy globális Hetzner token és globális környezet legyen, hanem projektalapú szeparáció:

| Projekt | Szerep |
|---|---|
| `development` / `homelab` | aktív dev platform |
| `n8n` | későbbi külön n8n host/runtime |
| `platforminit` | későbbi customer-facing / production irány |
| `default` | legacy, lehetőség szerint nyugdíjazandó |

Tervezett vagy részben kialakított modell:

- `1 GitHub environment = 1 Hetzner API token = 1 Hetzner project`
- workflow input: `project`
- resolver: projekt → token → host/volume/DNS kontextus
- tokenek például:
  - `HCLOUD_TOKEN_DEVELOPMENT`
  - `HCLOUD_TOKEN_N8N`
  - `HCLOUD_TOKEN_PLATFORMINIT`

---

## 3. Jelenlegi projektállapot röviden

| Réteg | Állapot |
|---|---|
| CH01 Host lifecycle | nagyrészt megtervezett / részben implementált, storage-layout és rebuild részletek visszatérő fókusz |
| CH02 Host baseline | baseline, sudo/access, drift, FIM/AIDE irány ismert |
| CH03 k3s | single-node k3s célállapot ismert |
| CH04 Platform services | Traefik, cert-manager, Argo CD, TLS, Cloudflare DNS-01 irány stabil |
| CH04.5 Identity | Authentik foundation kialakítva |
| CH04.6 Argo CD SSO | Authentik OIDC / SSO irány ismert |
| CH05 Operations | Grafana/VictoriaMetrics/Loki irányról Checkmk Community felé pivot; Checkmk stabil checkpoint létrejött |
| CH06+ | roadmap-szintű, CH06 a következő logikus nagy fejezet |

Fontos állapot: a CH05 monitoringnál a nyers Grafana-dashboard modell nem adott elég operator-friendly választ arra, hogy “mi romlott el és miért”. Emiatt a projekt iránya Checkmk Community felé mozdult, Authentik SSO-val, Traefik forwardAuth-tal és trusted-header auth modellel.

---

# 4. Részletes roadmap CH01–CH15

---

## CH01 – Host Lifecycle, Provisioning, Bootstrap és Access Foundation

### Cél

A CH01 célja, hogy egy friss Hetzner VPS-ből kontrollált, auditálható és újraépíthető host legyen. Ez a teljes platform alapja. Amíg a host lifecycle nem determinisztikus, addig minden magasabb réteg instabil.

### Scope

- Hetzner Cloud project kiválasztása.
- Host létrehozása vagy rebuildje.
- SSH kulcs és automation user kezelése.
- Alap könyvtárstruktúra létrehozása.
- Volume attach/mount validáció.
- Bootstrap audit artifactok előállítása.
- Host naming contract enforce.
- Immutable execution model: repo tartalom SHA-alapú temp könyvtárból futtatva, nem persistent checkoutból.

### Fontos komponensek

- `01 - Create or Rebuild Host`
- `01.1 - Host Bootstrap`
- `01.2 - Sync Host Access Tooling`
- host resolver / project resolver
- `/etc/platforminit/host-context.env`
- `/srv/platforminit/audit`
- `/var/lib/platforminit/audit -> /srv/platforminit/audit` symlink

### Storage célmodell

A projekt hosszabb távú split-volume célja:

| Mount | Méret | Szerep |
|---|---:|---|
| `/srv/data` | 80 GB | általános persistent data |
| `/srv/db` | 40 GB | adatbázis jellegű workloadok |
| `/srv/observability` | 40 GB | monitoring/logging adatok |

A CH01 validációnak meg kell akadályoznia, hogy CH02–CH05 fusson hibás storage baseline mellett.

### Output

- Validált host.
- Automation SSH access.
- Audit JSON/Markdown report.
- Host context file.
- Determinisztikus mount state.
- Bootstrap-ready állapot.

### Definition of Done

- SSH automation működik.
- Hostnév megfelel: például `platforminit-dev-01`.
- Volume/mount layout megfelel a kiválasztott role-nak.
- Audit path létezik.
- Bootstrap artifact előáll.
- CH02 előfeltételei teljesülnek.

### Tipikus hibák

- Rossz Hetzner project token miatt host rossz projektbe kerül.
- `sudo: a password is required`.
- `/srv` vagy split mount hibás.
- Audit path hiányzik.
- Workflow artifact ID / run ID mismatch.
- Host naming contract violation.

---

## CH02 – Host Baseline, OS Security, Drift és File Integrity

### Cél

A CH02 célja, hogy a host ne csak “elinduljon”, hanem stabil, policy-alapú, ellenőrzött baseline-t kapjon. Ez a biztonsági és üzemeltetési minimum.

### Scope

- Sudo / privilege management.
- UFW firewall.
- SSH hardening.
- Package baseline.
- journald limit / retention.
- sysctl tuning.
- swap policy.
- drift detection.
- restore-state.
- FIM / AIDE.
- audit reportok.

### Fontos komponensek

- `02 - Apply Host Baseline`
- `02.2 - Temporary Privilege Grant`
- `02.5.1 - Initialize AIDE Database`
- `02.5.2 - Run AIDE Check`
- baseline YAML-ek
- dependency YAML-ek
- drift check scripts
- restore-state workflow

### Output

- Hardened Ubuntu host.
- Validált firewall state.
- SSH policy.
- Baseline package set.
- FIM/AIDE database.
- Drift report.
- SRE-style validation email/report.

### Definition of Done

- UFW aktív, csak szükséges portok nyitva.
- SSH kulcsos belépés működik.
- Root/password login tiltott vagy kontrollált.
- AIDE init lefutott.
- Drift check PASS vagy magyarázott WARN.
- CH03 k3s telepítés előtt minden host baseline feltétel teljesül.

### Fontos döntések

- A CH02 nem cluster-szintű security; az majd CH06.
- CH02 host baseline-t ad.
- CH02 hibánál nem szabad továbbmenni CH03/CH04 irányba.

---

## CH03 – Kubernetes Baseline: single-node k3s

### Cél

A CH03 célja egy stabil single-node k3s cluster felépítése, amely alkalmas Argo CD és platformszolgáltatások futtatására.

### Scope

- k3s telepítés.
- k3s version pinning.
- kubeconfig kezelése.
- data-dir kontroll.
- Traefik / servicelb döntések.
- node readiness validáció.
- namespace baseline.
- cluster smoke test.

### Fontos komponensek

- k3s systemd unit.
- `/etc/rancher/k3s/k3s.yaml`
- `/srv/data/k3s` vagy layout-aware k3s data path.
- node/service/pod validation.

### Output

- Működő single-node k3s cluster.
- Valid kubeconfig.
- Running system namespaces.
- Ready node.
- Alap service routing előfeltétel.

### Definition of Done

- `kubectl get nodes` Ready.
- k3s service aktív.
- Traefik vagy választott ingress komponens későbbi CH04-hez kompatibilis.
- A k3s data-dir nem kerül rossz mount alá.
- A host reboot után is visszaáll.

### Fontos korábbi hiba

Volt olyan állapot, ahol a k3s systemd unit `--disable servicelb` miatt a Traefik external IP pending állapotban maradt, és a hoston nem volt 80/443 listener. A CH03/CH04 validációnak ezt explicit ellenőriznie kell.

---

## CH04 – Platform Services: Ingress, TLS, DNS, Argo CD

### Cél

A CH04 célja, hogy a cluster ne csak Kubernetes legyen, hanem platformként működjön: legyen ingress, TLS, DNS-integráció és GitOps control plane.

### Scope

- Traefik ingress.
- cert-manager.
- Let's Encrypt.
- Cloudflare DNS-01 challenge.
- Argo CD telepítés.
- Argo CD ingress + TLS.
- app-of-apps vagy platform bootstrap modell.
- alap platform namespace-ek.

### Fontos komponensek

- Traefik CRD-k.
- cert-manager ClusterIssuer.
- Cloudflare API token secret.
- Argo CD Application / AppProject.
- TLS validáció.
- DNS A/CNAME/wildcard validáció.

### Output

- HTTPS-en elérhető platform UI-k.
- Automatikus TLS cert kezelés.
- Argo CD GitOps control plane.
- Deklaratív platform bootstrap.

### Definition of Done

- 80/443 működik.
- cert-manager sikeresen kér certet.
- Cloudflare DNS-01 működik.
- Argo CD UI elérhető.
- Argo CD képes syncelni platform appokat.
- A targetRevision stringként van kezelve, nem numerikus YAML értékként.

### Fontos elv

CH04 után a hosszú életű cluster workloadokat lehetőség szerint már ne GitHub Actions deployolja közvetlenül, hanem Argo CD.

---

## CH04.5 – Identity Foundation: Authentik

### Cél

A CH04.5 célja az identity layer bevezetése. A platform UI-k ne külön-külön random admin jelszavakkal működjenek, hanem központi SSO irányba menjenek.

### Scope

- Authentik telepítés.
- Authentik ingress + TLS.
- Identity namespace.
- Admin bootstrap.
- Group/user model.
- Tech users / service accounts.
- OIDC provider minták.
- Proxy provider minták.
- ForwardAuth alapmodell.

### Fontos komponensek

- `auth.sysadminhomelab.hu`
- Authentik embedded outpost.
- OIDC providers.
- Proxy providers.
- Authentik flows.
- Group mapping.

### Output

- Elérhető Authentik UI.
- Alap identity modell.
- Későbbi Argo CD, Checkmk, OpenObserve/n8n integrációkhoz használható foundation.

### Definition of Done

- Authentik UI TLS-sel elérhető.
- Admin login működik.
- Provider/outpost működés validálható.
- Alap group modell dokumentált.
- ForwardAuth és OIDC irány is tiszta.

### Ismert integrációs megjegyzés

Authentik proxy provider reconciliation esetén szükséges lehet az `invalidation_flow=default-provider-invalidation-flow`, különben az API 400 hibát adhat `invalidation_flow` hiány miatt.

---

## CH04.6 – Argo CD SSO Authentik OIDC-vel

### Cél

A CH04.6 célja, hogy az Argo CD ne különálló admin loginra épüljön, hanem Authentik OIDC SSO-val működjön.

### Scope

- Authentik OIDC provider Argo CD számára.
- Argo CD OIDC config.
- redirect URI-k.
- group/claim mapping.
- RBAC mapping.
- login/logout flow validáció.

### Fontos komponensek

- Argo CD OIDC config.
- Authentik application/provider.
- `argocd` client.
- issuer URL.
- redirect URI.
- RBAC configmap.

### Output

- Argo CD SSO login.
- Csoport-alapú hozzáférés.
- Dokumentált fallback admin access.
- Validált logout/login flow.

### Definition of Done

- Argo CD login Authentiken keresztül működik.
- Admin group megfelelő jogosultságot kap.
- Logout nem hagy broken session állapotot.
- Fallback hozzáférés vészhelyzetre dokumentált.

---

## CH05 – Operations Monitoring / Observability

### Cél

A CH05 célja nem az, hogy minél több metrikát gyűjtsön a rendszer, hanem hogy az operátor gyorsan meg tudja mondani:

1. Mi romlott el?
2. Hol romlott el?
3. Mennyire sürgős?
4. Mi a következő diagnosztikai lépés?

### Korábbi irány

A projektben korábban futott vagy tesztelt stackek:

- Grafana
- VictoriaMetrics
- Loki
- Alloy
- kube-state-metrics
- node-exporter
- Alertmanager-szerű dashboardok
- Zabbix
- Vector
- OpenObserve

A nyers Grafana-dashboardos irány működött technikailag, de nem adott elég jó operator UX-et. Túl sok volt a dashboard, kevés volt az egyértelmű “hiba → ok → teendő” flow.

### Jelenlegi preferált irány

- Checkmk Community mint operations monitoring layer.
- Authentik SSO Traefik forwardAuth segítségével.
- Checkmk trusted HTTP header auth: `X-Remote-User`.
- Checkmk host/service modell.
- Agent discovery.
- Operator-first dashboard/view.

### Scope

- Checkmk deployment.
- Authentik forwardAuth.
- trusted-header SSO.
- Checkmk site/user/bootstrap.
- host registration.
- service discovery.
- operations entry point.
- WARN/CRIT-first view.
- validation workflows.

### Fontos komponensek

- `checkmk.sysadminhomelab.hu`
- `operations` namespace.
- Checkmk site.
- Checkmk agent.
- Checkmk host: `platforminit-dev-01`
- workflowk:
  - `05.2 Sync Operations Stack`
  - `05.3 Enable Checkmk Trusted-Header SSO`
  - `05.4 Validate Operations Stack`
  - `05.5 Provision Checkmk Operations Model`
  - `05.6 Configure Checkmk Operations Entry Point`
  - `05.7 Checkmk Linux Agent Install/Discovery`

### Output

- SSO mögötti Checkmk UI.
- Validált host/service monitoring.
- Agent alapú host health.
- Operator-központú operations entry point.
- Alap WARN/CRIT workflow.

### Definition of Done

- Checkmk UI elérhető.
- Authentik SSO működik.
- Native admin fallback dokumentált.
- Host megjelenik.
- Services discovered.
- Legalább alap host services OK/WARN/CRIT állapottal látszanak.
- Validation workflow nem csak “lefut”, hanem tényleges runtime állapotot ellenőriz.

### Ismert CH05 tanulságok

- A Grafana önmagában nem elég user-friendly operations centernek.
- A dashboard túltermelés rontja az üzemeltethetőséget.
- A Checkmk jobb “mi romlott el?” szemléletet ad.
- Az Authentik forwardAuth hibái gyakran Traefik/AuthentiK oldalon jelentkeznek, nem a backend appban.
- A public route 500 hibájánál külön kell választani:
  - backend Checkmk működik-e,
  - auth-shim működik-e,
  - Traefik forwardAuth működik-e,
  - Authentik outpost elérhető-e.

---

## CH06 – Security & Compliance v2

### Cél

A CH06 célja a host-baseline után a platform- és cluster-szintű security/compliance réteg megépítése.

### Scope

- Kubernetes RBAC hardening.
- Namespace policy.
- Secret management.
- SOPS / sealed-secrets / Vault irány döntése.
- NetworkPolicy alapok.
- Runtime security.
- CIS benchmark jellegű ellenőrzések.
- Kubernetes audit log pipeline.
- Security reportok.
- Compliance state dashboard.

### Lehetséges technológiák

| Terület | Opció |
|---|---|
| Secrets | SOPS, Sealed Secrets, Vault |
| Policy | Kyverno vagy OPA Gatekeeper |
| Runtime security | Falco vagy eBPF-alapú eszköz |
| Image scanning | Trivy |
| K8s benchmark | kube-bench |
| File integrity | AIDE + policy FIM |
| Audit | Kubernetes audit log + log pipeline |

### Output

- Deklarált security baseline.
- Secret handling standard.
- RBAC model.
- Policy enforcement.
- Security validation workflows.
- OWASP/security review checklist.

### Definition of Done

- Nincsenek hardcoded secretek.
- Namespace-ekhez minimális jogosultság tartozik.
- Privileged podok explicit kivételként kezeltek.
- Secret lifecycle dokumentált.
- Security workflow PASS/WARN/FAIL riportot ad.
- CH07 application onboarding már erre a baseline-ra épül.

### Fontos döntési pontok

- Vault erős, de lehet túl nehéz single-node homelabre.
- SOPS/age egyszerűbb és GitOps-barátabb.
- Kyverno könnyebben kezelhető lehet kezdő policy layerként, mint OPA Gatekeeper.

---

## CH07 – Service Templates és Application Onboarding

### Cél

A CH07 célja, hogy új alkalmazásokat ne nulláról kelljen kézzel bekötni, hanem sablonokkal lehessen onboardingolni.

### Scope

- Application template-ek.
- Helm/Kustomize standard.
- Ingress/TLS template.
- Authentik SSO integration template.
- Monitoring integration template.
- Logging integration template.
- Backup annotation/model.
- Resource request/limit standard.
- Runbook template.
- App ownership metadata.

### Output

- Új app onboarding guide.
- Template repo vagy platform templates.
- Standard app manifest struktúra.
- CI/validation checks.
- Service catalog alap.

### Definition of Done

- Egy új app deklaratívan felvehető.
- Automatikusan kap ingress/TLS-t.
- Opcionálisan SSO mögé tehető.
- Megjelenik monitoringban.
- Logjai kereshetők.
- Van minimális runbookja.
- Van rollback/rebuild stratégiája.

### Példa appok

- n8n
- belső admin UI
- demo FastAPI app
- customer-facing marketing site
- Ops Center backend/frontend

---

## CH08 – Multi-Environment Promotion

### Cél

A CH08 célja, hogy a platform ne csak egy dev hoston működjön, hanem legyen környezetmodell és promotion workflow.

### Scope

- dev / staging / production model.
- Git branch/tag promotion.
- Argo CD environment split.
- Project-scoped Hetzner tokenek.
- DNS/subdomain separation.
- Secrets separation.
- artifact promotion.
- release gates.
- smoke tests környezetenként.

### Output

- Környezet registry.
- Promotion workflow.
- Release checklist.
- Deployment gates.
- Rollback/rebuild procedure.

### Definition of Done

- Dev → staging → prod út dokumentált.
- Környezetenként külön secret/token modell.
- Nincs véletlen cross-environment deploy.
- Promotion validációk futnak.
- Release artifact visszakövethető.

### Fontos elv

A PlatformInit hosszú távú termékesítése csak akkor reális, ha nem egyetlen kézzel összerakott dev környezetre épül, hanem reproducible promotion modellre.

---

## CH09 – Reliability, Backup és Disaster Recovery

### Cél

A CH09 célja, hogy a platform ne csak újraépíthető legyen, hanem adatvesztés és recovery szempontból is kezelhető.

### Scope

- Backup strategy.
- Restore strategy.
- Volume backup / object storage döntés.
- Database backup.
- Argo CD state recovery.
- Authentik recovery.
- Checkmk recovery.
- n8n recovery.
- DR drill.
- RPO/RTO célok.

### Output

- Backup policy.
- Restore runbook.
- DR validation workflow.
- Backup monitoring.
- Recovery test report.

### Definition of Done

- Legalább egy teljes restore teszt lefut.
- Backup nem csak elkészül, hanem vissza is állítható.
- Kritikus appokhoz külön restore útvonal van.
- RPO/RTO deklarált.
- Backup failure alertel.

### Kritikus kérdések

- Mit mentünk Gitből?
- Mit mentünk volume-ból?
- Mit mentünk adatbázisból?
- Mi rebuildelhető teljesen?
- Mi stateful és nem elveszíthető?

---

## CH10 – Platform Productization

### Cél

A CH10 célja, hogy a PlatformInit ne csak belső homelab legyen, hanem strukturált, dokumentált, ismételhető termékjellegű csomag.

### Scope

- install flow egyszerűsítése.
- user-facing documentation.
- CLI vagy workflow-driven installer.
- profile-based setup.
- minimal / standard / full install.
- branding és naming standard.
- support matrix.
- compatibility matrix.
- release notes.
- upgrade policy.

### Output

- PlatformInit install guide.
- Versioned release model.
- Component matrix.
- Profile system.
- Release artifact.
- Operator handbook.

### Definition of Done

- Egy új környezet dokumentáció alapján újraépíthető.
- Nem kell “tribal knowledge”.
- A komponensek verziói és céljai tiszták.
- Van minimum viable production-ready profile.
- Van full profile extra komponensekkel.

### Profil javaslat

| Profil | Tartalom |
|---|---|
| Minimal | host baseline + k3s + ingress + TLS + Argo CD |
| Standard | Minimal + Authentik + Checkmk |
| Full | Standard + log pipeline + backup + compliance |
| Customer | Full + IDP + onboarding + governance |

---

## CH11 – FinOps és Governance

### Cél

A CH11 célja a költség, ownership, quota, lifecycle és policy kontroll kialakítása.

### Scope

- Hetzner cost model.
- Project budget.
- Resource tagging.
- Volume lifecycle.
- DNS lifecycle.
- Secret ownership.
- Access review.
- Change review.
- Cost reports.
- Cleanup workflows.

### Output

- Governance model.
- Cost report.
- Resource inventory.
- Ownership matrix.
- Cleanup policy.

### Definition of Done

- Minden cloud erőforrás címkézett.
- Host/volume/DNS ownership ismert.
- Nem maradnak orphan volume-ok.
- Környezetenként látszik a költség.
- Van manual approval pont éles jellegű művelethez.

### Fontos elv

A homelab olcsósága fontos, ezért a PlatformInit ne nőjön kontrollálatlanul. A single-node döntés is részben FinOps döntés.

---

## CH12 – Advanced Identity and Access Platform

### Cél

A CH12 célja az identity layer magasabb szintre emelése: nem csak login, hanem access governance.

### Scope

- Authentik advanced group model.
- RBAC across apps.
- app role mapping.
- break-glass accounts.
- access request flow.
- audit logok.
- service account lifecycle.
- MFA policy.
- session policy.
- tenant/customer identity model.

### Output

- Egységes IAM modell.
- App access matrix.
- Break-glass process.
- Access review report.
- SSO integration standard.

### Definition of Done

- Minden fontos UI SSO mögött van.
- Jogosultságok csoportalapon működnek.
- Break-glass nem keveredik napi adminnal.
- Authentik audit használható.
- Customer-facing modell előkészített.

---

## CH13 – AIOps / Intelligent Operations

### Cél

A CH13 célja AI-alapú vagy AI-segített operations képességek bevezetése, de nem úgy, hogy a rendszer black-box legyen.

### Scope

- Alert summarization.
- Log clustering.
- Incident timeline generation.
- Root cause candidate generation.
- Runbook suggestion.
- AI-assisted triage.
- DeepSeek vagy más olcsó API alapú elemzés.
- Human approval gates.
- Privacy/security guardrails.

### Output

- AI triage prototype.
- Alert summary.
- Incident report generator.
- Runbook recommender.
- Human-review queue.

### Definition of Done

- AI nem hajt végre automatikus destructive műveletet.
- AI output mindig ember által review-zható.
- Sensitive adatkezelés dokumentált.
- Incident summary hasznos, nem hallucination-alapú.
- A rendszer csökkenti a zajt, nem növeli.

### Kapcsolódás n8n-hez

A későbbi n8n workflow-k használhatók lehetnek:

- Gmail/job search automatizálásra;
- alert routingra;
- report generálásra;
- Canva / dokumentum outputokra;
- emberi review queue-kra.

---

## CH14 – Internal Developer Platform

### Cél

A CH14 célja, hogy a PlatformInit belső fejlesztői platformként működjön: egy új app vagy service bevezetése gyors, sablonos és kontrollált legyen.

### Scope

- Developer portal.
- Service catalog.
- Template-based app generation.
- CI/CD bootstrap.
- GitOps app registration.
- Secrets request.
- Monitoring/logging onboarding.
- Runbook generation.
- Environment promotion request.
- Documentation generation.

### Output

- Internal Developer Platform alap.
- App onboarding wizard vagy template workflow.
- Service catalog.
- Ownership metadata.
- Golden path dokumentáció.

### Definition of Done

- Új szolgáltatás létrehozása standard folyamat.
- App automatikusan kap CI, GitOps, ingress, TLS, monitoring, logging alapokat.
- Fejlesztő nem kézzel rakja össze a platform integrációkat.
- Operátor látja az app ownership és health state-et.

### Példa golden path

1. Új app template kiválasztása.
2. Repo/app manifest generálás.
3. CI pipeline létrehozás.
4. Argo CD app registration.
5. Ingress/TLS beállítás.
6. Authentik SSO bekötés.
7. Checkmk/logging onboarding.
8. Runbook és dashboard linkek generálása.

---

## CH15 – Customer-Facing PlatformInit

### Cél

A CH15 célja a PlatformInit ügyfél- vagy külső felhasználásra alkalmas termékesítése.

Ez már nem csak technikai platform, hanem csomagolt ajánlat:

> “Egy friss VPS-ből production-ready, SSO-val, monitoringgal, TLS-sel, GitOps-szal és backup/ops modellel rendelkező platform.”

### Scope

- Customer onboarding.
- Tenant/project model.
- Installer UX.
- Pricing/cost model.
- Docs portal.
- Support model.
- SLA/SLO alapok.
- Legal/security documentation.
- Demo environment.
- Customer handover package.
- Upgrade path.
- Managed vs self-hosted modell.

### Output

- Customer-facing documentation.
- Sales/technical overview.
- Installer/release package.
- Handover docs.
- Support runbooks.
- Security/compliance statement.
- Demo platform.

### Definition of Done

- Egy külső ügyfél/projekt számára érthető az értékajánlat.
- A telepítés nem csak fejlesztői tudással végezhető.
- A dokumentáció átadható.
- Van support és upgrade modell.
- Van világos scope: mit ad a PlatformInit és mit nem.

### Fontos pozicionálás

A CH15 nem azt jelenti, hogy a homelabból rögtön enterprise SaaS lesz. Inkább azt, hogy a korábbi CH01–CH14 eredményeiből összeáll egy átadható, csomagolt, reprodukálható platformindító rendszer.

---

# 5. Fejezetenkénti összefoglaló táblázat

| CH | Név | Fő cél | Állapot |
|---:|---|---|---|
| CH01 | Host Lifecycle | VPS létrehozás/rebuild, bootstrap, access, volume | aktív alapréteg |
| CH02 | Host Baseline | hardening, drift, FIM/AIDE, OS security | aktív alapréteg |
| CH03 | k3s Baseline | single-node Kubernetes | alapirány kész |
| CH04 | Platform Services | ingress, TLS, Argo CD | alapirány kész |
| CH04.5 | Identity Foundation | Authentik SSO alap | kialakítva |
| CH04.6 | Argo CD SSO | Argo CD + Authentik OIDC | kialakítva |
| CH05 | Operations | Checkmk alapú operator monitoring | aktuális stabilizált irány |
| CH06 | Security v2 | cluster security, policy, secrets | következő logikus fejezet |
| CH07 | Service Templates | app onboarding sablonok | roadmap |
| CH08 | Multi-Env Promotion | dev/stage/prod promotion | roadmap |
| CH09 | Backup/DR | restore, RPO/RTO, reliability | roadmap |
| CH10 | Productization | csomagolás, release, install profilok | roadmap |
| CH11 | FinOps/Governance | költség, ownership, policy | roadmap |
| CH12 | Advanced IAM | access governance, break-glass, audit | roadmap |
| CH13 | AIOps | AI-assisted operations | roadmap |
| CH14 | IDP | developer portal, service catalog | roadmap |
| CH15 | Customer PlatformInit | külső/ügyfélkész platformcsomag | roadmap |

---

# 6. Operációs workflow modell

## 6.1 Ajánlott workflow sorrend tiszta rebuild esetén

1. CH01 host create/rebuild.
2. CH01 bootstrap.
3. CH01 access tooling sync.
4. CH02 temporary privilege grant.
5. CH02 host baseline.
6. CH02 drift/FIM validation.
7. CH03 k3s install.
8. CH04 platform services.
9. CH04.5 identity foundation.
10. CH04.6 Argo CD SSO.
11. CH05 operations stack.
12. CH05 operations validation.
13. CH06+ security/platform expansion.

## 6.2 GitOps határ

| Réteg | Kezelés |
|---|---|
| Host provisioning | GitHub Actions / Terraform |
| Host bootstrap | GitHub Actions / scripts |
| Host baseline | GitHub Actions / scripts |
| k3s install | GitHub Actions / scripts |
| Long-running Kubernetes apps | Argo CD |
| App lifecycle | GitOps |
| Manual kubectl | csak diagnosztikára / emergency esetben |

---

# 7. Review és AI-fejlesztési workflow

A projektben kialakult preferált agentic workflow:

1. **DeepSeek Coder**
   - batchben végrehajtja a konkrét implementációs taskokat;
   - lehetőleg nem commitol végleges review nélkül.

2. **OpenAI Reviewer**
   - changed-files-only review;
   - minőség, integráció, regresszió;
   - reviewer commit.

3. **OWASP Reviewer**
   - periodikus vagy batch-végi security/privacy review;
   - nem minden kis task után külön;
   - MUST_FIX / SHOULD_FIX kategorizálás.

4. **Orchestrator**
   - batch lifecycle, validation, handoff.

Fontos szabályok:

- WSL/Linux-only utasítások.
- Nincs CMD/PowerShell wrapper.
- VS Code + WSL fejlesztési modell.
- Minimal targeted patch.
- Minden repo handoffnál branch név és enterprise-style commit message.
- Nem módosítunk fájlokat válogatás nélkül.

---

# 8. Skill roadmap

## 8.1 Már meglévő erős alapok

- Linux üzemeltetés.
- Incident management.
- Application operations.
- Monitoring szemlélet.
- GitHub Actions gyakorlati használat.
- Kubernetes/k3s gyakorlati homelab tapasztalat.
- Cloud/VPS költségtudatos gondolkodás.
- Terraform / infra automation alapok.
- SRE-style riport és validációs gondolkodás.

## 8.2 Fejlesztendő területek

| Terület | Miért fontos |
|---|---|
| Kubernetes mélyebb troubleshooting | CH03–CH07 stabilitáshoz |
| GitOps advanced | Argo CD app-of-apps, promotion, drift |
| Security policy | CH06, CH12 |
| Secrets management | production-ready baseline |
| Backup/restore | CH09 valós használhatóság |
| Observability design | CH05 operator UX finomítása |
| Platform product thinking | CH10–CH15 |
| Python/Go scripting | workflow tooling és validátorok |
| Web/backend alapok | Ops Center / IDP / customer portal |
| OWASP alapok | customer-facing irányhoz |

## 8.3 Javasolt tanulási sorrend

1. Kubernetes troubleshooting és k3s internals.
2. Argo CD GitOps patterns.
3. SOPS/age vagy Sealed Secrets.
4. Kyverno policy alapok.
5. Backup/restore: PostgreSQL, volumes, object storage.
6. Checkmk operations model.
7. CI/CD release promotion.
8. Platform productization.
9. Developer portal / IDP alapok.
10. AIOps workflow design.

---

# 9. Kockázatok és nyitott döntések

| Kockázat | Hatás | Kezelés |
|---|---|---|
| Túl sok komponens | lassú, törékeny platform | Minimal/Standard/Full profil |
| Dashboard noise | nem használható monitoring | Checkmk/operator-first UX |
| Storage layout drift | stateful appok sérülhetnek | CH01 hard fail validáció |
| Secrets rossz kezelése | security kockázat | CH06 secrets standard |
| Manual kubectl drift | GitOps sérül | Argo CD ownership |
| AI-generated code vakon elfogadva | minőség/security gond | Reviewer + OWASP batch gate |
| Single-node SPOF | nincs HA | elfogadott scope, backup/DR erősítése |
| Provider capacity gond | host create fail | több region / fallback / rebuild docs |
| Customer-facing túl korán | félkész product | CH10–CH15 csak stabil foundation után |

---

# 10. Rövid stratégiai értékelés

A PlatformInit akkor lesz erős projekt, ha nem akar egyszerre mindent megoldani. A helyes sorrend:

1. **CH01–CH05 stabil, érthető, reprodukálható foundation.**
2. **CH06 security baseline.**
3. **CH07 app onboarding template-ek.**
4. **CH08–CH09 promotion + backup/DR.**
5. **CH10 productization.**
6. **CH11–CH15 governance, IDP, AIOps, customer-facing csomag.**

A jelenlegi legjobb irány az, hogy a projekt megőrzi a single-node, cost-conscious, deterministic rebuild alapelveket, és nem csúszik át túl korán túlbonyolított enterprise platformba.

A CH05 Checkmk-pivot kifejezetten jó irány, mert az üzemeltetési érték nem az, hogy hány dashboard van, hanem hogy az operátor gyorsan megértse a hibát.

---

# 11. Következő javasolt munkacsomag

## Közvetlen következő lépés: CH05 checkpoint lezárás + CH06 előkészítés

### Taskok

1. CH05 aktuális stabil állapot dokumentálása.
2. Checkmk native admin fallback dokumentálása.
3. Checkmk SSO / forwardAuth / trusted-header flow rajzos vagy lépéses dokumentálása.
4. CH05 validation workflow review: tényleg runtime állapotot ellenőriz-e.
5. CH01 storage baseline véglegesítése.
6. CH06 security architecture döntés:
   - SOPS/age vs Sealed Secrets vs Vault;
   - Kyverno vs OPA;
   - Trivy/kube-bench/Falco szükségesség.
7. CH06 tasklist generálása.
8. CH06 branch létrehozása.
9. DeepSeek Coder batch prompt.
10. OpenAI Reviewer és OWASP Reviewer gate előkészítése.

---

# 12. Záró megfogalmazás

A PlatformInit / DevOps Homelab 2 jelenlegi formájában egy komoly, rétegzett platformépítési projekt. A legerősebb értéke nem önmagában a használt technológia, hanem az, hogy a teljes útvonalat próbálja lefedni:

- infrastruktúra létrehozás;
- host hardening;
- Kubernetes baseline;
- GitOps;
- identity;
- operations;
- security;
- backup;
- application onboarding;
- governance;
- végül customer-facing platformcsomag.

A legfontosabb fókusz most az, hogy CH01–CH05 maradjon stabil, tiszta és dokumentált, majd CH06-tal induljon el a platform security/compliance réteg. CH10–CH15 csak akkor lesz értelmes, ha az alsó rétegek tényleg reprodukálhatók és nem csak “épp működnek”.
