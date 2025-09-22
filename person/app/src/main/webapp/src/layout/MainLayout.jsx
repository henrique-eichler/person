import { NavLink, Outlet, useNavigate } from 'react-router-dom'

export default function MainLayout() {
  const navigate = useNavigate()

  return (
    <div className="min-vh-100 d-flex flex-column">
      <nav className="navbar navbar-expand-lg bg-body-tertiary border-bottom">
        <div className="container-fluid">
          <span className="navbar-brand fw-bold">Person App</span>
          <button className="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarNav" aria-controls="navbarNav" aria-expanded="false" aria-label="Toggle navigation">
            <span className="navbar-toggler-icon"></span>
          </button>
          <div className="collapse navbar-collapse" id="navbarNav">
            <ul className="navbar-nav me-auto">
              <li className="nav-item">
                <NavLink to="/person" className={({ isActive }) => `nav-link ${isActive ? 'active' : ''}`}>Person</NavLink>
              </li>
            </ul>
            <div className="d-flex">
              <button className="btn btn-outline-secondary" onClick={() => navigate('/login')}>Logout</button>
            </div>
          </div>
        </div>
      </nav>
      <div className="container-fluid flex-grow-1">
        <div className="row">
          <aside className="col-12 col-md-3 col-lg-2 border-end py-3">
            <ul className="nav flex-column gap-1">
              <li className="nav-item">
                <NavLink to="/person" className={({ isActive }) => `nav-link ${isActive ? 'active' : ''}`}>Person</NavLink>
              </li>
            </ul>
          </aside>
          <main className="col py-3">
            <Outlet />
          </main>
        </div>
      </div>
    </div>
  )
}
