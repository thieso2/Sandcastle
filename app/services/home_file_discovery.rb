class HomeFileDiscovery
  class Error < StandardError; end

  PREFIX_IGNORE = %w[
    .cache/
    .npm/_cacache/
    .npm/_logs/
    .local/share/Trash/
    .local/share/mise/
    .vscode-server/
    .config/configstore/
    node_modules/
  ].freeze

  EXACT_IGNORE = %w[
    .bash_history
    .zsh_history
    .lesshst
    .python_history
    .node_repl_history
    .Xauthority
    .ssh/known_hosts
    .gnupg/random_seed
    .DS_Store
    .viminfo
  ].freeze

  SUGGESTIONS = [
    [ %r{\A\.claude/},          "bind",   "Claude rewrites credentials on token refresh" ],
    [ %r{\A\.codex/},           "bind",   "Codex rewrites credentials on token refresh" ],
    [ %r{\A\.config/gh/},       "bind",   "gh rewrites tokens on refresh" ],
    [ %r{\A\.aws/sso/},         "bind",   "AWS SSO rewrites tokens hourly" ],
    [ %r{\A\.config/gcloud/},   "bind",   "gcloud rewrites tokens" ],
    [ %r{\A\.kube/},            "bind",   "kubectl exec plugins rewrite tokens" ],
    [ %r{\A\.gitconfig\z},      "inject", "static config" ],
    [ %r{\A\.npmrc\z},          "inject", "static token" ],
    [ %r{\A\.aws/credentials\z}, "inject", "static credentials" ],
    [ %r{\A\.vimrc\z},          "inject", "dotfile" ],
    [ %r{\A\.tmux\.conf\z},     "inject", "dotfile" ],
    [ %r{\A\.zshrc\z},          "inject", "dotfile" ],
    [ %r{\A\.bashrc\z},         "inject", "dotfile" ]
  ].freeze

  def initialize(sandbox)
    @sandbox = sandbox
    @user = sandbox.user
  end

  def call
    return [] if @sandbox.container_id.blank?

    container = Docker::Container.get(@sandbox.container_id)
    raw = run_diff(container)
    paths = raw.lines.map(&:chomp).reject(&:blank?)
    ignored = @user.ignored_paths.pluck(:path).to_set

    paths
      .reject { |p| ignored?(p, ignored) }
      .map { |p| classify(p) }
  rescue Docker::Error::NotFoundError
    []
  end

  def fetch_content(path)
    return nil if @sandbox.container_id.blank?
    container = Docker::Container.get(@sandbox.container_id)
    out = container.exec([
      "bash", "-c",
      "cat \"/home/$1/$2\" 2>/dev/null",
      "_", @user.name, path
    ])
    extract_stdout(out)
  rescue Docker::Error::NotFoundError
    nil
  end

  private

  def run_diff(container)
    script = <<~SH
      baseline="#{SandboxManager::HOME_BASELINE_PATH}"
      if [ ! -f "$baseline" ]; then exit 0; fi
      find /home/"$1" -xdev -type f -printf '%P\\n' 2>/dev/null | sort | comm -23 - "$baseline"
    SH
    out = container.exec([ "bash", "-c", script, "_", @user.name ])
    extract_stdout(out)
  end

  def extract_stdout(out)
    case out
    when Array
      first = out[0]
      first.is_a?(Array) ? first.join : first.to_s
    else
      out.to_s
    end
  end

  def ignored?(path, ignored_set)
    return true if ignored_set.include?(path)
    return true if EXACT_IGNORE.include?(path)
    PREFIX_IGNORE.any? { |pre| path.start_with?(pre) }
  end

  def classify(path)
    SUGGESTIONS.each do |regex, action, reason|
      return { path: path, suggested: action, reason: reason } if path.match?(regex)
    end
    { path: path, suggested: "ignore", reason: "no rule matched — pick the right action manually" }
  end
end
