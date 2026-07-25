# Third-party software in the published images

The Canvas Suite's own source is released under [the Unlicense](LICENSE) - public
domain, no conditions. **That covers the code, not the container images.**

A container image is a compilation. When you run `build-images.sh`, or pull an
image published from this repo, you receive an operating-system userland, a
JavaScript runtime and a set of npm packages alongside our code, each under its
own licence. Those licences are not replaced by ours and were never ours to
replace. This file exists so anyone redistributing or auditing an image can see
what is actually inside it.

None of this affects using the apps. It matters if you redistribute the images,
ship them inside a product, or have to answer a licence-compliance question.

## What is in an image

| Component | Licence | Where it comes from |
|---|---|---|
| Canvas Suite application code | Unlicense (public domain) | this project |
| Alpine Linux userland (musl libc, and friends) | MIT | `node:22-alpine` base image |
| **BusyBox** | **GPL-2.0** | Alpine base |
| **apk-tools** | **GPL-2.0** | Alpine base |
| Node.js | MIT | `node:22-alpine` base image |
| OpenSSL 3 (bundled in Node) | Apache-2.0 | Node.js |
| V8, libuv, zlib, c-ares, llhttp (bundled in Node) | BSD-3-Clause / MIT / ISC | Node.js |
| ICU (bundled in Node) | Unicode-DFS-2016 | Node.js |
| `better-sqlite3` | MIT | npm |
| SQLite (amalgamation, inside better-sqlite3) | Public domain | npm |
| `net-snmp` | MIT | npm |
| remaining npm dependencies | MIT / ISC / BSD | npm |

Generate the authoritative list for a specific image rather than trusting this
table, which is a summary written by hand and can drift:

```sh
docker buildx build --sbom=true --provenance=true -t snmpcanvas:local .
# or against an image you already have:
docker sbom snmpcanvas:local          # Docker Desktop
syft snmpcanvas:local                 # anywhere
```

Images built by `build-images.sh` carry an SBOM and provenance attestation when
pushed to a registry, which is a machine-readable answer to "what is in this".

## Notices

The MIT, BSD, ISC and Apache-2.0 components require their copyright notices and
licence text to travel with the binaries. They do: those files are inside the
image, unmodified, at their usual locations - `/usr/share/licenses/`,
`/usr/local/share/doc/node/LICENSE`, and each package's own `LICENSE` under
`/app/node_modules/`. Nothing here strips them, and neither should anything
downstream.

## Source for the GPL-2.0 components

BusyBox and apk-tools are GPL-2.0. They are included **unmodified** from the
official `node:22-alpine` image, which derives from Alpine Linux. Their complete
corresponding source is published by Alpine at
<https://gitlab.alpinelinux.org/alpine/aports> and mirrored at
<https://dl-cdn.alpinelinux.org/alpine/>; the exact versions in any image are
listed by `apk list --installed` inside it, or in the SBOM above.

For any image published from this repository, and for three years from the date
it was published, the maintainers will on request provide the complete
corresponding source for the GPL-2.0 components in that image, on a physical
medium or by download, for no more than the cost of distribution. Open an issue
on this repository to request it.

## If you would rather not rely on any of this

Build from source. Every app's `docker-compose.yml` still supports `build: .`,
which pulls its own base image and dependencies at build time - you are then the
one making the compilation, and there is nobody to redistribute anything to.
That is also the way to get the freshest base layers: a published image is only
as current as its last rebuild.
