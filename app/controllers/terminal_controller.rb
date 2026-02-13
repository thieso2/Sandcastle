class TerminalController < ApplicationController
  allow_unauthenticated_access only: :auth
  skip_before_action :require_password_change, only: :auth

  def open
    sandbox = find_sandbox

    TerminalManager.new.open(sandbox: sandbox)
    redirect_to terminal_wait_sandbox_path(sandbox), status: :see_other
  rescue TerminalManager::Error => e
    redirect_to root_path, alert: e.message
  end

  def wait
    @sandbox = find_sandbox
    @terminal_url = terminal_redirect_url("/terminal/#{@sandbox.id}/wetty")
  end

  def status
    sandbox = find_sandbox
    ready = TerminalManager.new.active?(sandbox: sandbox)
    render json: { status: ready ? "ready" : "waiting" }
  end

  def close
    sandbox = find_sandbox

    TerminalManager.new.close(sandbox: sandbox)
    redirect_to root_path, notice: "Terminal closed"
  rescue TerminalManager::Error => e
    redirect_to root_path, alert: e.message
  end

  private

  def find_sandbox
    if Current.user.admin?
      Sandbox.active.find(params[:id])
    else
      Current.user.sandboxes.active.find(params[:id])
    end
  end

  # Build the full terminal URL. In production, Traefik is the entry point
  # so a relative path works. In local dev (selfsigned TLS), Rails may be
  # accessed directly on a different port, so we need an absolute URL.
  def terminal_redirect_url(path)
    base = ENV["SANDCASTLE_TERMINAL_URL"]
    base ? "#{base}#{path}" : path
  end

  public

  # Called by Traefik forwardAuth. Returns 200 to allow, or redirects to
  # login (which Traefik passes through to the browser).
  def auth
    forwarded_uri = request.headers["X-Forwarded-Uri"] || ""
    match = forwarded_uri.match(%r{/terminal/(\d+)/wetty})
    head(:unauthorized) and return unless match

    session_record = find_session_by_cookie
    unless session_record
      # Build the original terminal URL from Traefik's forwarded headers
      # so the user returns here after logging in.
      proto = request.headers["X-Forwarded-Proto"] || "https"
      host  = request.headers["X-Forwarded-Host"] || request.host_with_port
      original_url = "#{proto}://#{host}#{forwarded_uri}"
      session[:return_to_after_authenticating] = original_url
      redirect_to new_session_url, allow_other_host: true
      return
    end

    user = session_record.user
    sandbox = Sandbox.active.find_by(id: match[1].to_i)
    head(:unauthorized) and return unless sandbox && (sandbox.user_id == user.id || user.admin?)

    head :ok
  end
end
