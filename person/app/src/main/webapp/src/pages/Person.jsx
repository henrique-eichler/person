import { useEffect, useMemo, useState } from 'react'
import { createPerson, deletePerson, listPersons, updatePerson } from '../api/personApi'

export default function PersonPage() {
  const [people, setPeople] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  // Modal state
  const [showModal, setShowModal] = useState(false)
  const [modalMode, setModalMode] = useState('create') // 'create' | 'edit'
  const [modalData, setModalData] = useState({ id: null, name: '', age: '' })
  const [modalError, setModalError] = useState(null)
  const [modalSaving, setModalSaving] = useState(false)

  async function refresh() {
    setLoading(true)
    setError(null)
    try {
      const data = await listPersons()
      setPeople(data)
    } catch (e) {
      setError(e.message || 'Error loading data')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    refresh()
  }, [])

  function openCreateModal() {
    setModalMode('create')
    setModalData({ id: null, name: '', age: '' })
    setModalError(null)
    setShowModal(true)
  }

  function openEditModal(person) {
    setModalMode('edit')
    setModalData({ id: person.id, name: person.name, age: String(person.age) })
    setModalError(null)
    setShowModal(true)
  }

  function closeModal() {
    if (modalSaving) return
    setShowModal(false)
    setModalError(null)
  }

  async function saveModal() {
    setModalError(null)
    const name = modalData.name.trim()
    const ageNum = Number(modalData.age)
    if (!name || isNaN(ageNum)) {
      setModalError('Please provide a valid name and age')
      return
    }
    try {
      setModalSaving(true)
      if (modalMode === 'create') {
        await createPerson({ name, age: ageNum })
      } else {
        await updatePerson(modalData.id, { id: modalData.id, name, age: ageNum })
      }
      setShowModal(false)
      await refresh()
    } catch (e) {
      setModalError(e.message || 'Operation failed')
    } finally {
      setModalSaving(false)
    }
  }

  async function handleDelete(id) {
    setError(null)
    try {
      await deletePerson(id)
      await refresh()
    } catch (e) {
      setError(e.message)
    }
  }

  const total = useMemo(() => people.length, [people])

  return (
    <div className="container">
      <div className="d-flex align-items-end justify-content-between mb-2">
        <div>
          <h2 className="mb-1">Person</h2>
          <p className="text-body-secondary mb-0">Manage the person records from the backend API.</p>
        </div>
        <div>
          <button className="btn btn-primary" onClick={openCreateModal}>New Person</button>
        </div>
      </div>

      {error && <div className="alert alert-danger py-2" role="alert">{error}</div>}
      {loading ? (
        <div className="d-flex align-items-center gap-2"><div className="spinner-border spinner-border-sm" role="status" aria-hidden="true"></div> Loading...</div>
      ) : (
        <>
          <div className="mb-2">Total: {total}</div>
          <div className="table-responsive">
            <table className="table table-sm table-striped align-middle">
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Name</th>
                  <th>Age</th>
                  <th className="text-nowrap" style={{ width: 1 }}>Actions</th>
                </tr>
              </thead>
              <tbody>
                {people.map(p => (
                  <PersonRow
                    key={p.id}
                    person={p}
                    onEdit={() => openEditModal(p)}
                    onDelete={() => handleDelete(p.id)}
                  />
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}

      {showModal && (
        <PersonEditModal
          show={showModal}
          mode={modalMode}
          data={modalData}
          error={modalError}
          saving={modalSaving}
          onClose={closeModal}
          onSave={saveModal}
          onChange={setModalData}
        />
      )}
    </div>
  )
}

function PersonRow({ person, onEdit, onDelete }) {
  return (
    <tr>
      <td>{person.id}</td>
      <td>{person.name}</td>
      <td>{person.age}</td>
      <td className="text-nowrap" style={{ width: 1 }}>
        <div className="btn-group btn-group-sm" role="group" aria-label="Actions">
          <button className="btn btn-outline-primary" onClick={onEdit}>Edit</button>
          <button className="btn btn-outline-danger" onClick={onDelete}>Delete</button>
        </div>
      </td>
    </tr>
  )
}

function PersonEditModal({ show, mode, data, error, saving, onClose, onSave, onChange }) {
  if (!show) return null
  return (
    <>
      <div className="modal d-block" tabIndex="-1" role="dialog" aria-modal="true">
        <div className="modal-dialog modal-lg">
          <div className="modal-content">
            <div className="modal-header">
              <h5 className="modal-title" id="personModalLabel">{mode === 'create' ? 'New Person' : `Edit Person #${data.id}`}</h5>
              <button type="button" className="btn-close" aria-label="Close" onClick={onClose} disabled={saving}></button>
            </div>
            <div className="modal-body">
              {error && <div className="alert alert-danger py-2" role="alert">{error}</div>}
              <div className="mb-3">
                <label className="form-label" htmlFor="personName">Name</label>
                <input id="personName" className="form-control" value={data.name} onChange={e => onChange({ ...data, name: e.target.value })} placeholder="Name" disabled={saving} />
              </div>
              <div className="mb-2">
                <label className="form-label" htmlFor="personAge">Age</label>
                <input id="personAge" className="form-control" value={data.age} onChange={e => onChange({ ...data, age: e.target.value.replace(/[^0-9]/g, '') })} placeholder="Age" disabled={saving} />
              </div>
            </div>
            <div className="modal-footer">
              <button type="button" className="btn btn-secondary" onClick={onClose} disabled={saving}>Cancel</button>
              <button type="button" className="btn btn-primary" onClick={onSave} disabled={saving}>
                {saving ? 'Saving...' : 'Save'}
              </button>
            </div>
          </div>
        </div>
      </div>
      <div className="modal-backdrop show"></div>
    </>
  )
}
