package com.henrique.person.repository.config;

import com.henrique.person.repository.PersonRepository;
import org.springframework.boot.autoconfigure.domain.EntityScan;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.PropertySource;
import org.springframework.data.jpa.repository.config.EnableJpaRepositories;

@Configuration
@PropertySource("classpath:repository.properties")
@ComponentScan(basePackageClasses = PersonRepository.class)
@EntityScan(basePackages = "com.henrique.person.model.entity")
@EnableJpaRepositories(basePackages = "com.henrique.person.repository")
public class RepositoryConfig {
}
