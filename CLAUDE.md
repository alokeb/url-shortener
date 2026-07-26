# Project Context

## Environment
- Host OS: Debian (desktop)
- Editor: VS Code (native install, not Flatpak)
- Docker is installed directly on the Debian host (rootless, confirmed working) — all builds/tests/runs go through it
- Debian host also has JDK 21 installed, but only for VS Code's Java language server (IntelliSense) — not used for actual builds
- No local Maven install on the host — builds happen via `docker build`, which runs the full Maven build inside the image each time
- Docker Compose (the `docker compose` plugin, v5.3.1) is available on the host for running the app alongside its backing services (PostgreSQL, Redis) locally
- All code lives permanently on the Debian filesystem under ~/mycode

## Developer background
- Experienced with Java and Maven (returning after ~10 years away)
- New to: VS Code, Docker, Kubernetes
- Prefers being walked through concepts, not just given commands

## Project goal
Building a Spring Boot URL shortener, to be:
1. Developed and built/tested via Docker directly on the Debian host
2. Backed by PostgreSQL for persistent storage — shortened URLs need to survive restarts and act as permalinks, and once there are multiple app replicas (see Kubernetes goal below) they all need one shared source of truth, which an in-memory/embedded database can't provide
3. Fronted by a Redis cache for hot short-code lookups, so repeated redirects don't have to hit Postgres every time — like Postgres, Redis is external and shared across all app replicas, unlike an in-process cache which would go stale/inconsistent between pods
4. Re-shortening a URL that's already been shortened should reuse and return its existing short code (a true permalink) rather than minting a duplicate
5. Eventually run as multiple Docker containers in an auto-scalable Kubernetes cluster

## Working agreement
- Build/run everything via Docker (`docker build`, `docker run`, `docker compose`) directly on the Debian host — there is no separate fast local Maven loop right now. This is a known, accepted tradeoff: slower iteration in exchange for one less environment to fight with. Revisit if the slowness becomes a real blocker.
- Explain Docker/Kubernetes concepts as they come up, since this is new territory
