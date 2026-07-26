package com.alokeb.urlshortener.web;

// Another record (see ShortenRequest for what that gives you for free). Returned from a
// controller method, Jackson serializes this straight into a JSON response body -
// {"shortCode": "...", "shortUrl": "..."} - again with no manual mapping code needed.
public record ShortenResponse(String shortCode, String shortUrl) {
}
