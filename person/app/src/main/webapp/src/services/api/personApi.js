const headers = {
  'Content-Type': 'application/json',
};

const base = '/v1/person';

export async function listPersons() {
  const res = await fetch(base);
  if (!res.ok) throw new Error('Failed to fetch persons');
  return res.json();
}

export async function getPerson(id) {
  const res = await fetch(`${base}/${id}`);
  if (!res.ok) throw new Error('Failed to fetch person');
  return res.json();
}

export async function createPerson(person) {
  const res = await fetch(base, {
    method: 'POST',
    headers,
    body: JSON.stringify(person),
  });
  if (!res.ok) throw new Error('Failed to create person');
  return res.json();
}

export async function updatePerson(id, person) {
  const res = await fetch(`${base}/${id}`, {
    method: 'PUT',
    headers,
    body: JSON.stringify(person),
  });
  if (!res.ok) throw new Error('Failed to update person');
  return res.json();
}

export async function deletePerson(id) {
  const res = await fetch(`${base}/${id}`, {
    method: 'DELETE',
  });
  if (!res.ok) throw new Error('Failed to delete person');
}
