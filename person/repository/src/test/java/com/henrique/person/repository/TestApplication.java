package com.henrique.person.repository;

import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.autoconfigure.domain.EntityScan;

@SpringBootApplication(scanBasePackages = "com.henrique.person")
@EntityScan(basePackages = "com.henrique.person.model.entity")
public class TestApplication {
}
