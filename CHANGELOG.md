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
