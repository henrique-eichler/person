package com.henrique.person.app.web;

import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.GetMapping;

/**
 * Minimal SPA forwarder: serves the React app for client-side routes so that direct navigation
 * (e.g., hitting /person directly or hard-refresh) does not result in a 404 from Spring.
 *
 * We only forward known app routes to avoid interfering with API endpoints (/v1/**) and static assets.
 */
@Controller
public class SpaForwardController {

    @GetMapping({"/person", "/login", "/"})
    public String forwardToIndex() {
        // Forward to the static index.html under classpath:/static/index.html
        return "forward:/index.html";
    }
}
