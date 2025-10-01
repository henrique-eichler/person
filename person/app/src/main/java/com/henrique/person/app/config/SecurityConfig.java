package com.henrique.person.app.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.oauth2.client.oidc.web.logout.OidcClientInitiatedLogoutSuccessHandler;
import org.springframework.security.oauth2.client.registration.ClientRegistrationRepository;
import org.springframework.security.web.SecurityFilterChain;

import java.net.URI;

@Configuration
@EnableWebSecurity
@EnableMethodSecurity
public class SecurityConfig {

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        http
            .csrf(csrf -> csrf.disable())
            .authorizeHttpRequests(auth -> auth
                // permit static assets and SPA entry points
                .requestMatchers(
                        "/assets/**",
                        "/index.html",
                        "/person.svg",
                        "/",
                        "/login",
                        "/error"
                ).permitAll()
                // actuator can be protected or partially open; here open info/health
                .requestMatchers("/actuator/health/**", "/actuator/info").permitAll()
                // API requires auth
                .requestMatchers("/v1/**").authenticated()
                // everything else requires authentication
                .anyRequest().authenticated()
            )
            // OAuth2 Login (OIDC)
            .oauth2Login(oauth2 -> oauth2
                .loginPage("/login")
                .defaultSuccessUrl("/", true)
            )
            // Resource server for JWT bearer tokens (e.g., API calls)
            .oauth2ResourceServer(oauth2 -> oauth2.jwt(Customizer.withDefaults()))
            .sessionManagement(sm -> sm.sessionCreationPolicy(SessionCreationPolicy.IF_REQUIRED))
            // Logout via OIDC end-session if available
            .logout(logout -> logout
                .logoutSuccessUrl("/")
            );

        return http.build();
    }

    // Optional helper for OIDC RP-initiated logout (Keycloak support). Not strictly required unless you want id_token_hint.
    @Bean
    public OidcClientInitiatedLogoutSuccessHandler oidcLogoutSuccessHandler(ClientRegistrationRepository clientRegistrationRepository) {
        OidcClientInitiatedLogoutSuccessHandler handler = new OidcClientInitiatedLogoutSuccessHandler(clientRegistrationRepository);
        handler.setPostLogoutRedirectUri(URI.create("/").toString());
        return handler;
    }
}