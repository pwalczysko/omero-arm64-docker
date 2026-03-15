# OMERO ARM64 Docker

ARM64-native Docker images and stack for [OMERO](https://www.openmicroscopy.org/omero/) on Apple Silicon (M1/M2/M3/M4) and other aarch64 hosts.

Official OMERO images are x86_64-only. This project builds native `linux/arm64` images by:
- compiling ZeroC Ice 3.6.5 from source (no pre-built aarch64 tarball exists)
- patching upstream OME Ansible roles for aarch64
- consolidating `dnf` layers for minimal image size

Pre-built images are published to GHCR: `ghcr.io/simonhard/omero-server-arm64` and `ghcr.io/simonhard/omero-web-arm64`.

## Architecture

Four containers orchestrated via Docker Compose:

```
nginx (:8094 / :8443)
  └── omero-web (:4080)
        └── omero-server (:4063/:4064)
              └── postgres (:5432)
```

## Quick start (pre-built images)

Requires: Docker Desktop (arm64 mode), ~5 GB disk.

```bash
git clone https://github.com/simonhard/omero-arm64-docker.git
cd omero-arm64-docker

cp .env.example .env
# Edit .env: set OMERO_DB_PASS and OMERO_ROOT_PASS

docker compose up -d
```

OMERO.web: **http://localhost:8094**

First startup takes a few minutes while OMERO initialises the database.

## Build images locally

Requires additionally: Python 3, Git, ~20 GB disk, ~20–40 min.

```bash
# Build both images (linux/arm64 by default)
python3 build.py

# Options
python3 build.py --omero-version 5.6.17
python3 build.py --platform linux/amd64
python3 build.py --server-only
python3 build.py --help
```

After building, use the locally tagged images by adding to `.env`:

```
OMERO_SERVER_IMAGE=ghcr.io/simonhard/omero-server-arm64:latest
OMERO_WEB_IMAGE=ghcr.io/simonhard/omero-web-arm64:latest
```

## Optional TLS

Uncomment the HTTPS server block in `nginx.conf`, place your certificates in `./certs/`, and add the volume mount to the nginx service in `docker-compose.yml`:

```yaml
volumes:
  - ./nginx.conf:/etc/nginx/nginx.conf:ro
  - ./certs:/etc/nginx/certs:ro
```

## Key files

| File | Purpose |
|------|---------|
| `build.py` | Clone upstream repos, build ARM64 images |
| `dockerfiles/omero-server.Dockerfile` | Two-stage build: Ice from source + OMERO.server |
| `dockerfiles/omero-web.Dockerfile` | OMERO.web with WhiteNoise static files |
| `docker-compose.yml` | Stack orchestration |
| `nginx.conf` | Reverse proxy (10G upload, 600s timeout) |
| `.env.example` | Credentials template |

## Releasing a new version

Push a version tag to trigger the release workflow and push new images to GHCR:

```bash
git tag v1.0.0
git push origin v1.0.0
```

## License

This project (scripts, Dockerfiles, configuration) is licensed under **Apache-2.0**.

The Docker images built from this project incorporate third-party software under different licenses (GPL-2.0 for OMERO and ZeroC Ice, BSD-2-Clause for upstream Docker wrappers). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for details.

## Acknowledgements

- [Open Microscopy Environment](https://www.openmicroscopy.org/) for OMERO and the upstream Docker repos
- [ZeroC](https://zeroc.com/) for Ice 3.6.5
