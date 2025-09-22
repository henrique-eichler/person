package com.henrique.person.controller;

import com.henrique.person.model.dto.PersonDto;
import com.henrique.person.service.PersonService;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.net.URI;
import java.util.List;

/**
 * REST controller exposing operations over People.
 */
@RestController
@RequestMapping("/v1/person")
public class PersonController {

    private final PersonService service;

    public PersonController(PersonService service) {
        this.service = service;
    }

    @PostMapping
    public ResponseEntity<PersonDto> create(@RequestBody PersonDto dto) {
        PersonDto created = service.create(dto);
        return ResponseEntity.created(URI.create("/v1/person/" + created.getId())).body(created);
    }

    @PutMapping("/{id}")
    public ResponseEntity<PersonDto> update(@PathVariable("id") Long id, @RequestBody PersonDto dto) {
        dto.setId(id);
        PersonDto updated = service.update(dto);
        return ResponseEntity.ok(updated);
    }

    @GetMapping("/{id}")
    public ResponseEntity<PersonDto> getById(@PathVariable("id") Long id) {
        return service.getById(id)
                .map(ResponseEntity::ok)
                .orElse(ResponseEntity.notFound().build());
    }

    @GetMapping
    public ResponseEntity<List<PersonDto>> getAll() {
        return ResponseEntity.ok(service.getAll());
    }

    @DeleteMapping("/{id}")
    public ResponseEntity<Void> delete(@PathVariable("id") Long id) {
        service.delete(id);
        return ResponseEntity.noContent().build();
    }

    @GetMapping("/count")
    public ResponseEntity<Long> count() {
        return ResponseEntity.ok(service.count());
    }
}
