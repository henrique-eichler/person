import { useNavigate } from 'react-router-dom'

export default function Login() {
  const navigate = useNavigate()

  function handleLogin(e) {
    e.preventDefault()
    // No auth, just navigate to the main page
    navigate('/')
  }

  return (
    <div className="container min-vh-100 d-flex align-items-center justify-content-center py-5">
      <div className="row justify-content-center w-100">
        <div className="col-12 col-sm-10 col-md-8 col-lg-5 col-xl-4">
          <div className="card shadow-sm">
            <div className="card-body">
              <h2 className="card-title h4 mb-4">Login</h2>
              <form onSubmit={handleLogin} className="d-grid gap-3">
                <div>
                  <label htmlFor="username" className="form-label">Username</label>
                  <input id="username" type="text" name="username" placeholder="Type anything" className="form-control" />
                </div>
                <div>
                  <label htmlFor="password" className="form-label">Password</label>
                  <input id="password" type="password" name="password" placeholder="Type anything" className="form-control" />
                </div>
                <button type="submit" className="btn btn-primary">Login</button>
              </form>
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}
