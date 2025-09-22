# Person (Multi-Module Java/Spring Boot Project)

Last updated: 2025-09-15 11:18

## Overview
Person is a multi-module Gradle project that exposes a simple REST API to manage people. It is built with Spring Boot and uses a layered architecture: controller, service, and repository. By default, the repository is in-memory, so you can run and test the API without a database.

### Modules
- app: Spring Boot application entry point and configuration.
- controller: REST controller exposing the HTTP API.
- service: Business logic and DTO/entity mapping.
- repository: In-memory data store for Person entities.
- model: DTOs and domain entity definitions.

## Requirements
- Java 17
- Gradle Wrapper (included). Use ./gradlew on Unix/macOS or gradlew.bat on Windows.

## Build
- Full build (all modules):
  - Unix/macOS: ./gradlew build
  - Windows: gradlew.bat build
- Run unit tests only:
  - ./gradlew test

## Run the Web API (Spring Boot)
Entry point: com.henrique.person.app.PersonApplication

- Start the app:
  - ./gradlew :app:bootRun
  - By default, the server runs on http://localhost:8080

- Build a runnable jar:
  - ./gradlew :app:bootJar
  - java -jar app/build/libs/app-<version>.jar

Note: The repository is in-memory; no database is required to exercise the API. You can still provide database-related environment variables for future integration.

## REST API Endpoints
Base path: /v1/person

- Create
  - POST /v1/person
  - Body: {"name": "Alice", "age": 25}
  - Response: 201 Created with the created Person JSON and Location header

- Get by ID
  - GET /v1/person/{id}
  - Response: 200 OK with Person JSON, or 404 if not found

- List all
  - GET /v1/person
  - Response: 200 OK with JSON array of Person

- Update
  - PUT /v1/person/{id}
  - Body: {"name": "Alice", "age": 26}
  - Response: 200 OK with updated Person JSON

- Delete
  - DELETE /v1/person/{id}
  - Response: 204 No Content

- Count
  - GET /v1/person/count
  - Response: 200 OK with a number (long)

Example curl commands:
- Create: curl -i -X POST http://localhost:8080/v1/person -H "Content-Type: application/json" -d '{"name":"Alice","age":25}'
- List: curl -i http://localhost:8080/v1/person
- Get: curl -i http://localhost:8080/v1/person/1
- Update: curl -i -X PUT http://localhost:8080/v1/person/1 -H "Content-Type: application/json" -d '{"name":"Alice","age":26}'
- Delete: curl -i -X DELETE http://localhost:8080/v1/person/1
- Count: curl -i http://localhost:8080/v1/person/count

## Environment configuration (Database)
If you plan to connect this application to a PostgreSQL database, configure the following environment variables before starting the app:

PERSON_DATABASE_URL=jdbc:postgresql://postgres.infra.henrique.com:5432/persondb
PERSON_DATABASE_USERNAME=person
PERSON_DATABASE_PASSWORD=personpwd

How to set them:
- Linux/macOS (temporary for the current shell):
  - export PERSON_DATABASE_URL="jdbc:postgresql://postgres.infra.henrique.com:5432/persondb"
  - export PERSON_DATABASE_USERNAME="person"
  - export PERSON_DATABASE_PASSWORD="personpwd"
- Windows (PowerShell):
  - $env:PERSON_DATABASE_URL = "jdbc:postgresql://postgres.infra.henrique.com:5432/persondb"
  - $env:PERSON_DATABASE_USERNAME = "person"
  - $env:PERSON_DATABASE_PASSWORD = "personpwd"

Note: The application currently uses an in-memory repository. These variables are provided in advance to streamline future database integration and align with the properties found in app/src/main/resources/application.properties.

## Project Structure (abridged)
- app/
  - src/main/java/com/henrique/person/app/PersonApplication.java
  - src/main/resources/application.properties
- controller/src/main/java/com/henrique/person/controller/PersonController.java
- service/src/main/java/com/henrique/person/service/PersonService.java
- repository/src/main/java/com/henrique/person/repository/PersonRepository.java
- model/src/main/java/com/henrique/person/model/dto/PersonDto.java
- model/src/main/java/com/henrique/person/model/entity/Person.java

## Notes
- Spring Boot version and plugin versions are defined in Gradle files under app and buildSrc.
- Components are scanned under the base package com.henrique.person.
- CI/CD and server provisioning helper scripts are available under scripts/.

## CI/CD Support
This repository includes scripts to provision a self-hosted CI/CD toolchain under scripts/server:
- Jenkins, Gitea, Nexus, Nginx, Prometheus, Grafana, Redis, Rancher, Ollama, and more.
See scripts/server/README.md for details.

## License
Add your license information here.



