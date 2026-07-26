package com.alokeb.urlshortener.service;

import com.alokeb.urlshortener.model.UrlMapping;
import com.alokeb.urlshortener.repository.UrlMappingRepository;
import org.springframework.cache.annotation.Cacheable;
import org.springframework.stereotype.Service;

import java.net.URI;
import java.net.URISyntaxException;
import java.security.SecureRandom;
import java.util.Locale;
import java.util.Optional;

// @Service marks this as a Spring-managed bean holding business logic (as opposed to
// @Repository for data access or @Controller for HTTP handling - functionally near-identical
// annotations, but the different names document each class's role and let Spring apply
// role-specific behavior, e.g. @Repository auto-translates database exceptions).
// Component-scanning (see @SpringBootApplication) finds this automatically at startup.
@Service
public class UrlShortenerService {

    private static final String ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    private static final int CODE_LENGTH = 7;
    private static final SecureRandom RANDOM = new SecureRandom();

    private final UrlMappingRepository repository;

    // Constructor injection: Spring sees this class needs a UrlMappingRepository and, since
    // that interface is itself a Spring-managed bean (see UrlMappingRepository.java),
    // automatically passes one in when it creates this service - nothing here has to go
    // looking for it. No @Autowired needed on a single constructor; that's implicit in
    // modern Spring Boot. This is "dependency injection": this class declares what it
    // needs and lets the framework supply it, rather than constructing it itself
    // (e.g. `new UrlMappingRepository()`, which wouldn't even be possible here - it's an
    // interface with no manual implementation, see the repository class for why).
    public UrlShortenerService(UrlMappingRepository repository) {
        this.repository = repository;
    }

    public UrlMapping shorten(String originalUrl) {
        String normalizedUrl = normalize(originalUrl);

        return repository.findByOriginalUrl(normalizedUrl)
                .orElseGet(() -> {
                    String code;
                    do {
                        code = generateCode();
                    } while (repository.existsByShortCode(code));

                    return repository.save(new UrlMapping(code, normalizedUrl));
                });
    }

    /**
     * Lowercases the host (case-insensitive per URL spec) and collapses redundant path
     * segments via URI.normalize() (e.g. "/a/../b" -> "/b"). Deliberately leaves trailing
     * slashes alone - whether "example.com" and "example.com/" are "the same" is a policy
     * call, not something either JDK or this app decides. Falls back to the raw string if
     * it isn't a parseable URI.
     */
    private static String normalize(String rawUrl) {
        try {
            URI uri = new URI(rawUrl).normalize();
            String host = uri.getHost();
            if (host == null) {
                return uri.toString();
            }

            String lowerHost = host.toLowerCase(Locale.ROOT);
            return new URI(uri.getScheme(), uri.getUserInfo(), lowerHost, uri.getPort(),
                    uri.getPath(), uri.getQuery(), uri.getFragment()).toString();
        } catch (URISyntaxException e) {
            return rawUrl;
        }
    }

    // @Cacheable wraps this method with caching behavior at call time, entirely outside the
    // method body: Spring generates a proxy around this bean, and every call to resolve()
    // actually goes through that proxy first. It checks the cache named "shortUrls" (backed
    // by Redis here - see application.properties' spring.data.redis.* settings) for a key
    // matching the shortCode argument; on a hit, the method body below never even runs and
    // the cached value is returned directly. On a miss, the method runs normally and its
    // return value gets stored in the cache for next time. sync=true makes concurrent misses
    // for the SAME key wait for the first one instead of all racing to hit the database (see
    // UrlShortenerServiceStressTest for exactly how strong that guarantee is in practice
    // with a Redis-backed cache vs. a plain in-memory one).
    @Cacheable(value = "shortUrls", sync = true)
    public Optional<UrlMapping> resolve(String shortCode) {
        return repository.findByShortCode(shortCode);
    }

    private String generateCode() {
        StringBuilder sb = new StringBuilder(CODE_LENGTH);
        for (int i = 0; i < CODE_LENGTH; i++) {
            sb.append(ALPHABET.charAt(RANDOM.nextInt(ALPHABET.length())));
        }
        return sb.toString();
    }
}
