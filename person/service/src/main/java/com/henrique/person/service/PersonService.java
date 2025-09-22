package com.henrique.person.service;

import com.henrique.person.model.dto.PersonDto;
import com.henrique.person.model.entity.Person;
import com.henrique.person.repository.PersonRepository;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

@Service
public class PersonService {

    private final PersonRepository repository;

    public PersonService(PersonRepository repository) {
        this.repository = repository;
    }

    public PersonDto create(PersonDto dto) {
        Person saved = repository.save(PersonDto.toEntity(dto));
        return PersonDto.fromEntity(saved);
    }

    public PersonDto update(PersonDto dto) {
        Person saved = repository.save(PersonDto.toEntity(dto));
        return PersonDto.fromEntity(saved);
    }

    public void delete(PersonDto dto) {
        repository.delete(PersonDto.toEntity(dto));
    }

    public Optional<PersonDto> getById(Long id) {
        return repository.findById(id).map(PersonDto::fromEntity);
    }

    public List<PersonDto> getAll() {
        List<PersonDto> dtos = new ArrayList<>();
        for (Person person : repository.findAll()) {
            dtos.add(PersonDto.fromEntity(person));
        }
        return dtos;
    }

    public void delete(Long id) {
        repository.deleteById(id);
    }

    public long count() {
        return repository.count();
    }
}