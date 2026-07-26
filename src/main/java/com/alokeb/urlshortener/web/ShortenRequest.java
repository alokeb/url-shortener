package com.alokeb.urlshortener.web;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;

// A Java `record` - a compact way to declare an immutable data-holder class. This one line
// generates a constructor, getters (url(), not getUrl() - records use the field name itself
// as the accessor), equals()/hashCode()/toString(), all without writing them by hand.
// Jackson (Spring Boot's default JSON library) deserializes incoming JSON request bodies
// straight into records like this one - see UrlShortenerController's shorten() method,
// where @RequestBody triggers exactly that conversion before the method even runs.
public record ShortenRequest(
        // These annotations don't validate anything by themselves - they're metadata that
        // Spring's validation framework reads when @Valid is present on a method parameter
        // (see the controller). @NotBlank rejects null/empty/whitespace-only; @Pattern checks
        // the value against a regex. A failing request never reaches the controller method
        // body at all - Spring returns a 400 response automatically before that point.
        @NotBlank
        @Pattern(regexp = "^https?://.+", message = "must be a valid http/https URL")
        String url
) {
}
