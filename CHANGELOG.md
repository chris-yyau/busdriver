## [1.98.2](https://github.com/chris-yyau/busdriver/compare/v1.98.1...v1.98.2) (2026-07-24)


### Bug Fixes

* **blueprint-review:** inject [#458](https://github.com/chris-yyau/busdriver/issues/458)-salvaged ultra-oracle advisory on --claude-only re-run ([#486](https://github.com/chris-yyau/busdriver/issues/486)) ([#487](https://github.com/chris-yyau/busdriver/issues/487)) ([9ac3b7b](https://github.com/chris-yyau/busdriver/commit/9ac3b7b0944ab7d0421d1e6539201a39fbbfff25)), closes [#458-salvaged](https://github.com/chris-yyau/busdriver/issues/458-salvaged) [#458-salvaged](https://github.com/chris-yyau/busdriver/issues/458-salvaged) [#458-salvaged](https://github.com/chris-yyau/busdriver/issues/458-salvaged)
* **oracle:** wire completed-but-hung salvage into blocking consults ([#481](https://github.com/chris-yyau/busdriver/issues/481)) ([#485](https://github.com/chris-yyau/busdriver/issues/485)) ([40e3049](https://github.com/chris-yyau/busdriver/commit/40e3049daca37da44f2c1989ccbe0205e65aa2cb)), closes [#458](https://github.com/chris-yyau/busdriver/issues/458) [#458](https://github.com/chris-yyau/busdriver/issues/458)

## [1.98.1](https://github.com/chris-yyau/busdriver/compare/v1.98.0...v1.98.1) (2026-07-24)


### Bug Fixes

* **council:** harden UltraOracle consult — long-timeout doc + concurrency mutex ([#477](https://github.com/chris-yyau/busdriver/issues/477)) ([#483](https://github.com/chris-yyau/busdriver/issues/483)) ([0c6c971](https://github.com/chris-yyau/busdriver/commit/0c6c971676d48c7aba2f405c6e2729b450788d6f)), closes [#458](https://github.com/chris-yyau/busdriver/issues/458)

# [1.98.0](https://github.com/chris-yyau/busdriver/compare/v1.97.1...v1.98.0) (2026-07-24)


### Features

* **pr-grind:** post [@codex](https://github.com/codex) review at PR-create for Codex's full pre-merge window ([#473](https://github.com/chris-yyau/busdriver/issues/473)) ([#482](https://github.com/chris-yyau/busdriver/issues/482)) ([4d472d7](https://github.com/chris-yyau/busdriver/commit/4d472d7bbd1a75ed17701ae7a5271d9d5f84206f)), closes [#1](https://github.com/chris-yyau/busdriver/issues/1) [#416](https://github.com/chris-yyau/busdriver/issues/416)

## [1.97.1](https://github.com/chris-yyau/busdriver/compare/v1.97.0...v1.97.1) (2026-07-23)


### Bug Fixes

* **pr-grind:** contain gh routing in the clean-path Codex nudge ([#470](https://github.com/chris-yyau/busdriver/issues/470) P1) ([#474](https://github.com/chris-yyau/busdriver/issues/474)) ([8506e05](https://github.com/chris-yyau/busdriver/commit/8506e0583723f8c210fe8c7285f379fa9acc1a80)), closes [#467](https://github.com/chris-yyau/busdriver/issues/467) [#473](https://github.com/chris-yyau/busdriver/issues/473)

# [1.97.0](https://github.com/chris-yyau/busdriver/compare/v1.96.3...v1.97.0) (2026-07-23)


### Features

* **blueprint-review:** arbiter pin tracks driver model, opus floor (ADR 0025) ([#472](https://github.com/chris-yyau/busdriver/issues/472)) ([c756618](https://github.com/chris-yyau/busdriver/commit/c756618cee3c83c0af5ed34d88e4ee95618a5ee0))

## [1.96.3](https://github.com/chris-yyau/busdriver/compare/v1.96.2...v1.96.3) (2026-07-23)


### Bug Fixes

* **pr-grind:** hoist Codex none-grace nudge to the clean path ([#467](https://github.com/chris-yyau/busdriver/issues/467)) ([#470](https://github.com/chris-yyau/busdriver/issues/470)) ([5c6b409](https://github.com/chris-yyau/busdriver/commit/5c6b4097c1265fa21cab87e5cd3359f2ecca627b))

## [1.96.2](https://github.com/chris-yyau/busdriver/compare/v1.96.1...v1.96.2) (2026-07-23)


### Bug Fixes

* **deps:** bump js-yaml 4.2.0 → 4.3.0 (ReDoS, dev-only) ([#471](https://github.com/chris-yyau/busdriver/issues/471)) ([509a6f0](https://github.com/chris-yyau/busdriver/commit/509a6f0bf5e3d5c687d89cfb93339a7126aed164)), closes [#2](https://github.com/chris-yyau/busdriver/issues/2)

## [1.96.1](https://github.com/chris-yyau/busdriver/compare/v1.96.0...v1.96.1) (2026-07-23)


### Bug Fixes

* **ultra-oracle:** tab-status probe + target-id harvest for completed-but-hung consults ([#458](https://github.com/chris-yyau/busdriver/issues/458)) ([#465](https://github.com/chris-yyau/busdriver/issues/465)) ([6695c49](https://github.com/chris-yyau/busdriver/commit/6695c49cdb697c0eede5291a66ce183ecee09bd7)), closes [#460](https://github.com/chris-yyau/busdriver/issues/460)

# [1.96.0](https://github.com/chris-yyau/busdriver/compare/v1.95.14...v1.96.0) (2026-07-23)


### Features

* **pre-merge:** ADR 0024 — non-gating missing-Codex advisory on allow paths ([#461](https://github.com/chris-yyau/busdriver/issues/461)) ([e1376a9](https://github.com/chris-yyau/busdriver/commit/e1376a97206373824141836e53abea38c7624646)), closes [#450](https://github.com/chris-yyau/busdriver/issues/450) [#444](https://github.com/chris-yyau/busdriver/issues/444) [#native](https://github.com/chris-yyau/busdriver/issues/native)

## [1.95.14](https://github.com/chris-yyau/busdriver/compare/v1.95.13...v1.95.14) (2026-07-22)


### Bug Fixes

* **ultra-oracle:** salvage + watchdog for completed-but-hung oracle browser consults ([#458](https://github.com/chris-yyau/busdriver/issues/458)) ([#460](https://github.com/chris-yyau/busdriver/issues/460)) ([fdb84c1](https://github.com/chris-yyau/busdriver/commit/fdb84c1fee729133e6ed0484924f24b0665e0418))

## [1.95.13](https://github.com/chris-yyau/busdriver/compare/v1.95.12...v1.95.13) (2026-07-22)


### Bug Fixes

* **design-review:** resolve relative file_path against payload cwd in detector ([#448](https://github.com/chris-yyau/busdriver/issues/448)) ([#456](https://github.com/chris-yyau/busdriver/issues/456)) ([039e681](https://github.com/chris-yyau/busdriver/commit/039e681cd32858b8b90b31251e574c900efe6da6))

## [1.95.12](https://github.com/chris-yyau/busdriver/compare/v1.95.11...v1.95.12) (2026-07-22)


### Bug Fixes

* **freeze-guard:** repo-relative anchoring for docs/ and .claude/ arms (+ cwd join) ([#375](https://github.com/chris-yyau/busdriver/issues/375)) ([#457](https://github.com/chris-yyau/busdriver/issues/457)) ([2c8638f](https://github.com/chris-yyau/busdriver/commit/2c8638fcec356f0c743362be71b8a5d8485b8ea5)), closes [170/#126](https://github.com/chris-yyau/busdriver/issues/126) [#369](https://github.com/chris-yyau/busdriver/issues/369)

## [1.95.11](https://github.com/chris-yyau/busdriver/compare/v1.95.10...v1.95.11) (2026-07-22)


### Bug Fixes

* **resolve-cli:** restrict opencode to Auditor-only roles ([#436](https://github.com/chris-yyau/busdriver/issues/436)) ([#455](https://github.com/chris-yyau/busdriver/issues/455)) ([1fc85e4](https://github.com/chris-yyau/busdriver/commit/1fc85e46e2892ba219fd685bff20d611a75846bf)), closes [#435](https://github.com/chris-yyau/busdriver/issues/435)

## [1.95.10](https://github.com/chris-yyau/busdriver/compare/v1.95.9...v1.95.10) (2026-07-22)


### Bug Fixes

* **design-review:** strip PASS on Write of a reviewed doc — no stale-PASS-with-token ([#449](https://github.com/chris-yyau/busdriver/issues/449)) ([#452](https://github.com/chris-yyau/busdriver/issues/452)) ([0594830](https://github.com/chris-yyau/busdriver/commit/059483024a9c9e423556715016d44b93237e4474)), closes [#347](https://github.com/chris-yyau/busdriver/issues/347)

## [1.95.9](https://github.com/chris-yyau/busdriver/compare/v1.95.8...v1.95.9) (2026-07-21)


### Bug Fixes

* **voices:** give advisory Auditor (k3) its own budget, not a 20s tail ([#453](https://github.com/chris-yyau/busdriver/issues/453)) ([9660d98](https://github.com/chris-yyau/busdriver/commit/9660d98912642e9dd40d2a2d51d00c5517d340ad)), closes [#435](https://github.com/chris-yyau/busdriver/issues/435)

## [1.95.8](https://github.com/chris-yyau/busdriver/compare/v1.95.7...v1.95.8) (2026-07-21)


### Bug Fixes

* **design-review:** close [#347](https://github.com/chris-yyau/busdriver/issues/347) items 4/5/6 (item 4 payload-cwd fail-open) ([#451](https://github.com/chris-yyau/busdriver/issues/451)) ([a731c6d](https://github.com/chris-yyau/busdriver/commit/a731c6df04835733394e220a08c3222ac4cfab4d)), closes [#346](https://github.com/chris-yyau/busdriver/issues/346)

## [1.95.7](https://github.com/chris-yyau/busdriver/compare/v1.95.6...v1.95.7) (2026-07-21)


### Bug Fixes

* **design-review:** unify detector onto gate's physical (realpath) grammar ([#446](https://github.com/chris-yyau/busdriver/issues/446)) ([#448](https://github.com/chris-yyau/busdriver/issues/448)) ([cafbb1b](https://github.com/chris-yyau/busdriver/commit/cafbb1bb91429f58c31973fe4901d97fe581fbc7))

## [1.95.6](https://github.com/chris-yyau/busdriver/compare/v1.95.5...v1.95.6) (2026-07-21)


### Bug Fixes

* **design-review:** fail-closed pre-arm + best-effort Bash cd resolution ([#347](https://github.com/chris-yyau/busdriver/issues/347) items 1&2) ([#444](https://github.com/chris-yyau/busdriver/issues/444)) ([1849434](https://github.com/chris-yyau/busdriver/commit/1849434e1a4a227a07f1d3275a28fbcc271d5677)), closes [#346](https://github.com/chris-yyau/busdriver/issues/346)

## [1.95.5](https://github.com/chris-yyau/busdriver/compare/v1.95.4...v1.95.5) (2026-07-20)


### Performance Improvements

* **cli:** cap agy --version probe at 2s so a stall adds +2s not +5s ([#423](https://github.com/chris-yyau/busdriver/issues/423)) ([#443](https://github.com/chris-yyau/busdriver/issues/443)) ([0035cf0](https://github.com/chris-yyau/busdriver/commit/0035cf06f2e1bab2080205e95aa847a91d91ed8d))

## [1.95.4](https://github.com/chris-yyau/busdriver/compare/v1.95.3...v1.95.4) (2026-07-20)


### Bug Fixes

* **blueprint-review:** unblock headless agy reviewer so it reaches FULL 3/3 ([#424](https://github.com/chris-yyau/busdriver/issues/424)) ([#441](https://github.com/chris-yyau/busdriver/issues/441)) ([e4ad78c](https://github.com/chris-yyau/busdriver/commit/e4ad78c20447e4029cd17d297052c0b5e9c84330))

## [1.95.3](https://github.com/chris-yyau/busdriver/compare/v1.95.2...v1.95.3) (2026-07-20)


### Bug Fixes

* **litmus:** pin PR diff-hash to deterministic flags so writer/gate agree ([#438](https://github.com/chris-yyau/busdriver/issues/438)) ([#440](https://github.com/chris-yyau/busdriver/issues/440)) ([951ca47](https://github.com/chris-yyau/busdriver/commit/951ca4797045475bf789aaf25f42e398233404a6))

## [1.95.2](https://github.com/chris-yyau/busdriver/compare/v1.95.1...v1.95.2) (2026-07-20)


### Bug Fixes

* **careful-guard:** warn when rm-extraction truncates at the depth bound ([#377](https://github.com/chris-yyau/busdriver/issues/377)) ([#439](https://github.com/chris-yyau/busdriver/issues/439)) ([5a7f3a5](https://github.com/chris-yyau/busdriver/commit/5a7f3a54d91889057244bcd56971f47833140b5f)), closes [#426](https://github.com/chris-yyau/busdriver/issues/426)

## [1.95.1](https://github.com/chris-yyau/busdriver/compare/v1.95.0...v1.95.1) (2026-07-20)


### Bug Fixes

* **litmus:** gate the commit short-circuit on passive paths, not diff size ([#415](https://github.com/chris-yyau/busdriver/issues/415)) ([#437](https://github.com/chris-yyau/busdriver/issues/437)) ([dbf29c0](https://github.com/chris-yyau/busdriver/commit/dbf29c02cb4580bc79ab18e8f69b328dceb0d388))

# [1.95.0](https://github.com/chris-yyau/busdriver/compare/v1.94.7...v1.95.0) (2026-07-20)


### Features

* **voices:** add opencode/kimi-k3 "Auditor" as an advisory review voice ([#435](https://github.com/chris-yyau/busdriver/issues/435)) ([99c6101](https://github.com/chris-yyau/busdriver/commit/99c61017d486617cab3948023dfd47a8e561ab80))

## [1.94.7](https://github.com/chris-yyau/busdriver/compare/v1.94.6...v1.94.7) (2026-07-20)


### Bug Fixes

* **gates:** count merges by command word so prose about the gate stops blocking ([#426](https://github.com/chris-yyau/busdriver/issues/426)) ([#431](https://github.com/chris-yyau/busdriver/issues/431)) ([b44d71a](https://github.com/chris-yyau/busdriver/commit/b44d71a72288b8ba316dbd946ee8dff39c7a83dd))

## [1.94.6](https://github.com/chris-yyau/busdriver/compare/v1.94.5...v1.94.6) (2026-07-19)


### Bug Fixes

* **pr-grind:** bind merge to the classified HEAD via --match-head-commit ([#429](https://github.com/chris-yyau/busdriver/issues/429)) ([136af68](https://github.com/chris-yyau/busdriver/commit/136af6875f5148e8e6acc316796a636b2e14bda7)), closes [#420](https://github.com/chris-yyau/busdriver/issues/420) [#427](https://github.com/chris-yyau/busdriver/issues/427) [#427](https://github.com/chris-yyau/busdriver/issues/427)

## [1.94.5](https://github.com/chris-yyau/busdriver/compare/v1.94.4...v1.94.5) (2026-07-19)


### Bug Fixes

* **pr-grind:** fail-CLOSED worktree resolution in Step 0 ([#421](https://github.com/chris-yyau/busdriver/issues/421)) ([#430](https://github.com/chris-yyau/busdriver/issues/430)) ([6a861fd](https://github.com/chris-yyau/busdriver/commit/6a861fd5fa40bbf04f341b1b70cb81bc5b902a67))

## [1.94.4](https://github.com/chris-yyau/busdriver/compare/v1.94.3...v1.94.4) (2026-07-19)


### Bug Fixes

* **pr-grind:** poll for Codex first engagement instead of a blind 20s sleep ([#420](https://github.com/chris-yyau/busdriver/issues/420)) ([#428](https://github.com/chris-yyau/busdriver/issues/428)) ([81003cb](https://github.com/chris-yyau/busdriver/commit/81003cb883db307e173e0fb53c72987598624413)), closes [409/#390](https://github.com/chris-yyau/busdriver/issues/390) [#419](https://github.com/chris-yyau/busdriver/issues/419) [#413](https://github.com/chris-yyau/busdriver/issues/413) [409/#390](https://github.com/chris-yyau/busdriver/issues/390) [#413](https://github.com/chris-yyau/busdriver/issues/413)

## [1.94.3](https://github.com/chris-yyau/busdriver/compare/v1.94.2...v1.94.3) (2026-07-18)


### Bug Fixes

* **cli:** make stdin mode an argument — env could starve every reviewer ([#422](https://github.com/chris-yyau/busdriver/issues/422)) ([4c4c97a](https://github.com/chris-yyau/busdriver/commit/4c4c97aadf8cb26ce7b58ed2beb7b3b425c2e2fb)), closes [#412](https://github.com/chris-yyau/busdriver/issues/412) [#325](https://github.com/chris-yyau/busdriver/issues/325)

## [1.94.2](https://github.com/chris-yyau/busdriver/compare/v1.94.1...v1.94.2) (2026-07-18)


### Bug Fixes

* **cli:** deliver agy prompts via argv — --print /dev/stdin broke on 1.1.x ([#412](https://github.com/chris-yyau/busdriver/issues/412)) ([a3049ec](https://github.com/chris-yyau/busdriver/commit/a3049ec110f203e327669989073efca273a112e2)), closes [#325](https://github.com/chris-yyau/busdriver/issues/325)

## [1.94.1](https://github.com/chris-yyau/busdriver/compare/v1.94.0...v1.94.1) (2026-07-18)


### Bug Fixes

* **hooks:** stop re-importing GH_REPO/GH_HOST into the codex nudge ([#416](https://github.com/chris-yyau/busdriver/issues/416)) ([#419](https://github.com/chris-yyau/busdriver/issues/419)) ([f71912d](https://github.com/chris-yyau/busdriver/commit/f71912d693edd340873581231e4f52cccdfcf235))

# [1.94.0](https://github.com/chris-yyau/busdriver/compare/v1.93.11...v1.94.0) (2026-07-18)


### Features

* **design-clear:** audited operator release of one design-review token ([#405](https://github.com/chris-yyau/busdriver/issues/405)) ([#413](https://github.com/chris-yyau/busdriver/issues/413)) ([061cdc1](https://github.com/chris-yyau/busdriver/commit/061cdc19656ef14d66b7af33b7ad4ca76e9847f5))

## [1.93.11](https://github.com/chris-yyau/busdriver/compare/v1.93.10...v1.93.11) (2026-07-18)


### Bug Fixes

* **ultraoracle:** attach to a running Chrome instead of launching one (ADR 0020) ([#409](https://github.com/chris-yyau/busdriver/issues/409)) ([f07568e](https://github.com/chris-yyau/busdriver/commit/f07568e2e1efcf781092b481a59489e582c9e5c4))

## [1.93.10](https://github.com/chris-yyau/busdriver/compare/v1.93.9...v1.93.10) (2026-07-18)


### Bug Fixes

* **codex-nudge:** fire none-nudge on rule-compliant pr-grind merges (ADR 0018) ([#406](https://github.com/chris-yyau/busdriver/issues/406)) ([33eb0e2](https://github.com/chris-yyau/busdriver/commit/33eb0e202b41254c59740d63ebbf23519253d5a5)), closes [#403](https://github.com/chris-yyau/busdriver/issues/403) [#403-shape](https://github.com/chris-yyau/busdriver/issues/403-shape) [#2](https://github.com/chris-yyau/busdriver/issues/2) [#3](https://github.com/chris-yyau/busdriver/issues/3)

## [1.93.9](https://github.com/chris-yyau/busdriver/compare/v1.93.8...v1.93.9) (2026-07-18)


### Bug Fixes

* **litmus:** default review timeout under the harness Bash cap ([#368](https://github.com/chris-yyau/busdriver/issues/368)) ([#403](https://github.com/chris-yyau/busdriver/issues/403)) ([57daf34](https://github.com/chris-yyau/busdriver/commit/57daf34f22c0eccbbd296e13555efc9a86c50378)), closes [#363](https://github.com/chris-yyau/busdriver/issues/363)

## [1.93.8](https://github.com/chris-yyau/busdriver/compare/v1.93.7...v1.93.8) (2026-07-17)


### Bug Fixes

* P1 triage — unpin stale codex model ([#331](https://github.com/chris-yyau/busdriver/issues/331)) + correct [update-merge] rationale ([#354](https://github.com/chris-yyau/busdriver/issues/354)) ([#401](https://github.com/chris-yyau/busdriver/issues/401)) ([a21a5a3](https://github.com/chris-yyau/busdriver/commit/a21a5a3aa0e39d5b5a4cf5afc22c0ed0f301ddcf)), closes [#361](https://github.com/chris-yyau/busdriver/issues/361) [#81](https://github.com/chris-yyau/busdriver/issues/81)

## [1.93.7](https://github.com/chris-yyau/busdriver/compare/v1.93.6...v1.93.7) (2026-07-17)


### Bug Fixes

* **codex-nudge:** bounded retry closes single-transient silent-skip on inline/admin merges ([#398](https://github.com/chris-yyau/busdriver/issues/398)) ([#402](https://github.com/chris-yyau/busdriver/issues/402)) ([3ec374b](https://github.com/chris-yyau/busdriver/commit/3ec374b853c80e91e9917f80aa7aa692c5c1de4e))

## [1.93.6](https://github.com/chris-yyau/busdriver/compare/v1.93.5...v1.93.6) (2026-07-17)


### Bug Fixes

* **security:** bump semgrep 1.170.0 and zizmor 1.27.0 ([#400](https://github.com/chris-yyau/busdriver/issues/400)) ([7cc6c3f](https://github.com/chris-yyau/busdriver/commit/7cc6c3f813d414eac4b030d1ce0cb7f5e267eb7f))

## [1.93.5](https://github.com/chris-yyau/busdriver/compare/v1.93.4...v1.93.5) (2026-07-17)


### Bug Fixes

* **codex-nudge:** harden none-check jq against ghost/malformed reviewers ([#397](https://github.com/chris-yyau/busdriver/issues/397)) ([5b65f9d](https://github.com/chris-yyau/busdriver/commit/5b65f9da1e5e773040676432fd1126a83c281214))

## [1.93.4](https://github.com/chris-yyau/busdriver/compare/v1.93.3...v1.93.4) (2026-07-17)


### Bug Fixes

* **gates:** dedup the unreviewed-commit audit so real gate-misses are visible ([#352](https://github.com/chris-yyau/busdriver/issues/352)) ([#395](https://github.com/chris-yyau/busdriver/issues/395)) ([d7fda4f](https://github.com/chris-yyau/busdriver/commit/d7fda4ff84baee794e9fdc15d3942fad8dffbbe5)), closes [#385](https://github.com/chris-yyau/busdriver/issues/385)
* **litmus:** render review prompt in one literal pass (bash 5.2 ampersand + token collision) ([#396](https://github.com/chris-yyau/busdriver/issues/396)) ([51a570d](https://github.com/chris-yyau/busdriver/commit/51a570dd0905d2a995e80af25509146264c46441)), closes [#393](https://github.com/chris-yyau/busdriver/issues/393) [#393](https://github.com/chris-yyau/busdriver/issues/393)

## [1.93.3](https://github.com/chris-yyau/busdriver/compare/v1.93.2...v1.93.3) (2026-07-17)


### Bug Fixes

* **gate:** surface arming worktree in design-review block message ([#356](https://github.com/chris-yyau/busdriver/issues/356)) ([#391](https://github.com/chris-yyau/busdriver/issues/391)) ([6f3a1eb](https://github.com/chris-yyau/busdriver/commit/6f3a1eba2f206014d2ae538bbdbff691dd3415b2))

## [1.93.2](https://github.com/chris-yyau/busdriver/compare/v1.93.1...v1.93.2) (2026-07-17)


### Bug Fixes

* **pr-grind:** fire the Codex none-nudge hook on real multi-line merges ([#390](https://github.com/chris-yyau/busdriver/issues/390)) ([6b856a6](https://github.com/chris-yyau/busdriver/commit/6b856a6e937a97149dbe87de0b77d82f18f20280)), closes [#pr-view](https://github.com/chris-yyau/busdriver/issues/pr-view) [98/#102](https://github.com/chris-yyau/busdriver/issues/102)

## [1.93.1](https://github.com/chris-yyau/busdriver/compare/v1.93.0...v1.93.1) (2026-07-17)


### Bug Fixes

* **gate-lib:** silence SC2015 in resolve-repo-dir common-dir probe ([#389](https://github.com/chris-yyau/busdriver/issues/389)) ([cb35d09](https://github.com/chris-yyau/busdriver/commit/cb35d092ae84a6edc5882c47ae5e8a51584e2ff4))

# [1.93.0](https://github.com/chris-yyau/busdriver/compare/v1.92.7...v1.93.0) (2026-07-17)


### Features

* **pr-grind:** re-add greptile-apps as 5th gated ack-bot ([#388](https://github.com/chris-yyau/busdriver/issues/388)) ([6866ea0](https://github.com/chris-yyau/busdriver/commit/6866ea01a4302c7ddf4ae141230d4754fc88be11)), closes [#179](https://github.com/chris-yyau/busdriver/issues/179) [#174](https://github.com/chris-yyau/busdriver/issues/174)

## [1.92.7](https://github.com/chris-yyau/busdriver/compare/v1.92.6...v1.92.7) (2026-07-17)


### Bug Fixes

* **litmus:** make the mode guard and the timeout docs tell the truth ([#363](https://github.com/chris-yyau/busdriver/issues/363)) ([#370](https://github.com/chris-yyau/busdriver/issues/370)) ([f0cef0f](https://github.com/chris-yyau/busdriver/commit/f0cef0f646f6534f2f1e4c6b710f53ce518a28a2)), closes [#368](https://github.com/chris-yyau/busdriver/issues/368) [#368](https://github.com/chris-yyau/busdriver/issues/368) [#368](https://github.com/chris-yyau/busdriver/issues/368) [#368](https://github.com/chris-yyau/busdriver/issues/368)

## [1.92.6](https://github.com/chris-yyau/busdriver/compare/v1.92.5...v1.92.6) (2026-07-17)


### Bug Fixes

* **design-gate:** refuse to authorize implementation on DEGRADED coverage ([#355](https://github.com/chris-yyau/busdriver/issues/355)) ([#387](https://github.com/chris-yyau/busdriver/issues/387)) ([e95777e](https://github.com/chris-yyau/busdriver/commit/e95777e3d4392290d5fd62f8975568fcb6806823))

## [1.92.5](https://github.com/chris-yyau/busdriver/compare/v1.92.4...v1.92.5) (2026-07-17)


### Bug Fixes

* **litmus:** retry the captured PR backstop on transient failures ([#382](https://github.com/chris-yyau/busdriver/issues/382)) ([de387d6](https://github.com/chris-yyau/busdriver/commit/de387d60c0271f48e14ee9220a94018c6c552fa2))

## [1.92.4](https://github.com/chris-yyau/busdriver/compare/v1.92.3...v1.92.4) (2026-07-17)


### Bug Fixes

* **hooks:** await async run() + fail-closed missing-hookId for blocking gates ([#385](https://github.com/chris-yyau/busdriver/issues/385)) ([453b3e1](https://github.com/chris-yyau/busdriver/commit/453b3e1b066685efaf6eaaaa4314d82a6fc61aec)), closes [#349](https://github.com/chris-yyau/busdriver/issues/349)

## [1.92.3](https://github.com/chris-yyau/busdriver/compare/v1.92.2...v1.92.3) (2026-07-17)


### Bug Fixes

* **gates:** harden block_emit JSON fallback when jq is absent ([#381](https://github.com/chris-yyau/busdriver/issues/381)) ([990ffa5](https://github.com/chris-yyau/busdriver/commit/990ffa586b8e7491b99877fb635af4e69287439a))

## [1.92.2](https://github.com/chris-yyau/busdriver/compare/v1.92.1...v1.92.2) (2026-07-17)


### Bug Fixes

* **gates:** exempt docs/specs and match doc exemptions post-normalization ([#369](https://github.com/chris-yyau/busdriver/issues/369)) ([63cb759](https://github.com/chris-yyau/busdriver/commit/63cb759f2c8b09fbb3d60fe14245c743d54ef804)), closes [#359](https://github.com/chris-yyau/busdriver/issues/359) [#359](https://github.com/chris-yyau/busdriver/issues/359) [#360](https://github.com/chris-yyau/busdriver/issues/360)

## [1.92.1](https://github.com/chris-yyau/busdriver/compare/v1.92.0...v1.92.1) (2026-07-17)


### Bug Fixes

* **careful-guard:** judge every rm in a chain, not just the last ([#376](https://github.com/chris-yyau/busdriver/issues/376)) ([6627c40](https://github.com/chris-yyau/busdriver/commit/6627c40063d8809a1851d306a6b909133c3dbe3f))

# [1.92.0](https://github.com/chris-yyau/busdriver/compare/v1.91.18...v1.92.0) (2026-07-17)


### Features

* **litmus:** captured backstop dispatch (--run-backstop) + reduce forge surface ([#374](https://github.com/chris-yyau/busdriver/issues/374)) ([ac9a8c1](https://github.com/chris-yyau/busdriver/commit/ac9a8c149acf02c9b96a85951029c6eb8faac628)), closes [#350](https://github.com/chris-yyau/busdriver/issues/350) [#350](https://github.com/chris-yyau/busdriver/issues/350)

## [1.91.18](https://github.com/chris-yyau/busdriver/compare/v1.91.17...v1.91.18) (2026-07-17)


### Bug Fixes

* **gates:** detect commands inside process substitutions ([#372](https://github.com/chris-yyau/busdriver/issues/372)) ([3a379c5](https://github.com/chris-yyau/busdriver/commit/3a379c5899211bd012c2584286e032447af4600f)), closes [358/#371](https://github.com/chris-yyau/busdriver/issues/371)

## [1.91.17](https://github.com/chris-yyau/busdriver/compare/v1.91.16...v1.91.17) (2026-07-17)


### Bug Fixes

* **gates:** strip bash line continuations before command detection ([#371](https://github.com/chris-yyau/busdriver/issues/371)) ([967ede0](https://github.com/chris-yyau/busdriver/commit/967ede069555e9ba915bc46919ae990e4f0d0cdf)), closes [#358](https://github.com/chris-yyau/busdriver/issues/358)

## [1.91.16](https://github.com/chris-yyau/busdriver/compare/v1.91.15...v1.91.16) (2026-07-17)


### Bug Fixes

* **gates:** tell the truth when an unparseable command mentions a marker ([#365](https://github.com/chris-yyau/busdriver/issues/365)) ([#367](https://github.com/chris-yyau/busdriver/issues/367)) ([4c3a17f](https://github.com/chris-yyau/busdriver/commit/4c3a17fcd0700f033492ebd0a4e09e199b5b4f3b))

## [1.91.15](https://github.com/chris-yyau/busdriver/compare/v1.91.14...v1.91.15) (2026-07-17)


### Bug Fixes

* **ack-ledger:** fail closed when the ledger cannot decide ([#364](https://github.com/chris-yyau/busdriver/issues/364)) ([#366](https://github.com/chris-yyau/busdriver/issues/366)) ([f6245ee](https://github.com/chris-yyau/busdriver/commit/f6245eeb4a8a909087ebb24142f10b603717cf00)), closes [#353](https://github.com/chris-yyau/busdriver/issues/353) [#294](https://github.com/chris-yyau/busdriver/issues/294)

## [1.91.14](https://github.com/chris-yyau/busdriver/compare/v1.91.13...v1.91.14) (2026-07-16)


### Bug Fixes

* **gates:** close interpreter-payload evasions in the shared detector ([#358](https://github.com/chris-yyau/busdriver/issues/358)) ([8995d0d](https://github.com/chris-yyau/busdriver/commit/8995d0d6e25c24bafb36698c3cbfd039cd0bd6ea)), closes [#336](https://github.com/chris-yyau/busdriver/issues/336)

## [1.91.13](https://github.com/chris-yyau/busdriver/compare/v1.91.12...v1.91.13) (2026-07-16)


### Bug Fixes

* **ack-ledger:** close Tier E success-status fail-open on rate-limited bots ([#361](https://github.com/chris-yyau/busdriver/issues/361)) ([350d337](https://github.com/chris-yyau/busdriver/commit/350d3372cb4a626685621e7e92949e2f2b98a4ec)), closes [#81](https://github.com/chris-yyau/busdriver/issues/81) [#294](https://github.com/chris-yyau/busdriver/issues/294) [#294](https://github.com/chris-yyau/busdriver/issues/294) [#294](https://github.com/chris-yyau/busdriver/issues/294) [#353](https://github.com/chris-yyau/busdriver/issues/353) [#353](https://github.com/chris-yyau/busdriver/issues/353) [#353](https://github.com/chris-yyau/busdriver/issues/353) [#294](https://github.com/chris-yyau/busdriver/issues/294)

## [1.91.12](https://github.com/chris-yyau/busdriver/compare/v1.91.11...v1.91.12) (2026-07-16)


### Bug Fixes

* **gates:** strip CR so the live server-clock path stops returning empty ([#362](https://github.com/chris-yyau/busdriver/issues/362)) ([f973f9b](https://github.com/chris-yyau/busdriver/commit/f973f9bead6548a5571464d00a92c14adad7042b)), closes [#300](https://github.com/chris-yyau/busdriver/issues/300) [#305](https://github.com/chris-yyau/busdriver/issues/305) [#314](https://github.com/chris-yyau/busdriver/issues/314) [#332](https://github.com/chris-yyau/busdriver/issues/332)

## [1.91.11](https://github.com/chris-yyau/busdriver/compare/v1.91.10...v1.91.11) (2026-07-16)


### Bug Fixes

* **manifest:** repoint test-setup doc entries after the [#357](https://github.com/chris-yyau/busdriver/issues/357) move ([#360](https://github.com/chris-yyau/busdriver/issues/360)) ([ee8f495](https://github.com/chris-yyau/busdriver/commit/ee8f4953759b4a26d0ed487e0059d494dd7b5ca4))

## [1.91.10](https://github.com/chris-yyau/busdriver/compare/v1.91.9...v1.91.10) (2026-07-16)


### Bug Fixes

* **docs:** complete the specs move — repair broken refs and skill paths ([#359](https://github.com/chris-yyau/busdriver/issues/359)) ([d68b422](https://github.com/chris-yyau/busdriver/commit/d68b42238ce179c6048519e88de61613fa17e1cf))

## [1.91.9](https://github.com/chris-yyau/busdriver/compare/v1.91.8...v1.91.9) (2026-07-15)


### Bug Fixes

* **gates:** contain pure-block node hooks via sanitized-node.sh (Task 3) ([#349](https://github.com/chris-yyau/busdriver/issues/349)) ([c0ffeb7](https://github.com/chris-yyau/busdriver/commit/c0ffeb718b9f5234acbbee85a6ea95e2a425b924))

## [1.91.8](https://github.com/chris-yyau/busdriver/compare/v1.91.7...v1.91.8) (2026-07-15)


### Bug Fixes

* **gates:** worktree-safe design-review marker via immutable per-arming tokens ([#346](https://github.com/chris-yyau/busdriver/issues/346)) ([3fef25a](https://github.com/chris-yyau/busdriver/commit/3fef25a0df2584a24b87e977bf3f9a96686fc9c3))

## [1.91.7](https://github.com/chris-yyau/busdriver/compare/v1.91.6...v1.91.7) (2026-07-14)


### Bug Fixes

* **hooks:** resolve Opus 4.x family to 1M window in strategic-compact ([#345](https://github.com/chris-yyau/busdriver/issues/345)) ([d2286a7](https://github.com/chris-yyau/busdriver/commit/d2286a75acfa58039dc716c0777ab246556815f4)), closes [#343](https://github.com/chris-yyau/busdriver/issues/343) [pre-#343](https://github.com/pre-/issues/343)

## [1.91.6](https://github.com/chris-yyau/busdriver/compare/v1.91.5...v1.91.6) (2026-07-14)


### Bug Fixes

* **pr-grind:** deterministic PreToolUse hook for the Codex none-nudge ([#344](https://github.com/chris-yyau/busdriver/issues/344)) ([9e61448](https://github.com/chris-yyau/busdriver/commit/9e6144818cb4c282267d84d9a61e23795291b659)), closes [335-#342](https://github.com/335-/issues/342) [#335](https://github.com/chris-yyau/busdriver/issues/335)

## [1.91.5](https://github.com/chris-yyau/busdriver/compare/v1.91.4...v1.91.5) (2026-07-13)


### Bug Fixes

* **hooks:** correct strategic-compact window for bare opus-4 model id ([#343](https://github.com/chris-yyau/busdriver/issues/343)) ([fb348f8](https://github.com/chris-yyau/busdriver/commit/fb348f8161c82e77814204ec622361c1d92dee5e)), closes [#2290](https://github.com/chris-yyau/busdriver/issues/2290)

## [1.91.4](https://github.com/chris-yyau/busdriver/compare/v1.91.3...v1.91.4) (2026-07-13)


### Bug Fixes

* **ultra-oracle:** pass --force to bypass oracle's stale duplicate-prompt guard ([#333](https://github.com/chris-yyau/busdriver/issues/333)) ([#342](https://github.com/chris-yyau/busdriver/issues/342)) ([88a80f6](https://github.com/chris-yyau/busdriver/commit/88a80f6d297d79c57a65de2a53380f8e78e62adf))

## [1.91.3](https://github.com/chris-yyau/busdriver/compare/v1.91.2...v1.91.3) (2026-07-13)


### Bug Fixes

* **ultra-oracle:** delegate to oracle serve when Chrome blocks cookie decryption + surface failures ([#340](https://github.com/chris-yyau/busdriver/issues/340)) ([#341](https://github.com/chris-yyau/busdriver/issues/341)) ([3eeba7f](https://github.com/chris-yyau/busdriver/commit/3eeba7faa432824a461ff28526effc68ed2a08df))

## [1.91.2](https://github.com/chris-yyau/busdriver/compare/v1.91.1...v1.91.2) (2026-07-13)


### Bug Fixes

* **gates:** shared quote-aware git/gh command detector (fail-open hardening) ([#336](https://github.com/chris-yyau/busdriver/issues/336)) ([eae6149](https://github.com/chris-yyau/busdriver/commit/eae6149b30f5c91482cbe0b1567fb8aca2bebe32))

## [1.91.1](https://github.com/chris-yyau/busdriver/compare/v1.91.0...v1.91.1) (2026-07-13)


### Bug Fixes

* **security:** always run trivy on PRs + pin scanners ([#335](https://github.com/chris-yyau/busdriver/issues/335)) ([dc9d8fe](https://github.com/chris-yyau/busdriver/commit/dc9d8fe8f54d90e94f4da99215d979ac8a8564df))

# [1.91.0](https://github.com/chris-yyau/busdriver/compare/v1.90.0...v1.91.0) (2026-07-11)


### Features

* **pr-grind:** hardened bulk advisory-downgrade enroller ([#326](https://github.com/chris-yyau/busdriver/issues/326)) ([#332](https://github.com/chris-yyau/busdriver/issues/332)) ([6f3d88f](https://github.com/chris-yyau/busdriver/commit/6f3d88f88aa7d81fc3d6f64d15346f2a1caa4f41)), closes [#314](https://github.com/chris-yyau/busdriver/issues/314)

# [1.90.0](https://github.com/chris-yyau/busdriver/compare/v1.89.2...v1.90.0) (2026-07-11)


### Features

* **pr-grind:** auto-detect Codex-active repos for the none-nudge ([#320](https://github.com/chris-yyau/busdriver/issues/320), [#327](https://github.com/chris-yyau/busdriver/issues/327)) ([#330](https://github.com/chris-yyau/busdriver/issues/330)) ([f5abd07](https://github.com/chris-yyau/busdriver/commit/f5abd07ae923e2d238ef90c4ab9af8124315e1cd)), closes [#325](https://github.com/chris-yyau/busdriver/issues/325)

## [1.89.2](https://github.com/chris-yyau/busdriver/compare/v1.89.1...v1.89.2) (2026-07-11)


### Bug Fixes

* **hooks:** contain gate env injection from committed settings.json ([#325](https://github.com/chris-yyau/busdriver/issues/325)) ([#329](https://github.com/chris-yyau/busdriver/issues/329)) ([55db7d1](https://github.com/chris-yyau/busdriver/commit/55db7d1e92905162bda4141b35e582c443061ec3))

## [1.89.1](https://github.com/chris-yyau/busdriver/compare/v1.89.0...v1.89.1) (2026-07-10)


### Performance Improvements

* inject condensed orchestrator brief at sessionstart instead of full skill ([#324](https://github.com/chris-yyau/busdriver/issues/324)) ([67d6c77](https://github.com/chris-yyau/busdriver/commit/67d6c77eaf5242dea562c95c2c02d2ef129db7cb)), closes [#309](https://github.com/chris-yyau/busdriver/issues/309)

# [1.89.0](https://github.com/chris-yyau/busdriver/compare/v1.88.1...v1.89.0) (2026-07-10)


### Features

* **pr-grind:** per-repo advisory-bot stale-ack downgrade opt-in ([#314](https://github.com/chris-yyau/busdriver/issues/314)) ([9ed5e23](https://github.com/chris-yyau/busdriver/commit/9ed5e2358efba1bdfa98906145f1f3c5d60ebe76))

## [1.88.1](https://github.com/chris-yyau/busdriver/compare/v1.88.0...v1.88.1) (2026-07-10)


### Bug Fixes

* **blueprint-review:** correct stale advisory name ORACLE-MAX -> ULTRA-ORACLE ([#323](https://github.com/chris-yyau/busdriver/issues/323)) ([31c1b6a](https://github.com/chris-yyau/busdriver/commit/31c1b6aab6d94eb6e5d6b95d6acf064377da517b)), closes [#322](https://github.com/chris-yyau/busdriver/issues/322)

# [1.88.0](https://github.com/chris-yyau/busdriver/compare/v1.87.1...v1.88.0) (2026-07-10)


### Features

* **writing-plans:** ultra-oracle plan advisory + de-version oracle prose ([#322](https://github.com/chris-yyau/busdriver/issues/322)) ([ca18d29](https://github.com/chris-yyau/busdriver/commit/ca18d2994235d561dac0ae5a4c1d889d58cbe2c2))

## [1.87.1](https://github.com/chris-yyau/busdriver/compare/v1.87.0...v1.87.1) (2026-07-10)


### Bug Fixes

* **rules:** sweep dangling rules/<lang>/ pointers (retired by [#315](https://github.com/chris-yyau/busdriver/issues/315) + pre-existing typos) ([#319](https://github.com/chris-yyau/busdriver/issues/319)) ([b239865](https://github.com/chris-yyau/busdriver/commit/b23986517744cdace99bde01cb533615f5e19f17)), closes [#316](https://github.com/chris-yyau/busdriver/issues/316)

# [1.87.0](https://github.com/chris-yyau/busdriver/compare/v1.86.1...v1.87.0) (2026-07-10)


### Features

* **rules:** retire 70 vendored ECC rules; own a tiny hand-written canon ([#315](https://github.com/chris-yyau/busdriver/issues/315)) ([8df00f4](https://github.com/chris-yyau/busdriver/commit/8df00f4122c6220db6f2ab8478b911c40f48904c))

## [1.86.1](https://github.com/chris-yyau/busdriver/compare/v1.86.0...v1.86.1) (2026-07-10)


### Bug Fixes

* **security:** fail-closed guard for .github/ changes in scanner detector ([#318](https://github.com/chris-yyau/busdriver/issues/318)) ([834088c](https://github.com/chris-yyau/busdriver/commit/834088cb03278e800d11e986b9c6ad1f90747c0c))

# [1.86.0](https://github.com/chris-yyau/busdriver/compare/v1.85.1...v1.86.0) (2026-07-10)


### Features

* ultimate-tier fable subagent-first + council plugin-root self-resolve ([#317](https://github.com/chris-yyau/busdriver/issues/317)) ([46ba372](https://github.com/chris-yyau/busdriver/commit/46ba37214a702a80eb206ec7335c01e900c8e251))

## [1.85.1](https://github.com/chris-yyau/busdriver/compare/v1.85.0...v1.85.1) (2026-07-10)


### Bug Fixes

* harden bump-version.sh (jq injection, semver anchor, empty-array guard) ([#312](https://github.com/chris-yyau/busdriver/issues/312)) ([a922afe](https://github.com/chris-yyau/busdriver/commit/a922afe18d94184811089275238337f5eb560210))

# [1.85.0](https://github.com/chris-yyau/busdriver/compare/v1.84.7...v1.85.0) (2026-07-10)


### Features

* **rules:** install-exclude mechanism to skip redundant common rules ([#313](https://github.com/chris-yyau/busdriver/issues/313)) ([d4ce47d](https://github.com/chris-yyau/busdriver/commit/d4ce47d71afcb19a702d4ef3f3f29bae27c4641c)), closes [310/#311](https://github.com/chris-yyau/busdriver/issues/311)

## [1.84.7](https://github.com/chris-yyau/busdriver/compare/v1.84.6...v1.84.7) (2026-07-10)


### Reverts

* Revert "refactor: vault 7 upstream-duplicated common rules behind rules-archive ([#310](https://github.com/chris-yyau/busdriver/issues/310))" ([#311](https://github.com/chris-yyau/busdriver/issues/311)) ([1f6e1d9](https://github.com/chris-yyau/busdriver/commit/1f6e1d9f0c5ca2c10886a65ac38d86fd063e6a56))

## [1.84.6](https://github.com/chris-yyau/busdriver/compare/v1.84.5...v1.84.6) (2026-07-09)


### Performance Improvements

* token & hook-latency optimization (registry −3.3k tokens, observe.sh ~571ms→127ms) ([#309](https://github.com/chris-yyau/busdriver/issues/309)) ([913a778](https://github.com/chris-yyau/busdriver/commit/913a778a0b4d743f240e1fada04c025f4794e48c))

## [1.84.5](https://github.com/chris-yyau/busdriver/compare/v1.84.4...v1.84.5) (2026-07-09)


### Bug Fixes

* **upstream:** track 136 vendored skills under 4 new upstreams ([#254](https://github.com/chris-yyau/busdriver/issues/254)) ([#307](https://github.com/chris-yyau/busdriver/issues/307)) ([a3d5fbc](https://github.com/chris-yyau/busdriver/commit/a3d5fbc29f83b775721bd1dda2ef807aecad5507))

## [1.84.4](https://github.com/chris-yyau/busdriver/compare/v1.84.3...v1.84.4) (2026-07-09)


### Bug Fixes

* **pr-grind:** opt-in one-shot Codex nudge when Codex never auto-triggers (none) ([#298](https://github.com/chris-yyau/busdriver/issues/298)) ([#306](https://github.com/chris-yyau/busdriver/issues/306)) ([22b0cbd](https://github.com/chris-yyau/busdriver/commit/22b0cbd6b7f54efaf84efe8a6d77bda196d667a5))

## [1.84.3](https://github.com/chris-yyau/busdriver/compare/v1.84.2...v1.84.3) (2026-07-09)


### Bug Fixes

* **gates:** anchor advisory-downgrade timestamp to github server clock ([#302](https://github.com/chris-yyau/busdriver/issues/302)) ([#305](https://github.com/chris-yyau/busdriver/issues/305)) ([429c4c9](https://github.com/chris-yyau/busdriver/commit/429c4c9030cec15294d904be2e2f4e85462bee0f))

## [1.84.2](https://github.com/chris-yyau/busdriver/compare/v1.84.1...v1.84.2) (2026-07-09)


### Bug Fixes

* **gates:** block indirect-write self-bypass of skip/marker files ([#290](https://github.com/chris-yyau/busdriver/issues/290)) ([#304](https://github.com/chris-yyau/busdriver/issues/304)) ([5045010](https://github.com/chris-yyau/busdriver/commit/504501000a37515514e0869d3a2985f853b6811f))

## [1.84.1](https://github.com/chris-yyau/busdriver/compare/v1.84.0...v1.84.1) (2026-07-08)


### Bug Fixes

* route brainstorming + ultraoracle oracle consults through bash wrapper ([#296](https://github.com/chris-yyau/busdriver/issues/296)) ([#303](https://github.com/chris-yyau/busdriver/issues/303)) ([a4f84bf](https://github.com/chris-yyau/busdriver/commit/a4f84bfab3de53abad2b4a095f5b8e95f67cbae8))

# [1.84.0](https://github.com/chris-yyau/busdriver/compare/v1.83.4...v1.84.0) (2026-07-08)


### Features

* bounded advisory-bot stale-ack timeout downgrade in pr-grind ([#295](https://github.com/chris-yyau/busdriver/issues/295)) ([#300](https://github.com/chris-yyau/busdriver/issues/300)) ([780b2ba](https://github.com/chris-yyau/busdriver/commit/780b2bac08560f7de7376dcf989132629be50da3)), closes [#291](https://github.com/chris-yyau/busdriver/issues/291) [#293](https://github.com/chris-yyau/busdriver/issues/293)

## [1.83.4](https://github.com/chris-yyau/busdriver/compare/v1.83.3...v1.83.4) (2026-07-07)


### Bug Fixes

* run UltraOracle via bash-shebang wrapper so ultra-council works under zsh ([#299](https://github.com/chris-yyau/busdriver/issues/299)) ([9370833](https://github.com/chris-yyau/busdriver/commit/93708335b4dad326f88c4db2d046a4f860201a79)), closes [#6](https://github.com/chris-yyau/busdriver/issues/6)

## [1.83.3](https://github.com/chris-yyau/busdriver/compare/v1.83.2...v1.83.3) (2026-07-07)


### Bug Fixes

* hoist Case 1b rate-limit exemption ahead of Tier E non-success exit ([#294](https://github.com/chris-yyau/busdriver/issues/294)) ([#297](https://github.com/chris-yyau/busdriver/issues/297)) ([a23ca20](https://github.com/chris-yyau/busdriver/commit/a23ca2003a113869a4754887bccd324bc5c4f831))

## [1.83.2](https://github.com/chris-yyau/busdriver/compare/v1.83.1...v1.83.2) (2026-07-07)


### Bug Fixes

* ultra-oracle hideWindow opt-in (visible default) + capture oracle stdout on failure (B8) ([#293](https://github.com/chris-yyau/busdriver/issues/293)) ([8c3414d](https://github.com/chris-yyau/busdriver/commit/8c3414dea4f7f3d63fda4c01b93e2db4a5963b70))

## [1.83.1](https://github.com/chris-yyau/busdriver/compare/v1.83.0...v1.83.1) (2026-07-07)


### Bug Fixes

* downgrade issue-comment rate-limit notices in ack-ledger (Case 1b) ([#292](https://github.com/chris-yyau/busdriver/issues/292)) ([d99001e](https://github.com/chris-yyau/busdriver/commit/d99001eba60db206e434ca9efa99b8d723d074d5))

# [1.83.0](https://github.com/chris-yyau/busdriver/compare/v1.82.0...v1.83.0) (2026-07-07)


### Features

* adopt tranche D upstream vault skills (loop-design-check live + 6 vaulted) ([#291](https://github.com/chris-yyau/busdriver/issues/291)) ([f7e53f8](https://github.com/chris-yyau/busdriver/commit/f7e53f89b130e3d6bf028058a2b60458ee560b8e))

# [1.82.0](https://github.com/chris-yyau/busdriver/compare/v1.81.1...v1.82.0) (2026-07-07)


### Features

* sync verified upstream content across clv2, hooks, and skills ([#289](https://github.com/chris-yyau/busdriver/issues/289)) ([c0d5d16](https://github.com/chris-yyau/busdriver/commit/c0d5d16126e1ec1015731c732283a0e52c06b604)), closes [#2296](https://github.com/chris-yyau/busdriver/issues/2296) [#2300](https://github.com/chris-yyau/busdriver/issues/2300) [#2413](https://github.com/chris-yyau/busdriver/issues/2413) [#2370](https://github.com/chris-yyau/busdriver/issues/2370) [#2417](https://github.com/chris-yyau/busdriver/issues/2417) [#2297](https://github.com/chris-yyau/busdriver/issues/2297) [#276](https://github.com/chris-yyau/busdriver/issues/276)

## [1.81.1](https://github.com/chris-yyau/busdriver/compare/v1.81.0...v1.81.1) (2026-07-06)


### Bug Fixes

* correct upstream attribution and licenses in manifest ([#288](https://github.com/chris-yyau/busdriver/issues/288)) ([7a5a5b8](https://github.com/chris-yyau/busdriver/commit/7a5a5b8cb4160c0b6e168a93a6aa471a5d856829)), closes [hi#end-visual-design](https://github.com/hi/issues/end-visual-design)

# [1.81.0](https://github.com/chris-yyau/busdriver/compare/v1.80.0...v1.81.0) (2026-07-06)


### Features

* complete superpowers v6 adoption (SDD scripts, manifest validator) ([#287](https://github.com/chris-yyau/busdriver/issues/287)) ([1046fbb](https://github.com/chris-yyau/busdriver/commit/1046fbb2d82a6d06459a7fb2eeb8a9a402856fc7)), closes [#49](https://github.com/chris-yyau/busdriver/issues/49) [#147](https://github.com/chris-yyau/busdriver/issues/147) [#215](https://github.com/chris-yyau/busdriver/issues/215)

# [1.80.0](https://github.com/chris-yyau/busdriver/compare/v1.79.3...v1.80.0) (2026-07-06)


### Features

* add vault-promote.sh helper for skill vault promotion ([#285](https://github.com/chris-yyau/busdriver/issues/285)) ([bc3dd76](https://github.com/chris-yyau/busdriver/commit/bc3dd766256b8ae1943a6cfe15bee32a07aeffc8))

## [1.79.3](https://github.com/chris-yyau/busdriver/compare/v1.79.2...v1.79.3) (2026-07-05)


### Bug Fixes

* resolve full-plugin audit findings (gates, agents, commands, CI validators) ([#283](https://github.com/chris-yyau/busdriver/issues/283)) ([b333137](https://github.com/chris-yyau/busdriver/commit/b333137f422c1bb9f5f11fce6abf0e8b2cc04d82))

## [1.79.2](https://github.com/chris-yyau/busdriver/compare/v1.79.1...v1.79.2) (2026-07-05)


### Bug Fixes

* **pr-grind:** reject gitlink path components in excluded-only exclusion verification ([#281](https://github.com/chris-yyau/busdriver/issues/281)) ([#282](https://github.com/chris-yyau/busdriver/issues/282)) ([87df515](https://github.com/chris-yyau/busdriver/commit/87df51574bebeaac6c8186e4d0c12bf34acb6f19))

## [1.79.1](https://github.com/chris-yyau/busdriver/compare/v1.79.0...v1.79.1) (2026-07-05)


### Bug Fixes

* resolve deferred issues [#271](https://github.com/chris-yyau/busdriver/issues/271), [#277](https://github.com/chris-yyau/busdriver/issues/277), [#278](https://github.com/chris-yyau/busdriver/issues/278) ([#280](https://github.com/chris-yyau/busdriver/issues/280)) ([f11b04f](https://github.com/chris-yyau/busdriver/commit/f11b04ffcf577b382a0bd98412b3af343d00a22b)), closes [#252](https://github.com/chris-yyau/busdriver/issues/252)

# [1.79.0](https://github.com/chris-yyau/busdriver/compare/v1.78.0...v1.79.0) (2026-07-04)


### Features

* **skills:** adopt marketing-skills pack into zero-context vault ([#276](https://github.com/chris-yyau/busdriver/issues/276)) ([553aa89](https://github.com/chris-yyau/busdriver/commit/553aa8966ffb9b3f9cb5c36cb7589187960c462f))

# [1.78.0](https://github.com/chris-yyau/busdriver/compare/v1.77.0...v1.78.0) (2026-07-03)


### Features

* **ultimate:** ultimate arbiter rename + ultimate council mythos witness ([#275](https://github.com/chris-yyau/busdriver/issues/275)) ([c9118ef](https://github.com/chris-yyau/busdriver/commit/c9118ef79b9f3c387e91d7d7cf86299497f6455d))

# [1.77.0](https://github.com/chris-yyau/busdriver/compare/v1.76.2...v1.77.0) (2026-07-02)


### Features

* **agents:** tier per-agent reasoning effort with enforced guard ([#272](https://github.com/chris-yyau/busdriver/issues/272)) ([65cd3aa](https://github.com/chris-yyau/busdriver/commit/65cd3aa62dad84bdc23ae45f17c22c43475007d0))

## [1.76.2](https://github.com/chris-yyau/busdriver/compare/v1.76.1...v1.76.2) (2026-07-02)


### Bug Fixes

* **ack-ledger:** branch+SHA-bound check-suite fallback anchor for new-branch codex ack ([#269](https://github.com/chris-yyau/busdriver/issues/269)) ([#270](https://github.com/chris-yyau/busdriver/issues/270)) ([b575734](https://github.com/chris-yyau/busdriver/commit/b57573409eb0c6aaa951c2d9e859bad873ae737f))

## [1.76.1](https://github.com/chris-yyau/busdriver/compare/v1.76.0...v1.76.1) (2026-07-02)


### Bug Fixes

* **refine-notes:** correct tuple unpacking in prune-notes stale loops ([#268](https://github.com/chris-yyau/busdriver/issues/268)) ([9d5024c](https://github.com/chris-yyau/busdriver/commit/9d5024c63606e8bccea8e7e83edd4d2c5fd63a44))

# [1.76.0](https://github.com/chris-yyau/busdriver/compare/v1.75.0...v1.76.0) (2026-07-01)


### Features

* **blueprint-review:** enforce ultra-arbiter opt-in + CI/test hardening ([#265](https://github.com/chris-yyau/busdriver/issues/265)) ([#267](https://github.com/chris-yyau/busdriver/issues/267)) ([fb86e2f](https://github.com/chris-yyau/busdriver/commit/fb86e2f01b3ef5e58f322bda9e74aa069d254564)), closes [#266](https://github.com/chris-yyau/busdriver/issues/266)

# [1.75.0](https://github.com/chris-yyau/busdriver/compare/v1.74.0...v1.75.0) (2026-07-01)


### Features

* **blueprint-review:** opus-default arbiter, drop fable, gateway-fable as opt-in ultra arbiter ([#266](https://github.com/chris-yyau/busdriver/issues/266)) ([cd320a1](https://github.com/chris-yyau/busdriver/commit/cd320a16c22271cc2dc00b153987becf6215e2b3)), closes [#265](https://github.com/chris-yyau/busdriver/issues/265)

# [1.74.0](https://github.com/chris-yyau/busdriver/compare/v1.73.0...v1.74.0) (2026-07-01)


### Features

* **ultraoracle:** ADR 0007 Phase 5 — two-round retrieval loop (deterministic core) ([#263](https://github.com/chris-yyau/busdriver/issues/263)) ([4de5dc1](https://github.com/chris-yyau/busdriver/commit/4de5dc1a2f5984614335df0207204c8ac54d7118))

# [1.73.0](https://github.com/chris-yyau/busdriver/compare/v1.72.2...v1.73.0) (2026-06-30)


### Features

* **ultra-council:** render UltraOracle as separate expert witness (ADR 0007 phase 3) ([#261](https://github.com/chris-yyau/busdriver/issues/261)) ([0c2f157](https://github.com/chris-yyau/busdriver/commit/0c2f1578cf0bfcab4f682a55509e47e32b9be434))

## [1.72.2](https://github.com/chris-yyau/busdriver/compare/v1.72.1...v1.72.2) (2026-06-29)


### Bug Fixes

* **test:** eliminate SIGPIPE race in verdict-freshness cleanup check ([#260](https://github.com/chris-yyau/busdriver/issues/260)) ([b1a9bd4](https://github.com/chris-yyau/busdriver/commit/b1a9bd45f99e8db9722b915b5af801b7f789838f))

## [1.72.1](https://github.com/chris-yyau/busdriver/compare/v1.72.0...v1.72.1) (2026-06-29)


### Bug Fixes

* **ultra-oracle:** reject degenerate near-empty verdicts (false-ok) ([#259](https://github.com/chris-yyau/busdriver/issues/259)) ([ca7e1c3](https://github.com/chris-yyau/busdriver/commit/ca7e1c381a8c495607c3648c6b3f60a4dcd7b993))

# [1.72.0](https://github.com/chris-yyau/busdriver/compare/v1.71.5...v1.72.0) (2026-06-28)


### Features

* **ultraoracle:** ADR 0007 Phase 1 — standalone expert-witness skill ([#258](https://github.com/chris-yyau/busdriver/issues/258)) ([194d735](https://github.com/chris-yyau/busdriver/commit/194d73575985093d6633514f6e74c5f3ec5dfb4e)), closes [#2](https://github.com/chris-yyau/busdriver/issues/2)

## [1.71.5](https://github.com/chris-yyau/busdriver/compare/v1.71.4...v1.71.5) (2026-06-28)


### Bug Fixes

* **ui-ux-pro-max:** path containment + input validation ([#234](https://github.com/chris-yyau/busdriver/issues/234)) ([#256](https://github.com/chris-yyau/busdriver/issues/256)) ([a6bb638](https://github.com/chris-yyau/busdriver/commit/a6bb6380e565f91d3a1cb4a8163f9f74295d9871))

## [1.71.4](https://github.com/chris-yyau/busdriver/compare/v1.71.3...v1.71.4) (2026-06-27)


### Bug Fixes

* **security:** harden upstream-synced path-safety + validate-hooks escaping ([#249](https://github.com/chris-yyau/busdriver/issues/249)) ([b2dc23a](https://github.com/chris-yyau/busdriver/commit/b2dc23a805ea34a7969a7a531d5a10de0cad3ca2))

## [1.71.3](https://github.com/chris-yyau/busdriver/compare/v1.71.2...v1.71.3) (2026-06-27)


### Bug Fixes

* **skills:** correct vendored ui-ux/supabase doc refs and track upstreams ([#255](https://github.com/chris-yyau/busdriver/issues/255)) ([30be5d9](https://github.com/chris-yyau/busdriver/commit/30be5d9ac4689a1b8e753111b1cc1b0f4814c1bc)), closes [#254](https://github.com/chris-yyau/busdriver/issues/254)

## [1.71.2](https://github.com/chris-yyau/busdriver/compare/v1.71.1...v1.71.2) (2026-06-27)


### Bug Fixes

* **litmus:** refuse excluded-only auto-pass when PR modifies review-exclude ([#252](https://github.com/chris-yyau/busdriver/issues/252)) ([#253](https://github.com/chris-yyau/busdriver/issues/253)) ([2e2aca4](https://github.com/chris-yyau/busdriver/commit/2e2aca444acf9bb5f7e022977df0998f7fcc0cd0))

## [1.71.1](https://github.com/chris-yyau/busdriver/compare/v1.71.0...v1.71.1) (2026-06-27)


### Bug Fixes

* **litmus:** unblock excluded-only PRs via PASS-EXCLUDED marker ([#250](https://github.com/chris-yyau/busdriver/issues/250)) ([72941bf](https://github.com/chris-yyau/busdriver/commit/72941bfe8283f3b50e314ba3edf54dbb32787dd3)), closes [#226](https://github.com/chris-yyau/busdriver/issues/226)

# [1.71.0](https://github.com/chris-yyau/busdriver/compare/v1.70.1...v1.71.0) (2026-06-25)


### Features

* adopt upstream gap-filler skills, agents, and rules from ECC ([#240](https://github.com/chris-yyau/busdriver/issues/240)) ([8b244e4](https://github.com/chris-yyau/busdriver/commit/8b244e4f18abd2b40b84b7b2b2bf32b94bfc9e17)), closes [#239](https://github.com/chris-yyau/busdriver/issues/239) [hi#score](https://github.com/hi/issues/score) [hi#score](https://github.com/hi/issues/score) [hi#score-example](https://github.com/hi/issues/score-example) [hi#score-example](https://github.com/hi/issues/score-example)

## [1.70.1](https://github.com/chris-yyau/busdriver/compare/v1.70.0...v1.70.1) (2026-06-23)


### Bug Fixes

* clear stale ultra-oracle output before dispatch ([#243](https://github.com/chris-yyau/busdriver/issues/243)) ([b36764a](https://github.com/chris-yyau/busdriver/commit/b36764ab182c9b7a0318e478895a96d87d833453))

# [1.70.0](https://github.com/chris-yyau/busdriver/compare/v1.69.0...v1.70.0) (2026-06-23)


### Features

* register devin as a fourth pr-grind ack-panel reviewer ([#241](https://github.com/chris-yyau/busdriver/issues/241)) ([209317f](https://github.com/chris-yyau/busdriver/commit/209317fa0ea1e151ade3cd9fffcb4aabb69c05dd))

# [1.69.0](https://github.com/chris-yyau/busdriver/compare/v1.68.0...v1.69.0) (2026-06-22)


### Features

* add opt-in oracle-max (GPT-5.5 Pro) consult at three surfaces ([#237](https://github.com/chris-yyau/busdriver/issues/237)) ([b0bef95](https://github.com/chris-yyau/busdriver/commit/b0bef957351e9450276431a71b154e3bdfc2a946))

# [1.68.0](https://github.com/chris-yyau/busdriver/compare/v1.67.0...v1.68.0) (2026-06-22)


### Features

* retry external review CLIs before droid fallback (blueprint, council, litmus) ([#236](https://github.com/chris-yyau/busdriver/issues/236)) ([a50e6d3](https://github.com/chris-yyau/busdriver/commit/a50e6d3f8a0d8ed8734c809abad031949e00daa8))

# [1.67.0](https://github.com/chris-yyau/busdriver/compare/v1.66.1...v1.67.0) (2026-06-21)


### Features

* **skills:** vendor ui-ux-pro-max + supabase-postgres-best-practices into busdriver ([#233](https://github.com/chris-yyau/busdriver/issues/233)) ([349e9c0](https://github.com/chris-yyau/busdriver/commit/349e9c0ebc2dec3218cbd1e6186d97f5c00cdeae))

## [1.66.1](https://github.com/chris-yyau/busdriver/compare/v1.66.0...v1.66.1) (2026-06-21)


### Bug Fixes

* state-dir-aware absolute skip-file paths + firecrawl allow-list helpers ([#232](https://github.com/chris-yyau/busdriver/issues/232)) ([9331840](https://github.com/chris-yyau/busdriver/commit/9331840eacc97fc0f34ad50bb0da02d331af17df)), closes [#228](https://github.com/chris-yyau/busdriver/issues/228)

# [1.66.0](https://github.com/chris-yyau/busdriver/compare/v1.65.0...v1.66.0) (2026-06-21)


### Features

* **skills:** consolidate web/docs/design/native tooling into busdriver; adopt official Vercel/Exa/Context7; rewrite deep-research ([#228](https://github.com/chris-yyau/busdriver/issues/228)) ([a822f91](https://github.com/chris-yyau/busdriver/commit/a822f91444ce70a1c7ed682521cef77dbacf7888))

# [1.65.0](https://github.com/chris-yyau/busdriver/compare/v1.64.0...v1.65.0) (2026-06-21)


### Features

* hand litmus PR-mode deep review to Codex lead + read-only Opus backstop ([#225](https://github.com/chris-yyau/busdriver/issues/225)) ([25ebef8](https://github.com/chris-yyau/busdriver/commit/25ebef878190b18d8cbbc7b676e47cffd87a4d34))

# [1.64.0](https://github.com/chris-yyau/busdriver/compare/v1.63.1...v1.64.0) (2026-06-20)


### Features

* auto-re-trigger codex when it is the sole stale blocker on an unchanged HEAD ([#221](https://github.com/chris-yyau/busdriver/issues/221)) ([c2462a6](https://github.com/chris-yyau/busdriver/commit/c2462a6d60ae69c1c2105f87257e91702085fb89)), closes [#stubbed](https://github.com/chris-yyau/busdriver/issues/stubbed)

## [1.63.1](https://github.com/chris-yyau/busdriver/compare/v1.63.0...v1.63.1) (2026-06-20)


### Bug Fixes

* **pr-grind:** carry reviewer acks forward across content-identical force-pushes ([#217](https://github.com/chris-yyau/busdriver/issues/217)) ([a900bf6](https://github.com/chris-yyau/busdriver/commit/a900bf6138d161fa6c55b2c23dc5f1673a334f90)), closes [186/#189](https://github.com/chris-yyau/busdriver/issues/189)

# [1.63.0](https://github.com/chris-yyau/busdriver/compare/v1.62.6...v1.63.0) (2026-06-20)


### Features

* opencode harness support — litmus, blueprint-review, council, pr-grind ([#207](https://github.com/chris-yyau/busdriver/issues/207)) ([ff1d0a3](https://github.com/chris-yyau/busdriver/commit/ff1d0a3b9cc29a497b7d7abfa9480bf6aa8ec537))


### Reverts

* remove opencode install docs from main README ([#213](https://github.com/chris-yyau/busdriver/issues/213) throwaway) ([#214](https://github.com/chris-yyau/busdriver/issues/214)) ([6869ba0](https://github.com/chris-yyau/busdriver/commit/6869ba02fa439782898335a5e4ae4086397b130a)), closes [#207](https://github.com/chris-yyau/busdriver/issues/207) [#207](https://github.com/chris-yyau/busdriver/issues/207)

## [1.62.6](https://github.com/chris-yyau/busdriver/compare/v1.62.5...v1.62.6) (2026-06-19)


### Bug Fixes

* **security-ci:** run secret scanning unconditionally on every PR ([#211](https://github.com/chris-yyau/busdriver/issues/211)) ([a18c7d0](https://github.com/chris-yyau/busdriver/commit/a18c7d0228b0a05a1306e1938b114dae78fff7b6)), closes [#172](https://github.com/chris-yyau/busdriver/issues/172) [#209](https://github.com/chris-yyau/busdriver/issues/209) [#209](https://github.com/chris-yyau/busdriver/issues/209) [#209](https://github.com/chris-yyau/busdriver/issues/209)

## [1.62.5](https://github.com/chris-yyau/busdriver/compare/v1.62.4...v1.62.5) (2026-06-18)


### Bug Fixes

* **ack-ledger:** fail closed on Tier-F +1 when push anchor absent ([#189](https://github.com/chris-yyau/busdriver/issues/189)) ([#205](https://github.com/chris-yyau/busdriver/issues/205)) ([61c20f2](https://github.com/chris-yyau/busdriver/commit/61c20f20844e0c179894594f1fff8dfad0b57544))

## [1.62.4](https://github.com/chris-yyau/busdriver/compare/v1.62.3...v1.62.4) (2026-06-17)


### Bug Fixes

* **ack-ledger:** push-anchor resolved-Codex-thread ack, fail closed without push date ([#186](https://github.com/chris-yyau/busdriver/issues/186), [#187](https://github.com/chris-yyau/busdriver/issues/187)) ([#204](https://github.com/chris-yyau/busdriver/issues/204)) ([41d109d](https://github.com/chris-yyau/busdriver/commit/41d109dd85edb27a2bb49c7bb7c37c5d48a3a56b))

## [1.62.3](https://github.com/chris-yyau/busdriver/compare/v1.62.2...v1.62.3) (2026-06-16)


### Bug Fixes

* **blueprint-review:** neutralize inherited Edit allow rules in gateway arbiter ([#198](https://github.com/chris-yyau/busdriver/issues/198)) ([#201](https://github.com/chris-yyau/busdriver/issues/201)) ([5f3c9f8](https://github.com/chris-yyau/busdriver/commit/5f3c9f8baf9a0d333fa463901dfda9547e4337f8)), closes [#202](https://github.com/chris-yyau/busdriver/issues/202)

## [1.62.2](https://github.com/chris-yyau/busdriver/compare/v1.62.1...v1.62.2) (2026-06-16)


### Bug Fixes

* **gates:** cwd-anchor repo resolution to close cd-substitution fail-open ([#200](https://github.com/chris-yyau/busdriver/issues/200)) ([16a5962](https://github.com/chris-yyau/busdriver/commit/16a5962da39fb9edb1482332acb7b8ef511aff81))

## [1.62.1](https://github.com/chris-yyau/busdriver/compare/v1.62.0...v1.62.1) (2026-06-14)


### Bug Fixes

* **blueprint-review:** make gateway arbiter work live + harden credential containment ([#197](https://github.com/chris-yyau/busdriver/issues/197)) ([649b310](https://github.com/chris-yyau/busdriver/commit/649b310bba1946d80aa9c402fb86eef87fefca78))

# [1.62.0](https://github.com/chris-yyau/busdriver/compare/v1.61.1...v1.62.0) (2026-06-12)


### Features

* **blueprint-review:** add gateway-fable arbiter fallback rung ([#196](https://github.com/chris-yyau/busdriver/issues/196)) ([96c9359](https://github.com/chris-yyau/busdriver/commit/96c93595214e5ea25d70b552a4c6be779db6e918))

## [1.61.1](https://github.com/chris-yyau/busdriver/compare/v1.61.0...v1.61.1) (2026-06-11)


### Bug Fixes

* **pre-pr-gate:** defer PR marker consumption until gh pr create succeeds ([#194](https://github.com/chris-yyau/busdriver/issues/194)) ([19aac01](https://github.com/chris-yyau/busdriver/commit/19aac01a7701bf0fe6293236c82883dd65ce73a6))

# [1.61.0](https://github.com/chris-yyau/busdriver/compare/v1.60.0...v1.61.0) (2026-06-10)


### Features

* **blueprint-review:** explicit arbiter model fallback chain (fable -> opus -> inherit) ([#193](https://github.com/chris-yyau/busdriver/issues/193)) ([6a4f43a](https://github.com/chris-yyau/busdriver/commit/6a4f43a750cceb80785a2692d2c0f468bc4cd5cd))

# [1.60.0](https://github.com/chris-yyau/busdriver/compare/v1.59.0...v1.60.0) (2026-06-10)


### Features

* **blueprint-review:** fresh fable subagent arbiter + verdict freshness re-key (adr 0003) ([#191](https://github.com/chris-yyau/busdriver/issues/191)) ([4568192](https://github.com/chris-yyau/busdriver/commit/45681923899a7ec1e25abad22e783a3ef562ae40))

# [1.59.0](https://github.com/chris-yyau/busdriver/compare/v1.58.0...v1.59.0) (2026-06-07)


### Features

* **orchestrator:** adopt impeccable + taste-skill dual-engine for ui/ux routing ([#190](https://github.com/chris-yyau/busdriver/issues/190)) ([b678351](https://github.com/chris-yyau/busdriver/commit/b678351a8f150c2b4584093d6f5fc0e43156948d)), closes [minimalist/brutalist/hi#end](https://github.com/minimalist/brutalist/hi/issues/end)

# [1.58.0](https://github.com/chris-yyau/busdriver/compare/v1.57.0...v1.58.0) (2026-06-07)


### Features

* **pr-grind:** gate Codex review via reaction-aware ack-ledger Tier F ([#185](https://github.com/chris-yyau/busdriver/issues/185)) ([81ea25a](https://github.com/chris-yyau/busdriver/commit/81ea25a3e4c330d11bf3a38ab4831c747ffa224a)), closes [#142](https://github.com/chris-yyau/busdriver/issues/142) [#140](https://github.com/chris-yyau/busdriver/issues/140) [#mock](https://github.com/chris-yyau/busdriver/issues/mock)

# [1.57.0](https://github.com/chris-yyau/busdriver/compare/v1.56.2...v1.57.0) (2026-06-06)


### Features

* harness epistemic-honesty (verify reflex + coverage provenance + council settling-checks) ([#184](https://github.com/chris-yyau/busdriver/issues/184)) ([4b8ad29](https://github.com/chris-yyau/busdriver/commit/4b8ad29f62c92361cd4a27d152b776803f9a07a0))

## [1.56.2](https://github.com/chris-yyau/busdriver/compare/v1.56.1...v1.56.2) (2026-06-06)


### Bug Fixes

* **litmus:** guard smart-context against large/long-line diff hang ([#183](https://github.com/chris-yyau/busdriver/issues/183)) ([7e86ed4](https://github.com/chris-yyau/busdriver/commit/7e86ed48a4f4758e41731d3fd9fd9471050cdac9))

## [1.56.1](https://github.com/chris-yyau/busdriver/compare/v1.56.0...v1.56.1) (2026-06-05)


### Bug Fixes

* **pr-grind:** approver-gap detector reads classic branch protection too ([#182](https://github.com/chris-yyau/busdriver/issues/182)) ([9e510d7](https://github.com/chris-yyau/busdriver/commit/9e510d7df56e30cdbb7509092e0101765869548e))

# [1.56.0](https://github.com/chris-yyau/busdriver/compare/v1.55.0...v1.56.0) (2026-06-05)


### Features

* **ci:** adopt canonical no-dedup bypass-audit standard ([#181](https://github.com/chris-yyau/busdriver/issues/181)) ([ba03bec](https://github.com/chris-yyau/busdriver/commit/ba03becff3c34130bdd24b5cc2a7d9bb8404ceac))

# [1.55.0](https://github.com/chris-yyau/busdriver/compare/v1.54.6...v1.55.0) (2026-06-05)


### Features

* **pr-grind:** swap greptile to cursor in ack registry, add codex as collected reviewer ([#179](https://github.com/chris-yyau/busdriver/issues/179)) ([639654c](https://github.com/chris-yyau/busdriver/commit/639654c5083a2dfac691daf395886175f54c7d6e))

## [1.54.6](https://github.com/chris-yyau/busdriver/compare/v1.54.5...v1.54.6) (2026-06-04)


### Bug Fixes

* **ci:** dedup admin-bypass audit issues by commit sha ([#177](https://github.com/chris-yyau/busdriver/issues/177)) ([868b5f2](https://github.com/chris-yyau/busdriver/commit/868b5f27c6666c4fb288373be6f60e984bd46459)), closes [Dive-And-Dev/diveanddev.com#30](https://github.com/Dive-And-Dev/diveanddev.com/issues/30)

## [1.54.5](https://github.com/chris-yyau/busdriver/compare/v1.54.4...v1.54.5) (2026-06-03)


### Bug Fixes

* **pr-grind:** unify check-status filter via shared relevant-check-status.sh ([#173](https://github.com/chris-yyau/busdriver/issues/173)) ([59425bb](https://github.com/chris-yyau/busdriver/commit/59425bb9d69f88a8446f142bda56709ef412dd8c)), closes [#155](https://github.com/chris-yyau/busdriver/issues/155) [#154](https://github.com/chris-yyau/busdriver/issues/154)

## [1.54.4](https://github.com/chris-yyau/busdriver/compare/v1.54.3...v1.54.4) (2026-06-01)


### Bug Fixes

* **security:** resolve codeql code-scanning alerts (double-escape, dom-xss, incomplete-escape) ([#169](https://github.com/chris-yyau/busdriver/issues/169)) ([6d8ff9f](https://github.com/chris-yyau/busdriver/commit/6d8ff9ff141a7f2720acebcef9f5d6dee9dce0aa)), closes [js/xss-throu#dom](https://github.com/js/xss-throu/issues/dom)

## [1.54.3](https://github.com/chris-yyau/busdriver/compare/v1.54.2...v1.54.3) (2026-05-29)


### Bug Fixes

* **codex-goal:** resolve plugin scripts via CLAUDE_PLUGIN_ROOT in consumer repos ([#168](https://github.com/chris-yyau/busdriver/issues/168)) ([6dc09b1](https://github.com/chris-yyau/busdriver/commit/6dc09b1e94ce9576906a156fe6a5ed2ca2f189f1))

## [1.54.2](https://github.com/chris-yyau/busdriver/compare/v1.54.1...v1.54.2) (2026-05-29)


### Bug Fixes

* **litmus:** point forge-block at trusted writer + cap cosmetic pr findings ([#167](https://github.com/chris-yyau/busdriver/issues/167)) ([dafabc9](https://github.com/chris-yyau/busdriver/commit/dafabc9dc2f12eebf50bcaa813075ded2694e4c5))

## [1.54.1](https://github.com/chris-yyau/busdriver/compare/v1.54.0...v1.54.1) (2026-05-29)


### Performance Improvements

* reduce per-session context via progressive disclosure ([#165](https://github.com/chris-yyau/busdriver/issues/165)) ([abefb75](https://github.com/chris-yyau/busdriver/commit/abefb759f25886cc3d8175f7de22428931eecb4b)), closes [#3542](https://github.com/chris-yyau/busdriver/issues/3542)

# [1.54.0](https://github.com/chris-yyau/busdriver/compare/v1.53.3...v1.54.0) (2026-05-29)


### Features

* add runtime droid fallback for failed council and blueprint voices ([#164](https://github.com/chris-yyau/busdriver/issues/164)) ([f617127](https://github.com/chris-yyau/busdriver/commit/f617127a3547dca737759d28c6d7ac6c04f80f7d))

## [1.53.3](https://github.com/chris-yyau/busdriver/compare/v1.53.2...v1.53.3) (2026-05-28)


### Bug Fixes

* **litmus:** bypass codex-companion stdin EAGAIN via --prompt-file ([#162](https://github.com/chris-yyau/busdriver/issues/162)) ([2484aa6](https://github.com/chris-yyau/busdriver/commit/2484aa63703b2b373591a2c677024b3c2bca7c3a))

## [1.53.2](https://github.com/chris-yyau/busdriver/compare/v1.53.1...v1.53.2) (2026-05-27)


### Bug Fixes

* **ack-ledger:** add tier e for legacy commit-statuses api (coderabbit free-tier) ([#161](https://github.com/chris-yyau/busdriver/issues/161)) ([4a7cc8d](https://github.com/chris-yyau/busdriver/commit/4a7cc8d10280f8e9c65eb83da817e027d257a7c2)), closes [HI#confidence](https://github.com/HI/issues/confidence)

## [1.53.1](https://github.com/chris-yyau/busdriver/compare/v1.53.0...v1.53.1) (2026-05-27)


### Bug Fixes

* **litmus:** bump codex retry defaults to absorb rate-limit windows ([#160](https://github.com/chris-yyau/busdriver/issues/160)) ([6c2b9f0](https://github.com/chris-yyau/busdriver/commit/6c2b9f0d09cb3740a5dfd5036f36a4d6991ff500))

# [1.53.0](https://github.com/chris-yyau/busdriver/compare/v1.52.0...v1.53.0) (2026-05-27)


### Features

* **grill-me:** keyword-triggered re-ask of self-decided reversible picks ([#158](https://github.com/chris-yyau/busdriver/issues/158)) ([55465d2](https://github.com/chris-yyau/busdriver/commit/55465d2a17d36bb88516d9a4ae7b49bb1bc0be4a)), closes [#157](https://github.com/chris-yyau/busdriver/issues/157)

# [1.52.0](https://github.com/chris-yyau/busdriver/compare/v1.51.1...v1.52.0) (2026-05-27)


### Features

* **spec-protocol:** classify-before-asking in brainstorming + grill-me ([#156](https://github.com/chris-yyau/busdriver/issues/156)) ([2a3a30e](https://github.com/chris-yyau/busdriver/commit/2a3a30e3567c06c58f8c6225eab9a42c886c1836))

## [1.51.1](https://github.com/chris-yyau/busdriver/compare/v1.51.0...v1.51.1) (2026-05-27)


### Bug Fixes

* **pre-merge-gate:** only block on failures of required checks ([#155](https://github.com/chris-yyau/busdriver/issues/155)) ([19ff9e2](https://github.com/chris-yyau/busdriver/commit/19ff9e26ceae60a321a159541e5712107196210a)), closes [#154](https://github.com/chris-yyau/busdriver/issues/154)

# [1.51.0](https://github.com/chris-yyau/busdriver/compare/v1.50.0...v1.51.0) (2026-05-26)


### Features

* **research:** tavily+exa primary, reserve firecrawl as paid fallback ([#153](https://github.com/chris-yyau/busdriver/issues/153)) ([8b4411e](https://github.com/chris-yyau/busdriver/commit/8b4411ec53cc6229045a3f80449ec7441280df80))

# [1.50.0](https://github.com/chris-yyau/busdriver/compare/v1.49.1...v1.50.0) (2026-05-26)


### Features

* **grok:** add as 3rd external voice in council and blueprint-review ([#152](https://github.com/chris-yyau/busdriver/issues/152)) ([f0b1fce](https://github.com/chris-yyau/busdriver/commit/f0b1fcee4d7d61a73017a544fb80deb8b4f773a1))

## [1.49.1](https://github.com/chris-yyau/busdriver/compare/v1.49.0...v1.49.1) (2026-05-25)


### Bug Fixes

* **scorecard:** remove top-level defaults block to unblock publish ([#151](https://github.com/chris-yyau/busdriver/issues/151)) ([a51328d](https://github.com/chris-yyau/busdriver/commit/a51328dbe05e248784c7d6d504798c5308d12122)), closes [#45](https://github.com/chris-yyau/busdriver/issues/45)

# [1.49.0](https://github.com/chris-yyau/busdriver/compare/v1.48.0...v1.49.0) (2026-05-24)


### Features

* **blueprint-review:** medium-trajectory early-stop + raise max_iter 3→5 ([#149](https://github.com/chris-yyau/busdriver/issues/149)) ([2513579](https://github.com/chris-yyau/busdriver/commit/25135799c664eda7f7ad3c968a93b0a7dd9dbd70)), closes [HI#only](https://github.com/HI/issues/only) [#55](https://github.com/chris-yyau/busdriver/issues/55)

# [1.48.0](https://github.com/chris-yyau/busdriver/compare/v1.47.0...v1.48.0) (2026-05-24)


### Features

* add package provenance audit to security-reviewer ([#148](https://github.com/chris-yyau/busdriver/issues/148)) ([a7ad7b6](https://github.com/chris-yyau/busdriver/commit/a7ad7b67d5e8f706046aa1fad1999fef6aa94871))

# [1.47.0](https://github.com/chris-yyau/busdriver/compare/v1.46.0...v1.47.0) (2026-05-23)


### Features

* **skills:** auto-route to codex on stalls + verifier-shaped plans ([#143](https://github.com/chris-yyau/busdriver/issues/143)) ([2082d0d](https://github.com/chris-yyau/busdriver/commit/2082d0d12506981802bc459862e5dcc8ae2317cc))

# [1.46.0](https://github.com/chris-yyau/busdriver/compare/v1.45.0...v1.46.0) (2026-05-23)


### Features

* **pr-grind:** solo-admin auto-detect for implicit --admin-on-approver-gap ([#142](https://github.com/chris-yyau/busdriver/issues/142)) ([db23f71](https://github.com/chris-yyau/busdriver/commit/db23f716033d070df1e235743481b9f8a8e0388e)), closes [HI#severity](https://github.com/HI/issues/severity)

# [1.45.0](https://github.com/chris-yyau/busdriver/compare/v1.44.0...v1.45.0) (2026-05-22)


### Features

* **litmus:** escalate to droid before builtin on codex rate-limit ([#141](https://github.com/chris-yyau/busdriver/issues/141)) ([586364e](https://github.com/chris-yyau/busdriver/commit/586364ef9a264ba127c6892cb81962e42130d959)), closes [#97](https://github.com/chris-yyau/busdriver/issues/97)

# [1.44.0](https://github.com/chris-yyau/busdriver/compare/v1.43.2...v1.44.0) (2026-05-22)


### Features

* **ack-ledger:** self-resolver re-execs working-tree copy from busdriver source repo ([#140](https://github.com/chris-yyau/busdriver/issues/140)) ([b6780a3](https://github.com/chris-yyau/busdriver/commit/b6780a37dc57fef8a9669c948f9038db9280374b))

## [1.43.2](https://github.com/chris-yyau/busdriver/compare/v1.43.1...v1.43.2) (2026-05-22)


### Bug Fixes

* **ack-ledger:** relax case 3 body regex to substring match ([#138](https://github.com/chris-yyau/busdriver/issues/138)) ([#139](https://github.com/chris-yyau/busdriver/issues/139)) ([ad18ad8](https://github.com/chris-yyau/busdriver/commit/ad18ad8188a792708d197b512239676b60ec2d92)), closes [#137](https://github.com/chris-yyau/busdriver/issues/137)

## [1.43.1](https://github.com/chris-yyau/busdriver/compare/v1.43.0...v1.43.1) (2026-05-22)


### Performance Improvements

* **codex-goal-dispatch:** replace O(N×M) linear scan with awk join ([#133](https://github.com/chris-yyau/busdriver/issues/133)) ([#137](https://github.com/chris-yyau/busdriver/issues/137)) ([62e1706](https://github.com/chris-yyau/busdriver/commit/62e170605faf7b33211e7053e09776dde623b2cd)), closes [#131](https://github.com/chris-yyau/busdriver/issues/131)

# [1.43.0](https://github.com/chris-yyau/busdriver/compare/v1.42.0...v1.43.0) (2026-05-21)


### Features

* **council:** droid fallback + strip opencode/amp/claude/aider CLI surface ([#134](https://github.com/chris-yyau/busdriver/issues/134)) ([41d31ef](https://github.com/chris-yyau/busdriver/commit/41d31ef0686e809f2b6443251ba04efd9435a0e4))

# [1.42.0](https://github.com/chris-yyau/busdriver/compare/v1.41.6...v1.42.0) (2026-05-21)


### Features

* **ack-ledger:** case 3 for check-run conclusion=skipped on head ([#130](https://github.com/chris-yyau/busdriver/issues/130)) ([952ad95](https://github.com/chris-yyau/busdriver/commit/952ad95295ec15885e5de4574d654b87a608fd06))

## [1.41.6](https://github.com/chris-yyau/busdriver/compare/v1.41.5...v1.41.6) (2026-05-21)


### Bug Fixes

* **codex-goal-handover:** dispatcher commits, not codex ([#131](https://github.com/chris-yyau/busdriver/issues/131)) ([ddd370a](https://github.com/chris-yyau/busdriver/commit/ddd370aaad21f0fde3087643dfd56425b9bc5b8e))

## [1.41.5](https://github.com/chris-yyau/busdriver/compare/v1.41.4...v1.41.5) (2026-05-20)


### Bug Fixes

* **pr-grind:** bail Step 0 when baseRefName not in {main,master,develop} ([#127](https://github.com/chris-yyau/busdriver/issues/127)) ([a093505](https://github.com/chris-yyau/busdriver/commit/a0935058308ab536053a0f8d9fbad7f661058567)), closes [#122](https://github.com/chris-yyau/busdriver/issues/122) [HI#severity](https://github.com/HI/issues/severity)

## [1.41.4](https://github.com/chris-yyau/busdriver/compare/v1.41.3...v1.41.4) (2026-05-20)


### Bug Fixes

* **pre-merge-gate:** per-PR marker check + deferred bypass consumption ([#117](https://github.com/chris-yyau/busdriver/issues/117)) ([216ef19](https://github.com/chris-yyau/busdriver/commit/216ef193fa3253253b9b1891401054a94e77b825)), closes [HI#confidence](https://github.com/HI/issues/confidence) [#pr-merge](https://github.com/chris-yyau/busdriver/issues/pr-merge) [HI#severity](https://github.com/HI/issues/severity) [HI#confidence](https://github.com/HI/issues/confidence) [#pr-merge](https://github.com/chris-yyau/busdriver/issues/pr-merge)

## [1.41.3](https://github.com/chris-yyau/busdriver/compare/v1.41.2...v1.41.3) (2026-05-19)


### Bug Fixes

* **pr-grind:** commitlint pre-flight before commit (closes [#114](https://github.com/chris-yyau/busdriver/issues/114)) ([#115](https://github.com/chris-yyau/busdriver/issues/115)) ([dc4eaa7](https://github.com/chris-yyau/busdriver/commit/dc4eaa72af1c369204f917b31c4a69f92ce03c27)), closes [#113](https://github.com/chris-yyau/busdriver/issues/113)

## [1.41.2](https://github.com/chris-yyau/busdriver/compare/v1.41.1...v1.41.2) (2026-05-19)


### Bug Fixes

* **dispatch-cli:** default council/dispatch droid tier to high ([#116](https://github.com/chris-yyau/busdriver/issues/116)) ([656ed36](https://github.com/chris-yyau/busdriver/commit/656ed36578f4532069833930261cba78ec2d2c66)), closes [#97](https://github.com/chris-yyau/busdriver/issues/97) [#97](https://github.com/chris-yyau/busdriver/issues/97)

## [1.41.1](https://github.com/chris-yyau/busdriver/compare/v1.41.0...v1.41.1) (2026-05-18)


### Bug Fixes

* **ack-ledger:** downgrade one-and-done COMMENTED bot to none ([#112](https://github.com/chris-yyau/busdriver/issues/112)) ([7499091](https://github.com/chris-yyau/busdriver/commit/7499091aca6e2a1e0888d811db33907dfb8620c4))

# [1.41.0](https://github.com/chris-yyau/busdriver/compare/v1.40.2...v1.41.0) (2026-05-18)


### Features

* **pr-grind:** commit-ownership inversion — Phase 2-6 + routing fix ([#111](https://github.com/chris-yyau/busdriver/issues/111)) ([153bb6b](https://github.com/chris-yyau/busdriver/commit/153bb6bfcac23fc1bf2dd38a24c4aee594e5bca2)), closes [#4](https://github.com/chris-yyau/busdriver/issues/4) [#1](https://github.com/chris-yyau/busdriver/issues/1) [#2](https://github.com/chris-yyau/busdriver/issues/2)

## [1.40.2](https://github.com/chris-yyau/busdriver/compare/v1.40.1...v1.40.2) (2026-05-17)


### Bug Fixes

* **pr-grind:** merge-cleanup drift-resistance + branch-currency detection ([#107](https://github.com/chris-yyau/busdriver/issues/107)) ([8fb39e7](https://github.com/chris-yyau/busdriver/commit/8fb39e7963d8b5e2ce8e89c0f25e0d8f1f6a7213)), closes [#102](https://github.com/chris-yyau/busdriver/issues/102) [#98](https://github.com/chris-yyau/busdriver/issues/98) [#102](https://github.com/chris-yyau/busdriver/issues/102) [#103](https://github.com/chris-yyau/busdriver/issues/103)

## [1.40.1](https://github.com/chris-yyau/busdriver/compare/v1.40.0...v1.40.1) (2026-05-17)


### Bug Fixes

* **codex-goal-handover:** allow git writes in sandbox + document litmus bypass ([#106](https://github.com/chris-yyau/busdriver/issues/106)) ([67ae05c](https://github.com/chris-yyau/busdriver/commit/67ae05cca1675b3b256f8eaff1cdd5cc026dc679)), closes [#108](https://github.com/chris-yyau/busdriver/issues/108) [#108](https://github.com/chris-yyau/busdriver/issues/108)

# [1.40.0](https://github.com/chris-yyau/busdriver/compare/v1.39.2...v1.40.0) (2026-05-17)


### Features

* **pr-grind:** Phase 0 helpers + Phase 1 terminal_status docs ([#102](https://github.com/chris-yyau/busdriver/issues/102)) ([8a3f046](https://github.com/chris-yyau/busdriver/commit/8a3f046c21eba4951114cdf637c8a7c54653d0d1))

## [1.39.2](https://github.com/chris-yyau/busdriver/compare/v1.39.1...v1.39.2) (2026-05-17)


### Bug Fixes

* **codex:** require all properties in goal-result schema for OpenAI strict mode ([#103](https://github.com/chris-yyau/busdriver/issues/103)) ([e657742](https://github.com/chris-yyau/busdriver/commit/e657742651e61d0686e7663980dbd45f00a5d3ea))

## [1.39.1](https://github.com/chris-yyau/busdriver/compare/v1.39.0...v1.39.1) (2026-05-13)


### Bug Fixes

* **dispatch-cli:** per-mode droid --auto tiers + DROID_AUTO_LEVEL override ([#97](https://github.com/chris-yyau/busdriver/issues/97)) ([a436445](https://github.com/chris-yyau/busdriver/commit/a436445d5747a81ce0b27b8e377c1d48d25b9959))

# [1.39.0](https://github.com/chris-yyau/busdriver/compare/v1.38.0...v1.39.0) (2026-05-13)


### Features

* **pr-grind:** per-round litmus cap, pre-push commitlint, amend bypass ([#98](https://github.com/chris-yyau/busdriver/issues/98)) ([3efb937](https://github.com/chris-yyau/busdriver/commit/3efb937ad7ec2fe4b23a65a52553ec7b6f311b31)), closes [#94](https://github.com/chris-yyau/busdriver/issues/94) [#96](https://github.com/chris-yyau/busdriver/issues/96) [#94](https://github.com/chris-yyau/busdriver/issues/94) [#96](https://github.com/chris-yyau/busdriver/issues/96) [#96](https://github.com/chris-yyau/busdriver/issues/96)

# [1.38.0](https://github.com/chris-yyau/busdriver/compare/v1.37.0...v1.38.0) (2026-05-12)


### Features

* **codex-goal:** verifier-led codex handover loop ([#99](https://github.com/chris-yyau/busdriver/issues/99)) ([f1bd1c6](https://github.com/chris-yyau/busdriver/commit/f1bd1c6b3a1fbf7fa6600bfdddcd19b0eb102216))

# [1.37.0](https://github.com/chris-yyau/busdriver/compare/v1.36.0...v1.37.0) (2026-05-12)


### Features

* **pr-grind:** approver-gap + Copilot auto-resolve + policy bail + marker-merge race fix ([#94](https://github.com/chris-yyau/busdriver/issues/94)) ([e4f2695](https://github.com/chris-yyau/busdriver/commit/e4f26953d676c657f413fca6bf9e8491d33512e1)), closes [#93](https://github.com/chris-yyau/busdriver/issues/93)

# [1.36.0](https://github.com/chris-yyau/busdriver/compare/v1.35.2...v1.36.0) (2026-05-11)


### Features

* **council:** rename from roundtable, add Researcher voice via droid ([#93](https://github.com/chris-yyau/busdriver/issues/93)) ([68eafc4](https://github.com/chris-yyau/busdriver/commit/68eafc4b0c36b155463ec024d2ef7791451666fc))

## [1.35.2](https://github.com/chris-yyau/busdriver/compare/v1.35.1...v1.35.2) (2026-05-11)


### Bug Fixes

* **pr-grind:** commit-template length split + dogfooded refinements ([#91](https://github.com/chris-yyau/busdriver/issues/91)) ([6a6ad90](https://github.com/chris-yyau/busdriver/commit/6a6ad90061a5568c445d4e029f021439d842a318))

## [1.35.1](https://github.com/chris-yyau/busdriver/compare/v1.35.0...v1.35.1) (2026-05-11)


### Bug Fixes

* **pr-grind:** contract tightening from PR [#89](https://github.com/chris-yyau/busdriver/issues/89) dogfooding ([#90](https://github.com/chris-yyau/busdriver/issues/90)) ([d1f3664](https://github.com/chris-yyau/busdriver/commit/d1f36648c600f5aa975bd36a689bb1ab9efbec09))

# [1.35.0](https://github.com/chris-yyau/busdriver/compare/v1.34.1...v1.35.0) (2026-05-10)


### Features

* **pr-grind:** out-of-scope-acknowledged disposition + invariant 4 ([#89](https://github.com/chris-yyau/busdriver/issues/89)) ([8b06a75](https://github.com/chris-yyau/busdriver/commit/8b06a75975e7aad774cbe152d70cdddfbbe580a1)), closes [jikdak#129-derived](https://github.com/jikdak/issues/129-derived) [#129](https://github.com/chris-yyau/busdriver/issues/129)

## [1.34.1](https://github.com/chris-yyau/busdriver/compare/v1.34.0...v1.34.1) (2026-05-09)


### Bug Fixes

* **pr-grind:** bail on history-rewriting fixes (judgment, not tooling) ([#87](https://github.com/chris-yyau/busdriver/issues/87)) ([cd85287](https://github.com/chris-yyau/busdriver/commit/cd85287c628ae3f0d11b5e87a0b599e73fc18c0d)), closes [#86](https://github.com/chris-yyau/busdriver/issues/86) [#86](https://github.com/chris-yyau/busdriver/issues/86)

# [1.34.0](https://github.com/chris-yyau/busdriver/compare/v1.33.0...v1.34.0) (2026-05-09)


### Features

* **pr-grind:** per-bot ledger + bounded recovery-via-inline ([#86](https://github.com/chris-yyau/busdriver/issues/86)) ([f7cd168](https://github.com/chris-yyau/busdriver/commit/f7cd168c6214fe3434410f197e9ff6b4607c639d)), closes [hi#impact](https://github.com/hi/issues/impact)

# [1.33.0](https://github.com/chris-yyau/busdriver/compare/v1.32.0...v1.33.0) (2026-05-09)


### Features

* **pr-grind:** split --max into --max-fix and --max-wait budgets ([#84](https://github.com/chris-yyau/busdriver/issues/84)) ([612188a](https://github.com/chris-yyau/busdriver/commit/612188a1e8951705effa777f7d2a18c7f739318f)), closes [#80](https://github.com/chris-yyau/busdriver/issues/80)

# [1.32.0](https://github.com/chris-yyau/busdriver/compare/v1.31.0...v1.32.0) (2026-05-08)


### Features

* **pr-grind:** add check-runs ack tier for bots that don't post /reviews ([#83](https://github.com/chris-yyau/busdriver/issues/83)) ([77b37ba](https://github.com/chris-yyau/busdriver/commit/77b37bacfbd51fe77811d90be1a0959d1c4ce75c))

# [1.31.0](https://github.com/chris-yyau/busdriver/compare/v1.30.2...v1.31.0) (2026-05-08)


### Features

* **pr-grind:** file-backed fallback for worker RESULT block ([#82](https://github.com/chris-yyau/busdriver/issues/82)) ([beb72f2](https://github.com/chris-yyau/busdriver/commit/beb72f2d8e45dee4427b154232a60ac5f055ab40)), closes [#80](https://github.com/chris-yyau/busdriver/issues/80)

## [1.30.2](https://github.com/chris-yyau/busdriver/compare/v1.30.1...v1.30.2) (2026-05-08)


### Bug Fixes

* **pr-grind:** auto-fallback to --no-worktree when branch already checked out ([#78](https://github.com/chris-yyau/busdriver/issues/78)) ([298477f](https://github.com/chris-yyau/busdriver/commit/298477f06e50d4a2ab749204d551c53377dbc02c))

## [1.30.1](https://github.com/chris-yyau/busdriver/compare/v1.30.0...v1.30.1) (2026-05-08)


### Bug Fixes

* **pr-grind:** downgrade infra-error/rate-limit reviews to none in ack ledger ([#77](https://github.com/chris-yyau/busdriver/issues/77)) ([52b8685](https://github.com/chris-yyau/busdriver/commit/52b8685892b7ae8f3d26ff1a8300b1249ef29620)), closes [#CLI](https://github.com/chris-yyau/busdriver/issues/CLI)

# [1.30.0](https://github.com/chris-yyau/busdriver/compare/v1.29.3...v1.30.0) (2026-05-08)


### Features

* add Dependabot auto-merge workflow (tier-portable) ([#75](https://github.com/chris-yyau/busdriver/issues/75)) ([1418fea](https://github.com/chris-yyau/busdriver/commit/1418fea11dc6bcd26acee376222cf3ac4152eac7)), closes [chris-yyau/helmet#33](https://github.com/chris-yyau/helmet/issues/33)

## [1.29.3](https://github.com/chris-yyau/busdriver/compare/v1.29.2...v1.29.3) (2026-05-07)


### Bug Fixes

* **security:** close fail-open from set -e suspension in if-condition ([#74](https://github.com/chris-yyau/busdriver/issues/74)) ([1e4dfd9](https://github.com/chris-yyau/busdriver/commit/1e4dfd9366d185830ab86bae260972693c711447)), closes [chris-yyau/helmet#27](https://github.com/chris-yyau/helmet/issues/27) [Dive-And-Dev/growth-engine#45](https://github.com/Dive-And-Dev/growth-engine/issues/45) [Dive-And-Dev/chrisyau.me#105](https://github.com/Dive-And-Dev/chrisyau.me/issues/105) [chris-yyau/helmet#28](https://github.com/chris-yyau/helmet/issues/28) [#27](https://github.com/chris-yyau/busdriver/issues/27)

## [1.29.2](https://github.com/chris-yyau/busdriver/compare/v1.29.1...v1.29.2) (2026-05-06)


### Bug Fixes

* **pr-grind:** add Step 6.5 ack-ledger to inline Opus path ([#71](https://github.com/chris-yyau/busdriver/issues/71)) ([937426b](https://github.com/chris-yyau/busdriver/commit/937426b2294620e8f07dee26204183d8c02d9b21)), closes [#70](https://github.com/chris-yyau/busdriver/issues/70) [#70](https://github.com/chris-yyau/busdriver/issues/70) [#70](https://github.com/chris-yyau/busdriver/issues/70)

## [1.29.1](https://github.com/chris-yyau/busdriver/compare/v1.29.0...v1.29.1) (2026-05-06)


### Bug Fixes

* **pr-grind:** restore reviewer-bot triage + add ack ledger for slow bots ([#70](https://github.com/chris-yyau/busdriver/issues/70)) ([bebaa4b](https://github.com/chris-yyau/busdriver/commit/bebaa4b04d1863caf6c01bbc523dbe1599c489b1)), closes [#65](https://github.com/chris-yyau/busdriver/issues/65) [#44](https://github.com/chris-yyau/busdriver/issues/44)

# [1.29.0](https://github.com/chris-yyau/busdriver/compare/v1.28.2...v1.29.0) (2026-05-06)


### Features

* **skills:** wire grill-me into Phase 1 as optional intensifier ([#68](https://github.com/chris-yyau/busdriver/issues/68)) ([13a5949](https://github.com/chris-yyau/busdriver/commit/13a59497fea63c846b1c372c7cb25fa7119b986c))

## [1.28.2](https://github.com/chris-yyau/busdriver/compare/v1.28.1...v1.28.2) (2026-05-06)


### Bug Fixes

* **blueprint-review:** close shell-into-python heredoc injection in 4 sites ([#67](https://github.com/chris-yyau/busdriver/issues/67)) ([e02da10](https://github.com/chris-yyau/busdriver/commit/e02da10c6592737236777b14eb93915f358b8edc))

## [1.28.1](https://github.com/chris-yyau/busdriver/compare/v1.28.0...v1.28.1) (2026-05-06)


### Bug Fixes

* **blueprint-review:** repair high_issues_history YAML serialization + add regression test ([#66](https://github.com/chris-yyau/busdriver/issues/66)) ([3c4e75a](https://github.com/chris-yyau/busdriver/commit/3c4e75adc0b90291723a7f033a724b374b7fa2fd))

# [1.28.0](https://github.com/chris-yyau/busdriver/compare/v1.27.1...v1.28.0) (2026-05-05)


### Features

* **pr-grind:** Sonnet subagent dispatch + --opus opt-in (~5x cheaper grinds) ([#65](https://github.com/chris-yyau/busdriver/issues/65)) ([22d9966](https://github.com/chris-yyau/busdriver/commit/22d996671abdcaff05d8842db670fb54bf2e536f))

## [1.27.1](https://github.com/chris-yyau/busdriver/compare/v1.27.0...v1.27.1) (2026-05-05)


### Bug Fixes

* **gates:** align hash discipline + cwd resolution across gate scripts ([#64](https://github.com/chris-yyau/busdriver/issues/64)) ([89b0bf0](https://github.com/chris-yyau/busdriver/commit/89b0bf08e776ac7a6731a1d96dcdd7847216475c))

# [1.27.0](https://github.com/chris-yyau/busdriver/compare/v1.26.0...v1.27.0) (2026-05-01)


### Features

* **supplements:** add 4 GSD thinking-models supplements ([#62](https://github.com/chris-yyau/busdriver/issues/62)) ([9454ee2](https://github.com/chris-yyau/busdriver/commit/9454ee26b7ef783b9ffbea2294886f68e9641bf0))

# [1.26.0](https://github.com/chris-yyau/busdriver/compare/v1.25.4...v1.26.0) (2026-04-29)


### Features

* **skills:** import 4 skills from mattpocock/skills ([#56](https://github.com/chris-yyau/busdriver/issues/56)) ([4046757](https://github.com/chris-yyau/busdriver/commit/4046757194774cf968d450e6b5d8af59aee2bf6b))

## [1.25.4](https://github.com/chris-yyau/busdriver/compare/v1.25.3...v1.25.4) (2026-04-29)


### Bug Fixes

* blueprint-review convergence + orchestrator skip-file protocol ([#55](https://github.com/chris-yyau/busdriver/issues/55)) ([7d00e6e](https://github.com/chris-yyau/busdriver/commit/7d00e6e04ed1a623dd5a20c50774aac5c84befcd))

## [1.25.3](https://github.com/chris-yyau/busdriver/compare/v1.25.2...v1.25.3) (2026-04-19)


### Bug Fixes

* **codex:** retry on EAGAIN — concurrent companion session collisions ([#50](https://github.com/chris-yyau/busdriver/issues/50)) ([14d7b96](https://github.com/chris-yyau/busdriver/commit/14d7b9638ef713a09c041b7fc40d4387b60558e8))

## [1.25.2](https://github.com/chris-yyau/busdriver/compare/v1.25.1...v1.25.2) (2026-04-19)


### Bug Fixes

* **codex:** preserve codex error output on non-transient wrapper failure ([#48](https://github.com/chris-yyau/busdriver/issues/48)) ([fd43fa7](https://github.com/chris-yyau/busdriver/commit/fd43fa7d0f187bdcf0027d063219a8328206aefb))

## [1.25.1](https://github.com/chris-yyau/busdriver/compare/v1.25.0...v1.25.1) (2026-04-16)


### Reverts

* "ci: helmet audit fixes — bypass-audit, pinact perms, scorecard shell" ([46eca0b](https://github.com/chris-yyau/busdriver/commit/46eca0ba2fe8da8f228954523c15b40a7dc7eeb0))

# [1.25.0](https://github.com/chris-yyau/busdriver/compare/v1.24.0...v1.25.0) (2026-04-16)


### Features

* litmus short-circuit gate + weighted quorum ([#44](https://github.com/chris-yyau/busdriver/issues/44)) ([570eed5](https://github.com/chris-yyau/busdriver/commit/570eed5b28a49d0546f292fbe3067fd2ed9c9155))

# [1.24.0](https://github.com/chris-yyau/busdriver/compare/v1.23.1...v1.24.0) (2026-04-15)


### Features

* treat CodeScene as advisory (non-blocking) check ([#43](https://github.com/chris-yyau/busdriver/issues/43)) ([d3c5845](https://github.com/chris-yyau/busdriver/commit/d3c58456e31434c5795c7d833bad5574565ab77c))

## [1.23.1](https://github.com/chris-yyau/busdriver/compare/v1.23.0...v1.23.1) (2026-04-15)


### Bug Fixes

* register 10 adopted hooks in hooks.json, fix stale path ([#42](https://github.com/chris-yyau/busdriver/issues/42)) ([6cba362](https://github.com/chris-yyau/busdriver/commit/6cba36297cc4918e8a6970751a1fc6044eba3132))

# [1.23.0](https://github.com/chris-yyau/busdriver/compare/v1.22.0...v1.23.0) (2026-04-15)


### Features

* adopt 11 upstream hooks, update orchestrator routing ([#41](https://github.com/chris-yyau/busdriver/issues/41)) ([c5247d5](https://github.com/chris-yyau/busdriver/commit/c5247d5d3330964dafcf4f0d96d3afa822b8e412))

# [1.22.0](https://github.com/chris-yyau/busdriver/compare/v1.21.0...v1.22.0) (2026-04-15)


### Features

* litmus agents-only PR review when commits pre-reviewed ([#39](https://github.com/chris-yyau/busdriver/issues/39)) ([5a1b96f](https://github.com/chris-yyau/busdriver/commit/5a1b96fd1621f9f7c24f2d59fb30f70ab1e4df43))

# [1.21.0](https://github.com/chris-yyau/busdriver/compare/v1.20.16...v1.21.0) (2026-04-15)


### Features

* pr-grind merges by default, add --no-merge opt-out ([#37](https://github.com/chris-yyau/busdriver/issues/37)) ([f535dc8](https://github.com/chris-yyau/busdriver/commit/f535dc8d33a2ece938de90bbfd5cb8fade6cb54e))

## [1.20.16](https://github.com/chris-yyau/busdriver/compare/v1.20.15...v1.20.16) (2026-04-15)


### Bug Fixes

* improve CI-wait messaging in pre-merge gate and pr-grind ([#36](https://github.com/chris-yyau/busdriver/issues/36)) ([02fe6e7](https://github.com/chris-yyau/busdriver/commit/02fe6e7784315f0cb6c88c4a7bb20769c7e4a61c))

## [1.20.15](https://github.com/chris-yyau/busdriver/compare/v1.20.14...v1.20.15) (2026-04-14)


### Bug Fixes

* resolve gate bootstrap deadlocks in marker writer and pre-merge gate ([#35](https://github.com/chris-yyau/busdriver/issues/35)) ([cbf8c72](https://github.com/chris-yyau/busdriver/commit/cbf8c72b188cb59f7c3ab1e28f6ada7baad33bd6))

## [1.20.14](https://github.com/chris-yyau/busdriver/compare/v1.20.13...v1.20.14) (2026-04-14)


### Bug Fixes

* resolve plugin load failures from async hooks, timeouts, and PATH issues ([#34](https://github.com/chris-yyau/busdriver/issues/34)) ([f9f9d49](https://github.com/chris-yyau/busdriver/commit/f9f9d49a2e3955411498326450f3ae324a14af90))

## [1.20.13](https://github.com/chris-yyau/busdriver/compare/v1.20.12...v1.20.13) (2026-04-14)


### Bug Fixes

* add toctou fallback for design-reviewed bypass in pre-commit gate ([#33](https://github.com/chris-yyau/busdriver/issues/33)) ([49a5bcb](https://github.com/chris-yyau/busdriver/commit/49a5bcb7d71006e68a7a125606414d18ed1ddc98))

## [1.20.12](https://github.com/chris-yyau/busdriver/compare/v1.20.11...v1.20.12) (2026-04-14)


### Bug Fixes

* enforce CI check verification in pre-merge gate ([#32](https://github.com/chris-yyau/busdriver/issues/32)) ([1dad810](https://github.com/chris-yyau/busdriver/commit/1dad810178b4c2924db081ea869bf2bc77d33322))

## [1.20.11](https://github.com/chris-yyau/busdriver/compare/v1.20.10...v1.20.11) (2026-04-14)


### Bug Fixes

* update orchestrator refs for impeccable plugin migration ([#31](https://github.com/chris-yyau/busdriver/issues/31)) ([2e770d9](https://github.com/chris-yyau/busdriver/commit/2e770d91d5e50ea25ec77955056e36cbf13c6b5b))

## [1.20.10](https://github.com/chris-yyau/busdriver/compare/v1.20.9...v1.20.10) (2026-04-13)


### Bug Fixes

* preserve claude.json when spec_hash matches during cleanup ([029f933](https://github.com/chris-yyau/busdriver/commit/029f9332903cfe2dd3b6d096e26692110e0724c8))

## [1.20.9](https://github.com/chris-yyau/busdriver/compare/v1.20.8...v1.20.9) (2026-04-13)


### Bug Fixes

* pr-grind marker write order — write before merge, not after worktree cleanup ([94315da](https://github.com/chris-yyau/busdriver/commit/94315dadd3cf2e3d32893b484394b81f21492f25))

## [1.20.8](https://github.com/chris-yyau/busdriver/compare/v1.20.7...v1.20.8) (2026-04-13)


### Bug Fixes

* enforce pr-grind before merge and fix design review deadlock ([#30](https://github.com/chris-yyau/busdriver/issues/30)) ([1cf022c](https://github.com/chris-yyau/busdriver/commit/1cf022c046d0a9c4b94aac46fb838dbd8783142e))

## [1.20.7](https://github.com/chris-yyau/busdriver/compare/v1.20.6...v1.20.7) (2026-04-13)


### Bug Fixes

* detect unreviewed commits and audit BUILTIN/SKIPPED-NONE acceptance ([#28](https://github.com/chris-yyau/busdriver/issues/28)) ([2db347f](https://github.com/chris-yyau/busdriver/commit/2db347f725f963ebc7e67f770a6685ec46fa5dc2))

## [1.20.6](https://github.com/chris-yyau/busdriver/compare/v1.20.5...v1.20.6) (2026-04-10)


### Bug Fixes

* auto-invoke pr-grind after PR creation, ban premature auto-merge ([#27](https://github.com/chris-yyau/busdriver/issues/27)) ([a72b512](https://github.com/chris-yyau/busdriver/commit/a72b512933abf4e3915e8e1a1f77ef5eee6695fb)), closes [#10](https://github.com/chris-yyau/busdriver/issues/10)

## [1.20.5](https://github.com/chris-yyau/busdriver/compare/v1.20.4...v1.20.5) (2026-04-10)


### Bug Fixes

* rename "self-review" to "sanity check" to prevent blueprint-review skip ([#26](https://github.com/chris-yyau/busdriver/issues/26)) ([2f0b917](https://github.com/chris-yyau/busdriver/commit/2f0b917f40beef01794da152d4c04e1c3520d730))

## [1.20.4](https://github.com/chris-yyau/busdriver/compare/v1.20.3...v1.20.4) (2026-04-10)


### Bug Fixes

* handle exit code 3 (BUILTIN_FALLBACK) in blueprint-review dispatch ([#25](https://github.com/chris-yyau/busdriver/issues/25)) ([e9de7a9](https://github.com/chris-yyau/busdriver/commit/e9de7a962c3b1095677f5174bc02aaecd403b221))

## [1.20.3](https://github.com/chris-yyau/busdriver/compare/v1.20.2...v1.20.3) (2026-04-10)


### Bug Fixes

* use heredoc stdin for dispatch prompts to prevent shell escaping bugs ([#24](https://github.com/chris-yyau/busdriver/issues/24)) ([5584d4b](https://github.com/chris-yyau/busdriver/commit/5584d4b9e1d3054ea8798917d04a6bd98ef18401))

## [1.20.2](https://github.com/chris-yyau/busdriver/compare/v1.20.1...v1.20.2) (2026-04-09)


### Bug Fixes

* capture PIDs in roundtable dispatch to prevent orphaned processes ([#23](https://github.com/chris-yyau/busdriver/issues/23)) ([0176a97](https://github.com/chris-yyau/busdriver/commit/0176a973626f9722492bb24778d81b862b031a85))

## [1.20.1](https://github.com/chris-yyau/busdriver/compare/v1.20.0...v1.20.1) (2026-04-09)


### Bug Fixes

* filter resolved/outdated threads in pr-grind ([#22](https://github.com/chris-yyau/busdriver/issues/22)) ([9775580](https://github.com/chris-yyau/busdriver/commit/9775580438402474e7e7969c68d19840beae1a30))

# [1.20.0](https://github.com/chris-yyau/busdriver/compare/v1.19.3...v1.20.0) (2026-04-09)


### Bug Fixes

* scope RELEASE_TOKEN to release environment ([914969b](https://github.com/chris-yyau/busdriver/commit/914969bdbc81b56e35ccec13913e4f4280dbf69d))
* use RELEASE_TOKEN for semantic-release push and downgrade pinact permissions ([71c74e6](https://github.com/chris-yyau/busdriver/commit/71c74e6ee3060eda885fda5dffee6c91fc1949cc))


### Features

* wire automatic version sync into release pipeline ([72de6f7](https://github.com/chris-yyau/busdriver/commit/72de6f70a9c7f98c52d2e49ff7542d61f5521df9))
