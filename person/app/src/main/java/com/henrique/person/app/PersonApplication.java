package com.henrique.person.app;

import com.henrique.person.app.config.SecurityConfig;
import com.henrique.person.controller.config.ControllerConfig;
import com.henrique.person.service.config.WebSocketConfig;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Import;

@SpringBootApplication(scanBasePackages = "com.henrique.person")
@Import({ControllerConfig.class, WebSocketConfig.class, SecurityConfig.class})
public class PersonApplication {
    public static void main(String[] args) {
        SpringApplication.run(PersonApplication.class, args);
    }
}
