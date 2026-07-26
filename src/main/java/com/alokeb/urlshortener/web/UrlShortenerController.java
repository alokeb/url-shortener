package com.alokeb.urlshortener.web;

import com.alokeb.urlshortener.model.UrlMapping;
import com.alokeb.urlshortener.service.UrlShortenerService;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.servlet.support.ServletUriComponentsBuilder;

import java.net.URI;

// @RestController = @Controller + @ResponseBody. It marks this class as an HTTP endpoint
// handler AND tells Spring "whatever these methods return should be written directly into
// the HTTP response body (as JSON, via Jackson), not treated as a view/template name" - the
// distinction that plain @Controller requires you to specify per-method or not at all.
@RestController
public class UrlShortenerController {

    // Same constructor-injection pattern as UrlShortenerService: Spring supplies this
    // service bean automatically since it's requested here as a constructor parameter.
    private final UrlShortenerService service;

    public UrlShortenerController(UrlShortenerService service) {
        this.service = service;
    }

    // @PostMapping("/api/urls") routes HTTP POST requests to that exact path to this method.
    // @RequestBody deserializes the raw JSON request body into a ShortenRequest (see that
    // class - it's just a record, Jackson fills it in). @Valid tells Spring to run the
    // validation annotations declared on ShortenRequest's fields BEFORE this method body
    // runs; an invalid request never reaches the code below at all.
    @PostMapping("/api/urls")
    public ResponseEntity<ShortenResponse> shorten(@Valid @RequestBody ShortenRequest request) {
        UrlMapping mapping = service.shorten(request.url());

        // Builds an absolute URL (e.g. "http://localhost:8080/AbC1234") from whatever host/
        // port/context-path the CURRENT request actually came in on, rather than hardcoding
        // "localhost:8080" - so this works the same whether you're hitting it locally or
        // through whatever hostname it's deployed behind later.
        String shortUrl = ServletUriComponentsBuilder.fromCurrentContextPath()
                .path("/{code}")
                .buildAndExpand(mapping.getShortCode())
                .toUriString();

        // ResponseEntity gives full control over the HTTP response: status code, headers,
        // and body all at once. Returning just a ShortenResponse (or any plain object) would
        // default to 200 OK - wrapping it like this lets us send 201 Created instead, since
        // this request just created a new resource (the short URL).
        return ResponseEntity.status(HttpStatus.CREATED)
                .body(new ShortenResponse(mapping.getShortCode(), shortUrl));
    }

    // {shortCode:[A-Za-z0-9]{7}} is a path variable with a regex constraint built into the
    // route pattern itself: only match if that segment is exactly 7 letters/digits (what
    // UrlShortenerService actually generates). Without the regex, "/{shortCode}" would match
    // ANY single path segment - including things meant for other handlers entirely, like a
    // static file at "/tester.html". See the project's git history for exactly that bug.
    @GetMapping("/{shortCode:[A-Za-z0-9]{7}}")
    public ResponseEntity<Void> redirect(@PathVariable String shortCode) {
        return service.resolve(shortCode)
                // Optional.map(): if resolve() found a mapping, transform it into a 302
                // redirect response pointing at the original URL.
                .map(mapping -> ResponseEntity.status(HttpStatus.FOUND)
                        .location(URI.create(mapping.getOriginalUrl()))
                        .<Void>build())
                // Optional.orElse(): if resolve() came back empty (unknown short code),
                // fall through to a plain 404 instead.
                .orElse(ResponseEntity.notFound().build());
    }
}
