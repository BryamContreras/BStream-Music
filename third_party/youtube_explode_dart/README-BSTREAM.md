# BStream Fork

This directory contains BStream's vendored fork of `youtube_explode_dart`
3.1.0. The upstream package remains licensed under the BSD 3-Clause license;
see `LICENSE` for the original notice.

Keep package-specific changes inside this directory. BStream application code
uses adapters under `lib/services/downloader/adapters/youtube_explode/` and
must not depend on the fork's internal implementation.

The fork is intentionally kept under the upstream package name so its public
API remains compatible with upstream updates while BStream can patch and test
the exact version it ships.
