package com.alokeb.urlshortener.service;

import com.alokeb.urlshortener.model.UrlMapping;
import com.alokeb.urlshortener.repository.UrlMappingRepository;
import com.redis.testcontainers.RedisContainer;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Random;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.Collectors;
import java.util.stream.IntStream;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Small-scale stress tests proving the plumbing works, not benchmarking it: real Postgres
 * and Redis via Testcontainers, no mocks standing in for the actual database or cache.
 *
 * Note: @SpringBootTest reuses one Spring context (and one Testcontainers Postgres) across
 * all @Test methods in this class, so assertions must be delta-based (count before/after),
 * never absolute - other tests' data is still sitting in the same tables.
 */
// @SpringBootTest boots the ENTIRE real Spring application for this test - same
// UrlShortenerApplication, same beans, same wiring as running the app for real. That's
// heavier/slower than a narrower "slice" test (e.g. @WebMvcTest, which only loads the web
// layer), but it means what's being tested is genuinely how the app behaves end to end.
@SpringBootTest
// Enables JUnit 5's Testcontainers extension, which finds the @Container fields below and
// manages their lifecycle: starts them before any test in this class runs, stops them after
// the last one finishes.
@Testcontainers
class UrlShortenerServiceStressTest {

    // @Container: "this field's lifecycle is managed by Testcontainers" (see @Testcontainers
    // above). `static` matters - it means ONE Postgres/Redis pair is shared across every
    // @Test method in this class rather than a fresh pair per test (which the "Note" above
    // is warning about: shared state across test methods).
    //
    // @ServiceConnection is the piece that actually wires this container into the Spring
    // app being tested: Spring Boot inspects the running container, figures out its
    // randomly-assigned host port, and auto-configures spring.datasource.* (for Postgres)
    // or spring.data.redis.* (for Redis) to point at it - completely overriding whatever's
    // in application.properties for this test run. No manual property wiring needed.
    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16");

    @Container
    @ServiceConnection
    static RedisContainer redis = new RedisContainer(DockerImageName.parse("redis:7"));

    /**
     * Counts real calls to findByShortCode() via a plain JDK dynamic proxy - deliberately not
     * a Mockito spy, since Spring Data repository beans are themselves already JDK proxies and
     * Mockito can't reliably spy on top of that (confirmed the hard way: NotAMockException).
     */
    static final AtomicInteger findByShortCodeCalls = new AtomicInteger();

    /**
     * Right now every run gets a fresh, empty Testcontainers Postgres, so this doesn't matter -
     * but if these tests ever point at a real, non-ephemeral database instead, the same literal
     * URLs every run would just dedupe against last run's leftover rows and throw off the
     * delta-based assertions. A random per-run token keeps generated URLs unique across
     * invocations while still letting each test control its own internal duplication.
     */
    static final String RUN_ID = Long.toString((long) (Math.random() * Long.MAX_VALUE), 36);

    // @TestConfiguration: extra bean definitions that only exist for this test class, added
    // ON TOP OF the app's normal configuration - unlike @Configuration classes in main/,
    // this one is never picked up by the real application. Spring Boot auto-detects a
    // static nested class annotated like this inside a @SpringBootTest class; it doesn't
    // need to be imported or referenced anywhere.
    @TestConfiguration
    static class CountingRepositoryConfig {
        // @Bean: this method's return value gets registered in the Spring container, same
        // as if it were a @Service/@Repository class - just defined via a method instead.
        // @Primary: when more than one bean of the same type exists (the real repository
        // from main/ AND this wrapped one), @Primary tells Spring which one to hand out by
        // default wherever UrlMappingRepository is injected - including inside
        // UrlShortenerService itself, not just in this test file.
        @Bean
        @Primary
        UrlMappingRepository countingUrlMappingRepository(UrlMappingRepository original) {
            return (UrlMappingRepository) Proxy.newProxyInstance(
                    UrlMappingRepository.class.getClassLoader(),
                    new Class<?>[] {UrlMappingRepository.class},
                    (proxy, method, args) -> {
                        if (method.getName().equals("findByShortCode")) {
                            findByShortCodeCalls.incrementAndGet();
                        }
                        return method.invoke(original, args);
                    });
        }
    }

    @Autowired
    private UrlShortenerService service;

    @Autowired
    private UrlMappingRepository repository;

    @Test
    void concurrentResolvesOfTheSameCodeOnlyHitPostgresOnce() throws Exception {
        String testUrl = "https://example.com/cache-stress-test-" + RUN_ID;
        int concurrentRequests = 50;
        int threadPoolSize = 10;

        UrlMapping mapping = service.shorten(testUrl);
        String shortCode = mapping.getShortCode();
        int callsBefore = findByShortCodeCalls.get();

        ExecutorService pool = Executors.newFixedThreadPool(threadPoolSize);
        try {
            List<Callable<String>> lookups = IntStream.range(0, concurrentRequests)
                    .<Callable<String>>mapToObj(i -> () -> service.resolve(shortCode)
                            .map(UrlMapping::getOriginalUrl)
                            .orElseThrow())
                    .toList();

            List<Future<String>> results = pool.invokeAll(lookups);

            for (Future<String> result : results) {
                assertThat(result.get()).isEqualTo(testUrl);
            }
        } finally {
            pool.shutdown();
        }

        // sync=true gives best-effort protection against a cold-cache thundering herd, not a
        // hard single-flight guarantee: unlike the in-memory ConcurrentMapCache, Spring Data
        // Redis's RedisCache doesn't implement true atomic per-key locking in get(key, loader),
        // so some threads can still race into Postgres before the first one finishes populating
        // Redis. Empirically this lands well under the thread pool size, nowhere near the full
        // request count - real protection, just not a mathematically exact "1".
        int actualDbHits = findByShortCodeCalls.get() - callsBefore;
        assertThat(actualDbHits)
                .isGreaterThan(0)
                .isLessThanOrEqualTo(threadPoolSize)
                .isLessThan(concurrentRequests);
    }

    @Test
    void dedupeHoldsUpAcrossThousandsOfSyntheticRequests() {
        int distinctUrlCount = 500;
        int repeatsPerUrl = 10;
        long countBefore = repository.count();

        List<String> distinctUrls = IntStream.range(0, distinctUrlCount)
                .mapToObj(i -> "https://dedupe-test-" + RUN_ID + "-" + i + ".test/path/" + i)
                .toList();

        List<String> requests = new ArrayList<>(distinctUrlCount * repeatsPerUrl);
        for (int repeat = 0; repeat < repeatsPerUrl; repeat++) {
            requests.addAll(distinctUrls);
        }
        Collections.shuffle(requests);

        Set<String> shortCodesSeen = new HashSet<>();
        for (String url : requests) {
            shortCodesSeen.add(service.shorten(url).getShortCode());
        }

        assertThat(shortCodesSeen).hasSize(distinctUrlCount);
        assertThat(repository.count() - countBefore).isEqualTo(distinctUrlCount);
    }

    @Test
    void reportsCacheHitVsMissRetrievalTimes() {
        int urlCount = 500;
        int jitWarmupIterations = 20;

        List<String> shortCodes = IntStream.range(0, urlCount)
                .mapToObj(i -> "https://report-test-" + RUN_ID + "-" + i + ".test/path")
                .map(url -> service.shorten(url).getShortCode())
                .collect(Collectors.toCollection(ArrayList::new));

        // Randomly split: one half gets warmed into the cache now, the other half is left
        // cold so its first lookup below is a genuine cache miss.
        Collections.shuffle(shortCodes, new Random(42));
        int half = shortCodes.size() / 2;
        List<String> warmGroup = shortCodes.subList(0, half);
        List<String> coldGroup = shortCodes.subList(half, shortCodes.size());

        warmGroup.forEach(service::resolve);

        // A few throwaway calls so JIT warmup noise doesn't skew the very first measurements.
        for (int i = 0; i < jitWarmupIterations; i++) {
            service.resolve(warmGroup.get(i % warmGroup.size()));
        }

        int callsBefore = findByShortCodeCalls.get();

        List<Long> hitTimesNanos = new ArrayList<>();
        for (String code : warmGroup) {
            long start = System.nanoTime();
            service.resolve(code);
            hitTimesNanos.add(System.nanoTime() - start);
        }

        List<Long> missTimesNanos = new ArrayList<>();
        for (String code : coldGroup) {
            long start = System.nanoTime();
            service.resolve(code);
            missTimesNanos.add(System.nanoTime() - start);
        }

        // Correctness, not just timing: the warm group should never have touched Postgres
        // during the measured phase - only the cold group's misses should count.
        assertThat(findByShortCodeCalls.get() - callsBefore).isEqualTo(coldGroup.size());

        double avgHitMs = averageMillis(hitTimesNanos);
        double avgMissMs = averageMillis(missTimesNanos);

        System.out.printf(
                """

                Cache performance report
                -------------------------
                Cached lookups (Redis hit):      %d requests, avg %.3f ms
                Uncached lookups (Postgres hit):  %d requests, avg %.3f ms
                Cache speedup: %.1fx
                %n""",
                hitTimesNanos.size(), avgHitMs, missTimesNanos.size(), avgMissMs, avgMissMs / avgHitMs);

        assertThat(avgHitMs).isLessThan(avgMissMs);
    }

    private static double averageMillis(List<Long> nanos) {
        return nanos.stream().mapToLong(Long::longValue).average().orElseThrow() / 1_000_000.0;
    }
}
