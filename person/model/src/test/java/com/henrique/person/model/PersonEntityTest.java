package com.henrique.person.model;

import com.henrique.person.model.entity.Person;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class PersonEntityTest {

    @Test
    void gettersSettersEqualsHashCodeToString() {
        Person p1 = new Person();
        p1.setId(1L);
        p1.setName("Bob");
        p1.setAge(40);

        Person p2 = new Person(1L, "Bob", 40);

        assertThat(p1.getId()).isEqualTo(1L);
        assertThat(p1.getName()).isEqualTo("Bob");
        assertThat(p1.getAge()).isEqualTo(40);

        // equals/hashCode based on id
        assertThat(p1).isEqualTo(p2);
        assertThat(p1.hashCode()).isEqualTo(p2.hashCode());

        assertThat(p1.toString()).contains("id=1").contains("name='Bob'").contains("age=40");
    }
}
