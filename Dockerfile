# This is a "multi-stage build" - two separate, named build stages (`build` and the
# unnamed final one below) in one file. Only the LAST stage becomes the actual image you
# run; everything from earlier stages is discarded unless explicitly copied forward with
# `COPY --from=`. The point: the build stage needs a full JDK + Maven + your source code to
# compile the jar, but none of that (JDK's compiler, Maven itself, .java source files) is
# needed to actually RUN the already-built jar - so the final image only carries the jar
# itself on top of a much smaller JRE-only base, not a full JDK.

# ---- Build stage ----
FROM eclipse-temurin:21-jdk AS build
WORKDIR /app

# Deliberately copying just the Maven wrapper + pom.xml first, and running dependency
# download as its own step, BEFORE copying the actual source code below. Docker caches each
# instruction as a "layer" and reuses cached layers if the inputs haven't changed - so as
# long as pom.xml is unchanged, this dependency-download step (the slow part) gets skipped
# entirely on rebuilds, even if you've edited every .java file. Reordering these two COPY
# steps would defeat that caching.
COPY .mvn/ .mvn/
COPY mvnw pom.xml ./
RUN chmod +x mvnw && ./mvnw dependency:go-offline

COPY src ./src
RUN ./mvnw package -DskipTests

# ---- Runtime stage ----
# A fresh, minimal image - none of the `build` stage's layers (JDK compiler, downloaded
# Maven plugins, source code) carry over from here on. This is what actually ships/runs.
FROM eclipse-temurin:21-jre
WORKDIR /app

# Reach back into the `build` stage (by name) and grab only the one file this stage
# actually needs: the already-compiled, already-packaged jar.
COPY --from=build /app/target/url-shortener-*.jar app.jar

# Documentation only - EXPOSE doesn't actually publish the port to the host. That's what
# `-p 8080:8080` on `docker run`, or the `ports:` key in docker-compose.yml, actually does.
EXPOSE 8080
# The command that runs when a container starts from this image - identical to what you'd
# type by hand to run the jar locally, just baked into the image itself.
ENTRYPOINT ["java", "-jar", "app.jar"]
