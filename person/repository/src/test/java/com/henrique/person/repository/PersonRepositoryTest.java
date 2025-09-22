package com.henrique.person.repository;

import com.henrique.person.model.entity.Person;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;

import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

@DataJpaTest
class PersonRepositoryTest {

    @Autowired
    private PersonRepository repository;

    @Test
    void save_find_delete_flow() {
        Person saved = repository.save(new Person(null, "Test", 22));
        assertThat(saved.getId()).isNotNull();

        Optional<Person> found = repository.findById(saved.getId());
        assertThat(found).isPresent();
        assertThat(found.get().getName()).isEqualTo("Test");

        long countBefore = repository.count();
        repository.deleteById(saved.getId());
        assertThat(repository.count()).isEqualTo(countBefore - 1);
        assertThat(repository.findById(saved.getId())).isEmpty();
    }
}
