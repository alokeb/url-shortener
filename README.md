# url-shortener

A URL shortening service, built to learn Spring Boot — and just as much to learn how to work effectively with an AI coding agent ("vibe coding") on a real, evolving project rather than a toy prompt. Given a long URL, it generates a short code (or reuses the one it already gave that URL — shortened URLs are permalinks) and redirects to the original URL when that code is visited.

## Stack

- Java 21
- Spring Boot 4.1.0 (Web MVC, Spring Data JPA, Validation, Cache)
- PostgreSQL — persistent storage, the source of truth
- Redis — caches short-code lookups so repeated redirects don't hit Postgres every time
- Docker / Docker Compose — build, run, and orchestrate all of the above
- Testcontainers — spins up real, throwaway Postgres/Redis containers for the test suite

## Project layout

```
src/main/java/com/alokeb/urlshortener/
├── UrlShortenerApplication.java   # entry point, @EnableCaching
├── model/UrlMapping.java          # JPA entity: id, shortCode, originalUrl, createdAt
├── repository/UrlMappingRepository.java  # Spring Data derived queries
├── service/UrlShortenerService.java      # dedupe + host-case normalization on shorten(),
│                                          # Redis-backed @Cacheable on resolve()
└── web/
    ├── UrlShortenerController.java   # REST endpoints
    ├── ShortenRequest.java           # POST request body
    └── ShortenResponse.java          # POST response body

src/main/resources/
├── application.properties   # env-var-driven Postgres/Redis config, no baked-in secrets
└── static/tester.html       # simple browser form to shorten/test URLs

src/test/java/com/alokeb/urlshortener/
├── UrlShortenerApplicationTests.java      # plain context-load smoke test
└── service/UrlShortenerServiceStressTest.java  # see Testing below

Dockerfile          # multi-stage build (Maven -> slim JRE runtime)
docker-compose.yml  # app + postgres + redis, wired together with a public/internal
                     # network split - only `app` is meant to be reachable externally
.env.example         # copy to .env and fill in real values (.env is git-ignored)
requests.http         # REST Client (VS Code) requests for shorten + redirect
test-requests.sh       # zero-dependency curl script exercising the same flow
```

## Running

No local JDK/Maven needed — everything runs through Docker.

```bash
cp .env.example .env   # first time only; edit in a real password
docker compose up -d --build
```

This builds the app image and starts three containers: `app` (port `8080`, the only one meant to be publicly reachable), `postgres` (named volume, so data survives restarts/recreation), and `redis`. Postgres and Redis also each publish to `127.0.0.1` only (not `0.0.0.0`) — reachable from local tooling on this machine (a database-browsing VS Code extension, `psql`, `redis-cli`), never from another machine on the network.

To stop everything: `docker compose down` (add `-v` only if you actually want to wipe the Postgres volume too).

If you change a service's config without touching its image (e.g. after removing a `docker-compose.yml` setting), a plain `docker compose up -d` may only *restart* affected containers rather than recreate them — which can leave stale network state behind. If something's misbehaving after a compose-file edit and a restart doesn't fix it, try `docker compose up -d --force-recreate`.

## API

### Shorten a URL

```bash
curl -X POST http://localhost:8080/api/urls \
  -H "Content-Type: application/json" \
  -d '{"url": "https://example.com/some/very/long/path"}'
```

Response:

```json
{"shortCode": "7Sgvani", "shortUrl": "http://localhost:8080/7Sgvani"}
```

`url` must start with `http://` or `https://`. Shortening the same URL again returns the *same* short code instead of minting a new one — matching is exact except the host is treated case-insensitively (`Example.com` and `example.com` dedupe to the same code; the path does not, since paths are case-sensitive by spec).

### Follow a short code

```bash
curl -i http://localhost:8080/7Sgvani
```

Returns a `302` redirect to the original URL (or `404` if the code doesn't exist).

### Browser tester

With the stack running, open `http://localhost:8080/tester.html` for a simple form to shorten URLs and click through the results. It has to be loaded through the running app at that URL (not opened as a local file) — its JavaScript calls the API using a relative path, which only resolves correctly when served by the app itself.

### Other ways to poke at the API

- `requests.http` — open in VS Code with the [REST Client](https://marketplace.visualstudio.com/items?itemName=humao.rest-client) extension installed; click "Send Request" above each block.
- `./test-requests.sh [base-url]` — plain curl, no extension needed.

## Testing

There's no fast local Maven test loop — see `CLAUDE.md` for why. All iteration goes through Docker.

**`UrlShortenerServiceStressTest`** is the real test suite: three small-scale stress tests against genuine Postgres/Redis via Testcontainers (not mocks) proving the cache actually shields the database under concurrent load, dedupe holds up across thousands of synthetic requests, and printing an actual cache-hit-vs-miss latency report. Needs a Docker daemon reachable from wherever it runs (Testcontainers spins up its own throwaway containers). To run it:

```bash
docker run --rm \
  -v "$(pwd)":/app \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -w /app \
  -e TESTCONTAINERS_RYUK_DISABLED=true \
  maven:3.9-eclipse-temurin-21 \
  mvn test -Dtest=UrlShortenerServiceStressTest
```

(`TESTCONTAINERS_RYUK_DISABLED` sidesteps some sibling-container complexity when Testcontainers itself is running inside a container via the mounted Docker socket; the containers it spins up still get cleaned up via a JVM shutdown hook either way.)

**`UrlShortenerApplicationTests`** is the original bare context-load smoke test generated by Spring Initializr. It needs a live Postgres/Redis to pass and currently has no Testcontainers setup of its own, so it isn't run as part of any normal workflow here — `mvn test` with no `-Dtest` filter would try to run it too and fail without one.

## Roadmap

- Deploy to Kubernetes as an auto-scalable cluster
