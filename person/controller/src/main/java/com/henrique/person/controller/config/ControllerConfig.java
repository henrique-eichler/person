package com.henrique.person.controller.config;

import com.henrique.person.controller.PersonController;
import com.henrique.person.service.config.ServiceConfig;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Import;

@Configuration
@ComponentScan(basePackageClasses = PersonController.class)
@Import(ServiceConfig.class)
public class ControllerConfig {
}
