# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-10-27

### Added

- Initial release.
- Test Kitchen `incus` driver: create, start, wait, delete, and live status.
- Test Kitchen `incus` transport: `incus exec`, tar-stream uploads with `incus file push` fallback, `incus file pull` downloads, and `kitchen login`.
- Bundled `incus` InSpec train backend for the `inspec` verifier.
- Cinc-by-default provisioning via `kitchen-cinc`.

[0.1.0]: https://github.com/aae42/kitchen-incus/releases/tag/v0.1.0
