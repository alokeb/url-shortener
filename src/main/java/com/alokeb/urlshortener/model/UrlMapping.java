package com.alokeb.urlshortener.model;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Index;
import jakarta.persistence.Table;

import java.io.Serializable;
import java.time.Instant;

// @Entity marks this as a JPA-managed class: Hibernate (the JPA implementation Spring Boot
// wires up automatically) treats one instance of this class as one row in a database table.
// The mapping is inferred from field names/types by default (e.g. `shortCode` -> a
// `short_code` column) - @Table/@Column below only override that default where needed.
@Entity
@Table(name = "url_mapping", indexes = @Index(name = "idx_short_code", columnList = "shortCode", unique = true))
// Serializable so Redis can store this object as cached bytes (see UrlShortenerService's
// @Cacheable resolve() method) - without it, caching an UrlMapping would throw at runtime.
public class UrlMapping implements Serializable {

    // @Id marks the primary key. @GeneratedValue(IDENTITY) means "let the database assign
    // this" (Postgres auto-increments it) - we never set `id` ourselves anywhere in the code.
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, unique = true, length = 10)
    private String shortCode;

    @Column(nullable = false, length = 2048)
    private String originalUrl;

    @Column(nullable = false)
    private Instant createdAt;

    // JPA requires a no-args constructor (it builds objects via reflection, then fills in
    // fields itself when loading rows from the database) - `protected` keeps it out of reach
    // of everyday application code, which should always use the constructor below instead.
    protected UrlMapping() {
    }

    public UrlMapping(String shortCode, String originalUrl) {
        this.shortCode = shortCode;
        this.originalUrl = originalUrl;
        this.createdAt = Instant.now();
    }

    public Long getId() {
        return id;
    }

    public String getShortCode() {
        return shortCode;
    }

    public String getOriginalUrl() {
        return originalUrl;
    }

    public Instant getCreatedAt() {
        return createdAt;
    }
}
