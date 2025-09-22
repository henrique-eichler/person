package com.henrique.person.service;

import com.henrique.person.model.dto.PersonDto;
import com.henrique.person.model.entity.Person;
import com.henrique.person.repository.PersonRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.Mockito;

import java.util.Arrays;
import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

class PersonServiceTest {

    private PersonRepository repository;
    private PersonService service;

    @BeforeEach
    void setUp() {
        repository = Mockito.mock(PersonRepository.class);
        service = new PersonService(repository);
    }

    @Test
    void create_shouldSaveAndReturnDto() {
        when(repository.save(any(Person.class))).thenAnswer(invocation -> {
            Person p = invocation.getArgument(0);
            return new Person(1L, p.getName(), p.getAge());
        });

        PersonDto created = service.create(new PersonDto(null, "Alice", 30));
        assertThat(created.getId()).isEqualTo(1L);
        assertThat(created.getName()).isEqualTo("Alice");
        assertThat(created.getAge()).isEqualTo(30);

        ArgumentCaptor<Person> captor = ArgumentCaptor.forClass(Person.class);
        verify(repository).save(captor.capture());
        assertThat(captor.getValue().getId()).isNull();
        assertThat(captor.getValue().getName()).isEqualTo("Alice");
    }

    @Test
    void update_shouldSaveWithGivenId() {
        when(repository.save(any(Person.class))).thenAnswer(invocation -> invocation.getArgument(0));
        PersonDto updated = service.update(new PersonDto(2L, "Bob", 40));
        assertThat(updated.getId()).isEqualTo(2L);
        assertThat(updated.getName()).isEqualTo("Bob");
        verify(repository).save(any(Person.class));
    }

    @Test
    void delete_byDto_shouldDelegate() {
        service.delete(new PersonDto(3L, "Carol", 20));
        verify(repository).delete(any(Person.class));
    }

    @Test
    void getById_shouldMapToDto() {
        when(repository.findById(10L)).thenReturn(Optional.of(new Person(10L, "Dan", 50)));
        Optional<PersonDto> dto = service.getById(10L);
        assertThat(dto).isPresent();
        assertThat(dto.get().getName()).isEqualTo("Dan");
    }

    @Test
    void getAll_shouldReturnListOfDtos() {
        when(repository.findAll()).thenReturn(Arrays.asList(
                new Person(1L, "A", 10), new Person(2L, "B", 20)
        ));
        List<PersonDto> all = service.getAll();
        assertThat(all).hasSize(2);
        assertThat(all.get(0).getName()).isEqualTo("A");
    }

    @Test
    void delete_byId_shouldDelegate() {
        service.delete(99L);
        verify(repository).deleteById(99L);
    }

    @Test
    void count_shouldDelegate() {
        when(repository.count()).thenReturn(123L);
        assertThat(service.count()).isEqualTo(123L);
    }
}
