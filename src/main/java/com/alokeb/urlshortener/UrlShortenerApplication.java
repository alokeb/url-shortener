package com.alokeb.urlshortener;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.cache.annotation.EnableCaching;

// @SpringBootApplication is shorthand for three annotations stacked together:
//   @Configuration     - this class can define beans
//   @EnableAutoConfiguration - Spring Boot guesses sensible config from what's on the
//                         classpath (e.g. seeing Postgres + JPA here means it wires up a
//                         DataSource and EntityManager automatically, no XML/manual setup)
//   @ComponentScan     - scan this package and sub-packages for @Component/@Service/
//                         @Repository/@Controller classes and register them as beans
@SpringBootApplication
// Turns on support for @Cacheable/@CacheEvict elsewhere in the app (see
// UrlShortenerService.resolve()). Without this, those annotations are silently ignored.
@EnableCaching
public class UrlShortenerApplication {

	// Entry point: a plain Java main() method, just like any other Java program. This one
	// line boots the whole application - starts the embedded Tomcat server, creates the
	// Spring container ("ApplicationContext"), and wires all the beans together.
	public static void main(String[] args) {
		SpringApplication.run(UrlShortenerApplication.class, args);
	}

}
