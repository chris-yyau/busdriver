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
