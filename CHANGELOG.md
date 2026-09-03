# Changelog

All notable changes to this project will be documented in this file. See [conventional commits](https://www.conventionalcommits.org/) for commit guidelines.

---
## [0.8.3](https://github.com/wefts/swarm/compare/v0.8.2..v0.8.3) - 2026-09-03

### Bug Fixes

- **(graph)** avoid opaque mapset kinds in contract checks - ([a731d0d](https://github.com/wefts/swarm/commit/a731d0df6b7d3a3a8a993b4eb01076d68fab7e02)) - Serhii BOREMCHUK

### Tests

- **(core)** use a synthetic address in the grounding-gate fixture - ([ba31579](https://github.com/wefts/swarm/commit/ba31579bc94799385b3d8599a8cc488859c29063)) - Searge

---
## [0.8.2](https://github.com/wefts/swarm/compare/v0.8.1..v0.8.2) - 2026-09-03

### Bug Fixes

- **(core)** prioritize relevant grounding before budget - ([0e3c6b8](https://github.com/wefts/swarm/commit/0e3c6b8f2f05d1d1d209109684a62f50c83f525f)) - Serhii BOREMCHUK

### Documentation

- **(graph)** specify temporal fact model - ([eeafd20](https://github.com/wefts/swarm/commit/eeafd206544c68790075b786ed95a232d266ee29)) - Serhii BOREMCHUK

### Miscellaneous Chores

- **(kernel)** apply elixir formatting - ([ef45cf9](https://github.com/wefts/swarm/commit/ef45cf9466b388d9ca17805653081d3fd6e66178)) - Serhii BOREMCHUK

### Style

- **(docs)** clear markdownlint findings in ADR-16 and pre-answering design - ([1f9c550](https://github.com/wefts/swarm/commit/1f9c550dea11834322321c6a56aa5f3878c44841)) - Serhii BOREMCHUK

---
## [0.8.1](https://github.com/wefts/swarm/compare/v0.8.0..v0.8.1) - 2026-09-02

### Bug Fixes

- **(consilium)** prevent self-judged synthesis - ([e463c21](https://github.com/wefts/swarm/commit/e463c2197f218087c3b9438f4ccb585d0e950e67)) - Serhii BOREMCHUK

---
## [0.8.0](https://github.com/wefts/swarm/compare/v0.7.0..v0.8.0) - 2026-09-02

### Features

- **(citations)** resolve source refs to configured links - ([062b852](https://github.com/wefts/swarm/commit/062b852c99e586482b9101d91d4805784c1d35c3)) - Serhii BOREMCHUK
- **(disposable-graph)** preserve page identity and skip ledgers - ([e44f79b](https://github.com/wefts/swarm/commit/e44f79b9efa51446e8bb6a1a7026ddb8ff881c12)) - Serhii BOREMCHUK
- **(ontology)** enforce governed relation endpoints - ([a1d338b](https://github.com/wefts/swarm/commit/a1d338b096a2c2e6ea7ff0aee12a8fdd2492e8fc)) - Serhii BOREMCHUK

---
## [0.7.0](https://github.com/wefts/swarm/compare/v0.6.0..v0.7.0) - 2026-09-02

### Features

- **(ontology)** add document-kind grounding controls - ([dce47cc](https://github.com/wefts/swarm/commit/dce47ccbd18fe08444251bb2b8512929a89d6e17)) - Serhii BOREMCHUK

---
## [0.6.0](https://github.com/wefts/swarm/compare/v0.5.0..v0.6.0) - 2026-09-02

### Bug Fixes

- **(core)** gate escalation grounding by relevance - ([46e490c](https://github.com/wefts/swarm/commit/46e490cb42db0cec497ac2f6b2b79d2a31264bed)) - Serhii BOREMCHUK
- **(core)** prewarm gate fleet and size breaker - ([94f7aca](https://github.com/wefts/swarm/commit/94f7aca5a1e808c18462e45ae2a0b6c2a18c6e1d)) - Serhii BOREMCHUK
- **(core)** reject mismatched live baselines - ([d2e3b1a](https://github.com/wefts/swarm/commit/d2e3b1aed2bbdbd9b4256539cf04db34b69c7606)) - Serhii BOREMCHUK
- **(core)** include visibility scopes in baselines - ([8c78aeb](https://github.com/wefts/swarm/commit/8c78aeb8968a0df9ba1f9d628e957fbacf14a09d)) - Serhii BOREMCHUK
- **(topology)** require explicit staging apply - ([ce3fd55](https://github.com/wefts/swarm/commit/ce3fd556332530be76c956c80910dae88ebe0768)) - Serhii BOREMCHUK
- **(topology)** derive cross-source routes privately - ([64c2cb7](https://github.com/wefts/swarm/commit/64c2cb7947aa540bfaa0d4919f274390bfa76e8b)) - Serhii BOREMCHUK

### Features

- **(network)** derive route facts at read time - ([e99633c](https://github.com/wefts/swarm/commit/e99633c647642d625638fa8b488fa32143106766)) - Serhii BOREMCHUK

### Tests

- **(core)** add live ask batch runner - ([84b01e0](https://github.com/wefts/swarm/commit/84b01e0a881dfc54392c7ef5e94a18e5bec00326)) - Serhii BOREMCHUK

---
## [0.5.0](https://github.com/wefts/swarm/compare/v0.4.0..v0.5.0) - 2026-09-02

### Bug Fixes

- **(ml)** disable thinking for intermediate generation - ([03d08ab](https://github.com/wefts/swarm/commit/03d08abcf6ef7cea2ef696c76849e83dc61e981e)) - Serhii BOREMCHUK
- **(world-map)** route qualified ip address cues - ([8ab4cfd](https://github.com/wefts/swarm/commit/8ab4cfd03c4804bcbf841f5c282d7d4d770359ae)) - Serhii BOREMCHUK

### Features

- **(world-map)** add structured technology serve - ([6f180c1](https://github.com/wefts/swarm/commit/6f180c17872eb0d333517888d11ac71667f6aa25)) - Serhii BOREMCHUK

---
## [0.4.0](https://github.com/wefts/swarm/compare/v0.3.0..v0.4.0) - 2026-09-02

### Features

- **(calibration)** add external calibration loop - ([03695d4](https://github.com/wefts/swarm/commit/03695d4c3b5583a128998451d0c2e56972b1921d)) - Serhii BOREMCHUK
- **(graph)** add deterministic network address semantics - ([7886a16](https://github.com/wefts/swarm/commit/7886a168ad464d5916c49f67a596b8d25e8d9949)) - Serhii BOREMCHUK

---
## [0.3.0](https://github.com/wefts/swarm/compare/v0.2.0..v0.3.0) - 2026-09-01

### Features

- **(world-map)** add semantic gate routing - ([0596e4c](https://github.com/wefts/swarm/commit/0596e4c5585fb1b7274316ffae38a6c1f8820c4c)) - Serhii BOREMCHUK

---
## [0.2.0](https://github.com/wefts/swarm/compare/v0.1.0..v0.2.0) - 2026-09-01

### Bug Fixes

- **(core)** route Ukrainian fast-tier asks - ([0a5e24e](https://github.com/wefts/swarm/commit/0a5e24e182c3a3f32a78af51837a091334d514ce)) - Serhii BOREMCHUK
- **(enrichment)** keep topology routes host-scoped - ([ed61afc](https://github.com/wefts/swarm/commit/ed61afc28aa7507b8273ae1f781d57c726ed933a)) - Serhii BOREMCHUK
- **(enrichment)** use class freshness frontier for who facts - ([bcc5299](https://github.com/wefts/swarm/commit/bcc5299157de2376518c979a03c86db5dd60cfa5)) - Serhii BOREMCHUK
- **(graph)** use class freshness frontier for network facts - ([c45fb50](https://github.com/wefts/swarm/commit/c45fb50d2e749a3f383d4edb69a2e8c4e1317fe7)) - Serhii BOREMCHUK

### Documentation

- propose structural spine vocabulary - ([86d15c6](https://github.com/wefts/swarm/commit/86d15c6938f9e58c27256ce8fb90fcb1c87b7198)) - Serhii BOREMCHUK
- define structural spine anchor types - ([1f991b0](https://github.com/wefts/swarm/commit/1f991b0584b69b4fef65b4bc44b17bdc3f19a547)) - Serhii BOREMCHUK

### Features

- **(core)** calibrate entity-profile structured serve - ([308f955](https://github.com/wefts/swarm/commit/308f955dc4085430969e8ba019d12aab12d3e72b)) - Serhii BOREMCHUK
- **(enrichment)** add page tree projection gate - ([faa2246](https://github.com/wefts/swarm/commit/faa2246ae11fb9c7003006909d3278329a77a4cb)) - Serhii BOREMCHUK
- **(enrichment)** derive topology joins - ([c0fc9bd](https://github.com/wefts/swarm/commit/c0fc9bd3dfa7ce2b97c56a530f30ec7dd9764051)) - Serhii BOREMCHUK

### Tests

- **(core)** cover broad entity profile asks - ([8a30689](https://github.com/wefts/swarm/commit/8a306898636ed1298e3897fc551590666330654e)) - Serhii BOREMCHUK

---
## [0.1.0](https://github.com/wefts/swarm/compare/pre-squash-swarm-20260709..v0.1.0) - 2026-08-28

### Bug Fixes

- **(gate)** pick the best-matching procedure candidate, not union all (ADR-17 #2) - ([6a8d122](https://github.com/wefts/swarm/commit/6a8d1228efab5d9726ec28c2e33483bc4b2676e7)) - Serhii BOREMCHUK
- **(gate)** entail with json:true + 3s breaker — thinking-model entail was timing out - ([687ea77](https://github.com/wefts/swarm/commit/687ea7798ef5b71e01344b54dc1897d9b4dc9cdc)) - Serhii BOREMCHUK
- **(gate)** entity_profile serve path OFF by default (live-validation false-serve guard) - ([425d271](https://github.com/wefts/swarm/commit/425d271fb66e653d45312ed89ed47a33b62aff26)) - Serhii BOREMCHUK
- **(identity)** authenticated public baseline in scopes_for — the KB was invisible to everyone - ([9c70342](https://github.com/wefts/swarm/commit/9c70342a02be9d90864f9637561db023df2b8f1c)) - Serhii BOREMCHUK
- **(ml)** pool long-lived gRPC channels to sidestep the disconnect crash - ([bd87f32](https://github.com/wefts/swarm/commit/bd87f326669fd1ceb50917db59a20a2c59f4cf7e)) - Serhii BOREMCHUK
- **(ml)** send keep_alive as a NUMBER, not a string (Ollama HTTP 400) - ([e7eb299](https://github.com/wefts/swarm/commit/e7eb299c446cc3bd99cab99d620e0bd6605c4a75)) - Serhii BOREMCHUK
- **(ml)** raise num_predict cap 512->4096 (512 truncated thinking models) - ([c1cff07](https://github.com/wefts/swarm/commit/c1cff078c13030b3dc73cdf8f13ccac202700497)) - Serhii BOREMCHUK
- **(runtime)** treat empty SWARM_TIER_GATE_ENTAIL_MODEL as unset ("" is truthy in Elixir) - ([f9fa045](https://github.com/wefts/swarm/commit/f9fa045e9fcf08baf4e74430867771bbb3487f0d)) - Serhii BOREMCHUK
- **(sh)** remove sync scripts - ([ed60b1d](https://github.com/wefts/swarm/commit/ed60b1d8dbef8175a717daf4d10da5097b841c41)) - Searge
- **(synonymy)** retrieval expands over the corpus's concept types (entity/article), not just concept - ([47a77ad](https://github.com/wefts/swarm/commit/47a77ad607f54cb79f774bb5c3c4012590ebbbe0)) - Serhii BOREMCHUK
- **(synonymy)** harden LLM-confirm against prompt injection (residual #4) - ([b95cec3](https://github.com/wefts/swarm/commit/b95cec31758e9c3874233c05c1059fd2745bef83)) - Serhii BOREMCHUK
- **(world-map)** network candidate matching — match term anywhere in key (mid-FQDN segments), best-overlap subject wins - ([9b12386](https://github.com/wefts/swarm/commit/9b1238668a628bacc5fedff7b6e59571ec873722)) - Serhii BOREMCHUK
- switch to alias - ([a127e27](https://github.com/wefts/swarm/commit/a127e27ca9bffa48f117ac2d849402fa60ce80c8)) - Searge

### Documentation

- **(adr)** ADR-14 data/memory model — coarse lineage node + content/chunk store - ([1030986](https://github.com/wefts/swarm/commit/10309868bc05ebf204cc5ce8f3a67508a0e36da6)) - Serhii BOREMCHUK
- **(adr)** ADR-14 Accepted; sync data-memory-model spec to built reality - ([acfe2bc](https://github.com/wefts/swarm/commit/acfe2bc2bed903fcdb947aec829b2f92f369f7d1)) - Serhii BOREMCHUK
- **(adr-15)** non-FOUND responses carry only status (review-step no-leak tightening) - ([68d8803](https://github.com/wefts/swarm/commit/68d88037b884191fe74ae433f7fbc68ace078397)) - Serhii BOREMCHUK
- **(adr-15)** pin recommended deliberation retention config defaults (config-driven, tunable) - ([e9f0ff1](https://github.com/wefts/swarm/commit/e9f0ff1a6402a5eb3fb691b1ae25322cad21231f)) - Serhii BOREMCHUK
- **(adr-16)** pg_search spike result — GREEN on relevance+no-leak, GO-WITH-CONDITIONS - ([e68b890](https://github.com/wefts/swarm/commit/e68b8900f9476dcc1cb73f9547239491d58b4777)) - Serhii BOREMCHUK
- **(adr-16)** native-bypass explored → resolved FOR pg_search; status Proposed→MIGRATING - ([6795b24](https://github.com/wefts/swarm/commit/6795b24bba9a73dd02355e0512afff01b27da2c4)) - Serhii BOREMCHUK
- **(design)** enrichment reward-gate control plane spec (ADR-13 EOS-4) - ([70a659c](https://github.com/wefts/swarm/commit/70a659cbaebf0f7582f6a6edbd81e593da5da2a3)) - Serhii BOREMCHUK
- **(design)** world-map pre-answering spec (workspace ADR-17) - ([1e280f6](https://github.com/wefts/swarm/commit/1e280f699e78953f70f3c73bdc548346a2fcc5dd)) - Serhii BOREMCHUK
- **(design)** reconcile world-map spec §1 — step_ordinal is a dedicated edge column, not a property map - ([65ee48b](https://github.com/wefts/swarm/commit/65ee48ba5d979fb1ee92837955cc554b4d4f9fa2)) - Serhii BOREMCHUK
- **(design)** world-map spec — ADR-17 Accepted, status in-build, step_index→step_ordinal drift fixed - ([50c46c0](https://github.com/wefts/swarm/commit/50c46c032f5b4bcadc06a6aae81084eb82a25a6b)) - Serhii BOREMCHUK
- **(design)** tier-gate §3 — fold in the Fork B council decisions - ([9735fe9](https://github.com/wefts/swarm/commit/9735fe9bd750a69e269e35330ee5a1f1aa4f4f11)) - Serhii BOREMCHUK
- **(design)** tier-gate BUILT — §6.4-7 done, §6.8 measurement next - ([e104130](https://github.com/wefts/swarm/commit/e10413074bd34e44d56a0cbafe75229492d6d1ad)) - Serhii BOREMCHUK
- sync architecture + dockerization specs to built reality - ([cb63f3a](https://github.com/wefts/swarm/commit/cb63f3abdd13c2e302be33464a10ac908163e0d4)) - Serhii BOREMCHUK
- correct the combine_typed overclaim — ready contract, not an active defense - ([75042f9](https://github.com/wefts/swarm/commit/75042f9bd5627ae4da914f1111f332decb724f98)) - Serhii BOREMCHUK
- combine_typed is now WIRED (workspace ADR-13 / EOS-2) — undo the review-#4 "unwired" note - ([557e422](https://github.com/wefts/swarm/commit/557e422f61f2c9f107a769d0e767d030ad6eb02e)) - Serhii BOREMCHUK
- ADR-15 dashboard projection RPCs + wire-contract spec (Proposed) - ([9c2f15c](https://github.com/wefts/swarm/commit/9c2f15c6256e9be0b92ca890a1941eb6c7707a55)) - Serhii BOREMCHUK
- add ADR-16 retrieval engine (pg_search/ParadeDB), Proposed - ([1bcbee1](https://github.com/wefts/swarm/commit/1bcbee1f01a689ddb41346820129b5cf8a72e36b)) - Serhii BOREMCHUK
- users/identity/privacy design spec (ADR-16) - ([0acbbba](https://github.com/wefts/swarm/commit/0acbbba2077e6498b059104d4ec3d23c35aee927)) - Serhii BOREMCHUK

### Features

- **(actor)** verified actor assertion — kernel verifies + derives, never trusts (ADR-16 step 2 / D9) - ([2771e1d](https://github.com/wefts/swarm/commit/2771e1d35406edbc4e9c2bfbad00db14cd9d20ce)) - Serhii BOREMCHUK
- **(admin)** access grants + user lifecycle — cap-gated, audited (ADR-16 step 5) - ([77bcee2](https://github.com/wefts/swarm/commit/77bcee268cccd305a2183529471e2364203e7705)) - Serhii BOREMCHUK
- **(bench)** confidence saturation spike (T1) + swarm ADR-3 - ([cf0e59b](https://github.com/wefts/swarm/commit/cf0e59b46726f17b95972ef82e656bb2dde0cde6)) - Serhii BOREMCHUK
- **(config)** make the consilium model fleet env-overridable - ([3838649](https://github.com/wefts/swarm/commit/3838649ccbb5243cfd6fde15ade480b7256df9dc)) - Serhii BOREMCHUK
- **(config)** derive DB name from SWARM_ENV, kill the swarm_dev silent default - ([b35cf84](https://github.com/wefts/swarm/commit/b35cf84a631ddebaf4bf96dcb7006b61a1d62dd3)) - Serhii BOREMCHUK
- **(connector)** kernel-driven ingestion contract (Phase B, swarm ADR-5) - ([17f3f4f](https://github.com/wefts/swarm/commit/17f3f4f54a09e6b0f0b733e8f69a27fd6f57f1ee)) - Serhii BOREMCHUK
- **(connector)** first live slice — Wikipedia connector + entity-resolution ADR-13 - ([148d76b](https://github.com/wefts/swarm/commit/148d76b8158e1fbcb3183247f1865ef17df9ce83)) - Serhii BOREMCHUK
- **(consilium)** supported-calibration eval + judge_verdict seam (Phase-2 gate) - ([0ac5468](https://github.com/wefts/swarm/commit/0ac5468ecfd479b351c01b1238a69b4f0e0a6490)) - Serhii BOREMCHUK
- **(consilium)** stricter groundedness judge prompt + corrected calibration labels - ([0038d2f](https://github.com/wefts/swarm/commit/0038d2fe5aecb67e2e509b059d4acf39fe145175)) - Serhii BOREMCHUK
- **(conversations)** kernel-owned, owner-private conversations + RLS belt (ADR-16 step 3) - ([85d9f78](https://github.com/wefts/swarm/commit/85d9f7815dc50a924b7e7979c57232cd3b52d106)) - Serhii BOREMCHUK
- **(conversations)** admin break-glass read — impersonate + audit-before-return (ADR-16 step 4/D6) - ([6cffed6](https://github.com/wefts/swarm/commit/6cffed61a752802db96d6dc414456a0a664207af)) - Serhii BOREMCHUK
- **(core)** Phase C — cost budget, result algebra, identity, deflection (T5–T9) - ([0180a95](https://github.com/wefts/swarm/commit/0180a95fda4c5339487f6316234f5566cf5e3cbc)) - Serhii BOREMCHUK
- **(core)** ActivityFeed RPC — polled, scope-safe, opaque cursor (ADR-15) - ([367bd11](https://github.com/wefts/swarm/commit/367bd11a6f1f63ba4224cacae2d5e18ab0af0b3e)) - Serhii BOREMCHUK
- **(core)** identity/privacy gRPC RPCs + dual-accept auth seam (ADR-16 step 6a) - ([55d72b9](https://github.com/wefts/swarm/commit/55d72b9e341d608517ddbb92f377c9a325eee653)) - Serhii BOREMCHUK
- **(core)** ProvisionActor — JIT-provision an SSO subject over the wire (ADR-16 D3) - ([28f443a](https://github.com/wefts/swarm/commit/28f443af763e95f02f88c83b581fe681a3eb73a2)) - Serhii BOREMCHUK
- **(core)** ListSsoMap + ManageSsoMap RPC (SSO group→our-group mapping) - ([36454f4](https://github.com/wefts/swarm/commit/36454f488444f5674435ef835dcf1589291ec8d0)) - Serhii BOREMCHUK
- **(core)** GetGroup RPC — group detail with member list (ADR-19 B1) - ([516018e](https://github.com/wefts/swarm/commit/516018e347a5542e871fc6e7707a8f12bcf8fc68)) - Serhii BOREMCHUK
- **(core)** ADR-19 authz enforcement guards (B2) - ([d05a6fb](https://github.com/wefts/swarm/commit/d05a6fb23be352b947c99abe2ba420d85243ff72)) - Serhii BOREMCHUK
- **(core)** group-derived superadmin + atomic authority migration (ADR-19 B3) - ([7d85c81](https://github.com/wefts/swarm/commit/7d85c81bae7fb1814117f2fce42d1ae914b191d6)) - Serhii BOREMCHUK
- **(core)** project-centered access + wheel elevation (workspace ADR-20, kernel) - ([7db12f2](https://github.com/wefts/swarm/commit/7db12f2768d20be890a31ad0474f1df16d286986)) - Serhii BOREMCHUK
- **(core/auth)** shadow-log plaintext viewers accepted in :dual mode - ([4b11866](https://github.com/wefts/swarm/commit/4b118669d1f664968bc433e2d6be8b361a3fc274)) - Serhii BOREMCHUK
- **(db)** swarm_app non-superuser runtime role — the RLS belt goes live (rls-app-role) - ([f04ea5f](https://github.com/wefts/swarm/commit/f04ea5f5954d4b935aa7060c4428174da36fecc6)) - Serhii BOREMCHUK
- **(docs)** translate and enhance - ([466bbc6](https://github.com/wefts/swarm/commit/466bbc6587153a4d7bf68e30a5a7c051cc5f9963)) - Searge
- **(docs)** add agents.md - ([36b50f5](https://github.com/wefts/swarm/commit/36b50f59d1888669be47aa3021118a63ca850cc0)) - Searge
- **(enrichment)** reward-gated extraction worker — claims as typed assertions (ADR-13 EW-2) - ([e5241d9](https://github.com/wefts/swarm/commit/e5241d9de1cf54bb6c61941592aa12af865485b6)) - Serhii BOREMCHUK
- **(enrichment)** content-sensitive watermark + stale-claim replacement (ADR-13 EW-3) - ([d677bb9](https://github.com/wefts/swarm/commit/d677bb926b9f3e106928e4fc51837dbe94e30e42)) - Serhii BOREMCHUK
- **(enrichment)** worth-it priority scheduler (ADR-13 EW-4) - ([f38e9f7](https://github.com/wefts/swarm/commit/f38e9f7e9682ebc492e7eaefc61392ab120fe62a)) - Serhii BOREMCHUK
- **(enrichment)** bounded worth-it scan + generation-bounded convergence (ADR-13 EW-5) - ([fba75d1](https://github.com/wefts/swarm/commit/fba75d1046dd9a115e466b9dec50ea704bd79054)) - Serhii BOREMCHUK
- **(enrichment)** persist priority decisions for calibration (CTC-2 prerequisite) - ([0c8fd13](https://github.com/wefts/swarm/commit/0c8fd1326d61e4dbe7d749e9d211b6c07664c495)) - Serhii BOREMCHUK
- **(enrichment)** make the reward-gate threshold env-overridable (per-corpus calibration) - ([7612a97](https://github.com/wefts/swarm/commit/7612a971f9c03b5dd8cd035b31ea9caf82c5bda9)) - Serhii BOREMCHUK
- **(enrichment)** procedure extraction — emit has_step edges (ADR-17 #2) - ([7f6e386](https://github.com/wefts/swarm/commit/7f6e3863f64ddde9079f57cbbd616f0fa793ccb7)) - Serhii BOREMCHUK
- **(entity-resolution)** entity identity vectors (ER-1) - ([826b2bb](https://github.com/wefts/swarm/commit/826b2bb8200dec10a6e5511983772405a3cb8427)) - Serhii BOREMCHUK
- **(entity-resolution)** candidate proposal under a two-signal hard gate (ER-2) - ([e460933](https://github.com/wefts/swarm/commit/e46093392a82a14070852fd4449b6fa1fa4b5262)) - Serhii BOREMCHUK
- **(entity-resolution)** confirm + merge + driver — precision-first soft-match (ER-3) - ([712f79a](https://github.com/wefts/swarm/commit/712f79a2a9eac18ea7d7ad7990b92c1d60d71c7b)) - Serhii BOREMCHUK
- **(gate)** Procedure.candidates/3 — the gate finds procedure entities directly (ADR-17 #2) - ([979bfc6](https://github.com/wefts/swarm/commit/979bfc65bea90904c7d64dd8e6a9c4370d35715f)) - Serhii BOREMCHUK
- **(gate)** thread procedure NAME into entail grounding + answer (go/no-go tuning) - ([29024a5](https://github.com/wefts/swarm/commit/29024a5dc9dc40ba48c45f69c7df9965b5bee26e)) - Serhii BOREMCHUK
- **(gate)** synthetic calibration eval + public Gate.entail/3 seam (go/no-go) - ([022eef0](https://github.com/wefts/swarm/commit/022eef04ac50623fe6e6b13ef0b013fa2505ef57)) - Serhii BOREMCHUK
- **(graph)** write-validated schema integrity contract (T2, swarm ADR-4) - ([6842435](https://github.com/wefts/swarm/commit/684243522d171e4e09f704e5988eb348af0cc335)) - Serhii BOREMCHUK
- **(graph)** Phase D — backpressure/DLQ, trace GC, zones+N3, coordination (T10–T13) - ([8ceb623](https://github.com/wefts/swarm/commit/8ceb62330ae9280d36a2c5f5b80dbfdceefdfb15)) - Serhii BOREMCHUK
- **(graph)** entity resolution layer 2 — merge primitive + redirect resolution (swarm ADR-13) - ([21e5dca](https://github.com/wefts/swarm/commit/21e5dca562e13a6db5df9eeba4942a204923e8ac)) - Serhii BOREMCHUK
- **(graph)** evidential origin substrate — distinct-origin reinforcement (ADR-13 EOS-1) - ([9f1aafe](https://github.com/wefts/swarm/commit/9f1aafefc21d1ae3ecf39ab331d54ffdb02588ef)) - Serhii BOREMCHUK
- **(graph)** wire combine_typed via node-local corroboration (ADR-13 EOS-2) - ([bb245e6](https://github.com/wefts/swarm/commit/bb245e65f5725e28a05eb99739d194434cd99670)) - Serhii BOREMCHUK
- **(graph)** edge-level evidence_kind — the assertion carries its own kind (ADR-13 EW-1) - ([25cd7eb](https://github.com/wefts/swarm/commit/25cd7ebf1e0b842b3baa34dc96918c6e2be862f8)) - Serhii BOREMCHUK
- **(graph)** node-bounded relaxation replaces path enumeration (swarm ADR-3) - ([5561744](https://github.com/wefts/swarm/commit/5561744b202b97cf7b3e79d980d7a04e4db249a9)) - Serhii BOREMCHUK
- **(graph)** source-node ghost-purge — merge/GC purge derived edges (ADR-17 §2/ADR-13) - ([8af0b91](https://github.com/wefts/swarm/commit/8af0b91ae45a39bfbfd34a34f0a9915123057d6c)) - Serhii BOREMCHUK
- **(identity)** kernel identity store — users/emails/links/groups/roles (ADR-16 step 1) - ([9568537](https://github.com/wefts/swarm/commit/9568537ccbe999290ea2e76b8d0a6311e79bacff)) - Serhii BOREMCHUK
- **(ingest)** structure-aware segmenter (swarm_markdown_v1) - ([c77f382](https://github.com/wefts/swarm/commit/c77f3828f59087b61b29ddc7f05e53924df102f9)) - Serhii BOREMCHUK
- **(ingest)** thread evidential origin from the connector boundary (ADR-13 EOS-1b) - ([f7ba86a](https://github.com/wefts/swarm/commit/f7ba86a4cf66551d586a6a53aa81776cd7494ba0)) - Serhii BOREMCHUK
- **(ingest)** write-amplification bound + resolve per-type node.vec (node-vec-per-type) - ([8120c8d](https://github.com/wefts/swarm/commit/8120c8d1a7ff7784d368f6a82793d0a71ddd1750)) - Serhii BOREMCHUK
- **(kernel)** stigmergy signal — transactional outbox to worker reactions - ([ce84fbe](https://github.com/wefts/swarm/commit/ce84fbee4be8273385aca9f122ea8c43def1072d)) - Serhii BOREMCHUK
- **(kernel)** data-foundation Phase 1 — content/chunk store, typed ingest, hybrid retrieval (ADR-14 / C1′) - ([e6303bc](https://github.com/wefts/swarm/commit/e6303bc1a76a1c0b885146c88e20cfefb1c601ac)) - Serhii BOREMCHUK
- **(kernel)** relevance floor + cosine-aware ranking for hybrid retrieval - ([a9d264c](https://github.com/wefts/swarm/commit/a9d264cefbd020f81bb9caa40829971cf6447447)) - Serhii BOREMCHUK
- **(kernel)** route Core.ask through hybrid retrieval with relevance gating - ([393ba43](https://github.com/wefts/swarm/commit/393ba4324f0b2dd53447b606b09ff8b7afbee4a0)) - Serhii BOREMCHUK
- **(person)** person-as-data projection + chat-fact leak rule (ADR-16 step 7) - ([1d2fb94](https://github.com/wefts/swarm/commit/1d2fb9400595dfea0ee94118f98b36c906d51c2b)) - Serhii BOREMCHUK
- **(privacy)** person-scope leak guard — private ungrantable, user nodes pinned private (ADR-16) - ([59b539f](https://github.com/wefts/swarm/commit/59b539f17339cddd21a95869a8dfb87ee1e366a5)) - Serhii BOREMCHUK
- **(procedure)** procedure representation + aggregation view (ADR-17 §1-2) - ([8246079](https://github.com/wefts/swarm/commit/8246079b3fb1b4b7b053edaa48eab99ffcc9d03e)) - Serhii BOREMCHUK
- **(procedure)** has_generation_collision? belt (ADR-17 §2/§3 Correction 3) - ([43ba6d1](https://github.com/wefts/swarm/commit/43ba6d15344ef5c0bb6a80231f11f9164ee7c3f8)) - Serhii BOREMCHUK
- **(retrieval)** weighted RRF — protect exact lexical hits from dense demotion - ([99767c1](https://github.com/wefts/swarm/commit/99767c1703a66262eb66d4a7cef965c7a9c48e10)) - Serhii BOREMCHUK
- **(retrieval)** OR-recall lexical arm (plainto AND excluded the answer page) - ([14b776e](https://github.com/wefts/swarm/commit/14b776e8ca452a95ea6c814c74485e8f68d71894)) - Serhii BOREMCHUK
- **(retrieval)** title-arm RRF boost — fix title-blindness in ranking - ([ba52ff2](https://github.com/wefts/swarm/commit/ba52ff2b2bcbeb82aa2e5dab159806e4de45f500)) - Serhii BOREMCHUK
- **(retrieval)** pg_search BM25 lexical arm behind lexical_engine flag (ADR-0016 5b) - ([cf1690c](https://github.com/wefts/swarm/commit/cf1690c45418e139e8a88e0518260bfd99dbd12a)) - Serhii BOREMCHUK
- **(retrieval)** bm25 title-arm fusion — integrated bm25 now beats native on the honest holdout - ([50867d8](https://github.com/wefts/swarm/commit/50867d858ca11f8be46da5aac7aae0bb8eae3036)) - Serhii BOREMCHUK
- **(retrieval)** flip default lexical_engine → :bm25; ADR-0016 Accepted - ([9415859](https://github.com/wefts/swarm/commit/9415859f3a2e12f1b0268156d8e8e613e427aedc)) - Serhii BOREMCHUK
- **(synonymy)** concept-synonymy slice 1 — acronym signal + reversible synonym_of + resolver (ADR-17) - ([a108ef7](https://github.com/wefts/swarm/commit/a108ef7bb99d45e438442648620049f36bcc0859)) - Serhii BOREMCHUK
- **(synonymy)** slice 2 — query-time synonym expansion in retrieval (ADR-17) - ([b0cc098](https://github.com/wefts/swarm/commit/b0cc0982fcf950567f9ddf66ddbd65c242258734)) - Serhii BOREMCHUK
- **(synonymy)** slice 3 — automated acronym-synonym proposer + guards (ADR-17) - ([b2bac55](https://github.com/wefts/swarm/commit/b2bac555a5a56a3ebbbf059cffe69016a1b731c6)) - Serhii BOREMCHUK
- **(world-map)** the tier-routing gate sufficient?/2 (ADR-17 §3, Fork B) - ([39257a5](https://github.com/wefts/swarm/commit/39257a5b0400756106d5c4667f4f1561df6106ba)) - Serhii BOREMCHUK
- **(world-map)** Phase-1 network-map skeleton extraction (ADR-17) - ([7e713a4](https://github.com/wefts/swarm/commit/7e713a4a94b4088704c5ada6db4544f93f98cd09)) - Serhii BOREMCHUK
- **(world-map)** relation-kind signature check in NetworkMap.validate - ([61930c2](https://github.com/wefts/swarm/commit/61930c23aa05d6581666667d34a5a5f2b4f5c0ea)) - Serhii BOREMCHUK
- **(world-map)** Phase-2 write path (IaC corroboration) + carries relation - ([e10c349](https://github.com/wefts/swarm/commit/e10c349b1c4618a3739dd8020e8d15fa7bd4c35f)) - Serhii BOREMCHUK
- **(world-map)** tier-gate :network serve-path (fail-closed, corroboration-floored) - ([cc3bef4](https://github.com/wefts/swarm/commit/cc3bef4fd019080e6e631c6e88d313fa53a0a2f1)) - Serhii BOREMCHUK
- **(world-map)** SWARM_TIER_GATE_NETWORK_SERVE runtime flag for the :network serve path - ([41cbfd1](https://github.com/wefts/swarm/commit/41cbfd185e4eb074e572911071636070911a49b3)) - Serhii BOREMCHUK
- **(world-map)** tunable network corroboration floor (SWARM_TIER_GATE_NETWORK_MIN_CORROB, default 2) - ([98caad2](https://github.com/wefts/swarm/commit/98caad280dbeb425da276b877a184a353b684111)) - Serhii BOREMCHUK
- **(world-map)** has_address relation + address kind + address query cue (wiki table facts) - ([c3ff8f4](https://github.com/wefts/swarm/commit/c3ff8f4a720f0f0450936367ddc645931f93ee4c)) - Serhii BOREMCHUK
- add python version - ([cfef7a5](https://github.com/wefts/swarm/commit/cfef7a5217570b6001a996e3aa9bffbed3325cb4)) - Searge
- add a core - ([45fe655](https://github.com/wefts/swarm/commit/45fe6555d519b90d2172ef43a84e957a836f9934)) - Searge
- add real embedings & connectors - ([3163679](https://github.com/wefts/swarm/commit/3163679b62d17a5cbc20e15723a2497c0f6667ff)) - Searge
- add gate routing, consilium & cli - ([862f5ea](https://github.com/wefts/swarm/commit/862f5eae4a6d29c961c857925aed33d6e15eea2a)) - Searge
- package kernel and ML as production Docker images - ([a552853](https://github.com/wefts/swarm/commit/a5528539f3dff135da16773ae60e59cef845b539)) - Serhii BOREMCHUK
- Deliberation + Neighborhood Core RPCs (ADR-15, scope-enforced) - ([29f204b](https://github.com/wefts/swarm/commit/29f204b53be6088f4c71753a4d09f2079bc360cb)) - Serhii BOREMCHUK
- chunk-grounding + confidence calibration + claim-aware answering - ([1f0652e](https://github.com/wefts/swarm/commit/1f0652e5c2df09ad489782a98bfa082b1bd44ba4)) - Serhii BOREMCHUK
- entity-centric knowledge aggregation (STEP 2 — "what is X" synthesis) - ([317986a](https://github.com/wefts/swarm/commit/317986a239392a9ecf24923662c7d369f432c745)) - Serhii BOREMCHUK
- SWARM_ER_VEC_THRESHOLD env knob — per-corpus ER vector-gate calibration - ([cb1f9a7](https://github.com/wefts/swarm/commit/cb1f9a7a32213ddfe090859f029401eb330eff3d)) - Serhii BOREMCHUK
- ADR-18 per-source scope + admin IAM console + rollout gates (squashed) - ([64d8a08](https://github.com/wefts/swarm/commit/64d8a0845388442a4f39c1c90c6858997047f0a3)) - Serhii BOREMCHUK

### Miscellaneous Chores

- **(docs)** update findings - ([ec79c41](https://github.com/wefts/swarm/commit/ec79c4110c2d80eb1f778f834b5fe8dadd4045c6)) - Searge
- **(docs)** add more docs - ([7d4b698](https://github.com/wefts/swarm/commit/7d4b698b604c304a91c5591cf02db0ebf8db8d4c)) - Searge
- **(residuals)** fold #5 hygiene + #3 shared-step stance (ADR-17 substrate) - ([aec4b94](https://github.com/wefts/swarm/commit/aec4b94a2e2f34aa1156fa7f413cd3335c3579ce)) - Serhii BOREMCHUK
- update skill - ([97e72ea](https://github.com/wefts/swarm/commit/97e72ea015aebeb79c30e969468b1c5bfa24cad9)) - Searge
- update docs - ([3c28a6e](https://github.com/wefts/swarm/commit/3c28a6eb150b0b646db2869e7b31803664302d00)) - Searge
- remove swarm-review skill (folded into review-step) - ([310b2bc](https://github.com/wefts/swarm/commit/310b2bc4a72674e0ed2d91f054d02fcb69991d3f)) - Serhii BOREMCHUK

### Other

- **(gate)** entail judges TASK-MATCH not perfection (was vetoing every valid procedure) - ([6608f1c](https://github.com/wefts/swarm/commit/6608f1c753577b1aae30d82da66487212e6b0902)) - Serhii BOREMCHUK
- **(gate)** default entail model -> lfm2.5:8b (qwen3:14b json:true returns empty {}) - ([b67e205](https://github.com/wefts/swarm/commit/b67e205d9aaf0bedaa351bb5faeb660d969978f8)) - Serhii BOREMCHUK
- **(gate)** entail = gemma4:31b (resident) + opposites-aware prompt → fsr 0.0/recall 1.0 - ([80ee79e](https://github.com/wefts/swarm/commit/80ee79e2249b03c34950c0f1641253e48ddc2728)) - Serhii BOREMCHUK
- **(runtime)** wire SWARM_TIER_GATE_ENABLED / _ENTAIL_MODEL (tier-gate config-gated) - ([2e5ef06](https://github.com/wefts/swarm/commit/2e5ef069ad63f0ebc9e1e0c8ecfc96aab5aedd19)) - Serhii BOREMCHUK
- :tada: initial commit - ([d6591b4](https://github.com/wefts/swarm/commit/d6591b4bdd817e4f46ef3476c05f73e7371a2c66)) - Searge
- ADR-20 implementation-review fixes + review-mandated tests; spec synced - ([6a9da15](https://github.com/wefts/swarm/commit/6a9da150d67e96c4bbe4e8685ccdc187b58a3345)) - Serhii BOREMCHUK
- final-council belt — migrated? refuses a half-applied store; stale comments - ([8b809d6](https://github.com/wefts/swarm/commit/8b809d69d465846894c0b8a8434c8e8809edbb41)) - Serhii BOREMCHUK
- bm25 scope field → keyword tokenizer (ADR-20 src:<uuid> scopes were invisible to the bm25 arm) - ([22e23ab](https://github.com/wefts/swarm/commit/22e23abf146c8c45d1a4e1a34e0f79505625072a)) - Serhii BOREMCHUK

### Performance

- **(consilium)** Phase-1 latency — model residency + output caps + disagreement overlap - ([a699237](https://github.com/wefts/swarm/commit/a699237568c9906800a355b18f7fd5f5eee773c3)) - Serhii BOREMCHUK
- **(ml)** cap fleet context (num_ctx=32768) to slash resident KV cache - ([5900791](https://github.com/wefts/swarm/commit/5900791a1a07a838be18ac381f20236398de9f3b)) - Serhii BOREMCHUK

### Style

- mix format drift from the bm25 session (formatting only, no behavior change) - ([864d961](https://github.com/wefts/swarm/commit/864d9610cd312383dccee3aa33929557fe47d60a)) - Serhii BOREMCHUK

### Tests

- **(graph)** verify per-origin reinforcement ceiling is distinct-origin counting (ADR-13 EOS-3) - ([b37c725](https://github.com/wefts/swarm/commit/b37c725211fb2abcb93625ee075593b1aa038589)) - Serhii BOREMCHUK
- **(no-leak)** adversarial per-user privacy ship gate (ADR-16 step 8) - ([55b3142](https://github.com/wefts/swarm/commit/55b31423b8148524b58b56cf07c3ac8a8ebaf050)) - Serhii BOREMCHUK
- **(no-leak)** de-vacuous the ship gate — positive controls, audit ordering, KbSearch wire - ([65e0d40](https://github.com/wefts/swarm/commit/65e0d40bdcb17509c6c4a8a143ae56a63d60e02e)) - Serhii BOREMCHUK

<!-- generated by git-cliff -->
