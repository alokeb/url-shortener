package com.alokeb.urlshortener.repository;

import com.alokeb.urlshortener.model.UrlMapping;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;

// This is just an interface - there's no class anywhere implementing it, and that's the
// whole point. Extending JpaRepository<UrlMapping, Long> (entity type, primary key type)
// already gives you save(), findById(), findAll(), delete(), count(), etc. for free.
//
// The three methods below are "derived queries": Spring Data JPA parses the METHOD NAME
// itself at startup and generates the SQL from it - findByShortCode() becomes
// `SELECT * FROM url_mapping WHERE short_code = ?`, existsByShortCode() becomes an
// `EXISTS` check, and so on. No SQL, no @Query annotation, no implementation to write.
// At runtime Spring creates a dynamic proxy object that actually does the work - this
// interface itself is compiled but never "run" in the normal sense.
public interface UrlMappingRepository extends JpaRepository<UrlMapping, Long> {

    Optional<UrlMapping> findByShortCode(String shortCode);

    Optional<UrlMapping> findByOriginalUrl(String originalUrl);

    boolean existsByShortCode(String shortCode);
}
