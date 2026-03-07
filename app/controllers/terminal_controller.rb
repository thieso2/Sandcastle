class TerminalController < ApplicationController
  layout "terminal", only: :show

  allow_unauthenticated_access only: :auth
  skip_before_action :require_password_change, only: :auth
  skip_forgery_protection only: :open

  def open
    sandbox = find_sandbox
    type    = params[:type].presence_in(%w[tmux shell]) || "tmux"
    TerminalManager.new.open(sandbox: sandbox, type: type)
    redirect_to terminal_show_path(sandbox, type), status: :see_other
  rescue TerminalManager::Error => e
    redirect_to root_path, alert: e.message
  end

  def show
    @sandbox = find_sandbox
    @emulator = Current.user.terminal_emulator || "xterm"
    type = params[:type].presence_in(%w[tmux shell]) || "tmux"

    terminal_base = ENV["SANDCASTLE_TERMINAL_URL"].presence
    if terminal_base
      # SANDCASTLE_TERMINAL_URL is a full URL (e.g. https://dev.sand:8443)
      uri = URI.parse(terminal_base)
      ws_proto = uri.scheme == "https" ? "wss" : "ws"
      @ws_url    = "#{ws_proto}://#{uri.host}:#{uri.port}/terminal/#{@sandbox.id}/#{type}/ws"
      @token_url = "#{uri.scheme}://#{uri.host}:#{uri.port}/terminal/#{@sandbox.id}/#{type}/token"
    else
      proto = request.ssl? ? "wss:" : "ws:"
      host  = request.host_with_port
      @ws_url    = "#{proto}//#{host}/terminal/#{@sandbox.id}/#{type}/ws"
      @token_url = "#{request.protocol}#{host}/terminal/#{@sandbox.id}/#{type}/token"
    end
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
    scope = Current.user.admin? ? Sandbox.active : Current.user.sandboxes.active
    scope.find(params[:id])
  end

  public

  # Called by Traefik forwardAuth. Returns 200 to allow, or redirects to
  # login (which Traefik passes through to the browser).
  def auth
    forwarded_uri = request.headers["X-Forwarded-Uri"] || ""
    match = forwarded_uri.match(%r{/terminal/(\d+)/(tmux|shell)})
    head(:unauthorized) and return unless match

    session_record = find_session_by_cookie
    unless session_record
      proto = request.headers["X-Forwarded-Proto"] || "https"
      host  = request.headers["X-Forwarded-Host"] || request.host_with_port
      original_url = "#{proto}://#{host}#{forwarded_uri}"
      session[:return_to_after_authenticating] = original_url
      redirect_to new_session_url, allow_other_host: true
      return
    end

    user    = session_record.user
    sandbox = Sandbox.active.find_by(id: match[1].to_i)
    head(:unauthorized) and return unless sandbox && (sandbox.user_id == user.id || user.admin?)

    head :ok
  end
end
