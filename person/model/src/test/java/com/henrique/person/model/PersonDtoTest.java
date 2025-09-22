package com.henrique.person.model;

import com.henrique.person.model.dto.PersonDto;
import com.henrique.person.model.entity.Person;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class PersonDtoTest {

    @Test
    void toEntity_and_fromEntity_shouldConvertCorrectly() {
        PersonDto dto = new PersonDto(1L, "Alice", 30);

        Person entity = PersonDto.toEntity(dto);
        assertThat(entity.getId()).isEqualTo(1L);
        assertThat(entity.getName()).isEqualTo("Alice");
        assertThat(entity.getAge()).isEqualTo(30);

        PersonDto roundTrip = PersonDto.fromEntity(entity);
        assertThat(roundTrip.getId()).isEqualTo(1L);
        assertThat(roundTrip.getName()).isEqualTo("Alice");
        assertThat(roundTrip.getAge()).isEqualTo(30);
    }
}
