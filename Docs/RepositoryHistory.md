# Beta repository scope and preserved milestones

This repository contains the Flora Mail macOS application. The separate
**Flora Lab - Beta** workspace owns the portfolio website. An older or reference
Flora Mail / Flora Lab directory is not a source or resource dependency of this
application.

## First GitHub baseline

The existing annotated `v0.1.0` tag points to the repository's only root commit,
`1493956355aaba2f9008feb20a2bbbc7d7ccb2e4`:
**Establish Flora Mail prototype baseline before live account validation**.
That snapshot declares application version 0.1.0, build 1, and already contains
Demo Mail, Local AI, and the read-only account prototype. The same tag and target
exist on GitHub. It represents the first versioned GitHub baseline; no replacement
tag is needed. Git does not record the exact time of the first push or prove the
provenance of files before the initial commit.

Preserved tag identities:

| Tag | Annotated tag object | Target commit |
| --- | --- | --- |
| `v0.1.0` | `199965aa357df2d9c9bc4401db2c2239b0cdbc35` | `1493956355aaba2f9008feb20a2bbbc7d7ccb2e4` |
| `v0.2.0` | `bd4c48a671641a0d36984f553b9e2d6f885be9c0` | `ae3054d8912f74885f84473d059719f592238a0a` |

These published milestones are unchanged. Current resource and cleanup changes
remain development commits after the v0.2.0 preview.

## Website separation

The website commits `55031ed`, `c9e6009`, `c780406`, `4209f9f`, and `51e5201`
changed only the misplaced `portfolio/` tree. Application source, tests, and
package configuration remained unchanged. The last application-only milestone
before those commits was `ae3054d`; its later legitimate icon integration
`6189fdb` is retained rather than rolling the application back.

Before removal, all 33 tracked website files were verified byte-for-byte against
the independent Flora Lab - Beta repository's committed baseline
`aebe78591fb5c71e5b48b591129b99026dc82832`. The complete original directory,
including ignored dependencies, screenshots and reports, was additionally saved
under that workspace's ignored `.migration-from-mail-beta/` directory. Its
`manifest.json` records file hashes, directory modes, symlinks and archive hash.
The destination site's existing files and Git history were not overwritten.

`rescue/mail-beta-before-portfolio-separation-20260915` preserves the complete
Mail repository at `6189fdbf021e279b50e6026f52bb60f7a36147f9`. Historical website
commits remain reachable; only the current application working tree is cleaned.

## Native source and icon provenance

Inspection of the available native Git history found no tracked symlinks,
external local-package dependencies, or source/resource references into older
non-Beta projects. Stable bundle, Keychain and application-support identifiers
are retained so existing user data remains associated with the application.
No native source rollback or restoration from a reference copy was necessary.

The active icon is the unchanged Main ICNS from the supplied
`Flora-Mail-macOS-Icons.zip`, integrated in `6189fdb`. See
[the resource provenance](../Resources/README.md) for its exact source and hashes.
No website favicon or older workspace icon is used. Both build configurations
and release packaging resolve the icon entirely inside this repository.
