export default function Login() {
  function handleLogin(e) {
    e.preventDefault()
    // Redirect to Spring Security's OAuth2 login for Keycloak
    window.location.href = '/oauth2/authorization/keycloak'
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
                <button type="submit" className="btn btn-primary">Login with Keycloak</button>
              </form>
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}
