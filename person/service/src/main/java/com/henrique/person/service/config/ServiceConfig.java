package com.henrique.person.service.config;

import com.henrique.person.repository.config.RepositoryConfig;
import com.henrique.person.service.PersonService;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Import;

@Configuration
@ComponentScan(basePackageClasses = PersonService.class)
@Import(RepositoryConfig.class)
public class ServiceConfig {
}